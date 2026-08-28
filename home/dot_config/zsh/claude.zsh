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

# Fable 5 orchestrator: run the main session on Fable 5 and steer task execution into Sonnet
# subagents via the orchestrator system prompt. The model is pinned to the full ID (not the
# "fable" alias) so the prompt's Sonnet-5-era delegation checklist and the main model generation
# cannot silently drift apart — update both together when the model generation changes.
# CLAUDE_CODE_SUBAGENT_MODEL is deliberately NOT set: it outranks per-invocation model params and
# agent frontmatter, which would kill the "escalate a hard verification to fable" path; the
# orchestrator prompt steers subagent model choice instead. The prompt file is shared with the r06
# account via an absolute path (same precedent as hooks-fork); when it is absent (before chezmoi
# apply or after manual removal) the session still starts, just without the orchestrator prompt.
# The prompt is passed via --append-system-prompt-file (path) instead of --append-system-prompt
# (content) so the prompt body stays out of argv — the CLI reads the file at process start,
# avoiding argv-length and control-char concerns as the prompt grows. The two flags are mutually
# exclusive: Claude Code >= 2.1.185 aborts with "Cannot use both ... Please use only one." The base
# claude wrapper deliberately injects neither, so this helper can layer --append-system-prompt-file
# on top of it; a wrapper that injected its own --append-system-prompt would have to inline the
# prompt instead (the retired phone-control wrapper needed exactly that separate path, #331).
# CLAUDE_CONFIG_DIR is set here (the wrapper keeps an explicit value via fill-gaps) so the fable
# session lands on the right account; the wrapper injects the rest of the per-account env.
_claude_fable() {
  local home_dir="$1"
  shift
  local prompt_file="$HOME/.claude/fable-orchestrator-prompt.md"
  local -a fable_flags=(--model claude-fable-5)
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
