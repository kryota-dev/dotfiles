# Claude Code account isolation.
# Each account gets its own config dir plus ECC/CLV2/gateguard state dirs, so cld and
# cld-r06 never share sessions, governance state.db, instincts, or hook caches.
# The command to run is passed after the home dir rather than hard-coded, so the helper
# stays agnostic about what it launches while still pinning the per-account environment.

# MCP API keys (exa, firecrawl) rendered from 1Password into a 0600 file. Sourced (not
# exported) so the keys stay out of the general shell environment; _claude_with_home re-exports
# them scoped to the claude subprocess. Absent until `chezmoi apply` provisions it, in which
# case the MCP servers just launch without a key.
[[ -r "${HOME}/.config/zsh/claude-secrets.zsh" ]] && source "${HOME}/.config/zsh/claude-secrets.zsh"

_claude_with_home() {
  local home_dir="$1"
  shift
  # Default to plain `claude` when no command is given, so a direct call still launches
  # Claude Code (the aliases always pass an explicit command).
  (($#)) || set -- claude
  # EXA_API_KEY/FIRECRAWL_API_KEY are exported here (scoped to "$@") so Claude Code can expand
  # the "${EXA_API_KEY}" / "${FIRECRAWL_API_KEY}" placeholders in its MCP env at spawn. The :-
  # default keeps this safe when the secrets file is absent.
  # The edit-write gateguard-fact-force gate is disabled via env.ECC_DISABLED_HOOKS in
  # settings.json, which overrides shell-inherited env — settings.json is the effective
  # SSOT for this flag; an alias-level default here would be dead code (see #280).
  # Per-session opt-outs instead go through ECC_DISABLED_HOOKS_EXTRA, which ecc-hook.sh
  # merges into ECC_DISABLED_HOOKS (see claude-config below, #281).
  # ECC_OBSERVER_TIMEOUT_SECONDS raises the CLV2 observer watchdog above its 120s default:
  # the Haiku analysis pass (up to a 500-line observation batch and 100 --max-turns) cannot
  # finish in 120s, so every run was SIGTERMed (observer log exit 143) and no instinct was
  # ever written (#256). The :- default keeps an explicit override winning.
  # CLV2 state must stay OUTSIDE the account config dir. Claude Code classifies every path
  # under the config dir as a sensitive file and demands interactive approval before a Write,
  # but the CLV2 analysis pass runs headless (claude --model haiku --print), so every instinct
  # write failed with "... which is a sensitive file", spent the turn budget negotiating
  # permission and ended at "Reached max turns" — not one instinct was ever produced while
  # this pointed at <account>/ecc-homunculus (#336). The per-account suffix keeps cld and
  # cld-r06 isolated from each other and both from the bare-`claude` fallback
  # (~/.local/share/ecc-homunculus). XDG_DATA_HOME is deliberately NOT consulted: morning-radar.sh
  # reproduces this same value, and a second precedence chain there is what would let the two
  # drift apart.
  # OBSERVER_ACTIVE_HOURS_* are both 0 to disable the CLV2 session-guardian clock gate
  # (default 800-2300), which skipped ~90 analysis cycles per project because sessions here
  # routinely run past midnight (#336). The guardian's cooldown and idle gates still throttle
  # cycles, so this does not make the observer busier while nobody is at the keyboard.
  # ECC_OBSERVER_MAX_TURNS pins the ceiling at the upstream cap rather than the auto-scaled
  # floor of 20, which cut the Read -> dedup-check -> Write pass off mid-write; the 300s
  # watchdog above is what actually bounds a cycle.
  # Supported account dirs are ~/.claude and ~/.claude-<suffix>; the last branch only exists so an
  # unexpected name still yields a usable dir name. Do not name an account dir ".claude-default":
  # its slug would collide with ~/.claude's and silently merge two accounts' observations.
  local account_dir_name="${home_dir:t}"
  local homunculus_slug
  case "$account_dir_name" in
    .claude) homunculus_slug=default ;;
    .claude-*) homunculus_slug="${account_dir_name#.claude-}" ;;
    *) homunculus_slug="${account_dir_name#.}" ;;
  esac
  CLAUDE_CONFIG_DIR="$home_dir" \
    ECC_AGENT_DATA_HOME="$home_dir" \
    CLV2_HOMUNCULUS_DIR="$HOME/.local/share/ecc-homunculus-${homunculus_slug}" \
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \
    ECC_OBSERVER_TIMEOUT_SECONDS="${ECC_OBSERVER_TIMEOUT_SECONDS:-300}" \
    OBSERVER_ACTIVE_HOURS_START="${OBSERVER_ACTIVE_HOURS_START:-0}" \
    OBSERVER_ACTIVE_HOURS_END="${OBSERVER_ACTIVE_HOURS_END:-0}" \
    ECC_OBSERVER_MAX_TURNS="${ECC_OBSERVER_MAX_TURNS:-100}" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    "$@"
}
alias cld='_claude_with_home "$HOME/.claude" claude'
alias cld-r06='_claude_with_home "$HOME/.claude-r06" claude'

