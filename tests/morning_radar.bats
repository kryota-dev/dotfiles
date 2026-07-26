#!/usr/bin/env bats

# morning-radar wrapper (home/dot_claude/executable_morning-radar.sh, #257/#361).
# The wrapper is source-safe (side effects live in main() behind a BASH_SOURCE
# guard), so these tests source it and exercise the pure delivery functions
# (ntfy_publish / render_brief_html / ntfy_brief_url) with curl stubbed out on
# PATH — no network, no server, no claude, CI-safe. Covers the osascript->ntfy
# migration (AC-002), fail-open delivery (AC-003), graceful degradation
# (AC-004), topic/priority split (AC-005), and token hygiene (AC-006).

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
NTFY_BRIEF_BASE_URL='https://host.example.ts.net/brief'
EOF
  # The wrapper refuses env files that are not owner-only (0600/0400).
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/morning-radar.log"
}

# Source the wrapper (main() is guarded, so nothing runs) and call one of its
# functions with the stubbed PATH and fixture env. Args after the function name
# are forwarded to it.
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

@test "token hygiene: no -H/--header Authorization, no set -x (AC-006)" {
  ! grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  ! grep -qF 'set -x' "$WRAPPER"
  # The token reaches curl only through a -K config file.
  grep -qF 'curl -fs -K' "$WRAPPER"
}

@test "ntfy_publish brief -> claude-brief topic with click URL (AC-001/005)" {
  run_fn ntfy_publish brief 3 "HEADLINE: P1 2件" "https://host.example.ts.net/brief/2026-07-26.html"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-brief" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "HEADLINE: P1 2件" ]
  [ "$(jq -r .click <"${STUB_DIR}/curl_stdin")" = "https://host.example.ts.net/brief/2026-07-26.html" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
}

@test "ntfy_publish attention -> claude-attention topic, priority 5, no click (AC-005)" {
  run_fn ntfy_publish attention 5 "Morning radar failed: claude not found"
  [ "$status" -eq 0 ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
  # No link on error notifications.
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
}

@test "empty click degrades to a headline-only payload (AC-004)" {
  run_fn ntfy_publish brief 3 "HEADLINE only" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "HEADLINE only" ]
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
}

@test "token never reaches curl argv (travels via -K config file) (AC-006)" {
  run_fn ntfy_publish brief 3 "HEADLINE" "https://host.example.ts.net/brief/x.html"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_args" ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -qE -- '-K' "${STUB_DIR}/curl_args"
}

@test "publish failure is fail-open: returns 0, token never logged (AC-003)" {
  NTFY_TEST_CURL_EXIT=1
  run_fn ntfy_publish brief 3 "HEADLINE" "https://host.example.ts.net/brief/x.html"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG_FILE" ] || ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

@test "no env file -> silent no-op, no publish" {
  ENV_FILE="${BATS_TEST_TMPDIR}/does-not-exist"
  run_fn ntfy_publish brief 3 "HEADLINE" "https://host/x.html"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "unknown kind is ignored without publishing" {
  run_fn ntfy_publish bogus 3 "HEADLINE"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "ntfy_brief_url builds the dated tailnet URL from the base URL" {
  run_fn ntfy_brief_url 2026-07-26
  [ "$status" -eq 0 ]
  [ "$output" = "https://host.example.ts.net/brief/2026-07-26.html" ]
}

@test "ntfy_brief_url yields nothing when the base URL is unset (degradation)" {
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
NTFY_TOPIC_BRIEF='claude-brief'
NTFY_BRIEF_BASE_URL=''
EOF
  chmod 600 "$ENV_FILE"
  run_fn ntfy_brief_url 2026-07-26
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_brief_html fallback escapes markup and is mobile-readable" {
  local md="${BATS_TEST_TMPDIR}/brief.md" html="${BATS_TEST_TMPDIR}/brief.html"
  printf '%s\n' '# Brief' '- item with <script> & ampersand' >"$md"
  # Force the pandoc-absent path with a minimal PATH (sed/bash only, no pandoc).
  run env PATH="/usr/bin:/bin" MORNING_RADAR_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; render_brief_html "$2" "$3" "Morning brief — test"' \
    _ "$WRAPPER" "$md" "$html"
  [ "$status" -eq 0 ]
  [ -s "$html" ]
  grep -qF '&lt;script&gt;' "$html"
  grep -qF '&amp; ampersand' "$html"
  grep -qF 'width=device-width' "$html"
  grep -qF 'white-space:pre-wrap' "$html"
  # Raw (unescaped) markup must not survive.
  ! grep -qF '<script>' "$html"
}
