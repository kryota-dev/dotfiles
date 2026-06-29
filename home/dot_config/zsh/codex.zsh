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

# happy (slopus/happy) variants: run Codex through the happy wrapper for phone control.
# `happy codex` forwards `--profile shared` to codex and respects CODEX_HOME, so each
# account keeps its SSOT config and isolation; happy's own state (~/.happy) is shared
# across accounts (one pairing controls every account).
#
# NOTE: `happy codex` runs Codex HEADLESS via `codex app-server`. The local terminal is a
#       read-only viewer ("Codex Agent Messages / Waiting for messages…") with NO local
#       interactive prompt — drive the session from the Happy mobile/web app. For a local
#       interactive Codex terminal, use `cdx` / `cdx-r06` instead. (This is asymmetric with
#       `happy claude`/`hcld`, which spawns a full local TUI.)
alias hcdx='happy codex --profile shared'
alias hcdx-r06='CODEX_HOME=$HOME/.codex-r06 happy codex --profile shared'
