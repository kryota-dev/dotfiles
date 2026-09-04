# Claude Code account isolation.
# Each account (~/.claude, ~/.claude-r06) gets its own config dir plus ECC/CLV2/gateguard state
# dirs, so cld and cld-r06 never share sessions, governance state.db, instincts, or hook caches.
#
# The per-account env injection now lives in a single wrapper, ~/.local/launchers/claude, reached
# as `claude` / `cld` / `cld-r06` (the latter two are symlinks to it; it dispatches on $0). Being a
# real file on PATH, the wrapper works from any shell — interactive, hook, launchd, Claude's Bash
# tool — so the hand-copied env blocks it replaces cannot drift (#345). It also sources the 0600
# MCP-keys file (claude-secrets.zsh) itself, so this module no longer sources it. The launcher dir
# is put on PATH in dot_zshrc.tmpl (static prepend + a precmd hook that keeps it ahead of mise).

# Dedicated session for intentional config edits on the DEFAULT account (~/.claude): disables the
# ECC config-protection gate so Claude can edit settings.json / biome.json / eslint.config.* etc.
# The opt-out goes through ECC_DISABLED_HOOKS_EXTRA: settings.json's env block overrides a
# shell-exported ECC_DISABLED_HOOKS (#280) but leaves EXTRA untouched, and ecc-hook.sh merges it
# into ECC_DISABLED_HOOKS for the hook runtime (#281). Setting CLAUDE_CONFIG_DIR explicitly pins
# the default account; the claude wrapper fill-gaps rule keeps it (it only fills an unset value).
# pre:edit-write:gateguard-fact-force was dropped from this list in #496 along with its
# settings.json wiring — naming a hook id that no longer exists is dead config, not a safety net.
# For the r06 account, prefix the same var to cld-r06:
#   ECC_DISABLED_HOOKS_EXTRA=pre:config-protection cld-r06
alias claude-config='ECC_DISABLED_HOOKS_EXTRA=pre:config-protection CLAUDE_CONFIG_DIR="$HOME/.claude" claude'

# Fable orchestrator: run the main session on Fable 5.1 and steer task execution into Sonnet
# subagents via the orchestrator system prompt. The model is pinned to the full ID (not the
# "fable" alias) so the prompt's Sonnet-5-era delegation checklist and the main model generation
# cannot silently drift apart — update both together when the model generation changes. The flag
# is what makes this work without touching the picker: Claude Code resolves the main model as
# /model in-session > --model > ANTHROPIC_MODEL > a model value in settings > organization default
# > ANTHROPIC_DEFAULT_MODEL, so --model beats a default saved with /model (#626).
# CLAUDE_CODE_SUBAGENT_MODEL is still deliberately NOT set, though the reason changed: it used to
# outrank everything, and 2.1.251 demoted it to a default. Claude Code >= 2.1.251 resolves a
# subagent's model as per-spawn model param > the agent definition's model: frontmatter ("inherit"
# means the main conversation's model) > CLAUDE_CODE_SUBAGENT_MODEL > the main conversation's
# model. Setting it to sonnet would therefore no longer kill the "escalate a hard verification to
# fable" path, but its reach is small enough not to be worth a second place that declares the
# subagent default: it applies only to spawns carrying neither a frontmatter model: nor a per-spawn
# model, and every agent in home/dot_claude/agents/ already pins model: sonnet. Among the built-ins
# the docs put general-purpose in that set, while Explore and Plan inherit the main conversation's
# model and are explicitly documented as unchanged by the variable on its own. Keeping the default
# in both the orchestrator prompt and an env var would mean syncing the two forever, so the prompt
# stays the single place (#627). 2.1.257 added CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1, which restores
# the old override-everything behaviour (Explore and Plan included); it is left unset so an
# explicit model: fable on a hard verification still wins.
# The prompt file is shared with the r06
# account via an absolute path (same precedent as hooks-fork); when it is absent (before chezmoi
# apply or after manual removal) the session still starts, just without the orchestrator prompt.
# The prompt is passed via --append-system-prompt-file (path) instead of --append-system-prompt
# (content) so the prompt body stays out of argv — the CLI reads the file at process start,
# avoiding argv-length and control-char concerns as the prompt grows. The two flags are mutually
# exclusive: Claude Code >= 2.1.185 aborts with "Cannot use both ... Please use only one."
# The base claude wrapper used to inject neither, so this helper could simply add its own flag.
# That stopped being true in #677, which injects the AskUserQuestion rule from the wrapper (the one
# file every entry point reaches, not just interactive zsh). Layering is not what happens there,
# because it cannot: --append-system-prompt-file is not repeatable and a later occurrence silently
# replaces an earlier one, so the wrapper strips whatever this helper passes and folds it together
# with the rule into a single composite file. The line below is therefore unchanged and still
# correct — the wrapper reads it as input rather than being overridden by it. Anything that starts
# passing --append-system-prompt (content) instead goes through the same fold, so the retired
# phone-control wrapper's separate inline path (#331) would no longer be needed.
# CLAUDE_CONFIG_DIR is set here (the wrapper keeps an explicit value via fill-gaps) so the fable
# session lands on the right account; the wrapper injects the rest of the per-account env.
_claude_fable() {
  local home_dir="$1"
  shift
  local prompt_file="$HOME/.claude/fable-orchestrator-prompt.md"
  local -a fable_flags=(--model claude-fable-5-1)
  if [[ -r "$prompt_file" ]]; then
    fable_flags+=(--append-system-prompt-file "$prompt_file")
  fi
  CLAUDE_CONFIG_DIR="$home_dir" claude "$@" "${fable_flags[@]}"
}
alias cldf='_claude_fable "$HOME/.claude"'
alias cldf-r06='_claude_fable "$HOME/.claude-r06"'

