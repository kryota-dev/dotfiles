#!/usr/bin/env bats
#
# Contract tests for the shared scheduled-job run log (kryota-dev/dotfiles#643).
#
# The library is job-agnostic on purpose: every caller passes the path to its
# own run-history file, so morning-radar, macos-defaults-drift and the #644
# staleness work can reuse it by handing over their own state dir rather than
# by teaching this file about their labels.
#
# It is SOURCED, never executed. Mirroring ~/.config/ntfy/lib.sh, no function
# here may call `exit`: each returns a status and the caller decides the exit
# policy. A weekly report must not be lost because its bookkeeping failed.

load helpers/setup

LIB="${HOME_DIR}/dot_claude/job-runlog.sh"

setup() {
  RUNLOG="${BATS_TEST_TMPDIR}/state/runs.jsonl"
}

# Source the library (nothing runs on source) and call one of its functions.
run_fn() {
  run bash -c 'source "$1"; shift; fn="$1"; shift; "$fn" "$@"' _ "$LIB" "$@"
}

# Append records without going through job_runlog_record, so the reader tests
# can build an exact history (including timestamps in the past) to assert on.
seed() {
  mkdir -p "$(dirname "$RUNLOG")"
  printf '%s\n' "$@" >>"$RUNLOG"
}

@test "the library exists and passes bash -n" {
  [ -f "$LIB" ]
  run bash -n "$LIB"
  [ "$status" -eq 0 ]
}

@test "the library is sourced, not executed: no executable_ prefix, no exit calls" {
  # chezmoi's executable_ prefix is what deploys 0755; a sourced library must
  # not carry it (same posture as home/dot_config/ntfy/lib.sh.tmpl, 0644).
  [ ! -f "${HOME_DIR}/dot_claude/executable_job-runlog.sh" ]
  # `exit` in a sourced file kills the caller's shell. The weekly wrapper must
  # survive a bookkeeping failure, so the library returns statuses instead.
  run grep -nE '^[[:space:]]*exit[[:space:]]*[0-9]*[[:space:]]*$' "$LIB"
  [ "$status" -ne 0 ]
  # Anchored to a command position: the contract forbids *enabling* xtrace,
  # not mentioning it in the comment that documents the contract.
  run grep -nE '^[[:space:]]*set[[:space:]]+-[a-z]*x' "$LIB"
  [ "$status" -ne 0 ]
}

@test "job_runlog_init creates the dir 0700 and the file 0600" {
  run_fn job_runlog_init "$RUNLOG"
  [ "$status" -eq 0 ]
  [ -f "$RUNLOG" ]
  [ "$(_file_mode "$(dirname "$RUNLOG")")" = "700" ]
  [ "$(_file_mode "$RUNLOG")" = "600" ]
}

@test "job_runlog_init is idempotent and keeps an existing history" {
  run_fn job_runlog_init "$RUNLOG"
  [ "$status" -eq 0 ]
  seed '{"status":"ok"}'
  run_fn job_runlog_init "$RUNLOG"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$RUNLOG")" -eq 1 ]
}

@test "job_runlog_init returns non-zero when the dir cannot be created" {
  # A regular file where the state dir should be: mkdir -p must fail.
  printf 'not a dir\n' >"${BATS_TEST_TMPDIR}/blocked"
  run_fn job_runlog_init "${BATS_TEST_TMPDIR}/blocked/runs.jsonl"
  [ "$status" -ne 0 ]
}

@test "job_runlog_record appends one compact line and injects ts + ts_epoch" {
  run_fn job_runlog_init "$RUNLOG"
  run_fn job_runlog_record "$RUNLOG" '{"status":"ok","exit_code":0}'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$RUNLOG")" -eq 1 ]
  [ "$(jq -r .status <"$RUNLOG")" = "ok" ]
  [ "$(jq -r .exit_code <"$RUNLOG")" = "0" ]
  # ts_epoch is what the staleness reader arithmetic uses, so no `date`
  # parsing (and no GNU/BSD divergence) is needed at read time.
  run bash -c 'jq -e ".ts_epoch | type == \"number\"" <"$1"' _ "$RUNLOG"
  [ "$status" -eq 0 ]
  run bash -c 'jq -e ".ts | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T\")" <"$1"' _ "$RUNLOG"
  [ "$status" -eq 0 ]
}

@test "job_runlog_record rejects input that is not a JSON object" {
  run_fn job_runlog_init "$RUNLOG"
  run_fn job_runlog_record "$RUNLOG" 'not json'
  [ "$status" -ne 0 ]
  run_fn job_runlog_record "$RUNLOG" '["an","array"]'
  [ "$status" -ne 0 ]
  # A rejected record must not leave a partial or corrupt line behind.
  [ ! -s "$RUNLOG" ]
}

@test "job_runlog_record trims the history to JOB_RUNLOG_MAX_RECORDS" {
  run bash -c '
    source "$1"
    export JOB_RUNLOG_MAX_RECORDS=3
    job_runlog_init "$2"
    for i in 1 2 3 4 5; do job_runlog_record "$2" "{\"status\":\"ok\",\"n\":$i}"; done
  ' _ "$LIB" "$RUNLOG"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$RUNLOG")" -eq 3 ]
  # The oldest records are the ones dropped.
  [ "$(head -1 "$RUNLOG" | jq -r .n)" = "3" ]
  [ "$(tail -1 "$RUNLOG" | jq -r .n)" = "5" ]
  # Trimming must not loosen the 0600 the init established.
  [ "$(_file_mode "$RUNLOG")" = "600" ]
}

