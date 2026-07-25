#!/bin/bash
# Publish a Claude Code hook event to the self-hosted ntfy channel (kryota-dev/dotfiles#337).
#
# Wired in settings.json for four events: Notification (matcher omitted, so it fires for
# all eight notification types), Stop, StopFailure and SessionEnd. It replaces the ECC
# stop:desktop-notify hook, which is switched off through ECC_DISABLED_HOOKS — that hook
# only ever saw last_assistant_message, so it could not attribute a notification to its
# session, repo or account, which is the whole point of this one.
#
# The script reads the hook's JSON payload on stdin, reshapes it into an ntfy JSON publish
# and POSTs it over the tailnet. ntfy's JSON publish is used rather than the X-Title /
# X-Tags header form because titles and bodies here are routinely Japanese and HTTP header
# values are ASCII-oriented.
#
# Everything degrades and the hook always exits 0, so a session is never blocked:
#   - no ~/.config/ntfy/notify-env (the channel has not been bootstrapped), no jq, no curl,
#     Docker Desktop stopped, server unreachable, non-2xx, or timeout
#     -> local osascript notification instead.
# The fallback is deliberately limited to priority >= 3. Min-priority lifecycle events
# (SessionEnd, auth_success, elicitation_complete) exist for the server-side history only;
# turning them into desktop popups whenever the server is down would make retiring the
# Stop-only ECC hook a net INCREASE in local notification volume.
#
# Shared by both accounts through the absolute $HOME/.claude path, exactly like
# hooks-fork/ and clv2-session-notify.sh: ~/.claude-r06/settings.json is a symlink to the
# same settings.json, so one file serves cld and cld-r06.

set -eu

# ${HOME:-} rather than ${HOME}: this file is sourced, so under `set -u` an unset HOME
# would abort the hook and break the "always exits 0" contract. Tests point the script at a
# fixture by overriding HOME itself; there is deliberately no dedicated override variable,
# because `. "$ENV_FILE"` EXECUTES the file — an env var naming an arbitrary path would be
# a persistent code-execution primitive for anything that can set the hook's environment.
readonly ENV_FILE="${HOME:-}/.config/ntfy/notify-env"
# Codepoints, not bytes: the truncation happens inside jq, whose string slicing is
# Unicode-aware. `cut -c` and BSD `awk substr` are byte-oriented and would split a
# multi-byte character in half.
readonly SUMMARY_MAX_CHARS=200
readonly CURL_MAX_SECONDS=3
readonly FALLBACK_MIN_PRIORITY=3
readonly SESSION_TAG_CHARS=8
readonly EMPTY_SUMMARY_PLACEHOLDER='(no message text)'

# macOS ships /usr/bin/jq, so a JSON tool is always available even when PATH is minimal.
# Prefer whatever PATH resolves (mise provides a newer jq interactively) and fall back to
# the system copy. No Brewfile entry is added on purpose: jq is not Homebrew-installed on
# this machine, so `brew "jq"` would be dropped by the next `make dump-brewfile`.
JQ=''
if command -v jq >/dev/null 2>&1; then
  JQ="$(command -v jq)"
elif [ -x /usr/bin/jq ]; then
  JQ='/usr/bin/jq'
fi

# $1 = body, $2 = title. Both are passed as argv rather than interpolated into the script
# text, which is the pattern morning-radar.sh already established in this directory: the
# message never enters the AppleScript source, so there is no injection surface and nothing
# needs escaping. An earlier revision of this hook did interpolate, and therefore had to
# delete backslashes and rewrite double quotes to keep the generated script parseable —
# silently mangling any path or code fragment in the notification. argv passing keeps the
# text byte-for-byte.
notify_local() {
  if command -v osascript >/dev/null 2>&1; then
    osascript \
      -e 'on run argv' \
      -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
      -e 'end run' \
      -- "$1" "$2" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    # Linux desktops. Same argv principle; `--` stops a title beginning with a dash from
    # being parsed as an option. Kept because the ECC hook this replaces covered non-macOS
    # too, and the fallback is the only path left when the server is unreachable.
    #
    # argv passing stops shell injection but not markup: a freedesktop server advertising
    # body-markup renders a subset of HTML, including links, and libnotify does not escape
    # it. The body here is model-generated text, so escape the three XML-significant
    # characters rather than letting a prompt-injected reply render a clickable link under
    # a trusted "repo/branch · account" title.
    # The title is escaped too: it embeds the branch name, and git happily accepts a
    # branch containing `<`, so "trusted title" is an assumption rather than a fact.
    local nbody ntitle
    nbody="$(printf '%s' "$1" | LC_ALL=C sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    ntitle="$(printf '%s' "$2" | LC_ALL=C sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    notify-send -- "$ntitle" "$nbody" >/dev/null 2>&1 || true
  fi
  return 0
}

# ntfy tags travel as one comma-separated list, so a component containing a comma would
# silently split into two tags. Reduce every component to [A-Za-z0-9_-] — which is also
# ntfy's own topic charset — and collapse the runs that leaves behind.
#
# LC_ALL=C throughout: BSD tr/sed abort with "illegal byte sequence" on input that is not
# valid in the current locale, and branch names are arbitrary bytes. Under C these are pure
# byte filters that cannot fail that way, so a stray byte truncates nothing.
tag_safe() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | LC_ALL=C tr -s '-' | LC_ALL=C sed 's/^-//; s/-$//'
}

