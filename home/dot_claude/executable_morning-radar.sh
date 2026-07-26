#!/bin/bash
# Weekday-morning radar wrapper (kryota-dev/dotfiles#257, delivery #361).
# Launched by the dev.kryota.morning-radar LaunchAgent on weekday mornings.
# Runs /morning-brief headless (degraded mode) on the personal Claude Code
# account, saves the brief to a dated file, renders a mobile-readable HTML page,
# and sends an ntfy notification whose click opens that page over the tailnet
# (#361). The page is served by a loopback nginx sidecar fronted by
# `tailscale serve --https` (a port proxy — macOS cannot serve files directly);
# a mobile browser renders the HTML natively (the ntfy apps do not render
# Markdown). Detection + notify only: no downstream skill dispatch. Delivery is
# tailnet-only — the page never leaves the tailnet, no Artifact/claude.ai path.
#
# Source-safe: side effects live in main(), guarded by the BASH_SOURCE check at
# the end, so tests can source this file and exercise ntfy_publish without
# launching claude.
set -euo pipefail

LABEL="dev.kryota.morning-radar"
LOG_FILE="${MORNING_RADAR_LOG_FILE:-$HOME/Library/Logs/${LABEL}.log}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/morning-radar"
BRIEF_DIR="$HOME/dotfiles/.kryota-dev/morning-brief"
# Publisher credentials + brief topic, written 0600 by ~/.config/ntfy/lib.sh
# (#337/#357/#361). Overridable for tests. Sourced only inside a subshell so the
# token never enters this script's (or claude's) environment.
ENV_FILE="${MORNING_RADAR_NTFY_ENV_FILE:-$HOME/.config/ntfy/notify-env}"
# Overridable only so the bats main() integration tests can shorten the watchdog
# (its backgrounded sleep would otherwise outlive the run); 600s in production.
TIMEOUT_SECONDS="${MORNING_RADAR_TIMEOUT_SECONDS:-600}"
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
# never matched, so it granted nothing while warning at every startup. Note:
# Artifact is deliberately NOT granted — brief delivery is tailnet-only (#361),
# so the brief is published to the self-hosted ntfy server, not to claude.ai.
# Everything else (edits outside that dir, WebFetch/WebSearch, Agent, mcp
# tools, other Bash commands) stays auto-denied in print mode.
ALLOWED_TOOLS="Bash(gh search:*),Bash(gh issue list:*),Bash(gh issue view:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh api graphql:*),Bash(git log:*),Bash(git status:*),Bash(git diff:*),Bash(git show:*),Bash(git branch:*),Bash(ls:*),Bash(cat:*),Bash(date:*),Bash(jq:*),Bash(find:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Read,Glob,Grep,Skill(morning-brief),Skill(repo-radar),Skill(gmail-triage),Edit(~/dotfiles/.kryota-dev/morning-brief/**)"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Publish a Markdown ntfy notification. Fail-open: a broken/absent ntfy
# provisioning is a silent no-op and no failure ever aborts the run.
#   ntfy_publish <kind> <priority> <title> <message>
#   kind: brief -> NTFY_TOPIC_BRIEF (success)   attention -> NTFY_TOPIC_ATTENTION (errors)
# The env file is sourced inside a subshell so NTFY_TOKEN never lands in this
# script's environment (and thus never in the claude subprocess); the token
# reaches curl only through a 0600 `curl -K` config file, never argv/stdout/
# trace (mirrors home/dot_claude/executable_ntfy-notify.sh; bats asserts this).
# The env file must be owner-only (0600/0400) — sourcing it is code execution,
# so a group/other-accessible file fails open (same guard as ntfy-notify.sh).
ntfy_publish() {
  local kind="$1" priority="$2" title="$3" message="$4" click="${5:-}"
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
    case "$kind" in
      brief)
        topic="${NTFY_TOPIC_BRIEF:-}"
        emoji="newspaper"
        ;;
      attention)
        topic="${NTFY_TOPIC_ATTENTION:-}"
        emoji="rotating_light"
        ;;
      *) exit 0 ;;
    esac
    [ -n "$topic" ] || exit 0
    # click (when present) opens the rendered brief page on the tailnet; omit it
    # when unavailable so a broken link is never sent (graceful degradation).
    if [ -n "$click" ]; then
      payload="$(jq -n --arg topic "$topic" --arg title "$title" \
        --arg message "$message" --arg emoji "$emoji" --arg click "$click" \
        --argjson priority "$priority" \
        '{topic: $topic, title: $title, message: $message, priority: $priority,
          click: $click, tags: [$emoji, "morning-radar"]}')" || exit 0
    else
      payload="$(jq -n --arg topic "$topic" --arg title "$title" \
        --arg message "$message" --arg emoji "$emoji" \
        --argjson priority "$priority" \
        '{topic: $topic, title: $title, message: $message, priority: $priority,
          tags: [$emoji, "morning-radar"]}')" || exit 0
    fi
    curl_cfg="$(mktemp "${TMPDIR:-/tmp}/morning-radar-ntfy.XXXXXX")" || exit 0
    # EXIT alone misses signal deaths (the watchdog may kill us); cover the
    # catchable signals so the token file never lingers.
    trap 'rm -f "$curl_cfg"' EXIT INT TERM HUP
    printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" >"$curl_cfg"
    if ! printf '%s' "$payload" | curl -fs -K "$curl_cfg" --max-time 5 \
      -o /dev/null -d @- "$NTFY_URL" 2>/dev/null; then
      log "ntfy publish failed: kind=${kind} topic=${topic} url=${NTFY_URL}"
    fi
  ) || true
}

