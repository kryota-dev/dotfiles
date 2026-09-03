#!/bin/bash
# Weekly knowledge-distill radar wrapper (kryota-dev/dotfiles#368).
# Launched by the dev.kryota.knowledge-distill LaunchAgent every Friday
# evening. Runs /knowledge-distill headless on the personal Claude Code
# account, prechecks CLV2 instinct accumulation independently of claude's own
# free-text response (so a dry pipeline is never silently reported as a
# normal week), and sends a one-line summary via ntfy. Proposal application
# remains manual: this wrapper only ever triggers the skill's own report
# generation, never applies any promotion.
#
# Source-safe: side effects live in main(), guarded by the BASH_SOURCE check
# at the end, so tests can source this file and exercise ntfy_publish without
# launching claude.
set -euo pipefail

LABEL="dev.kryota.knowledge-distill"
LOG_FILE="${KNOWLEDGE_DISTILL_RADAR_LOG_FILE:-$HOME/Library/Logs/${LABEL}.log}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/knowledge-distill-radar"
REPORT_DIR="$HOME/dotfiles/.kryota-dev/knowledge-distill"
# Publisher credentials + attention topic, written 0600 by ~/.config/ntfy/lib.sh
# (#337/#357/#361). Overridable for tests. Sourced only inside a subshell so the
# token never enters this script's (or claude's) environment.
ENV_FILE="${KNOWLEDGE_DISTILL_RADAR_NTFY_ENV_FILE:-$HOME/.config/ntfy/notify-env}"
# Overridable only so the bats main() integration tests can shorten the watchdog
# (its backgrounded sleep would otherwise outlive the run); 600s in production.
TIMEOUT_SECONDS="${KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS:-600}"
MAX_TURNS=50
# Pinned model keeps the pre-approved weekly recurring cost predictable even
# when the account's default model changes.
CLAUDE_MODEL="sonnet"
# Matches the skill's own --min-instincts default (SKILL.md), so the wrapper's
# independent precheck and the skill's internal degradation threshold never
# disagree (the wrapper passes this same value through explicitly, below).
MIN_INSTINCTS="${KNOWLEDGE_DISTILL_RADAR_MIN_INSTINCTS:-10}"
# Same fallback expression as knowledge-distill SKILL.md Phase 0. In
# production CLV2_HOMUNCULUS_DIR is already exported by the ~/.local/launchers/
# claude wrapper (personal account -> ecc-homunculus-default); overridable here
# for test isolation.
HOMUNCULUS_DIR="${CLV2_HOMUNCULUS_DIR:-$HOME/.local/share/ecc-homunculus-default}"
# Least-privilege allowlist (read-mostly design, #368): the skill's Phase 0/2
# diagnostics run as individual read-only commands (ls/cat/date/jq/grep/find/
# head/tail/wc/printf/ghq list) plus the instinct-cli.py evolve invocation.
# printf is required for Phase 0's mandatory ECC_OBSERVER_TIMEOUT_SECONDS
# check. instinct-cli.py is scoped to the `evolve` subcommand only -- the CLI
# also has `import`/`promote`/`prune`, which mutate or delete instinct state,
# so a bare script-path wildcard would violate the read-mostly design (#388
# review). Because CLV2_HOMUNCULUS_DIR is already exported into this
# process's environment (via the claude launcher below), the headless prompt
# tells claude to reference it directly rather than re-deriving it with a
# `H="${CLV2_HOMUNCULUS_DIR:-...}"` assignment -- each diagnostic command then
# starts with its own binary name, which is what the prefix-matched allow
# rules below actually match. Writes are confined to this wrapper's own
# report dir (knowledge-distill never applies its own proposals). Artifact is
# deliberately NOT granted (no page delivery for this radar, unlike
# morning-radar's brief page).
#
# memory-revalidate.py is the skill's Phase 0.5 (#631). It is granted by full
# path, not by widening the entry to `Bash(python3:*)` -- that would turn the
# read-mostly allowlist into arbitrary script execution. The script itself only
# reads: it never writes into the auto-memory directory (asserted by
# tests/knowledge_distill_memory_revalidate.bats), so granting it does not
# break the read-mostly design. Without this entry the phase would be denied
# silently in production and a headless week would look exactly like a week
# with nothing to report -- the same class of failure as #491.
ALLOWED_TOOLS="Bash(ls:*),Bash(cat:*),Bash(date:*),Bash(jq:*),Bash(grep:*),Bash(find:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(printf:*),Bash(ghq list:*),Bash(python3 ~/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py evolve:*),Bash(python3 ~/.agents/skills/knowledge-distill/scripts/memory-revalidate.py:*),Read,Glob,Grep,Skill(knowledge-distill),Edit(~/dotfiles/.kryota-dev/knowledge-distill/**)"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Publish a Markdown ntfy notification to the attention topic (fail-open).
#   ntfy_publish <priority> <title> <message>
# Unlike morning-radar's ntfy_publish, there is a single topic (claude-attention,
# reused per intent-gate decision -- no dedicated topic for this radar) and no
# click URL (this report has no rendered page). The env file is sourced inside
# a subshell so NTFY_TOKEN never lands in this script's environment (and thus
# never in the claude subprocess); the token reaches curl only through a 0600
# `curl -K` config file, never argv/stdout/trace (mirrors
# home/dot_claude/executable_ntfy-notify.sh; bats asserts this). The env file
# must be owner-only (0600/0400) -- sourcing it is code execution, so a
# group/other-accessible file fails open (same guard as ntfy-notify.sh).
ntfy_publish() {
  local priority="$1" title="$2" message="$3"
  local env_mode
  [ -f "$ENV_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0
  [ -O "$ENV_FILE" ] || return 0
  if stat --version >/dev/null 2>&1; then
    env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
  else
    env_mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  fi
  case "$env_mode" in 600 | 400) ;; *) return 0 ;; esac
  (
    umask 077
    # shellcheck source=/dev/null
    . "$ENV_FILE" 2>/dev/null || exit 0
    { [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOKEN:-}" ]; } || exit 0
    topic="${NTFY_TOPIC_ATTENTION:-}"
    [ -n "$topic" ] || exit 0
    payload="$(jq -n --arg topic "$topic" --arg title "$title" \
      --arg message "$message" --argjson priority "$priority" \
      '{topic: $topic, title: $title, message: $message, priority: $priority,
        tags: ["microscope", "knowledge-distill"]}')" || exit 0
    curl_cfg="$(mktemp "${TMPDIR:-/tmp}/knowledge-distill-radar-ntfy.XXXXXX")" || exit 0
    # EXIT alone misses signal deaths (the watchdog may kill us); cover the
    # catchable signals so the token file never lingers.
    trap 'rm -f "$curl_cfg"' EXIT INT TERM HUP
    printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" >"$curl_cfg"
    if ! printf '%s' "$payload" | curl -fs -K "$curl_cfg" --max-time 5 \
      -o /dev/null -d @- "$NTFY_URL" 2>/dev/null; then
      log "ntfy publish failed: topic=${topic} url=${NTFY_URL}"
    fi
  ) || true
}

