#!/usr/bin/env bats

load helpers/setup

# Behavioural tests for the ntfy publisher hook (#337). The static wiring assertions live
# in files.bats; this suite drives the real script with synthetic hook payloads.
#
# Every run gets a stub PATH entry ahead of the real one, so `curl` and `osascript` are
# captured instead of executed: no test can reach the network, and none can pop a real
# desktop notification. The script reads NTFY_NOTIFY_ENV_FILE precisely so these tests can
# point it at a fixture — or at a path that does not exist, which is how a machine that has
# never been bootstrapped looks.

SCRIPT=""

setup() {
  SCRIPT="${HOME_DIR}/dot_claude/executable_ntfy-notify.sh"
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"

  cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
cat >"${NTFY_TEST_DIR}/curl-body"
printf '%s\n' "$*" >"${NTFY_TEST_DIR}/curl-args"
exit "${NTFY_TEST_CURL_EXIT:-0}"
STUB

  cat >"${STUB_DIR}/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${NTFY_TEST_DIR}/osascript-args"
STUB

  chmod +x "${STUB_DIR}/curl" "${STUB_DIR}/osascript"

  export NTFY_TEST_DIR="${BATS_TEST_TMPDIR}"
  printf "NTFY_BASE_URL='https://ntfy.test.invalid'\nNTFY_TOPIC='topic-test'\nNTFY_TOKEN='tk_test'\n" \
    >"${BATS_TEST_TMPDIR}/notify-env"
}

# Run the hook with a payload on stdin. $1 = path to the env file (may be nonexistent).
run_hook() {
  local env_file="$1" payload="$2"
  printf '%s' "$payload" | env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_NOTIFY_ENV_FILE="$env_file" \
    CLAUDE_CONFIG_DIR="${HOME}/.claude" \
    bash "$SCRIPT"
}

published_body() {
  cat "${BATS_TEST_TMPDIR}/curl-body"
}

@test "ntfy-notify: the hook script exists and is executable in the chezmoi source tree" {
  [ -f "${HOME_DIR}/dot_claude/executable_ntfy-notify.sh" ]
  [ -x "${HOME_DIR}/dot_claude/executable_ntfy-notify.sh" ]
}

@test "ntfy-notify: publishes topic, title, priority and attribution tags" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"abcdef1234567890","cwd":"'"${REPO_ROOT}"'","message":"Claude needs permission"}'
  [ "$status" -eq 0 ]
  [ -f "${BATS_TEST_TMPDIR}/curl-body" ]
  # Permission prompts are the "stop what you are doing" tier.
  [ "$(published_body | jq -r '.priority')" = "4" ]
  [ "$(published_body | jq -r '.topic')" = "topic-test" ]
  [ "$(published_body | jq -r '.message')" = "Claude needs permission" ]
  published_body | jq -e '.tags | index("warning") != null' >/dev/null
  published_body | jq -e '.tags | index("evt-permission-prompt") != null' >/dev/null
  published_body | jq -e '.tags | index("acct-cld") != null' >/dev/null
  published_body | jq -e '.tags | index("sid-abcdef12") != null' >/dev/null
  # The token must travel in the Authorization header, never in the body or the URL.
  grep -qF 'Authorization: Bearer tk_test' "${BATS_TEST_TMPDIR}/curl-args"
  published_body | jq -e 'tostring | contains("tk_test") | not' >/dev/null
}

@test "ntfy-notify: derives the repo name from the git common dir, not the worktree dir" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v git >/dev/null 2>&1 || skip "git unavailable"
  # A linked worktree is the normal working state in this repo (wtp names each worktree
  # after its branch), so `basename $(git rev-parse --show-toplevel)` would report the
  # branch name as the repository name. Reproduce that exact shape.
  local main="${BATS_TEST_TMPDIR}/myrepo"
  local wt="${BATS_TEST_TMPDIR}/worktrees/feat-something"
  mkdir -p "$main"
  git -C "$main" init --quiet --initial-branch=main
  git -C "$main" -c user.email=t@example.com -c user.name=t commit --quiet --allow-empty -m init
  git -C "$main" worktree add --quiet -b feat/something "$wt" >/dev/null 2>&1

  run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"Stop","cwd":"'"${wt}"'","last_assistant_message":"done"}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.title')" = "myrepo/feat/something · cld" ]
  published_body | jq -e '.tags | index("repo-myrepo") != null' >/dev/null
  # The slash in the branch must not split the comma-separated tag list.
  published_body | jq -e '.tags | index("branch-feat-something") != null' >/dev/null
}