# Error notification helper: high-priority attention topic, no link.
notify_error() {
  ntfy_publish attention 5 "Morning Radar" "$1"
}

# Render the brief markdown as a mobile-readable HTML page at $2. Pandoc
# converts the body to an HTML fragment; `markdown-raw_html` escapes any raw
# HTML in the brief (GitHub issue titles etc. are untrusted) while keeping GFM
# pipe tables and bare-URI autolinking, so a `<script>` in brief content can
# never execute on the served page. The leading `# ...` line is dropped before
# conversion -- brief_page_shell supplies its own masthead heading, so
# pandoc's document h1 would otherwise duplicate it. On pandoc absence/
# failure, fall back to a self-contained shell that shows the markdown
# verbatim in a wrapping <pre>, HTML-escaping & < >. Returns non-zero if no
# page could be produced.
render_brief_html() {
  local md="$1" html="$2" title="$3"
  [ -s "$md" ] || return 1
  if command -v pandoc >/dev/null 2>&1; then
    local fragment
    if fragment="$(sed -e '1{' -e '/^# /d' -e '}' "$md" |
      pandoc -f markdown-raw_html+autolink_bare_uris -t html 2>>"$LOG_FILE")"; then
      brief_page_shell "$title" "$fragment" >"$html" 2>/dev/null && return 0
    fi
  fi
  {
    printf '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">'
    printf '<meta name="color-scheme" content="light dark">'
    printf '<title>%s</title>' "$title"
    printf '%s' '<style>body{margin:0;padding:1.25rem;font:16px/1.6 -apple-system,system-ui,sans-serif;color:#20242c;background:#f7f8fa}@media(prefers-color-scheme:dark){body{color:#f2f3f5;background:#20242c}}pre{white-space:pre-wrap;word-wrap:break-word;margin:0;font:15px/1.7 ui-monospace,"SF Mono",Menlo,monospace}</style>'
    printf '</head><body><pre>'
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$md"
    printf '</pre></body></html>'
  } >"$html" 2>/dev/null || return 1
  return 0
}