# Read one field out of the payload. Absent, null, or unparseable all yield an empty
# string, which every caller treats as "unknown" rather than as an error.
payload_field() {
  [ -n "$JQ" ] || return 0
  printf '%s' "$payload" | "$JQ" -r "${1} // empty" 2>/dev/null || printf ''
}

# priority / emoji_tag / event_tag are set here and consumed by the caller.
classify_event() {
  case "${1}:${2}" in
    'Notification:permission_prompt')
      priority=4 emoji_tag='warning' event_tag='permission-prompt'
      ;;
    'Notification:agent_needs_input')
      priority=4 emoji_tag='warning' event_tag='agent-needs-input'
      ;;
    'Notification:elicitation_dialog')
      priority=4 emoji_tag='warning' event_tag='elicitation-dialog'
      ;;
    'Notification:idle_prompt')
      priority=4 emoji_tag='hourglass' event_tag='idle-prompt'
      ;;
    'Notification:agent_completed')
      priority=3 emoji_tag='white_check_mark' event_tag='agent-completed'
      ;;
    'Notification:'*)
      # auth_success, elicitation_complete, elicitation_response and anything upstream
      # adds later: recorded in the history, silent on the device.
      priority=1 emoji_tag='information_source' event_tag="$(tag_safe "${2:-notification}")"
      ;;
    'Stop:'*)
      priority=3 emoji_tag='speech_balloon' event_tag='stop'
      ;;
    'StopFailure:'*)
      priority=5 emoji_tag='rotating_light' event_tag='stop-failure'
      ;;
    'SessionEnd:'*)
      priority=1 emoji_tag='wave' event_tag='session-end'
      ;;
    *)
      priority=3 emoji_tag='robot' event_tag="$(tag_safe "${1:-unknown}")"
      ;;
  esac
}

payload="$(cat 2>/dev/null)" || payload=''

hook_event="$(payload_field '.hook_event_name')"
notification_type="$(payload_field '.notification_type')"
session_id="$(payload_field '.session_id')"
cwd="$(payload_field '.cwd')"

priority=3
emoji_tag='robot'
event_tag='unknown'
classify_event "$hook_event" "$notification_type"

# Attribution. Every branch degrades to a literal rather than to an empty field, so a
# notification fired from a non-git directory still says where it came from.
repo='no-repo'
branch='no-branch'
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  # --git-common-dir, not --show-toplevel: in a linked worktree the toplevel basename is
  # the worktree's own directory name (wtp names them after the branch), so a notification
  # from ~/worktrees/dotfiles/feat/337-x would report the repo as "337-x". The common dir
  # always points at the main checkout's .git, whose parent is the real repository name.
  common_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common_dir=''
  if [ -z "$common_dir" ]; then
    common_dir="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || common_dir=''
    [ -z "$common_dir" ] || common_dir="${common_dir}/.git"
  fi
  if [ -n "$common_dir" ]; then
    repo="$(basename "$(dirname "$common_dir")")"
    branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=''
    if [ -z "$branch" ] || [ "$branch" = 'HEAD' ]; then
      branch="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)" || branch=''
      [ -n "$branch" ] || branch='detached'
    fi
  fi
fi

# Which account produced this: cld (~/.claude) or cld-r06 (~/.claude-r06). The wrapper
# exports CLAUDE_CONFIG_DIR per account, so the directory name is the discriminator.
account="$(basename "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}")"
case "$account" in
  '.claude') account='cld' ;;
  '.claude-r06') account='r06' ;;
  *) account="$(tag_safe "$account")" ;;
esac

title="${repo}/${branch} · ${account}"

tags="${emoji_tag},evt-${event_tag},repo-$(tag_safe "$repo"),branch-$(tag_safe "$branch"),acct-${account}"
if [ -n "$session_id" ]; then
  tags="${tags},sid-$(tag_safe "$(printf '%s' "$session_id" | cut -c "1-${SESSION_TAG_CHARS}")")"
fi

