#!/usr/bin/env bats

# morning-radar wrapper (home/dot_claude/executable_morning-radar.sh, #257/#361).
# The wrapper is source-safe (side effects live in main() behind a BASH_SOURCE
# guard), so these tests both source it to exercise the pure helpers and run it
# end-to-end with claude + curl stubbed on PATH — no network, no server, CI-safe.
# Covers the osascript->ntfy migration (AC-002), fail-open delivery (AC-003),
# graceful degradation (AC-004), topic/priority split (AC-005), token hygiene
# incl. the permission-mode guard (AC-006), HTML rendering (raw-HTML escaping),
# the click URL, and the main() stamp wiring.

load helpers/setup

WRAPPER="${HOME_DIR}/dot_claude/executable_morning-radar.sh"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  cat >"${STUB_DIR}/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${NTFY_TEST_STUB_DIR}/curl_args"
cat >"${NTFY_TEST_STUB_DIR}/curl_stdin"
exit "${NTFY_TEST_CURL_EXIT:-0}"
EOF
  chmod +x "${STUB_DIR}/curl"

  ENV_FILE="${BATS_TEST_TMPDIR}/notify-env"
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
NTFY_TOPIC_ATTENTION='claude-attention'
NTFY_TOPIC_DONE='claude-done'
NTFY_TOPIC_BRIEF='claude-brief'
NTFY_BRIEF_BASE_URL='https://host.example.ts.net:8443'
EOF
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/morning-radar.log"
}

# Source the wrapper (main() is guarded, so nothing runs) and call one of its
# functions with the stubbed PATH and fixture env.
run_fn() {
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    NTFY_TEST_CURL_EXIT="${NTFY_TEST_CURL_EXIT:-0}" \
    MORNING_RADAR_NTFY_ENV_FILE="$ENV_FILE" \
    MORNING_RADAR_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; shift; fn="$1"; shift; "$fn" "$@"' _ "$WRAPPER" "$@"
}

@test "morning-radar.sh exists and passes bash -n" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "no osascript path remains anywhere in the wrapper (AC-002)" {
  ! grep -qE 'osascript|display notification' "$WRAPPER"
}

@test "token hygiene: no -H/--header Authorization, no set -x, token via -K (AC-006)" {
  ! grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  ! grep -qF 'set -x' "$WRAPPER"
  grep -qF 'curl -fs -K' "$WRAPPER"
}

