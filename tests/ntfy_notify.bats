#!/usr/bin/env bats

# ntfy hook wrapper (home/dot_claude/executable_ntfy-notify.sh, #337).
# Runs the wrapper against fixture hook payloads with curl stubbed out on
# PATH; no network, no server, CI-safe. Covers the fail-open contract,
# payload construction, truncation/scrubbing, and token hygiene (AC-006/007).

load helpers/setup

WRAPPER="${HOME_DIR}/dot_claude/executable_ntfy-notify.sh"

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
EOF
  # The wrapper refuses env files that are not owner-only (0600/0400)
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/ntfy-notify.log"
  REDACT_TOML="${BATS_TEST_TMPDIR}/gitleaks-own.toml"
}

# Run the wrapper with the stubbed PATH and fixture env; stdin comes from $1.
run_wrapper() {
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    NTFY_TEST_CURL_EXIT="${NTFY_TEST_CURL_EXIT:-0}" \
    NTFY_NOTIFY_ENV_FILE="$ENV_FILE" \
    NTFY_NOTIFY_LOG_FILE="$LOG_FILE" \
    NTFY_NOTIFY_REDACT_TOML="$REDACT_TOML" \
    NTFY_NOTIFY_ALERT_SOUND="${BATS_TEST_TMPDIR}/nonexistent.m4r" \
    bash -c "printf '%s' \"\$1\" | bash \"$WRAPPER\"" _ "$1"
}

@test "ntfy-notify.sh exists and passes bash -n" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "ntfy-notify.sh is a silent no-op without the env file" {
  ENV_FILE="${BATS_TEST_TMPDIR}/does-not-exist"
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "permission_prompt goes to the attention topic with priority 4" {
  run_wrapper '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"0123456789abcdef","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  payload="$(cat "${STUB_DIR}/curl_stdin")"
  [ "$(printf '%s' "$payload" | jq -r '.topic')" = "claude-attention" ]
  [ "$(printf '%s' "$payload" | jq -r '.priority')" = "4" ]
  # Bodies are published as Markdown so the ntfy web app renders them (#361).
  [ "$(printf '%s' "$payload" | jq -r '.markdown')" = "true" ]
  [[ "$(printf '%s' "$payload" | jq -r '.title')" == *"permission_prompt"* ]]
  # Attribution (requirement 1.2): account in title and tags; cwd=/tmp is not a
  # git repo so repo/branch fall back to "-", which must also land in the tags.
  [[ "$(printf '%s' "$payload" | jq -r '.title')" == *"[default]"* ]]
  printf '%s' "$payload" | jq -e '.tags | index("default")' >/dev/null
  printf '%s' "$payload" | jq -e '.tags | index("-")' >/dev/null
  # 8-char session id lands in tags
  printf '%s' "$payload" | jq -e '.tags | index("01234567")' >/dev/null
}

@test "agent_needs_input is attention class; agent_completed is done class" {
  run_wrapper '{"hook_event_name":"Notification","notification_type":"agent_needs_input","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.topic' "${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r '.priority' "${STUB_DIR}/curl_stdin")" = "4" ]
  run_wrapper '{"hook_event_name":"Notification","notification_type":"agent_completed","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.topic' "${STUB_DIR}/curl_stdin")" = "claude-done" ]
  [ "$(jq -r '.priority' "${STUB_DIR}/curl_stdin")" = "3" ]
}

@test "Stop goes to the done topic (priority 3) and truncates to exactly 200 chars" {
  long_msg="$(printf 'a%.0s' $(seq 1 300))"
  run_wrapper "{\"hook_event_name\":\"Stop\",\"session_id\":\"abc\",\"cwd\":\"/tmp\",\"last_assistant_message\":\"${long_msg}\"}"
  [ "$status" -eq 0 ]
  payload="$(cat "${STUB_DIR}/curl_stdin")"
  [ "$(printf '%s' "$payload" | jq -r '.topic')" = "claude-done" ]
  [ "$(printf '%s' "$payload" | jq -r '.priority')" = "3" ]
  # jq length counts codepoints: the exact BODY_LIMIT boundary, not a loose cap
  [ "$(printf '%s' "$payload" | jq -r '.message | length')" -eq 200 ]
}

