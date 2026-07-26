# Codex CLI multi-account helpers.
#
# Account selection (~/.codex vs ~/.codex-r06) and `--profile shared` injection now live in the
# codex wrapper at ~/.local/launchers/codex, reached as `codex` / `cdx` / `cdx-r06` (the latter two
# are symlinks to it; it dispatches on $0). Being a real file on PATH, it works from any shell —
# interactive, hook, Claude's Bash tool — so bare `codex` now loads shared.config.toml too, and the
# codex skill's inline account-selection prelude is gone (#345). No aliases are defined here; this
# module is kept so the sheldon plugin entry stays valid and as the home for any future codex-only
# interactive helpers.
