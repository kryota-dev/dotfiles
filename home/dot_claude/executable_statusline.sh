#!/bin/bash
# Claude Code statusline (chezmoi-managed, shared by ~/.claude and ~/.claude-r06).
#
# Layout (3 lines):
#   L1  host  dir(project-relative)  branch *dirty ⇡ahead⇣behind  worktree
#   L2  model  effort  context  5h  7d  billable-session  billable-daily  (JPY)
#   L3  battery(macOS laptop only)  network-quality  claude-service-status
#
# Design notes:
#   - bash 3.2 compatible (macOS /bin/bash). Nerd Font glyphs are defined as raw
#     UTF-8 \xHH bytes inside $'...' (\u escapes are unavailable in bash 3.2 and
#     raw bytes survive editor/font accidents). Plain BMP symbols (circles,
#     arrows, ellipsis) are written as literal characters.
#   - All external/network I/O (ping, curl, ccusage, pmset) runs in the
#     background and is read from a cache, so rendering never blocks.
#   - stdin JSON spec: https://code.claude.com/docs/en/statusline

# Ensure mise-managed tools (jq, bunx) resolve even when Claude Code is launched
# outside an activated mise shell (e.g. headless). Zero overhead when mise is
# active: MISE_SHELL is exported by `mise activate`, so the prepend is skipped.
[ -n "$MISE_SHELL" ] || export PATH="$HOME/.local/share/mise/shims:$PATH"

input=$(cat)

