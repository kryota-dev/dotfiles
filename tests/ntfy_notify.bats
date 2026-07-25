#!/usr/bin/env bats

load helpers/setup

# Behavioural tests for the ntfy publisher hook (#337). The static wiring assertions live
# in files.bats; this suite drives the real script with synthetic hook payloads.
#
# Every run gets a stub PATH entry ahead of the real one, so `curl` and `osascript` are
# captured instead of executed: no test can reach the network, and none can pop a real
# desktop notification. Tests select between a bootstrapped and a never-bootstrapped
# channel by pointing HOME at one of two fake homes; the script has no dedicated override
# variable because overriding HOME is already sufficient here.

SCRIPT=""

setup() {
  SCRIPT="${HOME_DIR}/dot_claude/executable_ntfy-notify.sh"
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"

  cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
cat >"${NTFY_TEST_DIR}/curl-body"
printf '%s\n' "$*" >"${NTFY_TEST_DIR}/curl-args"
# The hook reads the status from --write-out, so the stub must speak the same protocol.
printf '%s' "${NTFY_TEST_HTTP_CODE:-200}"
exit "${NTFY_TEST_CURL_EXIT:-0}"
STUB

  cat >"${STUB_DIR}/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${NTFY_TEST_DIR}/osascript-args"
STUB

  chmod +x "${STUB_DIR}/curl" "${STUB_DIR}/osascript"

  export NTFY_TEST_DIR="${BATS_TEST_TMPDIR}"
  # A configured HOME: the hook reads ~/.config/ntfy/notify-env and has no override
  # variable, so tests select the fixture by pointing HOME at a fake home.
  CONFIGURED_HOME="${BATS_TEST_TMPDIR}/home-configured"
  UNCONFIGURED_HOME="${BATS_TEST_TMPDIR}/home-bare"
  mkdir -p "${CONFIGURED_HOME}/.config/ntfy" "${UNCONFIGURED_HOME}"
  printf "NTFY_BASE_URL='https://ntfy.test.invalid'\nNTFY_TOPIC='topic-test'\nNTFY_TOKEN='tk_test'\n" \
    >"${CONFIGURED_HOME}/.config/ntfy/notify-env"
}

# Run the hook with a payload on stdin. $1 = the HOME to run under (CONFIGURED_HOME for a
# bootstrapped channel, UNCONFIGURED_HOME for one that was never set up).
run_hook() {
  local home_dir="$1" payload="$2"
  printf '%s' "$payload" | env \
    PATH="${STUB_DIR}:${PATH}" \
    HOME="$home_dir" \
    CLAUDE_CONFIG_DIR="${home_dir}/.claude" \
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
  run run_hook "$CONFIGURED_HOME" \
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

  run run_hook "$CONFIGURED_HOME" \
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
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"\n---\n\n## Implementation complete\n\nDetails follow."}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.message')" = "Implementation complete" ]
}

@test "ntfy-notify: truncates the summary at 200 codepoints, not bytes" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local long
  long="$(printf 'あ%.0s' $(seq 1 250))"
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"'"${long}"'"}'
  [ "$status" -eq 0 ]
  # 200 kept characters plus the ellipsis. A byte-oriented cut would both land on the
  # wrong boundary and risk splitting a multi-byte character.
  [ "$(published_body | jq -r '.message | length')" = "201" ]
  published_body | jq -e '.message | endswith("…")' >/dev/null
}

@test "ntfy-notify: falls back to a local notification when the channel is not bootstrapped" {
  run run_hook "$UNCONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"turn finished"}'
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/curl-body" ]
  grep -qF 'turn finished' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: min-priority events stay silent when the channel is unavailable" {
  # SessionEnd exists for the server-side history. If it fell back to a desktop popup,
  # retiring ECC's Stop-only hook would have increased local notification volume.
  run run_hook "$UNCONFIGURED_HOME" \
    '{"hook_event_name":"SessionEnd","cwd":"'"${REPO_ROOT}"'","reason":"clear"}'
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/osascript-args" ]
}

@test "ntfy-notify: falls back to a local notification when the server rejects the publish" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  export NTFY_TEST_CURL_EXIT=22
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"StopFailure","cwd":"'"${REPO_ROOT}"'","error":"the turn failed"}'
  [ "$status" -eq 0 ]
  grep -qF 'the turn failed' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: the local fallback passes text as argv, never into the script source" {
  # Interpolating the message into `display notification "..."` would need lossy escaping,
  # because AppleScript string literals have no backslash-escape syntax: an earlier
  # revision deleted backslashes and rewrote quotes, mangling paths and code fragments.
  # Argv passing (the pattern morning-radar.sh already uses) removes both the injection
  # surface and the mangling, so the text must arrive byte-for-byte.
  run run_hook "$UNCONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"ran rm -rf \"a\\b\" now"}'
  [ "$status" -eq 0 ]
  local args
  args="$(cat "${BATS_TEST_TMPDIR}/osascript-args")"
  # The argv form, not an interpolated one-liner.
  [[ "$args" == *"on run argv"* ]]
  [[ "$args" == *"(item 1 of argv)"* ]]
  # The message survives verbatim, quotes and backslash intact.
  [[ "$args" == *'ran rm -rf "a\b" now'* ]]
}