# Build the full HTML shell around a pandoc-rendered fragment. Every static
# piece and both dynamic arguments go through `printf '%s' <single-arg>` --
# never through a format string containing the fragment/title -- so a literal
# `%` (e.g. "90%消費" occurs in real briefs) or a `$`/backtick sequence in
# untrusted brief content can never be misread as a printf conversion or
# expanded by the shell (a heredoc, by contrast, would expand `$(...)` found
# inside the fragment).
#
# Design: a single dawn-signal accent (amber) on a light, airy ground; dark
# mode via prefers-color-scheme stays a lighter slate rather than near-black
# so it reads as calm, not heavy (this is a one-shot static page with no
# theme toggle). System sans (-apple-system) carries the masthead, section
# headings, and body copy -- weight and size carry the hierarchy instead of a
# second typeface; system mono carries only the kicker label and tabular data
# (times, table cells) via font-variant-numeric. No web fonts are fetched --
# the page is served entirely tailnet-local.
brief_page_shell() {
  local title="$1" fragment="$2"
  printf '%s' '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
  printf '%s' '<meta name="viewport" content="width=device-width, initial-scale=1">'
  printf '%s' '<meta name="color-scheme" content="light dark">'
  printf '<title>%s</title>' "$title"
  printf '%s' '<style>'
  printf '%s' ':root{--bg:#f7f8fa;--surface:#fff;--ink:#20242c;--ink-soft:#666e7a;--line:#e4e7ec;--accent:#c1710f;--accent-soft:#fbe7cd;--crit:#c0392b;--ok:#2f8558}'
  printf '%s' '@media (prefers-color-scheme:dark){:root{--bg:#20242c;--surface:#2b3038;--ink:#f2f3f5;--ink-soft:#aab1bd;--line:#3c424c;--accent:#f0ac5c;--accent-soft:#3c2c14;--crit:#e8897c;--ok:#6fcb9e}}'
  printf '%s' '*{box-sizing:border-box}'
  printf '%s' 'body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}'
  printf '%s' '.wrap{max-width:38rem;margin:0 auto;padding:2.25rem 1.25rem 4rem}'
  printf '%s' '.kicker{display:block;font:600 .72rem/1 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:.16em;text-transform:uppercase;color:var(--accent);margin-bottom:.6rem}'
  printf '%s' 'h1.masthead{font:700 1.85rem/1.25 -apple-system,"SF Pro Display",system-ui,sans-serif;margin:0 0 2rem;text-wrap:balance;letter-spacing:-.015em}'
  printf '%s' 'main h2{font:700 1.05rem/1.3 -apple-system,"SF Pro Display",system-ui,sans-serif;margin:2.25rem 0 .75rem;padding-top:1.25rem;border-top:1px solid var(--line)}'
  printf '%s' 'main h2:first-of-type{border-top:none;padding-top:0;margin-top:0}'
  printf '%s' 'main h3{font:600 .92rem/1.4 -apple-system,system-ui,sans-serif;margin:1.25rem 0 .5rem;color:var(--ink-soft)}'
  printf '%s' 'main p{margin:.6rem 0}'
  printf '%s' 'main em{color:var(--ink-soft)}'
  printf '%s' 'main code{font:.85em ui-monospace,"SF Mono",Menlo,monospace;background:var(--accent-soft);padding:.1em .3em;border-radius:.25em}'
  printf '%s' 'main a{color:var(--accent);text-decoration-color:var(--line);text-underline-offset:.15em}'
  printf '%s' 'main ul{padding-left:1.15rem;margin:.6rem 0}'
  printf '%s' 'main ul li{margin:.35rem 0}'
  printf '%s' 'main ol{list-style:none;padding:0;margin:1rem 0;display:flex;flex-direction:column;gap:.55rem;counter-reset:step}'
  printf '%s' 'main ol li{position:relative;counter-increment:step;padding:.75rem .9rem .75rem 2.7rem;background:var(--surface);border:1px solid var(--line);border-radius:.5rem}'
  printf '%s' 'main ol li::before{position:absolute;left:.85rem;top:.72rem;content:counter(step,decimal-leading-zero);font:700 1.05rem/1 -apple-system,"SF Pro Display",system-ui,sans-serif;color:var(--accent);font-variant-numeric:tabular-nums}'
  printf '%s' 'main table{display:block;max-width:100%;overflow-x:auto;border-collapse:collapse;font-size:.92rem;margin:.75rem 0}'
  printf '%s' 'main th,main td{text-align:left;padding:.5rem .7rem;border-bottom:1px solid var(--line);font-variant-numeric:tabular-nums;white-space:nowrap}'
  printf '%s' 'main th{font:600 .7rem/1 ui-monospace,monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-soft)}'
  printf '%s' 'main strong{color:var(--ink);font-weight:700}'
  printf '%s' 'footer.meta{margin-top:2.5rem;padding-top:1rem;border-top:1px solid var(--line);color:var(--ink-soft);font:.75rem/1.5 ui-monospace,monospace}'
  printf '%s' '@media (prefers-reduced-motion:no-preference){main a{transition:opacity .15s ease}}'
  printf '%s' '</style></head><body><div class="wrap">'
  printf '%s' '<span class="kicker">Morning Radar</span>'
  printf '<h1 class="masthead">%s</h1>' "$title"
  printf '%s' '<main>'
  printf '%s' "$fragment"
  printf '%s' '</main>'
  printf '%s' '<footer class="meta">tailnet-only &middot; self-hosted</footer>'
  printf '%s' '</div></body></html>'
}