# Single jq extraction. The \x1f (Unit Separator) field delimiter is used
# instead of a tab because tabs collapse empty fields under IFS word splitting.
# session_id is read last, so any \x1f inside its value can only spill into
# itself and never corrupts an earlier field.
IFS=$'\x1f' read -r model effort cwd project wt ctx cost fh_pct fh_reset sd_pct sd_reset session_id < <(echo "$input" | jq -r '[
  (.model.display_name // "Claude"),
  (.effort.level // ""),
  (.workspace.current_dir // .cwd // ""),
  (.workspace.project_dir // ""),
  (.workspace.git_worktree // ""),
  (.context_window.remaining_percentage // "" | tostring),
  (.cost.total_cost_usd // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring),
  (.rate_limits.seven_day.resets_at // "" | tostring),
  (.session_id // "")
] | join("\u001f")')

# ANSI colors
DIM=$'\033[2m'
RST=$'\033[0m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
RED_BOLD=$'\033[1;31m'
BOLD=$'\033[1m'
REVERSE=$'\033[7m'
SEP="${DIM} | ${RST}"

# Nerd Font glyphs (raw UTF-8 bytes; see header note)
I_HOST=$'\xef\x84\x88'         # nf-fa-desktop        U+F108
I_DIR=$'\xef\x81\xbb'          # nf-fa-folder         U+F07B
I_BRANCH=$'\xee\x9c\xa5'       # nf-dev-git_branch    U+E725
I_WT=$'\xf3\xb0\x99\x85'       # nf-md-file_tree      U+F0645
I_MODEL=$'\xf3\xb0\x9a\xa9'    # nf-md-robot       U+F06A9
I_EFFORT=$'\xef\x83\xa4'       # nf-fa-tachometer     U+F0E4
I_INSTINCT=$'\xf3\xb0\x9a\x83' # nf-md-dna          U+F0683
I_5H=$'\xef\x80\x97'           # nf-fa-clock_o        U+F017
I_7D=$'\xef\x81\xb3'           # nf-fa-calendar       U+F073
I_COST=$'\xef\x83\x96'         # nf-fa-money          U+F0D6
I_NET=$'\xef\x80\x92'          # nf-fa-signal         U+F012
I_BATT=$'\xf3\xb0\x81\xb9'     # nf-md-battery        U+F0079
I_CHARGE=$'\xf3\xb0\x82\x84'   # nf-md-battery_charging U+F0084
I_PLUG=$'\xf3\xb0\x9a\xa5'     # nf-md-power_plug     U+F06A5

# Per-user cache directory (mode 700). Kept under $HOME instead of a
# world-readable, predictable /tmp path to avoid symlink/TOCTOU attacks and
# information disclosure on shared hosts.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 700 "$CACHE_DIR" 2>/dev/null

# A quota window counts as consumed at 100% used: below that the spend is
# covered by the subscription, at or above it every further dollar is invoiced
# against usage credits. Named so this billing threshold is never mistaken for
# the 50/80 warning bands pct_color paints with.
QUOTA_EXHAUSTED_PCT=100
# Sessions never signal "done", so the per-session billing state (below) is aged
# out by mtime instead of being deleted on exit.
SESSION_STATE_TTL_DAYS=7

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# file_mtime <file> -> epoch seconds of last modification (0 if missing).
# GNU (stat -c %Y) first, BSD (stat -f %m) second. The order matters: GNU's -f
# is --file-system, and for the unrecognized %m directive it prints the whole
# filesystem report on STDOUT before exiting 1 -- so a BSD-first order appended
# that report to the real mtime, every TTL check died with an arithmetic syntax
# error, and bash tore down the enclosing function's subshell before it could
# `cat` its cache. That silently emptied the daily-cost, FX-rate, network and
# service-status segments on Linux. BSD stat has no -c and fails cleanly on
# stderr, so this order is correct on both. The digit guard keeps any future
# platform quirk from reaching $(( )) at all.
# $OSTYPE is a bash builtin, so picking the platform's own form costs nothing
# and keeps this to a single stat per call. A blind `-c || -f` chain would spawn
# two processes on macOS, and this runs five-plus times per render.
file_mtime() {
  local m
  case "$OSTYPE" in
    darwin*) m=$(stat -f %m "$1" 2>/dev/null) ;;
    *) m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) ;;
  esac
  case "$m" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$m" ;;
  esac
}

# fmt_epoch <epoch> <strftime-fmt> -> formatted local time.
# Handles both macOS (date -r) and Linux (date -d @epoch).
fmt_epoch() {
  date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null
}

# sanitize_session_id <session_id> -> filesystem-safe id, empty when unusable.
# Matches ECC's sanitizeSessionId: reject traversal outright, map any character
# outside [A-Za-z0-9_-] to '_', cap at 64 chars. Shared by every session-keyed
# cache file so the harness-cost contract (cost-tracker.js resolves the same
# filename) and the billing state can never disagree on a session's identity.
sanitize_session_id() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  case "$sid" in *..* | */* | *\\*) return 0 ;; esac
  printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64
}

# pct_exhausted <used_percentage> -> 0 when that quota window is fully consumed.
# Truncating at the decimal point is exact enough for a ">= 100" test and keeps
# this fork-free, which matters because it runs on every render including the
# common case where nothing is billable. A missing or non-numeric percentage is
# never exhausted.
pct_exhausted() {
  local p=${1%%.*}
  case "$p" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge "$QUOTA_EXHAUSTED_PCT" ]
}

# epoch_after <a> <b> -> 0 when epoch a is strictly later than epoch b.
# An unknown b loses to a known a, so a window that reports resets_at always
# outranks one whose resets_at the harness omitted.
epoch_after() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  case "$2" in '' | *[!0-9]*) return 0 ;; esac
  [ "$1" -gt "$2" ]
}

# Context fill indicator (non-battery; circle fill by remaining percentage).
ctx_circle() {
  local r=${1%%.*}
  if [ "$r" -ge 80 ]; then
    printf '●'
  elif [ "$r" -ge 60 ]; then
    printf '◕'
  elif [ "$r" -ge 40 ]; then
    printf '◑'
  elif [ "$r" -ge 20 ]; then
    printf '◔'
  else
    printf '○'
  fi
}

# Color by usage percentage (higher = worse): <50 green, <80 yellow, else red.
pct_color() {
  local p=${1%%.*}
  if [ "$p" -ge 80 ]; then
    printf '\033[31m'
  elif [ "$p" -ge 50 ]; then
    printf '\033[33m'
  else
    printf '\033[32m'
  fi
}

# Color by battery level (lower = worse): <20 red, <50 yellow, else green.
batt_color() {
  local p=${1%%.*}
  if [ "$p" -lt 20 ]; then
    printf '\033[31m'
  elif [ "$p" -lt 50 ]; then
    printf '\033[33m'
  else
    printf '\033[32m'
  fi
}

# Today's Claude cost via ccusage (5-minute cache, background refresh).
daily_cost() {
  local cache
  cache="$CACHE_DIR/daily_$(date +%Y%m%d)"
  local now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$cache")
  if [ $((now - mtime)) -gt 300 ]; then
    touch "$cache"
    # Guard the swap on a non-empty result, like usd_jpy_rate and claude_status
    # already do: a missing bunx or a failed ccusage run yields an empty file,
    # and moving that into place would destroy a perfectly good cached total.
    (bunx ccusage@20 daily --since "$(date +%Y%m%d)" --json 2>/dev/null |
      jq -r '.totals.totalCost // empty' >"$cache.tmp" &&
      [ -s "$cache.tmp" ] && mv "$cache.tmp" "$cache") &
  fi
  cat "$cache" 2>/dev/null
}

# Review-ready instinct-cluster count (🧬N). Reads a single integer cached at
# "<homunculus>/.review-ready-clusters", so this renderer stays a cheap file read with no
# python. Mirrors the homunculus-dir precedence and sanitizes to digits (defends against a
# malformed cache). Empty output => caller hides the segment.
#
# The writer is gone: clv2-session-notify.sh ran this count on every SessionStart and was
# removed in #496 (#473 AC-027) because a session-start nudge is not an action request. The
# cache is deliberately left in place (#473 scopes that change to stopping new writes), so
# whatever value it last held is what this segment now shows, unchanging. Removing the segment
# belongs with the statusline, not with the hook reduction — until then this reads a frozen
# cache on purpose.
clv2_cluster_count() {
  local dir="${CLV2_HOMUNCULUS_DIR:-}"
  case "$dir" in
    /*) ;;
    *)
      # Precedence kept identical to what wrote the cache (the removed
      # clv2-session-notify.sh, and scripts/lib/homunculus-dir.sh): a non-absolute
      # XDG_DATA_HOME is ignored, not used verbatim, so a restored writer and this
      # reader would still resolve to the same file.
      case "${XDG_DATA_HOME:-}" in
        /*) dir="${XDG_DATA_HOME}/ecc-homunculus" ;;
        *) dir="${HOME}/.local/share/ecc-homunculus" ;;
      esac
      ;;
  esac
  local f="$dir/.review-ready-clusters"
  [ -r "$f" ] || return 0
  tr -dc '0-9' <"$f" 2>/dev/null
}

# USD->JPY rate from frankfurter.dev (ECB rates, daily cache, background refresh).
usd_jpy_rate() {
  local cache
  cache="$CACHE_DIR/usdjpy"
  local now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$cache")
  if [ $((now - mtime)) -gt 86400 ]; then
    touch "$cache"
    (curl -s --max-time 3 "https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY" 2>/dev/null |
      jq -r '.rates.JPY // empty' >"$cache.tmp" && [ -s "$cache.tmp" ] && mv "$cache.tmp" "$cache") &
  fi
  cat "$cache" 2>/dev/null
}

# Format a USD amount: JPY (comma-separated integer) when a rate is cached,
# otherwise fall back to USD.
#
# The locale is only requested for %'s thousands grouping, and distros commonly
# ship without en_US.UTF-8 (Ubuntu generates C.UTF-8 only). bash then warns on
# stderr for every call, which lands in the rendered statusline, so the warning
# is dropped: losing the grouping is a cosmetic downgrade, printing a setlocale
# error into the status line is not. The redirect has to wrap the whole group --
# bash emits the warning while applying the prefix assignment, before the
# command's own redirections take effect.
fmt_cost() {
  if [ -n "$JPY_RATE" ]; then
    { LC_ALL=en_US.UTF-8 printf "¥%'.0f" "$(awk -v u="$1" -v r="$JPY_RATE" 'BEGIN{print u*r}')"; } 2>/dev/null
  else
    printf '$%.2f' "$1"
  fi
}

# Raw `pmset -g batt` output (60s cache, background refresh). macOS only.
battery_raw() {
  local cache
  cache="$CACHE_DIR/batt"
  local now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$cache")
  if [ $((now - mtime)) -gt 60 ]; then
    touch "$cache"
    (pmset -g batt 2>/dev/null >"$cache.tmp" && mv "$cache.tmp" "$cache") &
  fi
  cat "$cache" 2>/dev/null
}

# Average ping RTT to 1.1.1.1 in ms, or "offline" (15s cache, background refresh).
network_rtt() {
  local cache
  cache="$CACHE_DIR/net"
  local now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$cache")
  if [ $((now - mtime)) -gt 15 ]; then
    touch "$cache"
    (
      if route -n get default >/dev/null 2>&1 || ip route show default 2>/dev/null | grep -q .; then
        local out rtt
        if [ "$(uname)" = "Darwin" ]; then
          out=$(ping -c 1 -t 2 1.1.1.1 2>/dev/null)
        else
          out=$(ping -c 1 -w 2 1.1.1.1 2>/dev/null)
        fi
        rtt=$(printf '%s\n' "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
        [ -z "$rtt" ] && rtt="offline"
        printf '%s' "$rtt" >"$cache.tmp"
      else
        printf 'offline' >"$cache.tmp"
      fi
      mv "$cache.tmp" "$cache"
    ) &
  fi
  cat "$cache" 2>/dev/null
}

# Claude service status as "<indicator>\x1f<description>" (60s cache, background).
claude_status() {
  local cache
  cache="$CACHE_DIR/status"
  local now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$cache")
  if [ $((now - mtime)) -gt 60 ]; then
    touch "$cache"
    (curl -s --max-time 3 "https://status.claude.com/api/v2/status.json" 2>/dev/null |
      jq -r '"\(.status.indicator)\u001f\(.status.description)"' >"$cache.tmp" 2>/dev/null &&
      [ -s "$cache.tmp" ] && mv "$cache.tmp" "$cache") &
  fi
  cat "$cache" 2>/dev/null
}

JPY_RATE=$(usd_jpy_rate)

# Harness-cost contract (task #2): persist the harness-authoritative session
# cost so ECC's `stop:cost-tracker` hook can prefer it over its rate-table
# estimate. Path and format match what cost-tracker.js reads: Node's
# os.tmpdir()/harness-cost-<session_id>.json holding {ts, cost_usd}. os.tmpdir()
# is resolved the same way Node does (TMPDIR/TMP/TEMP, trailing slash stripped,
# else /tmp) so the bash writer and the node reader agree on the path.
write_harness_cost() {
  local cost="$1" sid="$2"
  [ -n "$cost" ] && [ -n "$sid" ] || return 0
  # Accept only a JSON number (including jq's scientific form, e.g. 1E-7 for
  # costs below 1e-6) so a malformed value can never reach the JSON body or the
  # filename. A naive [0-9.]-only filter both let "1.2.3" through and silently
  # dropped jq's 1E-7, which cost-tracker.js accepts via Number().
  [[ "$cost" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] || return 0
  sid=$(sanitize_session_id "$sid")
  [ -n "$sid" ] || return 0
  local tmp="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
  tmp="${tmp%/}"
  # Write a mktemp file (umask 077, O_EXCL random name) then atomically rename.
  # The final name is fixed by the cost-tracker contract and lives in a shared
  # tmpdir (world-writable /tmp on Linux), so a predictable ".$$.tmp" name would
  # be a symlink/TOCTOU target for a co-located local user; mktemp's random
  # O_EXCL name avoids that. The closing rename(2) replaces the target link
  # itself, so the final hop never follows a planted symlink either.
  local target="$tmp/harness-cost-$sid.json" tmpf old_umask
  old_umask=$(umask)
  umask 077
  tmpf=$(mktemp "$tmp/harness-cost-$sid.XXXXXX" 2>/dev/null) || {
    umask "$old_umask"
    return 0
  }
  umask "$old_umask"
  if printf '{"ts":%s,"cost_usd":%s}' "$(date +%s)" "$cost" >"$tmpf" 2>/dev/null; then
    mv -f "$tmpf" "$target" 2>/dev/null || rm -f "$tmpf" 2>/dev/null
  else
    rm -f "$tmpf" 2>/dev/null
  fi
}
# Rate-limits snapshot contract: persist the harness-reported quota pressure
# (five_hour/seven_day used_percentage + resets_at) to a per-profile cache
# file, the same "statusline -> file -> reader" contract write_harness_cost
# uses above. model-fitness-check reads this to gate on measured quota
# pressure instead of guessing from session length. Effort is session-scoped
# and must not live in a profile-scoped file (#449): multiple concurrent
# sessions under one profile would clobber each other's effort here, so
# readers use the `${CLAUDE_EFFORT}` skill template variable instead.
write_rate_limits_snapshot() {
  local fh_pct="$1" fh_reset="$2" sd_pct="$3" sd_reset="$4"
  # rate_limits is absent on stdin for API-key auth sessions, and also for
  # subscription sessions before the first API response lands. Either way, skip
  # silently and leave any prior snapshot in place (the reader ages it out via
  # ts) rather than clobbering a still-fresh window with an empty one.
  [ -n "$fh_pct" ] || [ -n "$sd_pct" ] || return 0
  # Same JSON-number regex as write_harness_cost. Reject each field
  # independently so one malformed value can't sink the other window.
  local num_re='^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
  [[ "$fh_pct" =~ $num_re ]] || fh_pct=""
  [[ "$fh_reset" =~ $num_re ]] || fh_reset=""
  [[ "$sd_pct" =~ $num_re ]] || sd_pct=""
  [[ "$sd_reset" =~ $num_re ]] || sd_reset=""
  # Both windows may have been invalidated above; re-check before writing.
  [ -n "$fh_pct" ] || [ -n "$sd_pct" ] || return 0

  # ~/.claude and ~/.claude-r06 share this script and CACHE_DIR, so the
  # profile (derived from CLAUDE_CONFIG_DIR, same as the line-1 badge) must
  # be baked into the filename to keep the two accounts' snapshots apart.
  local profile=${CLAUDE_CONFIG_DIR##*/}
  [ -n "$profile" ] || profile=".claude"
  profile=$(printf '%s' "$profile" | tr -c 'A-Za-z0-9._-' '_')

  # Build each window fragment only from validated fields; an empty fragment
  # omits the whole window object rather than emit a null/garbage value.
  local fh_json="" sd_json=""
  if [ -n "$fh_pct" ]; then
    if [ -n "$fh_reset" ]; then
      fh_json="\"five_hour\":{\"used_percentage\":${fh_pct},\"resets_at\":${fh_reset}},"
    else
      fh_json="\"five_hour\":{\"used_percentage\":${fh_pct}},"
    fi
  fi
  if [ -n "$sd_pct" ]; then
    if [ -n "$sd_reset" ]; then
      sd_json="\"seven_day\":{\"used_percentage\":${sd_pct},\"resets_at\":${sd_reset}},"
    else
      sd_json="\"seven_day\":{\"used_percentage\":${sd_pct}},"
    fi
  fi

  # Match write_harness_cost: umask 077 so the temp file is 0600 regardless of
  # the caller's umask. CACHE_DIR is already chmod 700, but that chmod swallows
  # errors (2>/dev/null), so a pre-existing loosely-permissioned XDG_CACHE_HOME
  # would otherwise leak quota data to group/other. Belt and suspenders.
  local target="$CACHE_DIR/rate_limits_${profile}.json" tmpf old_umask
  old_umask=$(umask)
  umask 077
  tmpf=$(mktemp "$CACHE_DIR/rate_limits_${profile}.XXXXXX" 2>/dev/null) || {
    umask "$old_umask"
    return 0
  }
  umask "$old_umask"
  # fh_json/sd_json each carry a trailing comma when present; strip the one
  # left dangling after concatenation before closing the object.
  local windows="${fh_json}${sd_json}"
  windows="${windows%,}"
  if printf '{"ts":%s,"profile":"%s",%s}' \
    "$(date +%s)" "$profile" "$windows" >"$tmpf" 2>/dev/null; then
    mv -f "$tmpf" "$target" 2>/dev/null || rm -f "$tmpf" 2>/dev/null
  else
    rm -f "$tmpf" 2>/dev/null
  fi
}

# Billable-delta contract (#446): under a subscription, spend inside the 5h/7d
# quota is already paid for and only spend past an exhausted window is invoiced
# against usage credits. A raw session/daily total therefore parks money that
# will never be billed next to money that will, behind the same glyph. The
# helpers below pin the spend at the moment a window ran out and report only the
# increment above that baseline.
#
# The baseline is session-scoped, so unlike the rate-limits snapshot above it
# lives in a session-keyed file: concurrent sessions under one profile would
# otherwise clobber each other's baseline, the failure #449 established for
# effort. The `billing` wrapper key leaves room for other session-scoped
# statusline state to join the same file, and #499 uses exactly that room for
# a `context` sibling key below.

# billing_state_path <session_id> -> this session's state file, empty when the
# id is unusable. Session ids are UUIDs, i.e. already filesystem-safe, so the
# common case is resolved with parameter expansion alone -- important because
# this sits on the render path. Only an unusual id pays the shared sanitizer's
# subshell, and for a [A-Za-z0-9_-] id the two agree by construction: `tr -c`
# has nothing to map and `cut -c1-64` is `${sid:0:64}`.
billing_state_path() {
  local sid="$1" safe
  case "$sid" in
    '') return 0 ;;
    *[!A-Za-z0-9_-]*)
      safe=$(sanitize_session_id "$sid")
      [ -n "$safe" ] || return 0
      ;;
    *) safe=${sid:0:64} ;;
  esac
  printf '%s/session_%s.json' "$CACHE_DIR" "$safe"
}

# session_state_write <target> <billing_body> <context_body> -> the shared
# atomic-write core for this session's state file (#499), producing
# {"ts":N[,"billing":{...}][,"context":{...}]}. Each body is included only
# when non-empty, so billing_state_reset can drop `billing` while keeping
# `context`, and the no-rate_limits fallback further below can write
# `context` with no `billing` at all. Mirrors write_harness_cost /
# write_rate_limits_snapshot's umask 077 + mktemp + rename dance, so every
# session-state file gets the same 0600-under-lax-umask guarantee and the same
# silent-failure contract: a missing write is simply retried next render.
session_state_write() {
  local target="$1" billing_body="$2" context_body="$3"
  local body=""
  [ -n "$billing_body" ] && body="${body},\"billing\":{${billing_body}}"
  [ -n "$context_body" ] && body="${body},\"context\":{${context_body}}"

  local tmpf old_umask
  old_umask=$(umask)
  umask 077
  tmpf=$(mktemp "${target%.json}.XXXXXX" 2>/dev/null) || {
    umask "$old_umask"
    return 0
  }
  umask "$old_umask"
  if printf '{"ts":%s%s}' "$(date +%s)" "$body" >"$tmpf" 2>/dev/null; then
    mv -f "$tmpf" "$target" 2>/dev/null || rm -f "$tmpf" 2>/dev/null
  else
    rm -f "$tmpf" 2>/dev/null
  fi
}

# Drop this session's baseline: the windows have room again, so the next
# overage has to start from a fresh one. Context is unrelated to quota state
# and is persisted every render regardless of it (#499), so this no longer
# always deletes the file: with a valid context body the file is rewritten
# carrying only `context` (billing dropped), and it is removed outright only
# when there is no context to keep either.
billing_state_reset() {
  local target
  target=$(billing_state_path "$1")
  [ -n "$target" ] || return 0
  if [ -n "$SESSION_CTX_BODY" ]; then
    session_state_write "$target" "" "$SESSION_CTX_BODY"
  else
    [ -e "$target" ] && rm -f "$target" 2>/dev/null
  fi
  return 0
}

# Age out the baselines left behind by sessions that have ended. Sessions never
# signal "done", so they are pruned by mtime. Called on every render regardless
# of quota state -- a baseline written during an overage must still be collected
# once that session is gone, and the overage may outlive it.
#
# The leading glob is a shell builtin, so a machine with no baseline on disk --
# every machine that never exceeds its quota -- pays no fork at all here. Once
# some baseline does exist the daily stamp check costs a `date` and a `stat`,
# which is the price of collecting it.
#
# Note `find -mtime +N` compares whole 24h periods with a strict `>`, so the
# effective retention is up to N+1 days. That slack is fine for a sweep.
billing_state_prune() {
  local f found=0
  for f in "$CACHE_DIR"/session_*.json; do
    if [ -e "$f" ]; then
      found=1
      break
    fi
  done
  [ "$found" = 1 ] || return 0

  # Once a day, the same stamp-file TTL idiom the caches above use.
  # Backgrounded so the render never waits on the directory walk.
  local stamp="$CACHE_DIR/.session-gc" now mtime
  now=$(date +%s)
  mtime=$(file_mtime "$stamp")
  if [ $((now - mtime)) -gt 86400 ]; then
    touch "$stamp"
    (find "$CACHE_DIR" -maxdepth 1 -type f -name 'session_*.json' -mtime "+${SESSION_STATE_TTL_DAYS}" -delete 2>/dev/null) &
  fi
}

# Persist the baseline, mirroring write_harness_cost / write_rate_limits_snapshot:
# every numeric field is re-validated as a JSON number, fields that did not
# validate are omitted rather than written as null. The actual write is
# delegated to session_state_write (#499), which folds in the session's
# current context body alongside `billing` so a session that is being billed
# also keeps a live context snapshot in the same file.
billing_state_write() {
  local target="$1" window="$2" resets_at="$3" sess_base="$4"
  local daily_date="$5" daily_base="$6" daily_carry="$7" daily_last="$8"

  case "$window" in
    five_hour | seven_day) ;;
    *) return 0 ;;
  esac
  local num_re='^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
  [[ "$resets_at" =~ $num_re ]] || resets_at=""
  [[ "$sess_base" =~ $num_re ]] || sess_base=""
  # The daily trio is all-or-nothing: a carry without the baseline it was
  # measured against would silently overstate the next day's charge.
  case "$daily_date" in
    '' | *[!0-9]*) daily_date="" ;;
  esac
  if ! [[ "$daily_base" =~ $num_re ]] || ! [[ "$daily_carry" =~ $num_re ]] || ! [[ "$daily_last" =~ $num_re ]]; then
    daily_date=""
  fi

  local body="\"window\":\"${window}\""
  [ -n "$resets_at" ] && body="${body},\"resets_at\":${resets_at}"
  [ -n "$sess_base" ] && body="${body},\"session_baseline\":${sess_base}"
  [ -n "$daily_date" ] && body="${body},\"daily_date\":\"${daily_date}\",\"daily_baseline\":${daily_base},\"daily_carry\":${daily_carry},\"daily_last\":${daily_last}"

  session_state_write "$target" "$body" "$SESSION_CTX_BODY"
}

