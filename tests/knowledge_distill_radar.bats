#!/usr/bin/env bats

# knowledge-distill radar wrapper (home/dot_claude/executable_knowledge-distill-radar.sh, #368).
# The wrapper is source-safe (side effects live in main() behind a BASH_SOURCE
# guard), so these tests both source it to exercise the pure helpers and run it
# end-to-end with claude + curl stubbed on PATH — no network, no server, CI-safe.
# Covers: permission allowlist hygiene, token hygiene, fail-open ntfy delivery,
# the same-week guard, the independent dry-pipeline precheck, and main()'s
# stamp/notification wiring for both healthy and dry weeks.

load helpers/setup

WRAPPER="${HOME_DIR}/dot_claude/executable_knowledge-distill-radar.sh"

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
EOF
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/knowledge-distill-radar.log"
}

# Source the wrapper (main() is guarded, so nothing runs) and call one of its
# functions with the stubbed PATH and fixture env.
run_fn() {
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    NTFY_TEST_CURL_EXIT="${NTFY_TEST_CURL_EXIT:-0}" \
    KNOWLEDGE_DISTILL_RADAR_NTFY_ENV_FILE="$ENV_FILE" \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; shift; fn="$1"; shift; "$fn" "$@"' _ "$WRAPPER" "$@"
}

@test "knowledge-distill-radar.sh exists and passes bash -n" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "no dangerously-skip-permissions / bypassPermissions bypass" {
  run grep -q 'dangerously-skip-permissions' "$WRAPPER"
  [ "$status" -ne 0 ]
  run grep -q 'bypassPermissions' "$WRAPPER"
  [ "$status" -ne 0 ]
}

@test "keeps the explicit permission allowlist and pinned model/turns" {
  grep -q -- '--allowedTools' "$WRAPPER"
  grep -q -- '--max-turns' "$WRAPPER"
  grep -q -- '--model' "$WRAPPER"
  grep -q 'CLAUDE_CONFIG_DIR' "$WRAPPER"
}

@test "allowlist grants Skill(knowledge-distill) and confines writes to the report dir" {
  local allowed_tools_line
  allowed_tools_line="$(grep '^ALLOWED_TOOLS=' "$WRAPPER")"
  [[ "$allowed_tools_line" == *'Skill(knowledge-distill)'* ]]
  [[ "$allowed_tools_line" == *'Edit(~/dotfiles/.kryota-dev/knowledge-distill/**)'* ]]
  # No page-delivery tool for this radar (unlike morning-radar's brief page).
  [[ "$allowed_tools_line" != *'Artifact'* ]]
}

@test "token hygiene: no -H/--header Authorization, no set -x, token via -K" {
  run grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  [ "$status" -ne 0 ]
  ! grep -qF 'set -x' "$WRAPPER"
  grep -qF 'curl -fs -K' "$WRAPPER"
}

@test "does not hand-copy per-account isolation env (delegates to the claude launcher, #336/#345)" {
  # Unlike morning-radar, this wrapper DOES legitimately reference the
  # ecc-homunculus-default fallback path (HOMUNCULUS_DIR, matching SKILL.md's
  # own Phase 0 fallback) for its independent precheck -- only a literal
  # re-assignment of the isolation env vars themselves is forbidden.
  run grep -qE 'CLV2_HOMUNCULUS_DIR=|ECC_AGENT_DATA_HOME=|GATEGUARD_STATE_DIR=|ECC_MCP_HEALTH_STATE_PATH=' "$WRAPPER"
  [ "$status" -ne 0 ]
  grep -qF '$HOME/.local/launchers:' "$WRAPPER"
  grep -qF 'CLAUDE_CONFIG_DIR="$HOME/.claude"' "$WRAPPER"
  grep -qF 'EXA_API_KEY=""' "$WRAPPER"
  grep -qF 'FIRECRAWL_API_KEY=""' "$WRAPPER"
}

@test "ntfy_publish -> claude-attention topic with given priority and message" {
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: 昇華提案 4件"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "HEADLINE: 昇華提案 4件" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
}

@test "notify_error publishes priority 5 to claude-attention" {
  run_fn notify_error "claude not found"
  [ "$status" -eq 0 ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "claude not found" ]
}

@test "token never reaches curl argv (travels via -K config file)" {
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_args" ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -qE -- '-K' "${STUB_DIR}/curl_args"
}

@test "publish failure is fail-open: returns 0, token never logged" {
  NTFY_TEST_CURL_EXIT=1 run_fn ntfy_publish 5 "Knowledge Distill" "boom"
  [ "$status" -eq 0 ]
  ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

@test "no env file -> silent no-op, no publish" {
  rm -f "$ENV_FILE"
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_stdin" ]
}

@test "group/other-readable env file fails open without publishing" {
  chmod 644 "$ENV_FILE"
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_stdin" ]
}

@test "same-week guard skips a second run within the same ISO week" {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "${tmp}/state/knowledge-distill-radar"
  printf '%s\n' "$(date +%G-W%V)" >"${tmp}/state/knowledge-distill-radar/last-run"
  # claude is not resolvable from the sandboxed HOME, so a bypassed guard would exit 1.
  run env HOME="$tmp" XDG_STATE_HOME="${tmp}/state" bash "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "main(): healthy pipeline publishes the plain HEADLINE and stamps the week" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-healthy"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy" \
    "${home}/.local/share/ecc-homunculus-default/instincts/personal"
  # 10 instincts == the MIN_INSTINCTS default: not dry.
  for i in $(seq 1 10); do
    printf 'instinct %s\n' "$i" >"${home}/.local/share/ecc-homunculus-default/instincts/personal/inst-${i}.md"
  done
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
# Extract the report path from the -p prompt so the stub writes where the
# wrapper expects (mirrors the wrapper's own $REPORT_FILE construction).
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# Knowledge Distill\n\n昇華提案 4件。\n' >"$report"
echo "HEADLINE: 昇華提案 4件 / instinct 12件"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
  # The "HEADLINE:" prefix is stripped before publishing (matches morning-radar).
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "昇華提案 4件 / instinct 12件" ]
  run grep -qF '縮退' <(jq -r .message <"${STUB_DIR}/curl_stdin")
  [ "$status" -ne 0 ]
}

@test "main(): dry pipeline is flagged explicitly regardless of claude's own wording" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-dry"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy" \
    "${home}/.local/share/ecc-homunculus-default/instincts/personal"
  # 3 instincts < the MIN_INSTINCTS default (10): dry pipeline.
  for i in 1 2 3; do
    printf 'instinct %s\n' "$i" >"${home}/.local/share/ecc-homunculus-default/instincts/personal/inst-${i}.md"
  done
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# Knowledge Distill (degraded)\n\ninstinct 蓄積不足。\n' >"$report"
echo "HEADLINE: 縮退終了"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  local message
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  [[ "$message" == *"縮退"* ]]
  [[ "$message" == *"3/10"* ]]
}

@test "main(): a failed run notifies attention priority 5 and leaves no stamp" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-fail"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  printf '%s\n' '#!/bin/bash' 'exit 1' >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 1 ]
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
}
