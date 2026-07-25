# Codex CLI multi-account helpers (shared by ~/.codex and ~/.codex-r06).
# Personal account uses the default ~/.codex (no CODEX_HOME set); the work
# account sets CODEX_HOME=~/.codex-r06 for that invocation only.
# `--profile shared` layers $CODEX_HOME/shared.config.toml (chezmoi-managed SSOT)
# on top of the dynamically-written config.toml.
#
# NOTE: Running bare `codex` (without these aliases) does NOT load
#       shared.config.toml, so the SSOT static config is not applied.
#       Always use `cdx` / `cdx-r06` to pick an account with the SSOT config.
alias cdx='codex --profile shared'
alias cdx-r06='CODEX_HOME=$HOME/.codex-r06 codex --profile shared'
