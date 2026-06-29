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

# claude's MCP API keys (exa, firecrawl) live in the same 0600 secrets file claude.zsh sources
# (non-exported). dmux launches claude without _claude_with_home, so the wrappers below re-pass
# these keys (scoped to the dmux subprocess) for parity with cld / cld-r06 — claude expands the
# ${EXA_API_KEY} / ${FIRECRAWL_API_KEY} placeholders in its MCP env at spawn. Sourced here too
# (not only in claude.zsh) so this file does not depend on plugin load order. Absent until
# chezmoi apply provisions it, in which case the MCP servers just launch without a key.
[[ -r "${HOME}/.config/zsh/claude-secrets.zsh" ]] && source "${HOME}/.config/zsh/claude-secrets.zsh"

# Directory holding the `codex` PATH shim. dmux launches the bare `codex` binary (it spawns
# `sh -c "codex …"`), so it cannot pass `--profile shared`, the chezmoi-managed SSOT static
# config ($CODEX_HOME/shared.config.toml). Prepending this dir to PATH makes dmux pick up the
# shim, which re-injects `--profile shared` for every codex pane (both accounts). dmux's PATH
# sanitiser only strips node_modules/.bin, so the shim dir survives into the panes. The same
# dir also holds an opt-in `claude` shim: by default it is a transparent passthrough (claude's
# account is selected purely by CLAUDE_CONFIG_DIR), but `DMUX_HAPPY=1 dmux` makes it launch
# `happy claude` for phone control. Codex is deliberately not wrapped: `happy codex` is
# headless/remote-only (no local TUI), so it cannot drive a dmux pane (see docs/agents/codex.md).
_DMUX_SHIM_DIR="${HOME}/.config/dmux/bin"

dmux() {
  # Scope the API keys to the dmux process only; the :- defaults keep this safe when a secrets
  # file is absent. The shim dir is prepended so dmux's bare `codex` loads the SSOT config.
  # `command` bypasses this function to reach the mise-shimmed binary.
  PATH="${_DMUX_SHIM_DIR}:${PATH}" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    command dmux "$@"
}

# dmux-r06: run a whole dmux session bound to the r06 (work) account, mirroring cld-r06 /
# cdx-r06. dmux launches bare `claude` / `codex` with no per-account env injection. tmux
# captures a session's environment from the client that runs `new-session`, and new agent panes
# (created via `split-window`) inherit that captured session env — so the r06 env below, passed
# to the outer dmux, reaches every pane. The dedicated TMUX_TMPDIR socket is what makes this
# account-correct: dmux keys sessions by project name and ATTACHES to an existing one instead of
# recreating it, so without a separate server a dmux-r06 started where a default-account dmux
# session already exists would attach to the wrong account. A dedicated server gives r06 its own
# session namespace. (Caveat: a reused session keeps the env captured at its creation; the r06
# paths are static so this is moot, but newly-provisioned secrets need `tmux -L … kill-server`
# to refresh.) The per-account env set must stay in sync with _claude_with_home (claude.zsh);
# CODEX_HOME mirrors cdx-r06 (codex.zsh).
dmux-r06() {
  local tmpdir="${HOME}/.dmux-r06"
  # 0700 keeps the tmux socket dir as private as tmux's default $TMPDIR-based socket.
  [[ -d "$tmpdir" ]] || mkdir -m 700 -p "$tmpdir" || return 1
  TMUX_TMPDIR="$tmpdir" \
    PATH="${_DMUX_SHIM_DIR}:${PATH}" \
    CLAUDE_CONFIG_DIR="${HOME}/.claude-r06" \
    ECC_AGENT_DATA_HOME="${HOME}/.claude-r06" \
    CLV2_HOMUNCULUS_DIR="${HOME}/.claude-r06/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="${HOME}/.claude-r06/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="${HOME}/.claude-r06/.gateguard" \
    CODEX_HOME="${HOME}/.codex-r06" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    command dmux "$@"
}
