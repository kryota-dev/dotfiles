# Claude Code account isolation.
# Each account gets its own config dir plus ECC/CLV2/gateguard state dirs, so cld and
# cld-r06 never share sessions, governance state.db, instincts, or hook caches.
# The command to run is passed after the home dir ("claude ..." or "happy claude ..."),
# so the happy wrapper inherits the exact same per-account environment.
_claude_with_home() {
  local home_dir="$1"
  shift
  # Default to plain `claude` when no command is given, so a direct call still launches
  # Claude Code (the aliases always pass an explicit command).
  (($#)) || set -- claude
  CLAUDE_CONFIG_DIR="$home_dir" \
    ECC_AGENT_DATA_HOME="$home_dir" \
    CLV2_HOMUNCULUS_DIR="$home_dir/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \
    "$@"
}
alias cld='_claude_with_home "$HOME/.claude" claude'
alias cld-r06='_claude_with_home "$HOME/.claude-r06" claude'

# happy (slopus/happy) variants: run Claude Code through the happy wrapper for phone
# control, keeping the same per-account isolation. happy spawns claude inheriting this
# env (so CLAUDE_CONFIG_DIR etc. still pick the account); happy's own state (~/.happy,
# i.e. HAPPY_HOME_DIR default) is intentionally shared across accounts (one pairing).
alias hcld='_claude_with_home "$HOME/.claude" happy claude'
alias hcld-r06='_claude_with_home "$HOME/.claude-r06" happy claude'

# Dedicated session for intentional config edits on the DEFAULT account (~/.claude): routes
# through _claude_with_home (so ECC state stays isolated to ~/.claude) and disables the ECC
# config-protection / gateguard-fact-force gates so Claude can edit settings.json / biome.json /
# eslint.config.* etc. For the r06 account, prefix the same var to cld-r06:
#   ECC_DISABLED_HOOKS=pre:config-protection,pre:edit-write:gateguard-fact-force cld-r06
alias claude-config='ECC_DISABLED_HOOKS=pre:config-protection,pre:edit-write:gateguard-fact-force _claude_with_home "$HOME/.claude" claude'

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
