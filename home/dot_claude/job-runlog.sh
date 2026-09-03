#!/bin/bash
# Run history for scheduled (launchd) jobs — kryota-dev/dotfiles#643.
# Deployed 0644 to ~/.claude/job-runlog.sh (no executable_ prefix: this file is
# SOURCED, never executed).
#
# This file is SOURCED. Following the contract ~/.config/ntfy/lib.sh already
# establishes, it never calls `exit`: functions `return` a status and the
# caller decides the exit policy, and it never enables `set -x`. That matters
# more here than usual — the callers are weekly jobs whose actual product is a
# report, and losing a report because its bookkeeping failed would be a worse
# outcome than losing the bookkeeping.
#
# Why this is job-agnostic rather than knowledge-distill-specific: the blind
# spot #643 documents (a job failing week after week with nothing recorded
# anywhere) is not specific to knowledge-distill. dev.kryota.morning-radar and
# dev.kryota.macos-defaults-drift run the same wrapper shape with the same
# gap, and #644 needs the same "has this run at all lately" reading. Every
# function therefore takes the path to the caller's own history file: a new
# caller wires itself in by passing its own state dir, not by teaching this
# file about its label.
#
# Storage is JSON Lines: one object per run, appended, newest last. That shape
# is what makes "the same failure two weeks running" answerable by reading
# backwards from the end, and it survives partial writes — a truncated line is
# skipped rather than invalidating the whole history.

# Upper bound on retained records. A weekly job reaches this in about four
# years; it exists only so the file cannot grow without limit.
JOB_RUNLOG_MAX_RECORDS="${JOB_RUNLOG_MAX_RECORDS:-200}"

# Whether the library can do its job at all. Everything here is jq-backed, so
# a host without jq can still run its weekly report — it just cannot record.
# Callers are expected to degrade explicitly rather than fail (and, per #643,
# to say so out loud: a silently missing record is indistinguishable from a
# week that never ran, which is the failure mode this file exists to remove).
job_runlog_available() {
  command -v jq >/dev/null 2>&1
}

# Emit only the well-formed object lines of a history file, compact, in order.
# `fromjson?` drops lines that do not parse instead of aborting the read, so a
# single truncated write cannot hide every record written after it.
_job_runlog_lines() {
  local file="$1"
  [ -f "$file" ] || return 0
  jq -Rc 'fromjson? | select(type == "object")' <"$file" 2>/dev/null || true
}

# job_runlog_init <file>
# Create the history file and its directory with the same permissions the rest
# of this repo's per-user state uses (dir 0700, file 0600).
job_runlog_init() {
  local file="$1" dir
  [ -n "$file" ] || return 1
  dir="$(dirname "$file")"
  # umask inside the subshell so the directory is never briefly world-readable
  # between creation and chmod. The chmod stays for the case where the directory
  # already existed with looser permissions.
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || return 1
  if [ ! -f "$file" ]; then
    (
      umask 077
      : >"$file"
    ) 2>/dev/null || return 1
  fi
  chmod 600 "$file" 2>/dev/null || return 1
}