@test "job_runlog_last_field reads the most recent record" {
  seed '{"status":"max_turns","headline":"old"}' '{"status":"ok","headline":"new"}'
  run_fn job_runlog_last_field "$RUNLOG" status
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run_fn job_runlog_last_field "$RUNLOG" headline
  [ "$output" = "new" ]
}

@test "job_runlog_last_field is empty on a missing or empty history" {
  run_fn job_runlog_last_field "${BATS_TEST_TMPDIR}/absent.jsonl" status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "job_runlog_repeat_count counts only the trailing run of one status" {
  seed '{"status":"max_turns"}' '{"status":"max_turns"}' '{"status":"max_turns"}'
  run_fn job_runlog_repeat_count "$RUNLOG" max_turns
  [ "$output" = "3" ]
}

@test "job_runlog_repeat_count stops at the first differing status" {
  # This is the property that makes "2 weeks in a row, same cause" meaningful:
  # an intervening success or a different failure breaks the streak.
  seed '{"status":"max_turns"}' '{"status":"ok"}' '{"status":"max_turns"}'
  run_fn job_runlog_repeat_count "$RUNLOG" max_turns
  [ "$output" = "1" ]
  seed '{"status":"timeout"}'
  run_fn job_runlog_repeat_count "$RUNLOG" max_turns
  [ "$output" = "0" ]
}

@test "job_runlog_repeat_periods counts scheduled slots, not records" {
  # A retry writes two records for one week. Reporting that as "3 weeks
  # running" would overstate the evidence in the notification, so the streak a
  # human is shown is counted in distinct periods.
  seed '{"status":"api_error","period":"2026-W35"}' \
    '{"status":"api_error","period":"2026-W36"}' \
    '{"status":"api_error","period":"2026-W36"}'
  run_fn job_runlog_repeat_count "$RUNLOG" api_error
  [ "$output" = "3" ]
  run_fn job_runlog_repeat_periods "$RUNLOG" api_error
  [ "$output" = "2" ]
}

@test "job_runlog_repeat_periods stops at the first differing status" {
  seed '{"status":"max_turns","period":"2026-W33"}' \
    '{"status":"ok","period":"2026-W34"}' \
    '{"status":"max_turns","period":"2026-W35"}' \
    '{"status":"max_turns","period":"2026-W36"}'
  run_fn job_runlog_repeat_periods "$RUNLOG" max_turns
  [ "$output" = "2" ]
}

@test "job_runlog_repeat_periods is 0 on a missing history" {
  run_fn job_runlog_repeat_periods "${BATS_TEST_TMPDIR}/absent.jsonl" max_turns
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "job_runlog_repeat_count is 0 on a missing history" {
  run_fn job_runlog_repeat_count "${BATS_TEST_TMPDIR}/absent.jsonl" max_turns
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "job_runlog_stale_days measures from the last success, not the last run" {
  local now old
  now="$(date +%s)"
  old=$((now - 21 * 86400))
  seed "{\"status\":\"ok\",\"ts_epoch\":${old}}" \
    "{\"status\":\"max_turns\",\"ts_epoch\":$((now - 7 * 86400))}" \
    "{\"status\":\"max_turns\",\"ts_epoch\":${now}}"
  run_fn job_runlog_stale_days "$RUNLOG"
  [ "$status" -eq 0 ]
  [ "$output" = "21" ]
}

@test "job_runlog_stale_days reports never when nothing has ever succeeded" {
  seed '{"status":"max_turns","ts_epoch":1}'
  run_fn job_runlog_stale_days "$RUNLOG"
  [ "$status" -eq 0 ]
  [ "$output" = "never" ]
  run_fn job_runlog_stale_days "${BATS_TEST_TMPDIR}/absent.jsonl"
  [ "$output" = "never" ]
}

@test "readers skip corrupt lines instead of failing the whole history" {
  # A truncated write (power loss, disk full) must not blind the streak
  # detector to every record that came after it.
  seed '{"status":"ok"}' '{"status":"max_t' '{"status":"max_turns"}' '{"status":"max_turns"}'
  run_fn job_runlog_repeat_count "$RUNLOG" max_turns
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run_fn job_runlog_last_field "$RUNLOG" status
  [ "$output" = "max_turns" ]
}

@test "job_runlog_available reports whether jq is present, and writers fail closed without it" {
  run_fn job_runlog_available
  [ "$status" -eq 0 ]
  # With an empty PATH jq cannot be found. The library must return non-zero
  # rather than write an unvalidated line -- and must not exit the caller.
  run bash -c '
    source "$1"
    PATH=/nonexistent job_runlog_available && echo "AVAILABLE" || echo "UNAVAILABLE"
    PATH=/nonexistent job_runlog_record "$2" "{}" && echo "WROTE" || echo "REFUSED"
    echo "CALLER-ALIVE"
  ' _ "$LIB" "$RUNLOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNAVAILABLE"* ]]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"CALLER-ALIVE"* ]]
}
