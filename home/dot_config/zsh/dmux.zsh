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

dmux() {
  # Scope OPENROUTER_API_KEY to the dmux process only; the :- default keeps this safe when the
  # secrets file is absent. `command` bypasses this function to reach the mise-shimmed binary.
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" command dmux "$@"
}
