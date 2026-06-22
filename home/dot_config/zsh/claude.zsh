# Claude Code account isolation.
# Each account gets its own config dir plus ECC/CLV2/gateguard state dirs, so cld and
# cld-r06 never share sessions, governance state.db, instincts, or hook caches.
_claude_with_home() {
  local home_dir="$1"
  shift
  CLAUDE_CONFIG_DIR="$home_dir" \
    ECC_AGENT_DATA_HOME="$home_dir" \
    CLV2_HOMUNCULUS_DIR="$home_dir/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \
    claude "$@"
}
alias cld='_claude_with_home "$HOME/.claude"'
alias cld-r06='_claude_with_home "$HOME/.claude-r06"'

# Dedicated session for intentional config edits: disables the ECC config-protection and
# gateguard-fact-force gates so Claude can edit settings.json / biome.json / eslint.config.* etc.
alias claude-config='ECC_DISABLED_HOOKS=pre:config-protection,pre:edit-write:gateguard-fact-force claude'

# ECC state.db CLI (account-aware via ECC_AGENT_DATA_HOME). ECC scripts are chezmoi-managed
# under ~/.agents/skills/ecc; these need the ECC runtime deps that a later PR installs.
alias ecc-status='node "$HOME/.agents/skills/ecc/scripts/status.js" --db "${ECC_AGENT_DATA_HOME:-$HOME/.claude}/ecc/state.db"'
alias ecc-sessions='node "$HOME/.agents/skills/ecc/scripts/sessions-cli.js" --db "${ECC_AGENT_DATA_HOME:-$HOME/.claude}/ecc/state.db"'
alias ecc-work-items='node "$HOME/.agents/skills/ecc/scripts/work-items.js" --db "${ECC_AGENT_DATA_HOME:-$HOME/.claude}/ecc/state.db"'

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