@test "ntfy-notify: an empty payload still exits 0" {
  run run_hook "$UNCONFIGURED_HOME" ''
  [ "$status" -eq 0 ]
}

@test "ntfy-notify: a malformed payload still exits 0" {
  run run_hook "$UNCONFIGURED_HOME" 'this is not json {'
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

  LC_ALL=ja_JP.UTF-8 run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${main}"'","last_assistant_message":"完了しました"}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.title')" = "jrepo/feat/日本語ブランチ · cld" ]
  [ "$(published_body | jq -r '.message')" = "完了しました" ]
  # Every tag must remain a single, separator-free token.
  published_body | jq -e '.tags | all(test("^[A-Za-z0-9_-]+$"))' >/dev/null
  published_body | jq -e '.tags | index("repo-jrepo") != null' >/dev/null
}

@test "ntfy-notify: a 3xx response is not treated as a successful publish" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # `curl --fail` only errors on >= 400, so a redirect would have been counted as
  # published and the notification lost with no fallback. The status is checked explicitly.
  export NTFY_TEST_HTTP_CODE=301
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"redirected away"}'
  [ "$status" -eq 0 ]
  [ -f "${BATS_TEST_TMPDIR}/curl-body" ]
  grep -qF 'redirected away' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: the publish request refuses plaintext and bypasses any proxy" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"'"${REPO_ROOT}"'","last_assistant_message":"done"}'
  [ "$status" -eq 0 ]
  # The bearer token travels in a header, so a plaintext base URL must be impossible and
  # no ambient proxy may see the body.
  grep -qF -- "--proto =https" "${BATS_TEST_TMPDIR}/curl-args"
  grep -qF -- "--noproxy *" "${BATS_TEST_TMPDIR}/curl-args"
}

@test "ntfy-notify: exits 0 even with HOME unset" {
  # `set -u` plus a bare ${HOME} would abort the hook outright, breaking the contract that
  # nothing about this channel can fail a session.
  run env -u HOME PATH="${STUB_DIR}:${PATH}" CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/.claude" \
    bash "$SCRIPT" <<<'{"hook_event_name":"Stop","cwd":"/","last_assistant_message":"x"}'
  [ "$status" -eq 0 ]
}

@test "ntfy-notify: StopFailure publishes its error, not a placeholder" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # StopFailure carries `error`; it has no `message`, and `last_assistant_message` is
  # empty or stale for a turn that died. Reading only those two published a literal
  # "(no message text)" for the single priority-5 event this channel has.
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"StopFailure","cwd":"'"${REPO_ROOT}"'","error":"API 500 overloaded"}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.message')" = "API 500 overloaded" ]
  [ "$(published_body | jq -r '.priority')" = "5" ]
}

@test "ntfy-notify: SessionEnd records its reason in the history" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # SessionEnd carries `reason` and nothing else usable. It is silent on the device
  # (priority 1) but must still be meaningful when the history is read back.
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"SessionEnd","cwd":"'"${REPO_ROOT}"'","reason":"clear"}'
  [ "$status" -eq 0 ]
  [ "$(published_body | jq -r '.message')" = "clear" ]
  [ "$(published_body | jq -r '.priority')" = "1" ]
}

@test "ntfy-notify: an unconfigured channel does not raise local notification volume" {
  # This is the state every machine is in when the feature lands, because it ships
  # disabled. The retired ECC hook fired on Stop alone; falling back for every
  # priority-3-and-up event here would make removing it a large net INCREASE in popups.
  local ev
  for ev in \
    '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/","message":"perm"}' \
    '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"/","message":"idle"}' \
    '{"hook_event_name":"Notification","notification_type":"agent_needs_input","cwd":"/","message":"input"}' \
    '{"hook_event_name":"Notification","notification_type":"agent_completed","cwd":"/","message":"done"}' \
    '{"hook_event_name":"SessionEnd","cwd":"/","reason":"clear"}'; do
    run run_hook "$UNCONFIGURED_HOME" "$ev"
    [ "$status" -eq 0 ]
  done
  [ ! -f "${BATS_TEST_TMPDIR}/osascript-args" ]

  # Turn-end events keep ECC parity and still notify.
  run run_hook "$UNCONFIGURED_HOME" \
    '{"hook_event_name":"Stop","cwd":"/","last_assistant_message":"your turn"}'
  [ "$status" -eq 0 ]
  grep -qF 'your turn' "${BATS_TEST_TMPDIR}/osascript-args"
}

@test "ntfy-notify: a configured channel still falls back for every attention event" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Once the channel exists, a transient publish failure must still reach the desktop —
  # the narrower rule above applies only to the never-bootstrapped state.
  export NTFY_TEST_CURL_EXIT=7
  run run_hook "$CONFIGURED_HOME" \
    '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/","message":"needs permission"}'
  [ "$status" -eq 0 ]
  grep -qF 'needs permission' "${BATS_TEST_TMPDIR}/osascript-args"
}
