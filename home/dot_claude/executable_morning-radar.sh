#!/bin/bash
# Weekday-morning radar wrapper (kryota-dev/dotfiles#257).
# Launched by the dev.kryota.morning-radar LaunchAgent on weekday mornings.
# Runs /morning-brief headless (degraded mode) on the personal Claude Code
# account, saves the brief to a dated file, and hands the result off as a
# macOS notification. Detection + notify only: no downstream skill dispatch.
set -euo pipefail

# launchd provides a minimal environment; build PATH ourselves so the claude wrapper, the
# mise-managed binaries, and gh resolve. ~/.local/launchers is first so `claude` hits the
# per-account wrapper (#345); the mise shims dir follows so gh/jq resolve headless, the same
# hand-built-PATH approach statusline.sh uses for its own headless launchd/hook context.
export PATH="$HOME/.local/launchers:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="dev.kryota.morning-radar"
LOG_FILE="$HOME/Library/Logs/${LABEL}.log"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/morning-radar"
BRIEF_DIR="$HOME/dotfiles/.kryota-dev/morning-brief"
TIMEOUT_SECONDS=600
MAX_TURNS=50
# Pinned model keeps the pre-approved weekday recurring cost predictable even
# when the account's default model changes.
CLAUDE_MODEL="sonnet"
# Least-privilege allowlist (#257): gh/git are enumerated read-only subcommand
# prefixes -- a bare Bash(gh:*) would also match write paths like `gh auth
# token`, `gh secret set` or `gh api -X DELETE`, which a prompt-injected issue
# title could otherwise invoke. Residual risk: `gh api graphql` (needed for
# review-thread queries) cannot distinguish queries from mutations at the
# prefix level; the prompt additionally forbids all writes. git is limited to
# plain read verbs (no `git -C`, so other repos' history comes from session
# summaries instead). Skill is scoped to the morning-brief handoff chain. File
# edits are confined to the brief output dir and spelled as an Edit(path) rule:
# since Claude Code v2.1.210 the file permission checks match only Edit(path)
# and Read(path), and one Edit rule covers every file-editing tool (Write and
# NotebookEdit included). The Write(path) form it replaced was accepted but
# never matched, so it granted nothing while warning at every startup.
# Everything else (edits outside that dir, WebFetch/WebSearch, Agent, mcp
# tools, other Bash commands) stays auto-denied in print mode.
ALLOWED_TOOLS="Bash(gh search:*),Bash(gh issue list:*),Bash(gh issue view:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh api graphql:*),Bash(git log:*),Bash(git status:*),Bash(git diff:*),Bash(git show:*),Bash(git branch:*),Bash(ls:*),Bash(cat:*),Bash(date:*),Bash(jq:*),Bash(find:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Read,Glob,Grep,Skill(morning-brief),Skill(repo-radar),Skill(gmail-triage),Edit(~/dotfiles/.kryota-dev/morning-brief/**)"

notify_user() {
  # Argv-passing keeps claude-derived text out of the AppleScript source
  # (no string interpolation -> no AppleScript injection). Notification
  # failures never fail the run (same tolerance as clv2-session-notify.sh).
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"' \
    -e 'end run' \
    -- "$1" "$2" >/dev/null 2>&1 || true
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"
}

[ "$(uname)" = "Darwin" ] || exit 0

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$BRIEF_DIR"

# Run claude with the dotfiles repo as cwd (project trust + local context);
# direct invocations then behave identically to launchd's WorkingDirectory.
cd "$HOME/dotfiles"

# Rotate the log once it exceeds 1 MiB (daily appends stay small).
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt 1048576 ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old"
fi

# Same-day guard: launchd coalesces missed fires on wake, and kickstart can
# re-fire manually; one billed run per day is the approved budget (#257).
# --force bypasses for smoke tests and deliberate manual reruns.
TODAY="$(date +%F)"
if [ "${1:-}" != "--force" ] && [ -f "$STATE_DIR/last-run" ] &&
  [ "$(cat "$STATE_DIR/last-run")" = "$TODAY" ]; then
  log "skip: already ran today ($TODAY)"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  log "error: claude not found on PATH"
  notify_user "Morning radar failed: claude not found on PATH — log: $LOG_FILE" "Morning Radar"
  exit 1
fi

BRIEF_FILE="$BRIEF_DIR/$TODAY.md"
# Prompt is Japanese to match the skill-steering language policy (the brief
# itself is a Japanese artifact). Output contract mirrors the 運用メモ section
# of morning-brief SKILL.md — keep the two in sync.
PROMPT=$(
  cat <<EOF
/morning-brief を headless の縮退モード前提で実行してください。
- Gmail / Calendar の MCP コネクタが使えない場合は、該当セクションに「取得失敗（headless 実行）」と明記して続行する（SKILL.md の縮退挙動）。
- --post は使わない。GitHub への書き込み・下流 skill（issue-fleet / renovate-sweep / review-fleet）の起動は一切しない。
- ブリーフ全文を $BRIEF_FILE に Write で保存する。同日ファイルが既に存在する場合（--force 再実行時）も、Read してから全文を上書き保存する。
- 最終応答は「HEADLINE: <P1 n件 / 要対応 m件 / 定点観測 k件>」形式の 1 行のみとする。
EOF
)