# Dedicated session for intentional config edits on the DEFAULT account (~/.claude): routes
# through _claude_with_home (so ECC state stays isolated to ~/.claude) and disables the ECC
# config-protection / gateguard-fact-force gates so Claude can edit settings.json / biome.json /
# eslint.config.* etc. The opt-out goes through ECC_DISABLED_HOOKS_EXTRA: settings.json's env
# block overrides a shell-exported ECC_DISABLED_HOOKS (#280) but leaves EXTRA untouched, and
# ecc-hook.sh merges it into ECC_DISABLED_HOOKS for the hook runtime (#281). The
# gateguard-fact-force id is redundant with the settings.json default (#280) but kept
# deliberately so the alias contract survives a future default flip. For the r06
# account, prefix the same var to cld-r06:
#   ECC_DISABLED_HOOKS_EXTRA=pre:config-protection,pre:edit-write:gateguard-fact-force cld-r06
alias claude-config='ECC_DISABLED_HOOKS_EXTRA=pre:config-protection,pre:edit-write:gateguard-fact-force _claude_with_home "$HOME/.claude" claude'

# Fable 5 orchestrator: run the main session on Fable 5 and steer task execution into
# Sonnet subagents via the orchestrator system prompt. The model is pinned to the full ID
# (not the "fable" alias) so the prompt's Sonnet-5-era delegation checklist and the main
# model generation cannot silently drift apart — update both together when the model
# generation changes. CLAUDE_CODE_SUBAGENT_MODEL is deliberately NOT set: it outranks
# per-invocation model params and agent frontmatter, which would kill the "escalate a
# hard verification to fable" path; the orchestrator prompt steers subagent model choice
# instead. The prompt file is shared with the r06 account via an absolute path (same
# precedent as hooks-fork); when it is absent (before chezmoi apply or after manual
# removal) the session still starts, just without the orchestrator prompt.
# The prompt is passed via --append-system-prompt-file (path) instead of --append-system-prompt
# (content) so the prompt body stays out of argv — the CLI reads the file at process start,
# avoiding argv-length and control-char concerns as the prompt grows.
# The two flags are mutually exclusive: Claude Code >= 2.1.185 aborts with "Cannot use both
# ... Please use only one." So a wrapper that injects its own --append-system-prompt cannot
# simply be layered on top of this helper — it would have to inline the prompt instead. The
# retired phone-control wrapper needed exactly that separate code path (#331).
_claude_fable() {
  local home_dir="$1"
  shift
  # Symmetry with _claude_with_home: allow a bare `_claude_fable "$HOME/.claude"` to still
  # launch a fable session instead of exec'ing `--model` as a command.
  (($#)) || set -- claude
  local prompt_file="$HOME/.claude/fable-orchestrator-prompt.md"
  local -a fable_flags=(--model claude-fable-5)
  if [[ -r "$prompt_file" ]]; then
    fable_flags+=(--append-system-prompt-file "$prompt_file")
  fi
  _claude_with_home "$home_dir" "$@" "${fable_flags[@]}"
}
alias cldf='_claude_fable "$HOME/.claude" claude'
alias cldf-r06='_claude_fable "$HOME/.claude-r06" claude'

# ecc-* CLIs (PR-C, #4/#5): inspect the per-account ECC governance state.db that the
# governance-capture fork writes. Account is selected by ECC_AGENT_DATA_HOME; the reader
# defaults to ~/.claude when it is unset, so a plain shell shows the default account. To
# inspect the r06 account, prefix it: `ECC_AGENT_DATA_HOME=$HOME/.claude-r06 ecc-status`.
# Functions (not aliases) so flags like --json pass through. The reader lives under the
# default account dir and is shared by both accounts (same as the governance-capture fork).
ecc-status()     { node "$HOME/.claude/hooks-fork/ecc-state-reader.js" status "$@"; }
ecc-sessions()   { node "$HOME/.claude/hooks-fork/ecc-state-reader.js" sessions "$@"; }
ecc-work-items() { node "$HOME/.claude/hooks-fork/ecc-state-reader.js" work-items "$@"; }

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
  jq '.env |= with_entries(select(.key | test("DISABLE_TELEMETRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") | not))' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
  trap 'cp "$backup" "$settings"; rm -f "$backup"' EXIT INT TERM
  claude remote-control "$@"
  cp "$backup" "$settings"
  rm -f "$backup"
  trap - EXIT INT TERM
}