# Build the tailnet click URL for the given date, or empty when the brief base
# URL was not provisioned (MagicDNS underivable). Sourced in a subshell so only
# the (non-secret) base URL is read out — the token never enters this env.
ntfy_brief_url() {
  local today="$1" base
  [ -f "$ENV_FILE" ] || return 0
  [ -O "$ENV_FILE" ] || return 0
  base="$(
    # shellcheck source=/dev/null
    . "$ENV_FILE" 2>/dev/null || true
    printf '%s' "${NTFY_BRIEF_BASE_URL:-}"
  )"
  [ -n "$base" ] || return 0
  printf '%s/%s.html' "$base" "$today"
}

main() {
  # launchd provides a minimal environment; build PATH ourselves so the claude wrapper, the
  # mise-managed binaries (gh/jq), and curl resolve. ~/.local/launchers is first so `claude`
  # hits the per-account wrapper (#345); the mise shims dir follows, the same hand-built-PATH
  # approach statusline.sh uses for its own headless launchd/hook context.
  export PATH="$HOME/.local/launchers:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

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
    notify_error "Morning radar failed: claude not found on PATH — log: $LOG_FILE"
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
      notify_error "Morning radar timed out (${TIMEOUT_SECONDS}s) — log: $LOG_FILE"
    else
      log "error: claude exited $STATUS"
      notify_error "Morning radar failed (exit $STATUS) — log: $LOG_FILE"
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
    notify_error "Morning radar failed: brief file missing — log: $LOG_FILE"
    exit 1
  fi

  # Written only on success: a failed run leaves the stamp absent so the same
  # day can be retried manually (the approved budget is one successful run/day).
  printf '%s\n' "$TODAY" >"$STATE_DIR/last-run"

  # Render the mobile page and build the tailnet click URL. If either is
  # unavailable, the notification still carries the HEADLINE (no link).
  # publish is fail-open, so a delivery failure never affects the stamp above.
  click=""
  if render_brief_html "$BRIEF_FILE" "$BRIEF_DIR/$TODAY.html" "Morning brief — $TODAY"; then
    click="$(ntfy_brief_url "$TODAY")"
    [ -n "$click" ] || log "warn: brief base URL unavailable; notifying without a link"
  else
    log "warn: brief HTML render failed; notifying without a link"
  fi

  log "done: $HEADLINE"
  ntfy_publish brief 3 "Morning brief" "$HEADLINE" "$click"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