STDOUT_FILE="$(mktemp -t morning-radar)"
trap 'rm -f "$STDOUT_FILE"' EXIT

CLAUDE_ARGS=(--model "$CLAUDE_MODEL" --max-turns "$MAX_TURNS")
# Let the brief read other repos' session summaries under the ghq root.
if [ -d "$HOME/ghq" ]; then
  CLAUDE_ARGS+=(--add-dir "$HOME/ghq")
fi
# --allowedTools is variadic and would swallow a trailing positional prompt,
# so it stays a single comma-joined value and the prompt binds to -p below.
CLAUDE_ARGS+=(--allowedTools "$ALLOWED_TOOLS")

log "start: claude -p /morning-brief (model=$CLAUDE_MODEL, max-turns=$MAX_TURNS)"

# Launch through the claude wrapper (~/.local/launchers/claude, first on PATH above). It injects
# the personal account's isolation env — CLAUDE_CONFIG_DIR/ECC_AGENT_DATA_HOME, the
# CLV2_HOMUNCULUS_DIR that deliberately sits outside the config dir (Claude Code treats paths under
# it as sensitive files that no headless session can approve a write to, #336), and the observer
# knobs (clock gate off, turn ceiling 100 — the lazy-started PreToolUse observer inherits this env
# for its whole lifetime). That injection used to be hand-copied here and could drift (#345); now
# there is one source. Setting CLAUDE_CONFIG_DIR explicitly pins the personal account (the wrapper
# keeps an explicit value via its fill-gaps rule). Exporting empty EXA/FIRECRAWL keys opts out of
# web search — the wrapper's `+x` guard then skips sourcing the MCP-keys file — since the brief
# does not need them and the MCP servers tolerate missing keys.
CLAUDE_CONFIG_DIR="$HOME/.claude" \
  EXA_API_KEY="" \
  FIRECRAWL_API_KEY="" \
  claude "${CLAUDE_ARGS[@]}" -p "$PROMPT" >"$STDOUT_FILE" 2>>"$LOG_FILE" &
CLAUDE_PID=$!

# Watchdog: TERM after TIMEOUT_SECONDS, KILL 10s later (runaway-billing
# guard on top of --max-turns).
(
  sleep "$TIMEOUT_SECONDS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
    sleep 10
    kill -9 "$CLAUDE_PID" 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

STATUS=0
wait "$CLAUDE_PID" || STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null || true

cat "$STDOUT_FILE" >>"$LOG_FILE"

if [ "$STATUS" -ne 0 ]; then
  # 143 = SIGTERM, 137 = SIGKILL: treat both as the watchdog timeout.
  if [ "$STATUS" -eq 143 ] || [ "$STATUS" -eq 137 ]; then
    log "error: claude timed out after ${TIMEOUT_SECONDS}s (exit $STATUS)"
    notify_user "Morning radar timed out (${TIMEOUT_SECONDS}s) — log: $LOG_FILE" "Morning Radar"
  else
    log "error: claude exited $STATUS"
    notify_user "Morning radar failed (exit $STATUS) — log: $LOG_FILE" "Morning Radar"
  fi
  exit 1
fi

# Trailing `|| true` keeps a missing HEADLINE line from aborting the script
# here: grep exits 1 on no match, which pipefail + set -e would turn into a
# script-level exit, skipping the fallback and the notification below.
HEADLINE="$(grep -E '^HEADLINE:' "$STDOUT_FILE" | tail -1 | sed 's/^HEADLINE:[[:space:]]*//' || true)"
if [ -z "$HEADLINE" ]; then
  HEADLINE="brief generated (no headline)"
fi

# Verify the brief before stamping the day done: a missing/empty file means the
# run broke its output contract, so treat it as a failure (notify + exit 1) and
# leave the stamp absent so the day stays retryable.
if [ ! -s "$BRIEF_FILE" ]; then
  log "error: brief file missing or empty at $BRIEF_FILE"
  notify_user "Morning radar failed: brief file missing — log: $LOG_FILE" "Morning Radar"
  exit 1
fi

# Written only on success: a failed run leaves the stamp absent so the same
# day can be retried manually (the approved budget is one successful run/day).
printf '%s\n' "$TODAY" >"$STATE_DIR/last-run"

log "done: $HEADLINE"
notify_user "$HEADLINE — $BRIEF_FILE" "Morning Radar"