@test "ntfy_publish brief -> claude-brief topic with click URL (AC-001/005)" {
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE: P1 2件" "https://host.example.ts.net:8443/2026-07-27.html"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-brief" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "HEADLINE: P1 2件" ]
  [ "$(jq -r .click <"${STUB_DIR}/curl_stdin")" = "https://host.example.ts.net:8443/2026-07-27.html" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
}

@test "ntfy_publish attention -> claude-attention topic, priority 5, no click (AC-005)" {
  run_fn ntfy_publish attention 5 "Morning Radar" "claude not found"
  [ "$status" -eq 0 ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
}

@test "empty click degrades to a link-less payload (AC-004)" {
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE only" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
}

@test "token never reaches curl argv (travels via -K config file) (AC-006)" {
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE" "https://host/x.html"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_args" ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -qE -- '-K' "${STUB_DIR}/curl_args"
}

@test "publish failure is fail-open: returns 0, token never logged (AC-003)" {
  NTFY_TEST_CURL_EXIT=1
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE" "https://host/x.html"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG_FILE" ] || ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

@test "no env file -> silent no-op, no publish" {
  ENV_FILE="${BATS_TEST_TMPDIR}/does-not-exist"
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE" "https://host/x.html"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "group/other-readable env file fails open without publishing (mode check, AC-006)" {
  chmod 644 "$ENV_FILE"
  run_fn ntfy_publish brief 3 "Morning brief" "HEADLINE" "https://host/x.html"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "unknown kind is ignored without publishing" {
  run_fn ntfy_publish bogus 3 "Morning brief" "HEADLINE"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "ntfy_brief_url builds the dated tailnet URL from the base URL" {
  run_fn ntfy_brief_url 2026-07-27
  [ "$status" -eq 0 ]
  [ "$output" = "https://host.example.ts.net:8443/2026-07-27.html" ]
}

@test "ntfy_brief_url yields nothing when the base URL is unset (degradation)" {
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
NTFY_TOPIC_BRIEF='claude-brief'
NTFY_BRIEF_BASE_URL=''
EOF
  chmod 600 "$ENV_FILE"
  run_fn ntfy_brief_url 2026-07-27
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_brief_html escapes raw HTML (no <script> executes on the page)" {
  local md="${BATS_TEST_TMPDIR}/brief.md" html="${BATS_TEST_TMPDIR}/brief.html"
  printf '%s\n' '# Brief' '' '- P1: <script>alert(1)</script> issue title' '' '| 時刻 | 件名 |' '|---|---|' '| 09:00 | 会議 |' >"$md"
  run_fn render_brief_html "$md" "$html" "Morning brief — test"
  [ "$status" -eq 0 ]
  [ -s "$html" ]
  # Raw <script> must never survive (pandoc markdown-raw_html or the <pre> fallback).
  ! grep -qF '<script>' "$html"
  grep -qF '&lt;script&gt;' "$html"
}

@test "render_brief_html fallback (pandoc absent) still escapes and is mobile-readable" {
  local md="${BATS_TEST_TMPDIR}/b.md" html="${BATS_TEST_TMPDIR}/b.html"
  printf '%s\n' '# Brief' '- item with <b> & ampersand' >"$md"
  run env PATH="/usr/bin:/bin" MORNING_RADAR_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; render_brief_html "$2" "$3" "t"' _ "$WRAPPER" "$md" "$html"
  [ "$status" -eq 0 ]
  [ -s "$html" ]
  ! grep -qF '<b>' "$html"
  grep -qF '&lt;b&gt;' "$html"
  grep -qF 'width=device-width' "$html"
  grep -qF 'white-space:pre-wrap' "$html"
}

@test "render_brief_html closes the raw_attribute bypass (script stays inert)" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not on PATH"
  local md="${BATS_TEST_TMPDIR}/rawattr.md" html="${BATS_TEST_TMPDIR}/rawattr.html"
  printf '%s\n' '# Brief' '' '`<script>alert(1)</script>`{=html}' >"$md"
  run_fn render_brief_html "$md" "$html" "Morning brief — test"
  [ "$status" -eq 0 ]
  [ -s "$html" ]
  # raw_attribute ({=html}) is a separate pandoc extension from raw_html and
  # bypasses it unless also disabled -- verify no live <script> tag survives.
  ! grep -qF '<script>' "$html"
}

@test "render_brief_html leaves a bare javascript: URI as inert plain text" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not on PATH"
  local md="${BATS_TEST_TMPDIR}/jsuri.md" html="${BATS_TEST_TMPDIR}/jsuri.html"
  printf '%s\n' '# Brief' '' '- P1: javascript:alert(1) bare' >"$md"
  run_fn render_brief_html "$md" "$html" "Morning brief — test"
  [ "$status" -eq 0 ]
  # autolink_bare_uris is deliberately not enabled: a dangerous scheme must
  # never become a clickable <a href>.
  ! grep -qF '<a href="javascript' "$html"
  grep -qF 'javascript:alert(1) bare' "$html"
}

@test "render_brief_html preserves literal --flags and straight quotes (smart disabled)" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not on PATH"
  local md="${BATS_TEST_TMPDIR}/flags.md" html="${BATS_TEST_TMPDIR}/flags.html"
  printf '%s\n' '# Brief' '' 'run --apply now, not "later"' >"$md"
  run_fn render_brief_html "$md" "$html" "Morning brief — test"
  [ "$status" -eq 0 ]
  grep -qF -- '--apply' "$html"
  ! grep -qF '–apply' "$html"
}

@test "render_brief_html renders a GFM pipe table and drops the duplicate leading H1" {
  command -v pandoc >/dev/null 2>&1 || skip "pandoc not on PATH"
  local md="${BATS_TEST_TMPDIR}/table.md" html="${BATS_TEST_TMPDIR}/table.html"
  printf '%s\n' '# Brief' '' '| 時刻 | 件名 |' '|---|---|' '| 09:00 | 会議 |' >"$md"
  run_fn render_brief_html "$md" "$html" "Morning brief — test"
  [ "$status" -eq 0 ]
  grep -qF '<table>' "$html"
  # brief_page_shell supplies its own masthead <h1>; pandoc's document h1 for
  # the dropped leading "# Brief" line must not also appear.
  [ "$(grep -c '<h1' "$html")" -eq 1 ]
  grep -qF 'class="masthead"' "$html"
}

# --- main() integration (Darwin-only; the wrapper's uname guard exits early) --

@test "main(): success writes the last-run stamp and publishes with a click URL (AC-003)" {
  [ "$(uname)" = "Darwin" ] || skip "morning-radar main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-ok"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
d="$HOME/dotfiles/.kryota-dev/morning-brief"
mkdir -p "$d"
printf '# Morning Brief\n\n- P1: alpha issue\n' >"$d/$(date +%F).md"
echo "HEADLINE: P1 1件"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    MORNING_RADAR_TIMEOUT_SECONDS=2 \
    MORNING_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/morning-radar/last-run" ]
  [ -f "${home}/dotfiles/.kryota-dev/morning-brief/$(date +%F).html" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-brief" ]
  jq -e '.click | test("/[0-9-]+\\.html$")' <"${STUB_DIR}/curl_stdin" >/dev/null
}

@test "main(): a failed run notifies attention and leaves no last-run stamp (AC-003/005)" {
  [ "$(uname)" = "Darwin" ] || skip "morning-radar main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-fail"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  printf '%s\n' '#!/bin/bash' 'exit 1' >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    MORNING_RADAR_TIMEOUT_SECONDS=2 \
    MORNING_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 1 ]
  [ ! -f "${home}/state/morning-radar/last-run" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
}
