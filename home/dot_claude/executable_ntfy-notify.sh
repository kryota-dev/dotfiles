#!/bin/bash
# Claude Code hook -> ntfy publisher (kryota-dev/dotfiles#337).
#
# Wired in settings.json for the Notification event (permission_prompt,
# idle_prompt, agent_needs_input, agent_completed) and the Stop event. Reads
# the hook payload on stdin, enriches it with repo/branch/account/session
# attribution, and publishes JSON to the local ntfy server.
#
# Fail-open contract (async hook, timeout 10): every exit path is 0. When the
# server is unreachable the failure is logged and a content-free local alert
# sound plays; the session is never blocked. Deployed on every OS: with no
# env file (Linux, unprovisioned machines) the script is a silent no-op.
#
# Token hygiene: the write-only publisher token is sourced from a 0600 env
# file and reaches curl through a temporary `curl -K` config file. It must
# never appear in argv (`-H` with expansion is forbidden; bats asserts this),
# stdout, stderr, logs, or `set -x` traces (never enable tracing here).
set -euo pipefail

ENV_FILE="${NTFY_NOTIFY_ENV_FILE:-$HOME/.config/ntfy/notify-env}"
LOG_FILE="${NTFY_NOTIFY_LOG_FILE:-$HOME/Library/Logs/ntfy-notify.log}"
REDACT_TOML="${NTFY_NOTIFY_REDACT_TOML:-$HOME/.config/git/gitleaks-own.toml}"
ALERT_SOUND="${NTFY_NOTIFY_ALERT_SOUND:-/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Glass.m4r}"
BODY_LIMIT=200

log_failure() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

# Content-free local alert: signals "a notification was dropped" without
# resurrecting the rich local channel this system replaces.
local_alert() {
  if command -v afplay >/dev/null 2>&1 && [ -f "$ALERT_SOUND" ]; then
    afplay "$ALERT_SOUND" >/dev/null 2>&1 || true
  fi
}

# Extract the client-identifier alternation from the deployed gitleaks-own
# config. The file has exactly one fixed-format line:
#   regex = '''(?i)(name1|name2)'''
# Anything else (missing file, format drift) yields empty output and the
# caller falls back to truncation-only scrubbing.
extract_redact_pattern() {
  [ -f "$REDACT_TOML" ] || return 0
  sed -n "s/^regex = '''(?i)(\(.*\))'''\$/\1/p" "$REDACT_TOML" | head -n 1
}

# Best-effort client-identifier scrub (NOT a secret/PII detector — see the
# #337 PRD). The pattern reaches perl via the environment, never via code
# interpolation. Any failure returns the input unchanged.
scrub_body() {
  local body="$1" pattern scrubbed
  pattern="$(extract_redact_pattern 2>/dev/null || true)"
  if [ -z "$pattern" ]; then
    printf '%s' "$body"
    return 0
  fi
  if scrubbed="$(printf '%s' "$body" | NTFY_REDACT_PATTERN="$pattern" perl -pe 'BEGIN { $SIG{ALRM} = sub { die }; alarm 2 } s/$ENV{NTFY_REDACT_PATTERN}/[redacted]/gi' 2>/dev/null)"; then
    printf '%s' "$scrubbed"
  else
    printf '%s' "$body"
  fi
}

# Flatten to one line and hard-cap at BODY_LIMIT characters. jq slices by
# codepoint regardless of locale, so multibyte text is never cut mid-character
# (`cut -c` corrupts UTF-8 under LANG=C). Truncation is the primary defense
# for last_assistant_message-derived content.
truncate_body() {
  printf '%s' "$1" | tr '\n' ' ' | jq -Rrs --argjson n "$BODY_LIMIT" '.[0:$n]'
}

# CLAUDE_CONFIG_DIR -> account slug: ~/.claude -> default, ~/.claude-r06 -> r06.
# Intentionally self-contained (hook scripts stay dependency-free); statusline.sh
# derives the same slug for display — keep the two in sync on changes.
account_slug() {
  local base="${CLAUDE_CONFIG_DIR:-}"
  base="${base##*/}"
  case "$base" in
    "" | .claude) printf 'default' ;;
    .claude-*) printf '%s' "${base#.claude-}" ;;
    *) printf '%s' "$base" ;;
  esac
}