# billing_delta <fh_pct> <fh_reset> <sd_pct> <sd_reset> <cost> <daily> <sid>
#
# Results come back in three globals (the file's existing convention for cheap
# cross-function results, cf. JPY_RATE) instead of on stdout, so the common path
# costs no subshell:
#   BILLING_STATE   none     no rate_limits on stdin -> raw totals are billed
#                   included inside quota -> nothing is billable
#                   billed   a window is exhausted -> BILLED_* hold the deltas
#   BILLED_SESSION  billable session spend, empty when it cannot be computed
#   BILLED_DAILY    billable spend today, carried across midnight
billing_delta() {
  local fh_pct="$1" fh_reset="$2" sd_pct="$3" sd_reset="$4"
  local cost="$5" daily="$6" sid="$7"

  BILLING_STATE="none"
  BILLED_SESSION=""
  BILLED_DAILY=""

  # No rate_limits at all: an API-key (pay-as-you-go) session, or a
  # subscription session before its first API response. There is no quota being
  # consumed, so every dollar really is billed -- report the raw totals.
  [ -n "$fh_pct" ] || [ -n "$sd_pct" ] || return 0

  local fh_out=0 sd_out=0
  pct_exhausted "$fh_pct" && fh_out=1
  pct_exhausted "$sd_pct" && sd_out=1

  if [ "$fh_out" = 0 ] && [ "$sd_out" = 0 ]; then
    # Inside quota: nothing is billable, and a baseline left from an earlier
    # overage is now stale -- the next overage has to start from a fresh one.
    BILLING_STATE="included"
    billing_state_reset "$sid"
    return 0
  fi

  local state_file
  state_file=$(billing_state_path "$sid")
  # With no usable session id there is nowhere to keep a baseline, and a delta
  # cannot be invented. Fall back to the raw totals rather than show a number
  # with nothing behind it.
  [ -n "$state_file" ] || return 0

  # Anchor on the exhausted window that resets last: it is the one keeping the
  # overage alive, so the baseline outlives the shorter window rolling over.
  local anchor_win="" anchor_reset=""
  if [ "$fh_out" = 1 ]; then
    anchor_win="five_hour"
    anchor_reset="$fh_reset"
  fi
  if [ "$sd_out" = 1 ] && { [ -z "$anchor_win" ] || epoch_after "$sd_reset" "$anchor_reset"; }; then
    anchor_win="seven_day"
    anchor_reset="$sd_reset"
  fi

  local st_win="" st_reset="" st_sess="" st_date="" st_base="" st_carry="" st_last="" st_ctx=""
  if [ -f "$state_file" ]; then
    # st_ctx rides along in the same jq pass (no extra fork). It is not part of
    # the billing state machine below -- only of the write decision.
    IFS=$'\x1f' read -r st_win st_reset st_sess st_date st_base st_carry st_last st_ctx < <(
      jq -r '[
        (.billing.window // ""),
        (.billing.resets_at // "" | tostring),
        (.billing.session_baseline // "" | tostring),
        (.billing.daily_date // ""),
        (.billing.daily_baseline // "" | tostring),
        (.billing.daily_carry // "" | tostring),
        (.billing.daily_last // "" | tostring),
        (.context.remaining_percentage // "" | tostring)
      ] | join("\u001f")' "$state_file" 2>/dev/null
    )
  fi
  local was="${st_win}|${st_reset}|${st_sess}|${st_date}|${st_base}|${st_carry}|${st_last}"

  # The stored anchor holds only while its window is the same instance and is
  # still exhausted. used_percentage is monotonic within one instance, so that
  # pair proves the overage never lapsed since the baseline was taken -- which
  # is why no wall-clock comparison is needed, and clock skew cannot lose a
  # baseline or resurrect a stale one.
  local win_out=0 live_reset=""
  case "$st_win" in
    five_hour)
      win_out=$fh_out
      live_reset="$fh_reset"
      ;;
    seven_day)
      win_out=$sd_out
      live_reset="$sd_reset"
      ;;
  esac
  if [ "$win_out" = 1 ] && [ "$live_reset" = "$st_reset" ]; then
    # Hand the anchor over to a longer-lived window while both are exhausted:
    # continuity transfers at that instant, so the baseline survives the
    # current window's reset instead of being discarded mid-overage.
    if [ "$anchor_win" != "$st_win" ] && epoch_after "$anchor_reset" "$st_reset"; then
      st_win="$anchor_win"
      st_reset="$anchor_reset"
    fi
  else
    # Fresh anchor. A session that was already running when the window ran out
    # is the common case, so the baseline is this render's spend: anchoring at 0
    # would bill everything it spent while still inside quota. The cost is that
    # a session which *starts* mid-overage loses its first turn from the total,
    # since there is no way to tell the two apart without state we do not have.
    # Under-reporting by one turn beats over-reporting a whole session.
    st_win="$anchor_win"
    st_reset="$anchor_reset"
    st_sess=""
    st_date=""
    st_base=""
    st_carry=""
    st_last=""
  fi

  # The two halves of the baseline are taken independently and lazily: ccusage
  # refreshes in the background, so `daily` is empty on a cold cache and
  # anchoring it at 0 there would bill the whole day.
  [ -n "$st_sess" ] || st_sess="$cost"

  local today=""
  if [ -n "$daily" ] || [ -n "$st_date" ]; then
    today=$(date +%Y%m%d)
  fi
  if [ -z "$st_date" ] && [ -n "$daily" ]; then
    st_date="$today"
    st_base="$daily"
    st_carry=0
    st_last="$daily"
  elif [ -n "$st_date" ] && [ "$st_date" != "$today" ]; then
    # ccusage totals reset at midnight, so bank the previous day's billable
    # remainder into the carry before re-basing on the new day. Everything spent
    # today is billable, hence the 0 baseline.
    st_carry=$(awk -v c="$st_carry" -v l="$st_last" -v b="$st_base" \
      'BEGIN { d = l - b; if (d < 0) d = 0; printf "%.10f", c + d }')
    st_date="$today"
    st_base=0
    st_last="${daily:-0}"
  fi
  if [ -n "$st_date" ] && [ -n "$daily" ]; then
    st_last="$daily"
  fi

  # One awk pass for all the money: bash 3.2 has no float arithmetic. Every
  # delta is clamped at 0 -- including after the carry is added, since the carry
  # comes back out of the state file and a corrupted one must not be able to
  # render a negative charge for even a single frame.
  IFS=$'\x1f' read -r BILLED_SESSION BILLED_DAILY < <(
    awk -v cost="$cost" -v sb="$st_sess" -v dn="$daily" -v db="$st_base" -v dc="$st_carry" '
      BEGIN {
        s = ""
        d = ""
        if (cost != "" && sb != "") {
          s = cost - sb
          if (s < 0) s = 0
        }
        if (dn != "" && db != "") {
          d = dn - db
          if (d < 0) d = 0
          d = d + dc
          if (d < 0) d = 0
        }
        printf "%s\037%s\n", s, d
      }'
  )

  BILLING_STATE="billed"
  # Rendering happens on every turn, but the baseline only moves when ccusage
  # refreshes or the day turns, so skip the write when nothing actually changed.
  local now_state="${st_win}|${st_reset}|${st_sess}|${st_date}|${st_base}|${st_carry}|${st_last}"
  # Context moves on every render (#499), so a valid context body forces the
  # write even when the billing half is unchanged -- otherwise a session
  # sitting in a stable overage would freeze its persisted context at whatever
  # it was on the render that last moved the baseline.
  # The stored-context test is the other half of that: every write embeds the
  # *current* body, so when the harness stops reporting context_window the key
  # has to be actively dropped -- a skipped write would leave the last reported
  # value on disk. Self-terminating: once the key is gone both tests are empty
  # and the write is skipped again.
  if [ "$now_state" != "$was" ] || [ ! -f "$state_file" ] ||
    [ -n "$SESSION_CTX_BODY" ] || [ -n "$st_ctx" ]; then
    billing_state_write "$state_file" "$st_win" "$st_reset" "$st_sess" \
      "$st_date" "$st_base" "$st_carry" "$st_last"
  fi
}

write_harness_cost "$cost" "$session_id"
write_rate_limits_snapshot "$fh_pct" "$fh_reset" "$sd_pct" "$sd_reset"

# ---------------------------------------------------------------------------
# Line 1: host | dir | branch *dirty ⇡ahead⇣behind | worktree
# ---------------------------------------------------------------------------
# Config profile badge: prominent (reverse video) when launched with a
# non-default CLAUDE_CONFIG_DIR (e.g. `cld-r06` -> R06). Empty for the
# default ~/.claude profile, so the badge's presence alone signals the profile.
profile=${CLAUDE_CONFIG_DIR##*/}
profile_badge=""
case "$profile" in
  '' | '.claude') ;;
  *)
    tag=${profile#.claude-}
    tag=${tag#.}
    tag=$(printf '%s' "$tag" | tr '[:lower:]' '[:upper:]')
    profile_badge="${REVERSE}${BOLD} ${tag} ${RST}"
    ;;
esac

line1="${profile_badge:+$profile_badge }${I_HOST} ${MAGENTA}$(hostname -s)${RST}"

if [ -n "$project" ] && [ "$cwd" != "$project" ] && [[ "$cwd" == "$project"/* ]]; then
  rel_path="$(basename "$project")/${cwd#"$project"/}"
else
  rel_path=$(basename "$cwd")
fi
line1+="${SEP}${I_DIR} ${CYAN}${rel_path}${RST}"

if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  line1+="${SEP}${YELLOW}${I_BRANCH} ${branch:-detached}${RST}"
  dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" -gt 0 ] && line1+=" ${RED}*${dirty}${RST}"
  read -r behind ahead < <(git -C "$cwd" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  [ "${ahead:-0}" -gt 0 ] && line1+=" ${CYAN}⇡${ahead}${RST}"
  [ "${behind:-0}" -gt 0 ] && line1+=" ${CYAN}⇣${behind}${RST}"
fi

[ -n "$wt" ] && line1+="${SEP}${I_WT} ${wt}"
printf '%s\n' "$line1"

# ---------------------------------------------------------------------------
# Line 2: model | effort | context | 5h | 7d | session cost | daily cost
# ---------------------------------------------------------------------------
line2="${I_MODEL} ${model}"
[ -n "$effort" ] && line2+="${SEP}${I_EFFORT} ${effort}"

icc=$(clv2_cluster_count)
[ -n "$icc" ] && [ "$icc" -gt 0 ] 2>/dev/null && line2+="${SEP}${I_INSTINCT} ${icc}"

if [ -n "$ctx" ]; then
  used=$((100 - ${ctx%%.*}))
  line2+="${SEP}$(ctx_circle "$ctx") $(pct_color "$used")${ctx}%${RST}"
fi

if [ -n "$fh_pct" ]; then
  fh_rem=$(awk -v p="$fh_pct" 'BEGIN{printf "%.0f", 100-p}')
  line2+="${SEP}${I_5H} 5h $(pct_color "$fh_pct")${fh_rem}%${RST}"
  [ -n "$fh_reset" ] && line2+=" ${DIM}↻$(fmt_epoch "$fh_reset" '%H:%M')${RST}"
fi

if [ -n "$sd_pct" ]; then
  sd_rem=$(awk -v p="$sd_pct" 'BEGIN{printf "%.0f", 100-p}')
  line2+="${SEP}${I_7D} 7d $(pct_color "$sd_pct")${sd_rem}%${RST}"
  [ -n "$sd_reset" ] && line2+=" ${DIM}↻$(fmt_epoch "$sd_reset" '%-m/%-d %H:%M')${RST}"
fi

# Session context-window snapshot (#499): validated once per render so every
# writer below (the "billed" and "included" paths inside billing_delta, and
# the no-rate_limits fallback right after it) can embed it without
# re-validating or re-deriving it. Unlike billing, which is rare, context
# moves on every render and is persisted unconditionally -- readers need a
# live value regardless of quota state. Same JSON-number regex as
# write_harness_cost / write_rate_limits_snapshot; an invalid or missing value
# leaves this empty, which omits the `context` key rather than writing null.
SESSION_CTX_BODY=""
[[ "$ctx" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] && SESSION_CTX_BODY="\"remaining_percentage\":${ctx}"

# Cost, as money actually owed rather than money spent (#446). daily_cost is
# read even while nothing is billable, so ccusage stays warm and a baseline can
# be taken the instant a quota window runs out.
daily=$(daily_cost)
billing_delta "$fh_pct" "$fh_reset" "$sd_pct" "$sd_reset" "$cost" "$daily" "$session_id"
# billing_delta leaves BILLING_STATE at "none" without ever touching the state
# file in two cases: stdin carries no rate_limits at all, or the session id is
# unusable (billing_state_path resolves empty, so there is nowhere to write --
# a silent no-op, same guard billing_state_reset uses). Cover the first case
# here so context still gets persisted even when nothing is billable.
if [ "$BILLING_STATE" = "none" ] && [ -n "$SESSION_CTX_BODY" ]; then
  ctx_only_target=$(billing_state_path "$session_id")
  [ -n "$ctx_only_target" ] && session_state_write "$ctx_only_target" "" "$SESSION_CTX_BODY"
fi
# Collect ended sessions' baselines regardless of this session's quota state: a
# machine sitting in a long overage would otherwise never sweep, and a session
# that is inside quota is not the only one that can leave a baseline behind.
billing_state_prune
case "$BILLING_STATE" in
  billed)
    [ -n "$BILLED_SESSION" ] && line2+="${SEP}${I_COST} $(fmt_cost "$BILLED_SESSION") ${DIM}(session)${RST}"
    [ -n "$BILLED_DAILY" ] && line2+="${SEP}${I_COST} $(fmt_cost "$BILLED_DAILY") ${DIM}(daily)${RST}"
    ;;
  included)
    # Inside quota the spend is covered, so there is no amount to show. The
    # marker still occupies the slot: a silently missing segment would read as
    # "the cost lookup broke" rather than "this costs nothing".
    line2+="${SEP}${I_COST} ${DIM}incl.${RST}"
    ;;
  *)
    # Pay-as-you-go (no rate_limits): the raw totals already are the bill.
    [ -n "$cost" ] && line2+="${SEP}${I_COST} $(fmt_cost "$cost") ${DIM}(session)${RST}"
    [ -n "$daily" ] && line2+="${SEP}${I_COST} $(fmt_cost "$daily") ${DIM}(daily)${RST}"
    ;;
esac
printf '%s\n' "$line2"

# ---------------------------------------------------------------------------
# Line 3: battery (macOS laptop) | network quality | Claude service status
# ---------------------------------------------------------------------------
line3=""

# Battery (macOS only, and only when an internal battery is present).
if [ "$(uname)" = "Darwin" ]; then
  batt=$(battery_raw)
  case "$batt" in
    *InternalBattery*)
      batt_pct=$(printf '%s\n' "$batt" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
      case "$batt" in
        *discharging*) batt_icon=$I_BATT ;;
        *"; charging"*) batt_icon=$I_CHARGE ;;
        *) batt_icon=$I_PLUG ;;
      esac
      [ -n "$batt_pct" ] && line3="${batt_icon} $(batt_color "$batt_pct")${batt_pct}%${RST}"
      ;;
  esac
fi

# Network quality (ping RTT tiers). Empty cache (cold) is skipped silently.
net=$(network_rtt)
if [ "$net" = "offline" ]; then
  net_seg="${RED}${I_NET} offline${RST}"
elif [ -n "$net" ]; then
  net_int=${net%%.*}
  # Guard against a non-numeric cache value; skip the segment if malformed.
  case "$net_int" in
    '' | *[!0-9]*) net_int=-1 ;;
  esac
  if [ "$net_int" -lt 0 ]; then
    : # malformed value; leave net_seg unset
  elif [ "$net_int" -lt 80 ]; then
    net_seg="${GREEN}${I_NET} ${net_int}ms${RST}" # excellent / good
  elif [ "$net_int" -lt 150 ]; then
    net_seg="${YELLOW}${I_NET} ${net_int}ms${RST}" # fair
  else
    net_seg="${RED}${I_NET} ${net_int}ms${RST}" # poor
  fi
fi
[ -n "$net_seg" ] && line3="${line3:+$line3$SEP}$net_seg"

# Claude service status.
status_raw=$(claude_status)
if [ -n "$status_raw" ]; then
  IFS=$'\x1f' read -r ind desc <<<"$status_raw"
  show_desc=0
  case "$ind" in
    none) status_col=$GREEN ;;
    minor)
      status_col=$YELLOW
      show_desc=1
      ;;
    major)
      status_col=$RED
      show_desc=1
      ;;
    critical)
      status_col=$RED_BOLD
      show_desc=1
      ;;
    maintenance)
      status_col=$BLUE
      show_desc=1
      ;;
    *) status_col=$DIM ;;
  esac
  status_seg="${status_col}●${RST} claude"
  if [ "$show_desc" = 1 ] && [ -n "$desc" ]; then
    desc="${desc//[[:cntrl:]]/}" # strip control chars (terminal-injection hardening)
    [ ${#desc} -gt 28 ] && desc="${desc:0:28}…"
    status_seg="$status_seg ${status_col}${desc}${RST}"
  fi
  line3="${line3:+$line3$SEP}$status_seg"
fi

[ -n "$line3" ] && printf '%s\n' "$line3"

# Always succeed: the final test above returns non-zero when line 3 is empty
# (e.g. cold caches on a non-laptop), which would otherwise be the exit code.
exit 0