# job_runlog_record <file> <json-object>
# Append one run. `ts` and `ts_epoch` are injected here rather than supplied by
# the caller so every record carries them in one format. `ts_epoch` is what the
# staleness reader does arithmetic on, which keeps the read path free of any
# date parsing (and therefore of the GNU/BSD `date` divergence).
# Returns non-zero — without writing anything — if the payload is not a JSON
# object, so a malformed record can never enter the history.
job_runlog_record() {
  local file="$1" payload="$2" line max count tmp
  job_runlog_available || return 1
  [ -n "$file" ] || return 1
  line="$(printf '%s' "$payload" | jq -c \
    --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson epoch "$(date +%s)" \
    'if type == "object" then . + {ts: $ts, ts_epoch: $epoch}
     else error("run log record must be a JSON object") end' 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  (
    umask 077
    printf '%s\n' "$line" >>"$file"
  ) || return 1

  max="$JOB_RUNLOG_MAX_RECORDS"
  case "$max" in '' | *[!0-9]*) max=200 ;; esac
  [ "$max" -gt 0 ] || return 0
  count="$(wc -l <"$file" 2>/dev/null | tr -d ' ')"
  case "$count" in '' | *[!0-9]*) return 0 ;; esac
  [ "$count" -gt "$max" ] || return 0
  # Same directory as the target so the rename stays on one filesystem and the
  # history is never observed half-trimmed. `mktemp` rather than a PID-derived
  # name: it creates with O_EXCL and so will not follow a symlink planted at a
  # predictable path (CWE-377). An explicit template is required because macOS
  # `mktemp -t` ignores TMPDIR, and here the file has to land beside the target
  # anyway for the rename to stay on one filesystem.
  tmp="$(mktemp "${file}.trim.XXXXXX" 2>/dev/null)" || return 1
  (
    umask 077
    tail -n "$max" "$file" >"$tmp"
  ) 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$file" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
}

# job_runlog_last_field <file> <field>
# Echo one field of the most recent record; empty when there is no history.
job_runlog_last_field() {
  local file="$1" field="$2"
  job_runlog_available || return 1
  _job_runlog_lines "$file" | jq -rs --arg f "$field" '
    if length == 0 then ""
    else (.[-1][$f]) as $v | if $v == null then "" else ($v | tostring) end
    end'
}

# job_runlog_repeat_count <file> <status>
# Echo how many records at the END of the history share <status>. Counting from
# the end (rather than totalling matches) is the whole point: it answers "is
# this still happening", so an intervening success or a different failure
# breaks the streak and the count restarts.
job_runlog_repeat_count() {
  local file="$1" status="$2"
  if ! job_runlog_available; then
    printf '0\n'
    return 1
  fi
  _job_runlog_lines "$file" | jq -rs --arg s "$status" '
    [.[] | .status] | reverse | (map(. == $s) | index(false)) as $i
    | if $i == null then length else $i end'
}

# job_runlog_repeat_periods <file> <status>
# Echo how many DISTINCT `period` values appear in that trailing streak.
#
# Why this exists alongside repeat_count: a caller that retries writes more
# than one record for the same scheduled slot, so a run of three records can
# still be two weeks of failure — reporting it as "3 weeks running" would
# overstate the evidence in the one notification a person actually reads.
# `period` is whatever bucket the caller stamps its records with (an ISO week
# for a weekly job, a date for a daily one); this file never interprets it.
job_runlog_repeat_periods() {
  local file="$1" status="$2"
  if ! job_runlog_available; then
    printf '0\n'
    return 1
  fi
  _job_runlog_lines "$file" | jq -rs --arg s "$status" '
    [.[] | {status: .status, period: .period}] | reverse
    | (map(.status == $s) | index(false)) as $i
    | (if $i == null then . else .[0:$i] end)
    | [.[].period] | map(select(. != null)) | unique | length'
}

# job_runlog_stale_days <file>
# Echo whole days since the last SUCCESSFUL run, or `never` if none is
# recorded. Deliberately measured from the last success rather than the last
# run: a job that fails every week is running fine and producing nothing, which
# is exactly the state #643 went unnoticed in for five weeks.
#
# Note the limit of this signal: it can only be read while the job is running,
# so it detects "has not succeeded lately", not "has not fired at all". A job
# whose LaunchAgent never fires needs an outside poller.
job_runlog_stale_days() {
  local file="$1" epoch now
  if ! job_runlog_available; then
    printf 'never\n'
    return 1
  fi
  epoch="$(_job_runlog_lines "$file" | jq -rs '
    [.[] | select(.status == "ok") | .ts_epoch // empty]
    | if length == 0 then "" else (.[-1] | floor | tostring) end')"
  case "$epoch" in
    '' | *[!0-9]*)
      printf 'never\n'
      return 0
      ;;
  esac
  now="$(date +%s)"
  printf '%s\n' "$(((now - epoch) / 86400))"
}