# improvement-* helpers (#501, sub-issue of #473): the conversational/shell face of the
# ECC continuous-improvement candidate queue. The CLI itself is
# ~/.local/bin/agent-improvement (a mise-pinned node launcher over
# ~/.local/lib/agent-improvement/cli.mjs) and the queue lives at
# ${XDG_STATE_HOME:-~/.local/state}/agent-improvement/queue.json, owner-only.
#
# Functions (not aliases) so flags like --history / --json pass through — the same reason the
# retired ecc-status / ecc-sessions / ecc-work-items readers were functions (#193, removed in
# #496). status and next are strictly read-only: they never re-run the weekly evaluator and
# never create the state dir. improvement-resolve is the ONLY writer here, and it takes the
# fixed three-way answer (--decision=adopt|defer|reject).
improvement-status() { agent-improvement status "$@"; }
improvement-next() { agent-improvement next "$@"; }
improvement-resolve() { agent-improvement resolve "$@"; }

alias ccdcmds='ccdcommands'

function ccdpaths() {
  local dir="${1:-.}"
  echo "=== Directories ==="
  /usr/bin/find "$dir" -type d -exec echo "- @{}/" \;
  echo "=== Files ==="
  /usr/bin/find "$dir" -type f -exec echo "- @{}" \;
}

function ccdcommands() {
  local base_dir="${1:-.}"
  local commands_dir=".claude/commands"
  if [ ! -d "$commands_dir" ]; then
    echo "Error: .claude/commands directory not found in ${base_dir}" >&2
    return 1
  fi
  /usr/bin/find "$commands_dir" -name "*.md" -type f -exec echo "- @{}" \;
}

function claude-rc() {
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local settings="$config_dir/settings.json"
  local backup=$(mktemp)
  cp "$settings" "$backup"
  jq '.env |= with_entries(select(.key | test("DISABLE_TELEMETRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") | not))' "$settings" >"${settings}.tmp" && mv "${settings}.tmp" "$settings"
  trap 'cp "$backup" "$settings"; rm -f "$backup"' EXIT INT TERM
  claude remote-control "$@"
  cp "$backup" "$settings"
  rm -f "$backup"
  trap - EXIT INT TERM
}