repo_name() {
  local cwd="$1" top
  if top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"; then
    basename "$top"
  else
    printf -- '-'
  fi
}

branch_name() {
  local cwd="$1" branch
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
  [ -n "$branch" ] && printf '%s' "$branch" || printf -- '-'
}

main() {
  local input event_name event topic priority emoji
  local session_id sid cwd account repo branch title body payload
  local curl_cfg

  # No env file / no jq -> silent no-op (unprovisioned machine or Linux).
  [ -f "$ENV_FILE" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # Sourcing is code execution: only accept a file we own with no group/other
  # permissions (the chezmoi-deployed private_ file is 0600). Anything else —
  # including an env-var override pointing at hostile content — fails open.
  [ -O "$ENV_FILE" ] || exit 0
  local env_mode
  if stat --version >/dev/null 2>&1; then
    env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
  else
    env_mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  fi
  case "$env_mode" in 600 | 400) ;; *) exit 0 ;; esac
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  { [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOKEN:-}" ]; } || exit 0

  input="$(cat)"
  event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
  if [ "$event_name" = "Notification" ]; then
    event="$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null || true)"
  else
    event="$event_name"
  fi

  # Topic names come exclusively from the env file (rendered from the [ntfy]
  # SSOT in .chezmoidata.toml) — no hardcoded fallbacks that could drift.
  case "$event" in
    permission_prompt | idle_prompt | agent_needs_input)
      topic="${NTFY_TOPIC_ATTENTION:-}"
      priority=4
      emoji="rotating_light"
      ;;
    agent_completed)
      topic="${NTFY_TOPIC_DONE:-}"
      priority=3
      emoji="white_check_mark"
      ;;
    Stop)
      topic="${NTFY_TOPIC_DONE:-}"
      priority=3
      emoji="checkered_flag"
      ;;
    *)
      # Unknown/unsubscribed event: ignore quietly.
      exit 0
      ;;
  esac
  # Broken/partial env file: fail open rather than publish to a bogus topic.
  [ -n "$topic" ] || exit 0

  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  sid="$(printf '%.8s' "$session_id")"
  [ -n "$sid" ] || sid='-'
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [ -n "$cwd" ] || cwd="$PWD"
  account="$(account_slug)"
  repo="$(repo_name "$cwd")"
  branch="$(branch_name "$cwd")"

  # Attribution fields go through the client-identifier scrub too: repo and
  # branch names are where client names are most likely to appear, and on
  # Notification events they are the only published content.
  repo="$(scrub_body "$repo")"
  branch="$(scrub_body "$branch")"
  title="[${account}] ${repo}@${branch} — ${event}"
  body=""
  if [ "$event" = "Stop" ]; then
    body="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
    # Scrub BEFORE truncating so an identifier straddling the 200-char boundary
    # cannot survive with its tail cut off; the byte pre-cap bounds the perl
    # input so pathological messages cannot stall the hook.
    body="$(printf '%s' "$body" | head -c 8192)"
    body="$(truncate_body "$(scrub_body "$body")")"
  fi

  payload="$(jq -n \
    --arg topic "$topic" \
    --arg title "$title" \
    --arg message "$body" \
    --arg emoji "$emoji" \
    --arg event "$event" \
    --arg repo "$repo" \
    --arg account "$account" \
    --arg sid "$sid" \
    --argjson priority "$priority" \
    '{topic: $topic, title: $title, message: $message, priority: $priority,
      tags: [$emoji, $event, $repo, $account, $sid]}')"

  # Token travels via a 0600 curl config file, never argv.
  umask 077
  curl_cfg="$(mktemp "${TMPDIR:-/tmp}/ntfy-notify.XXXXXX")"
  # EXIT alone misses signal deaths (the hook runs under a 10s timeout that
  # may kill us) — cover the catchable signals so the token file never lingers.
  trap 'rm -f "$curl_cfg"' EXIT INT TERM HUP
  printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" >"$curl_cfg"

  if ! printf '%s' "$payload" | curl -fs -K "$curl_cfg" --max-time 3 \
    -o /dev/null -d @- "$NTFY_URL" 2>/dev/null; then
    log_failure "publish failed: event=${event} topic=${topic} url=${NTFY_URL}"
    local_alert
  fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