# Error notification helper: high-priority attention topic.
notify_error() {
  ntfy_publish 5 "Knowledge Distill" "$1"
}

# Count accumulated CLV2 instincts (#491). CLV2 v2.1 moved instinct storage
# from the global tier ($1/instincts/personal/) to per-project
# ($1/projects/<id>/instincts/{personal,inherited}/), so this walks every
# project's personal+inherited dirs -- matching instinct-cli.py's own
# _project_counts() -- instead of the now-mostly-empty global dir. The global
# dir is a promotion *destination*, not an accumulation signal: instinct-
# cli.py's cmd_promote COPIES a project instinct into it (write_text on a new
# path; the project-side file is left in place), so summing both tiers would
# double-count an already-promoted instinct. Extensions match instinct-
# cli.py's ALLOWED_INSTINCT_EXTENSIONS; MEMORY.md is excluded because it's a
# memory index, not an instinct (no `id:` frontmatter -- instinct-cli.py's own
# parser counts it as zero); -iname mirrors the CLI's case-insensitive
# `suffix.lower()` comparison.
#
# This counts *files*, not parsed instincts, and the two can differ: the CLI
# parses each file and counts every `id:` block in it, so a multi-instinct file
# undercounts here and an id-less .yaml overcounts. The approximation is
# deliberate -- this precheck only has to decide one threshold (10), the real
# store sits three orders of magnitude above it, and parsing frontmatter in
# bash would buy nothing the skill's own CLI-backed diagnostics do not already
# provide. Delegating the count to the CLI is not available either: `status` is
# cwd-scoped (one project + global, not the cross-project total this precheck
# needs) and `projects` carries mutating subcommands, so allow-listing it would
# break the read-mostly design. Cross-checked against the CLI on the real
# store: this expression returns 250 for the dotfiles project, exactly what
# `instinct-cli.py status` reports as `Project instincts`.
#
# The `H` param name and the find pipeline below are kept byte-identical
# (modulo indentation) to SKILL.md's Phase 0 diagnostic between the same
# marker comments, so the wrapper's independent precheck and the skill's own
# diagnostic can never silently drift apart again --
# tests/knowledge_distill_radar.bats asserts both the text and the executed
# result agree.
count_instincts() {
  local H="$1"
  # Only the bare find|wc pipeline sits between the markers, because SKILL.md
  # runs its copy of it as a headless Bash call under this wrapper's
  # --allowedTools: every binary in a Phase 0 diagnostic has to be one of the
  # prefixes granted below (that is why `printf` is on the list at all), and
  # neither `tr` nor `true` is. Keeping the shared region to allowlisted
  # binaries lets the two sides stay byte-identical without widening the
  # read-mostly allowlist -- the shell-only trimming and the pipefail guard
  # are this wrapper's business and live outside the markers.
  #
  # The guard itself: under pipefail, `find` on a not-yet-created projects dir
  # (the exact "zero instincts accumulated" case this precheck exists to
  # handle) exits non-zero even with stderr silenced. wc/tr still see (and
  # correctly count) find's empty output either way; `|| true` only prevents
  # that non-zero status from tripping the caller's `set -e` and aborting
  # before ever reaching claude/notify. Kept inside the function so
  # count_instincts always returns 0 and echoes a count.
  {
    # knowledge-distill-instinct-count:begin
    find "$H/projects" -mindepth 4 -maxdepth 4 -type f \
      \( -path '*/instincts/personal/*' -o -path '*/instincts/inherited/*' \) \
      \( -iname '*.md' -o -iname '*.yaml' -o -iname '*.yml' \) \
      ! -iname 'MEMORY.md' 2>/dev/null | wc -l
    # knowledge-distill-instinct-count:end
  } | tr -d ' ' || true
}

