#!/bin/bash
# Claude Code statusline (chezmoi-managed, shared by ~/.claude and ~/.claude-r06).
#
# Layout (3 lines):
#   L1  host  dir(project-relative)  branch *dirty ⇡ahead⇣behind  worktree
#   L2  model  effort  context  5h  7d  session-cost  daily-cost   (cost in JPY)
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
I_HOST=$'\xef\x84\x88'       # nf-fa-desktop        U+F108
I_DIR=$'\xef\x81\xbb'        # nf-fa-folder         U+F07B
I_BRANCH=$'\xee\x9c\xa5'     # nf-dev-git_branch    U+E725
I_WT=$'\xf3\xb0\x99\x85'     # nf-md-file_tree      U+F0645
I_MODEL=$'\xf3\xb0\x9a\xa9'  # nf-md-robot       U+F06A9
I_EFFORT=$'\xef\x83\xa4'     # nf-fa-tachometer     U+F0E4
I_5H=$'\xef\x80\x97'         # nf-fa-clock_o        U+F017
I_7D=$'\xef\x81\xb3'         # nf-fa-calendar       U+F073
I_COST=$'\xef\x83\x96'       # nf-fa-money          U+F0D6
I_NET=$'\xef\x80\x92'        # nf-fa-signal         U+F012
I_BATT=$'\xf3\xb0\x81\xb9'   # nf-md-battery        U+F0079
I_CHARGE=$'\xf3\xb0\x82\x84' # nf-md-battery_charging U+F0084
I_PLUG=$'\xf3\xb0\x9a\xa5'   # nf-md-power_plug     U+F06A5

# Per-user cache directory (mode 700). Kept under $HOME instead of a
# world-readable, predictable /tmp path to avoid symlink/TOCTOU attacks and
# information disclosure on shared hosts.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 700 "$CACHE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# file_mtime <file> -> epoch seconds of last modification (0 if missing).
# Handles both macOS (stat -f %m) and Linux (stat -c %Y).
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# fmt_epoch <epoch> <strftime-fmt> -> formatted local time.
# Handles both macOS (date -r) and Linux (date -d @epoch).
fmt_epoch() {
  date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null
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
    (bunx ccusage@20 daily --since "$(date +%Y%m%d)" --json 2>/dev/null |
      jq -r '.totals.totalCost // empty' >"$cache.tmp" && mv "$cache.tmp" "$cache") &
  fi
  cat "$cache" 2>/dev/null
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
fmt_cost() {
  if [ -n "$JPY_RATE" ]; then
    LC_ALL=en_US.UTF-8 printf "¥%'.0f" "$(awk -v u="$1" -v r="$JPY_RATE" 'BEGIN{print u*r}')"
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
  # Cost must be a bare decimal — guards against emitting malformed JSON.
  case "$cost" in '' | *[!0-9.]*) return 0 ;; esac
  # Match ECC sanitizeSessionId: reject traversal, map any char outside
  # [A-Za-z0-9_-] to '_', cap at 64 chars.
  case "$sid" in *..* | */* | *\\*) return 0 ;; esac
  sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)
  [ -n "$sid" ] || return 0
  local tmp="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
  tmp="${tmp%/}"
  local target="$tmp/harness-cost-$sid.json" tmpf
  tmpf="$tmp/harness-cost-$sid.$$.tmp"
  printf '{"ts":%s,"cost_usd":%s}' "$(date +%s)" "$cost" >"$tmpf" 2>/dev/null &&
    mv -f "$tmpf" "$target" 2>/dev/null
}
write_harness_cost "$cost" "$session_id"

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

[ -n "$cost" ] && line2+="${SEP}${I_COST} $(fmt_cost "$cost") ${DIM}(session)${RST}"
daily=$(daily_cost)
[ -n "$daily" ] && line2+="${SEP}${I_COST} $(fmt_cost "$daily") ${DIM}(daily)${RST}"
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