@test "ntfy-notify: summary skips Markdown structure and takes the first prose line" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # A heading marker, a rule, a fence and an empty bullet must all fall through; a heading
  # WITH text keeps the text and loses the marker.
  run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"\n---\n\n## Implementation complete\n\nDetails follow."}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.message')" = "Implementation complete" ]
}

@test "ntfy-notify: truncates the summary at 200 codepoints, not bytes" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local long
  long="$(printf 'あ%.0s' $(seq 1 250))"
  run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"'"${long}"'"}'
  [ "$status" -eq 0 ]
  # 200 kept characters plus the ellipsis. A byte-oriented cut would both land on the
  # wrong boundary and risk splitting a multi-byte character.
  [ "$(published_body | jq -r '.message | length')" = "201" ]
  published_body | jq -e '.message | endswith("…")' >/dev/null
}

@test "ntfy-notify: falls back to a local notification when the channel is not bootstrapped" {
  run run_hook "${BATS_TEST_TMPDIR}/does-not-exist" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"turn finished"}'
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/curl-body" ]
  grep -qF 'turn finished' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: min-priority events stay silent when the channel is unavailable" {
  # SessionEnd exists for the server-side history. If it fell back to a desktop popup,
  # retiring ECC's Stop-only hook would have increased local notification volume.
  run run_hook "${BATS_TEST_TMPDIR}/does-not-exist" \
    '{"hook_event_name":"SessionEnd","cwd":"'"${REPO_ROOT}"'","reason":"clear"}'
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/osascript-args" ]
}

@test "ntfy-notify: falls back to a local notification when the server rejects the publish" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  export NTFY_TEST_CURL_EXIT=22
  run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"StopFailure","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"the turn failed"}'
  [ "$status" -eq 0 ]
  grep -qF 'the turn failed' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: the local fallback is AppleScript-safe for quotes and backslashes" {
  # AppleScript string literals have no backslash-escape syntax, so an unescaped " or \
  # from an assistant message would break the generated script. The published JSON keeps
  # the original text; only the osascript path is rewritten.
  run run_hook "${BATS_TEST_TMPDIR}/does-not-exist" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"ran rm -rf \"a\\b\" now"}'
  [ "$status" -eq 0 ]
  local args
  args="$(cat "${BATS_TEST_TMPDIR}/osascript-args")"
  # Exactly the two quotes that delimit the body and the two that delimit the title.
  [ "$(printf '%s' "$args" | tr -cd '"' | wc -c | tr -d ' ')" = "4" ]
  [ "$(printf '%s' "$args" | tr -cd '\\' | wc -c | tr -d ' ')" = "0" ]
}

@test "ntfy-notify: an empty payload still exits 0" {
  run run_hook "${BATS_TEST_TMPDIR}/does-not-exist" ''
  [ "$status" -eq 0 ]
}

@test "ntfy-notify: a malformed payload still exits 0" {
  run run_hook "${BATS_TEST_TMPDIR}/does-not-exist" 'this is not json {'
  [ "$status" -eq 0 ]
}

@test "ntfy-notify: multibyte branch names survive tag sanitisation under any locale" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v git >/dev/null 2>&1 || skip "git unavailable"
  # Branch names and assistant text are arbitrary bytes. BSD tr/sed abort with "illegal
  # byte sequence" on input that is invalid in the caller's locale, which under `set -eu`
  # would silently truncate a tag rather than fail loudly — hence the LC_ALL=C byte
  # filters. Drive a real multibyte branch to lock that in.
  local main="${BATS_TEST_TMPDIR}/jrepo"
  mkdir -p "$main"
  git -C "$main" init --quiet --initial-branch=main
  git -C "$main" -c user.email=t@example.com -c user.name=t commit --quiet --allow-empty -m init
  git -C "$main" checkout --quiet -b 'feat/日本語ブランチ'

  LC_ALL=ja_JP.UTF-8 run run_hook "${BATS_TEST_TMPDIR}/notify-env" \
    '{"hook_event_name":"Stop","cwd":"'"${main}"'","last_assistant_message":"完了しました"}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.title')" = "jrepo/feat/日本語ブランチ · cld" ]
  [ "$(published_body | jq -r '.message')" = "完了しました" ]
  # Every tag must remain a single, separator-free token.
  published_body | jq -e '.tags | all(test("^[A-Za-z0-9_-]+$"))' >/dev/null
  published_body | jq -e '.tags | index("repo-jrepo") != null' >/dev/null
}