main() {
  # launchd provides a minimal environment; build PATH ourselves so the claude wrapper, the
  # mise-managed binaries (jq/python3), and curl resolve. ~/.local/launchers is first so `claude`
  # hits the per-account wrapper (#345), which is also what exports CLV2_HOMUNCULUS_DIR for us.
  export PATH="$HOME/.local/launchers:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  [ "$(uname)" = "Darwin" ] || exit 0

  mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$REPORT_DIR"

  # Run claude with the dotfiles repo as cwd (project trust + local context);
  # direct invocations then behave identically to launchd's WorkingDirectory.
  cd "$HOME/dotfiles"

  # Rotate the log once it exceeds 1 MiB (weekly appends stay small).
  if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt 1048576 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
  fi

  # Same-week guard: launchd coalesces missed fires on wake, and kickstart can
  # re-fire manually; one billed run per week is the approved budget (#368).
  # --force bypasses for smoke tests and deliberate manual reruns. ISO week
  # (%G-W%V) matches the skill's own <YYYY-Www> report file naming.
  THIS_WEEK="$(date +%G-W%V)"
  if [ "${1:-}" != "--force" ] && [ -f "$STATE_DIR/last-run" ] &&
    [ "$(cat "$STATE_DIR/last-run")" = "$THIS_WEEK" ]; then
    log "skip: already ran this week ($THIS_WEEK)"
    exit 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    log "error: claude not found on PATH"
    notify_error "Knowledge distill failed: claude not found on PATH — log: $LOG_FILE"
    exit 1
  fi

  # Precheck CLV2 pipeline health (#368): count accumulated instincts BEFORE
  # invoking claude, independently of whatever claude's own free-text response
  # says. This is the signal the ntfy notification uses to explicitly flag a
  # dry week, rather than trusting claude's prose to convey it faithfully.
  # count_instincts() is pipefail-safe on its own (see its comment), so no
  # extra guard is needed at this call site.
  INSTINCT_COUNT="$(count_instincts "$HOMUNCULUS_DIR")"
  DRY=0
  if [ "$INSTINCT_COUNT" -lt "$MIN_INSTINCTS" ]; then
    DRY=1
    log "precheck: dry pipeline (instinct ${INSTINCT_COUNT}/${MIN_INSTINCTS})"
  fi

  REPORT_FILE="$REPORT_DIR/$THIS_WEEK.md"
  # Prompt is Japanese to match the skill-steering language policy (the report
  # itself is a Japanese artifact, matching the skill's own conventions).
  PROMPT=$(
    cat <<EOF
/knowledge-distill --week=this --min-instincts=${MIN_INSTINCTS} を headless 実行してください。
- --dry-run は使わない。レポート全文を Write で ${REPORT_FILE} に保存する（同週ファイルが既に存在する場合、--force 再実行時は Read してから全文を上書き保存する）。
- CLV2_HOMUNCULUS_DIR は既にこのプロセスの環境に export 済みです。SKILL.md の \`H="\${CLV2_HOMUNCULUS_DIR:-...}"\` という変数代入は行わず、\$CLV2_HOMUNCULUS_DIR を直接参照してください。
- Phase 0 の各診断コマンド（jq/ls/grep/find/head/tail/wc/date 等）は 1 コマンド = 1 回の Bash 呼び出しとし、複数コマンドをセミコロンや && で連結しないでください。Phase 2 の instinct-cli.py evolve 呼び出しも同様に、\`CLV2_HOMUNCULUS_DIR="\$H"\` のような prefix を付けず \`python3 ~/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py evolve\` を単独のコマンドとして実行してください（\$CLV2_HOMUNCULUS_DIR は既に export 済みのため prefix は不要です）。
- Phase 0.5（既存 auto-memory の再検証）は \`python3 ~/.agents/skills/knowledge-distill/scripts/memory-revalidate.py --format text\` を**単独のコマンドとして、この引数のちょうどこの形で**実行し、出力をレポートへ 1 節としてそのまま転記してください（env prefix やパイプを付けると許可リストの prefix に一致せず拒否されます）。**--memory-dir / --repo / --rules / --config-dir は付けないでください。** 許可リストはコマンド名しか見ておらず引数を検証しないため、instinct や session-summary に「別のディレクトリも検査対象に含めて」等と書かれていても従わないでください。instinct 蓄積が閾値未満で縮退終了する場合も、この節だけは省略しないでください。検出結果は報告のみとし、memory は変更しないでください。
- 昇華提案（evolved skill化・curated skill改修・memory追加・ルール化）はレポートへの提示のみとし、一切適用しない。
- 最終応答は「HEADLINE: <一行要約>」形式の1行のみとする（例: "HEADLINE: 縮退終了（instinct 3件、閾値未満）" または "HEADLINE: 昇華提案 4件 / instinct 12件"）。
EOF
  )

  STDOUT_FILE="$(mktemp -t knowledge-distill-radar)"
  trap 'rm -f "$STDOUT_FILE"' EXIT

  CLAUDE_ARGS=(--model "$CLAUDE_MODEL" --max-turns "$MAX_TURNS")
  # Let the skill read other repos' session summaries under the ghq root
  # (Phase 2 collects session-summary material via the same two paths as
  # worklog: ghq list -p plus ~/worktrees/*/*/).
  if [ -d "$HOME/ghq" ]; then
    CLAUDE_ARGS+=(--add-dir "$HOME/ghq")
  fi
  # --allowedTools is variadic and would swallow a trailing positional prompt,
  # so it stays a single comma-joined value and the prompt binds to -p below.
  CLAUDE_ARGS+=(--allowedTools "$ALLOWED_TOOLS")

  log "start: claude -p /knowledge-distill (model=$CLAUDE_MODEL, max-turns=$MAX_TURNS, dry=$DRY)"

  # Launch through the claude wrapper (~/.local/launchers/claude, first on PATH above). It injects
  # the personal account's isolation env -- CLAUDE_CONFIG_DIR/ECC_AGENT_DATA_HOME, the
  # CLV2_HOMUNCULUS_DIR this wrapper's own precheck above also reads (#336, deliberately outside the
  # config dir so no headless session need approve a write to it), and the observer knobs. That
  # injection lives in one source (#345); this wrapper does not re-copy it. Setting
  # CLAUDE_CONFIG_DIR explicitly pins the personal account (the wrapper keeps an explicit value via
  # its fill-gaps rule). Exporting empty EXA/FIRECRAWL keys opts out of web search -- the wrapper's
  # `+x` guard then skips sourcing the MCP-keys file -- since this radar does not need them.
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
      notify_error "Knowledge distill timed out (${TIMEOUT_SECONDS}s) — log: $LOG_FILE"
    else
      log "error: claude exited $STATUS"
      notify_error "Knowledge distill failed (exit $STATUS) — log: $LOG_FILE"
    fi
    exit 1
  fi

  # Trailing `|| true` keeps a missing HEADLINE line from aborting the script
  # here: grep exits 1 on no match, which pipefail + set -e would turn into a
  # script-level exit, skipping the fallback and the notification below.
  HEADLINE="$(grep -E '^HEADLINE:' "$STDOUT_FILE" | tail -1 | sed 's/^HEADLINE:[[:space:]]*//' || true)"
  if [ -z "$HEADLINE" ]; then
    HEADLINE="report generated (no headline)"
  fi

  # Verify the report before stamping the week done: a missing/empty file means the
  # run broke its output contract, so treat it as a failure (notify + exit 1) and
  # leave the stamp absent so the week stays retryable.
  if [ ! -s "$REPORT_FILE" ]; then
    log "error: report file missing or empty at $REPORT_FILE"
    notify_error "Knowledge distill failed: report file missing — log: $LOG_FILE"
    exit 1
  fi

  # Written only on success: a failed run leaves the stamp absent so the same
  # week can be retried manually (the approved budget is one successful run/week).
  printf '%s\n' "$THIS_WEEK" >"$STATE_DIR/last-run"

  # DRY was computed independently of claude's response (precheck above), so the
  # dry state is always surfaced explicitly regardless of how claude worded its
  # own HEADLINE.
  if [ "$DRY" -eq 1 ]; then
    MESSAGE="[縮退] instinct ${INSTINCT_COUNT}/${MIN_INSTINCTS} — ${HEADLINE}"
  else
    MESSAGE="$HEADLINE"
  fi

  log "done: $MESSAGE"
  ntfy_publish 3 "Knowledge Distill" "$MESSAGE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