@test "multibyte body is truncated on codepoint boundaries (stays valid UTF-8)" {
  long_msg="$(printf 'あ%.0s' $(seq 1 250))"
  run_wrapper "{\"hook_event_name\":\"Stop\",\"session_id\":\"abc\",\"cwd\":\"/tmp\",\"last_assistant_message\":\"${long_msg}\"}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.message | length' "${STUB_DIR}/curl_stdin")" -eq 200 ]
  # No mid-character cut: the message must still be pure あ (no U+FFFD debris)
  jq -e '.message | test("^あ+$")' "${STUB_DIR}/curl_stdin" >/dev/null
}

@test "missing NTFY_TOPIC_* in the env file fails open without publishing" {
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
EOF
  chmod 600 "$ENV_FILE"
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "group/other-readable env file fails open without publishing" {
  chmod 644 "$ENV_FILE"
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "identifier straddling the truncation boundary is scrubbed (scrub before truncate)" {
  command -v perl >/dev/null 2>&1 || skip "perl not available"
  printf "regex = '''(?i)(acmecorp)'''\n" >"$REDACT_TOML"
  long_msg="$(printf 'a%.0s' $(seq 1 195))acmecorp$(printf 'b%.0s' $(seq 1 50))"
  run_wrapper "{\"hook_event_name\":\"Stop\",\"session_id\":\"abc\",\"cwd\":\"/tmp\",\"last_assistant_message\":\"${long_msg}\"}"
  [ "$status" -eq 0 ]
  msg="$(jq -r '.message' "${STUB_DIR}/curl_stdin")"
  [[ "$msg" != *"acme"* ]]
  [ "$(jq -r '.message | length' "${STUB_DIR}/curl_stdin")" -le 200 ]
}

@test "redact extraction understands the real gitleaks-own template format" {
  # Integration guard against silent format drift: the wrapper's sed contract
  # must keep matching the actual chezmoi source template's regex line.
  run env NTFY_NOTIFY_REDACT_TOML="${HOME_DIR}/dot_config/git/private_gitleaks-own.toml.tmpl" \
    bash -c "source '$WRAPPER'; extract_redact_pattern"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "Stop without last_assistant_message publishes an empty message" {
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.message' "${STUB_DIR}/curl_stdin")" = "" ]
}

@test "client identifiers are scrubbed via the deployed redact pattern" {
  command -v perl >/dev/null 2>&1 || skip "perl not available"
  printf "regex = '''(?i)(acmecorp|widgetco)'''\n" >"$REDACT_TOML"
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp","last_assistant_message":"deployed AcmeCorp api for WidgetCo"}'
  [ "$status" -eq 0 ]
  msg="$(jq -r '.message' "${STUB_DIR}/curl_stdin")"
  [[ "$msg" != *"AcmeCorp"* ]]
  [[ "$msg" != *"WidgetCo"* ]]
  [[ "$msg" == *"[redacted]"* ]]
}

@test "malformed redact TOML falls back to truncation-only" {
  printf 'not the expected format\n' >"$REDACT_TOML"
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp","last_assistant_message":"mentions AcmeCorp"}'
  [ "$status" -eq 0 ]
  msg="$(jq -r '.message' "${STUB_DIR}/curl_stdin")"
  [[ "$msg" == *"AcmeCorp"* ]]
}

@test "publish failure is fail-open: exit 0, logged, token never logged" {
  NTFY_TEST_CURL_EXIT=22
  run_wrapper '{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ -f "$LOG_FILE" ]
  grep -q 'publish failed' "$LOG_FILE"
  ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

@test "unsubscribed events are ignored without publishing" {
  run_wrapper '{"hook_event_name":"Notification","notification_type":"auth_success","session_id":"abc","cwd":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "token never reaches curl argv (travels via -K config file)" {
  run_wrapper '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp","last_assistant_message":"hi"}'
  [ "$status" -eq 0 ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -q -- '-K' "${STUB_DIR}/curl_args"
}

@test "wrapper source keeps token hygiene: no -H/--header Authorization, no set -x" {
  # Catch -H"Authorization (no space) and the --header long option too;
  # scope both greps to non-comment content so prose about the rule can't match
  ! grep -E -- '^[^#]*(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  # Catch combined flag forms like `set -eux`, not just a literal `set -x`
  ! grep -E '^[^#]*set -[a-zA-Z]*x' "$WRAPPER"
}