# Summary: the first line that carries prose, then truncated. Taking the head of the raw
# string instead would routinely yield a blank line or a bare marker, because assistant
# replies often open with a heading or a fence — this is the reduction ECC's
# desktop-notify.js performed, at 200 chars instead of 100 and with one addition: leading
# Markdown decoration is stripped before the emptiness test. That makes a line of pure
# structure (`---`, a code fence, an empty bullet) fall through to the next line, and turns
# "## 実装完了" into "実装完了" rather than shipping the marker to the lock screen.
# Field order follows the actual hook schemas, not just Notification/Stop: StopFailure
# carries `error` (and no message), SessionEnd carries `reason`. Reading only `message` and
# `last_assistant_message` published a literal "(no message text)" for exactly the two
# events that matter most — a failed turn is the only priority-5 event there is.
raw_message="$(payload_field '.message')"
[ -n "$raw_message" ] || raw_message="$(payload_field '.error')"
[ -n "$raw_message" ] || raw_message="$(payload_field '.reason')"
[ -n "$raw_message" ] || raw_message="$(payload_field '.last_assistant_message')"
summary="$(printf '%s\n' "$raw_message" |
  awk '{ sub(/^[ \t]+/, ""); sub(/^[#>*+`~=_-]+[ \t]*/, ""); sub(/[ \t*`_]+$/, "") } NF > 0 { print; exit }')" || summary=''
if [ -n "$summary" ] && [ -n "$JQ" ]; then
  # SC2016: $max is a jq variable bound by --argjson, not a shell variable. It must stay
  # unexpanded.
  # shellcheck disable=SC2016
  summary="$(printf '%s' "$summary" | "$JQ" -Rr --argjson max "$SUMMARY_MAX_CHARS" \
    'if length > $max then .[0:$max] + "…" else . end' 2>/dev/null)" || summary=''
fi
[ -n "$summary" ] || summary="$EMPTY_SUMMARY_PLACEHOLDER"

channel_configured=0
NTFY_BASE_URL=''
NTFY_TOPIC=''
NTFY_TOKEN=''
if [ -r "$ENV_FILE" ]; then
  # `set +u` around the source: an unset-variable expansion inside a sourced file is a
  # fatal shell error that `|| true` cannot catch, and it would take the hook down with it.
  # chezmoi renders this file with single-quoted literals, so there is nothing to expand —
  # this only guarantees the failure mode.
  set +u
  # shellcheck source=/dev/null
  . "$ENV_FILE" || true
  set -u
fi

# A non-https base URL cannot carry the bearer token safely; treat it as unconfigured so
# the local fallback runs instead of a doomed request.
case "${NTFY_BASE_URL}" in
  https://*) ;;
  *) NTFY_BASE_URL='' ;;
esac

if [ -n "$NTFY_BASE_URL" ] && [ -n "$NTFY_TOPIC" ] && [ -n "$NTFY_TOKEN" ]; then
  channel_configured=1
fi

published=0
if [ -n "$JQ" ] && [ "$channel_configured" -eq 1 ] &&
  command -v curl >/dev/null 2>&1; then
  # SC2016: every $name in the filter is a jq variable bound by --arg / --argjson.
  # shellcheck disable=SC2016
  body="$("$JQ" -n \
    --arg topic "$NTFY_TOPIC" \
    --arg title "$title" \
    --arg message "$summary" \
    --arg tags "$tags" \
    --argjson priority "$priority" \
    '{topic: $topic, title: $title, message: $message, priority: $priority, tags: ($tags | split(","))}' \
    2>/dev/null)" || body=''
  if [ -n "$body" ]; then
    # Explicit status check rather than --fail: --fail only treats >= 400 as an error, so a
    # 3xx would be reported as success and the publish would be silently lost with no
    # fallback. --proto '=https' refuses a plaintext base URL (the token travels in a
    # header), --noproxy '*' keeps the body and token away from any proxy the hook's
    # environment happens to define, and `--` stops a URL beginning with a dash being read
    # as an option. A connection failure yields 000 and falls through to the fallback.
    http_code="$(printf '%s' "$body" | curl --silent \
      --proto '=https' --noproxy '*' \
      --max-time "$CURL_MAX_SECONDS" \
      --header "Authorization: Bearer ${NTFY_TOKEN}" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      --output /dev/null --write-out '%{http_code}' \
      -- "$NTFY_BASE_URL" 2>/dev/null)" || http_code='000'
    case "$http_code" in
      2??) published=1 ;;
    esac
  fi
fi

# Fallback policy depends on whether the channel exists yet, which is not a detail: this
# feature ships with the channel disabled, so "never bootstrapped" is the state every
# machine is in the moment it lands.
#   - Configured: any priority >= FALLBACK_MIN_PRIORITY, so a transient publish failure
#     still reaches the desktop.
#   - Never bootstrapped: turn-end events only. The retired ECC hook fired on Stop alone,
#     and falling back for every priority-3-and-up event would turn its removal into a
#     roughly sevenfold INCREASE in local popups — the opposite of the invariant this
#     design set itself.
if [ "$published" -eq 0 ] && [ "$priority" -ge "$FALLBACK_MIN_PRIORITY" ]; then
  if [ "$channel_configured" -eq 1 ]; then
    notify_local "$summary" "$title"
  else
    case "$hook_event" in
      'Stop' | 'StopFailure') notify_local "$summary" "$title" ;;
    esac
  fi
fi

exit 0
