#!/bin/bash
# CLV2 instinct→skill flow: SessionStart producer + review-ready notifier.
#
# Runs once per session (async, wired in settings.json SessionStart) and does two things:
#   1. Compute the number of "review-ready" instinct clusters (2+ instincts sharing a
#      normalized trigger) by running the pinned continuous-learning-v2 engine
#      `instinct-cli.py evolve` and parsing its "Potential skill clusters found: N" line,
#      then cache N to "<homunculus>/.review-ready-clusters". The statusline reads that
#      cache (a cheap file read, no python) to render the 🧬N segment.
#   2. If N>=1 and the last notification was more than 7 days ago, emit a desktop
#      notification (macOS osascript) nudging a /evolve or retrospective-codify pass,
#      then record the notification epoch in "<homunculus>/.last-instinct-notify".
#
# Everything degrades to a no-op: missing python, missing engine, <3 instincts (evolve
# exits 1), or non-macOS (no osascript). Session start is never blocked or failed; async
# in settings.json means this adds zero latency to session start.
#
# Per-account: the homunculus dir is selected by CLV2_HOMUNCULUS_DIR, set per account by
# _claude_with_home (cld -> ~/.claude/ecc-homunculus, cld-r06 -> ~/.claude-r06/ecc-homunculus),
# so the cache and throttle files are naturally isolated between accounts.

set -eu

readonly NOTIFY_THROTTLE_SECONDS=604800 # 7 days

# Resolve the homunculus data dir. Mirrors scripts/lib/homunculus-dir.sh precedence
# (CLV2_HOMUNCULUS_DIR -> XDG_DATA_HOME/ecc-homunculus -> HOME/.local/share/ecc-homunculus)
# inline so this hook stays self-contained and never depends on sourcing the skill tree.
homunculus_dir() {
  if [ -n "${CLV2_HOMUNCULUS_DIR:-}" ]; then
    case "$CLV2_HOMUNCULUS_DIR" in
      /*)
        printf '%s\n' "$CLV2_HOMUNCULUS_DIR"
        return 0
        ;;
    esac
  fi
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    case "$XDG_DATA_HOME" in
      /*)
        printf '%s/ecc-homunculus\n' "$XDG_DATA_HOME"
        return 0
        ;;
    esac
  fi
  case "${HOME:-}" in
    /*) printf '%s/.local/share/ecc-homunculus\n' "$HOME" ;;
    *) return 1 ;;
  esac
}

home_dir=$(homunculus_dir) || exit 0

# The engine ships with the continuous-learning-v2 external skill (deployed by PR-A). If it
# is absent the whole flow is a no-op.
cli="$HOME/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py"
[ -r "$cli" ] || exit 0

# Resolve a python interpreter, honoring CLV2_PYTHON_CMD like the CLV2 observe hook does.
py=""
if [ -n "${CLV2_PYTHON_CMD:-}" ] && command -v "$CLV2_PYTHON_CMD" >/dev/null 2>&1; then
  py="$CLV2_PYTHON_CMD"
elif command -v python3 >/dev/null 2>&1; then
  py="python3"
elif command -v python >/dev/null 2>&1; then
  py="python"
fi
[ -n "$py" ] || exit 0

# `evolve` prints "Potential skill clusters found: N" on success and exits 1 when there are
# <3 instincts (nothing to surface). A non-zero exit resets evolve_out to "" (so the <3
# case yields no count line); on success we parse the count. The sed capture is digits-only
# and `|| count=0` guarantees the cache always holds a clean integer.
evolve_out=$("$py" "$cli" evolve 2>/dev/null) || evolve_out=""
count=$(printf '%s\n' "$evolve_out" |
  sed -n 's/.*Potential skill clusters found: \([0-9][0-9]*\).*/\1/p' | head -n1)
[ -n "$count" ] || count=0

# Cache the count for the statusline (atomic write so a concurrent reader never sees a
# half-written file). A write failure degrades to a no-op rather than aborting the hook.
mkdir -p "$home_dir" || exit 0
cache="$home_dir/.review-ready-clusters"
tmp="$cache.tmp.$$"
{ printf '%s\n' "$count" >"$tmp" && mv -f "$tmp" "$cache"; } || exit 0

# Notify only when there is something to review and we are on macOS.
[ "$count" -ge 1 ] || exit 0
command -v osascript >/dev/null 2>&1 || exit 0

# Throttle to at most once per 7 days. The epoch is stored as file content (not mtime) so
# it survives mtime-mutating operations (rsync, backups, chezmoi re-apply).
stamp="$home_dir/.last-instinct-notify"
now=$(date +%s)
last=0
if [ -r "$stamp" ]; then
  last=$(tr -dc '0-9' <"$stamp" 2>/dev/null || true)
  # Force base-10: a corrupt stamp like "08"/"09" would otherwise be read as octal
  # and the arithmetic below would fail (and abort the hook under set -e).
  last=$((10#${last:-0}))
fi
[ "$((now - last))" -ge "$NOTIFY_THROTTLE_SECONDS" ] || exit 0

osascript -e "display notification \"🧬 ${count} review-ready instinct cluster(s) — run /evolve or retrospective-codify\" with title \"Claude Code · CLV2\" sound name \"Glass\"" >/dev/null 2>&1 || true
printf '%s\n' "$now" >"$stamp.tmp.$$" && mv -f "$stamp.tmp.$$" "$stamp"
