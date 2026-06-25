# dmux (standardagents/dmux): a tmux-based pane manager for orchestrating parallel AI agent
# sessions. Its AI features — smart branch slugs, AI commit messages, pane-state analysis, and
# aiMerge conflict assistance — read OPENROUTER_API_KEY from the environment; without it dmux
# still runs, falling back to dmux-{timestamp} branch names and skipping the AI assists.
#
# The key is rendered from 1Password into a 0600 ~/.config/zsh/dmux-secrets.zsh and sourced
# (not exported), so it stays out of the general shell environment. The wrapper re-exports it
# scoped to the dmux subprocess only, mirroring _claude_with_home. Absent until chezmoi apply
# provisions it, in which case dmux just launches without a key.
[[ -r "${HOME}/.config/zsh/dmux-secrets.zsh" ]] && source "${HOME}/.config/zsh/dmux-secrets.zsh"

# Directory holding the `codex` PATH shim. dmux launches the bare `codex` binary (it spawns
# `sh -c "codex …"`), so it cannot pass `--profile shared`, the chezmoi-managed SSOT static
# config ($CODEX_HOME/shared.config.toml). Prepending this dir to PATH makes dmux pick up the
# shim, which re-injects `--profile shared` for every codex pane (both accounts). dmux's PATH
# sanitiser only strips node_modules/.bin, so the shim dir survives into the panes. claude
# needs no shim: its account is selected purely by CLAUDE_CONFIG_DIR.
_DMUX_SHIM_DIR="${HOME}/.config/dmux/bin"

dmux() {
  # Scope OPENROUTER_API_KEY to the dmux process only; the :- default keeps this safe when the
  # secrets file is absent. The shim dir is prepended so dmux's bare `codex` loads the SSOT
  # config. `command` bypasses this function to reach the mise-shimmed binary.
  PATH="${_DMUX_SHIM_DIR}:${PATH}" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    command dmux "$@"
}

# dmux-r06: run a whole dmux session bound to the r06 (work) account, mirroring cld-r06 /
# cdx-r06. dmux launches bare `claude` / `codex` with no per-account env injection, and tmux
# captures a session's environment from the server at creation time — so with a default-socket
# server already running (e.g. the auto-tmux-dev hook), a plain pre-launch export would not
# reach new panes. To guarantee propagation this points tmux at a dedicated socket via
# TMUX_TMPDIR: the first dmux-r06 starts a *fresh* tmux server whose global environment is
# captured from the r06 env below, so every pane (and the codex shim) inherits it. The r06
# env set mirrors _claude_with_home (claude.zsh) plus CODEX_HOME (codex.zsh).
dmux-r06() {
  local tmpdir="${HOME}/.dmux-r06"
  [[ -d "$tmpdir" ]] || mkdir -p "$tmpdir" || return 1
  TMUX_TMPDIR="$tmpdir" \
    PATH="${_DMUX_SHIM_DIR}:${PATH}" \
    CLAUDE_CONFIG_DIR="${HOME}/.claude-r06" \
    ECC_AGENT_DATA_HOME="${HOME}/.claude-r06" \
    CLV2_HOMUNCULUS_DIR="${HOME}/.claude-r06/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="${HOME}/.claude-r06/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="${HOME}/.claude-r06/.gateguard" \
    CODEX_HOME="${HOME}/.codex-r06" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    command dmux "$@"
}
