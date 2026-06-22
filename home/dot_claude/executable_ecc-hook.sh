#!/bin/bash
# Thin launcher for ECC hooks whose runtime is fetched via chezmoi external
# (see home/.chezmoiexternal.toml ['.agents/skills/ecc/scripts']).
#
# Why this exists: ECC ships each hook in its hooks.json as a ~1.5 KB minified
# `node -e "..."` blob whose bulk is plugin-root *fallback* resolution (scanning
# ~/.claude/plugins/... for an installed ECC). We don't install ECC as a plugin
# — the root is fixed and chezmoi-managed — so that fallback is dead weight and
# made settings.json unreadable. This launcher sets CLAUDE_PLUGIN_ROOT and hands
# the hook spec to ECC's own plugin-hook-bootstrap.js, which resolves the target
# under the root, passes stdin through, and dispatches. Behaviour is identical to
# the inline form for every event (SessionStart/PreCompact/PreToolUse/PostToolUse
# and the stdin/transcript-based Stop hooks).
#
# Usage (from settings.json hooks commands):
#   ecc-hook.sh scripts/hooks/session-start-bootstrap.js
#   ecc-hook.sh scripts/hooks/run-with-flags.js <hook-id> <script-rel> <flags>
#
# Account isolation (cld vs cld-r06) is unaffected: the launcher is
# account-agnostic and the aliases export ECC_AGENT_DATA_HOME (and friends),
# which the hook subprocess inherits.
set -euo pipefail

export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.agents/skills/ecc}"
bootstrap="$CLAUDE_PLUGIN_ROOT/scripts/hooks/plugin-hook-bootstrap.js"

# Fail open: if the external isn't deployed yet (fresh machine, pre-`chezmoi
# apply`), pass stdin straight through so the hook is a silent no-op instead of
# an error — matching ECC's own missing-runtime convention.
if [ ! -f "$bootstrap" ]; then
  cat
  exit 0
fi

# plugin-hook-bootstrap.js reads argv as: [node, bootstrap, mode, relPath, ...args].
# `node` is the mode (spawn the target with the node runtime); "$@" supplies
# relPath plus any run-with-flags arguments.
exec node "$bootstrap" node "$@"
