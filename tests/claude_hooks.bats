#!/usr/bin/env bats

load helpers/setup

# Guards for the Claude Code hook surface after the #496 reduction (sub-issue of #473).
#
# Why a dedicated file rather than more cases in files.bats: a hook that quietly comes back
# is invisible in review — settings.json is 600 lines and a restored entry reads like every
# other entry. Keeping the absence guards, the retention guards and the wave-orchestrator
# invariant in one place makes "which hooks are supposed to exist" a single readable
# contract, and gives any future change that touches hooks one obvious file to update.
#
# The three-way split matters:
#   REMOVED  — wiring deleted outright; must not reappear.
#   DISABLED — wiring lives in the ECC external runtime and cannot be deleted from here, so
#              it is switched off through env.ECC_DISABLED_HOOKS instead.
#   RETAINED — the safety boundary (#473 AC-008) plus the learning-engine observer and the
#              wave-orchestrator session events (#473 AC-016), which this change must not touch.

SETTINGS="${HOME_DIR}/dot_claude/settings.json"

# Hook ids removed in #496. Listed literally (not derived) so restoring an entry has to
# delete a line here too — a derived list would silently accept its own regression.
REMOVED_HOOK_IDS=(
  # AC-027 — SessionStart instinct-cluster recompute + desktop notification
  "session:start:clv2-notify"
  # AC-025 — automatic session summary persistence and the PreCompact LLM summary
  "stop:session-end"
  "pre:compact"
  # AC-013 — per-edit / per-stop quality advisories (moved to $code-change-verification + CI)
  "pre:edit-write:suggest-compact"
  "pre:write:doc-file-warning"
  "post:edit:accumulate"
  "post:quality-gate"
  "post:edit:design-quality-check"
  "post:edit:console-warn"
  "stop:format-typecheck"
  "stop:check-console-log"
  # AC-011 — the already-disabled Edit/Write fact-forcing wiring
  "pre:edit-write:gateguard-fact-force"
  # AC-014 — proactive MCP health probe (the PostToolUseFailure recovery is retained)
  "pre:mcp-health-check"
  # AC-015 — governance SQLite capture and the raw Bash audit log
  "pre:governance-capture"
  "post:governance-capture"
  "post:bash:command-log-audit"
  # AC-010 — post-Bash dispatcher (its only enabled sub-hook was PR-created advice)
  "post:bash:dispatcher"
  # AC-017 — metrics aggregate and the context/cost/scope/loop warning injector
  "post:ecc-metrics-bridge"
  "post:ecc-context-monitor"
)

# Sub-hooks of the retained pre-Bash dispatcher that AC-010 switches off. Their ids come from
# the ECC runtime's bash-hook-dispatcher.js PRE_BASH_HOOKS table; the dispatcher self-gates
# each one on ECC_DISABLED_HOOKS.
DISABLED_SUB_HOOK_IDS=(
  "pre:bash:tmux-reminder"
  "pre:bash:git-push-reminder"
  "pre:bash:commit-quality"
)

# The safety boundary (AC-008) plus the learning-engine observer (AC-028) and the MCP
# recovery half of AC-014.
RETAINED_HOOK_IDS=(
  "pre:bash:dispatcher"
  "pre:config-protection"
  "pre:observe:continuous-learning"
  "post:observe:continuous-learning"
  "post:mcp-health-check"
)

_require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
}

_hook_ids() {
  jq -r '.hooks | to_entries[] | .value[] | .id' "$SETTINGS"
}

@test "settings.json is valid JSON" {
  _require_jq
  jq empty "$SETTINGS"
}

@test "every hook entry carries an id (the guards below key off it)" {
  _require_jq
  local total ided
  total="$(jq -r '[.hooks | to_entries[] | .value[]] | length' "$SETTINGS")"
  ided="$(jq -r '[.hooks | to_entries[] | .value[] | select(has("id"))] | length' "$SETTINGS")"
  [ "$total" = "$ided" ] || {
    echo "${total} hook entries but only ${ided} have an id"
    false
  }
}

@test "#496: every removed hook id is absent from settings.json" {
  _require_jq
  local ids id
  ids="$(_hook_ids)"
  for id in "${REMOVED_HOOK_IDS[@]}"; do
    if printf '%s\n' "$ids" | grep -qFx "$id"; then
      echo "hook '${id}' was removed in #496 but is wired again in settings.json"
      false
    fi
  done
}

@test "#496: no hook command still points at a script deleted with the wiring" {
  _require_jq
  local commands
  commands="$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$SETTINGS")"
  local script
  for script in governance-capture.js post-bash-command-log.js ecc-state-reader.js \
    clv2-session-notify.sh post-bash-dispatcher.js session-end.js pre-compact.js \
    ecc-metrics-bridge.js ecc-context-monitor.js quality-gate.js post-edit-accumulator.js \
    design-quality-check.js post-edit-console-warn.js stop-format-typecheck.js \
    check-console-log.js suggest-compact.js doc-file-warning.js; do
    if printf '%s\n' "$commands" | grep -qF "$script"; then
      echo "a hook command still invokes ${script}, which #496 removed"
      false
    fi
  done
}

@test "#496: PreCompact has no wiring left (the event key is dropped, not left empty)" {
  _require_jq
  jq -e '.hooks | has("PreCompact") | not' "$SETTINGS" >/dev/null
}

@test "#496: ECC_DISABLED_HOOKS switches off the advisory pre-Bash sub-hooks" {
  _require_jq
  local ids id
  ids="$(jq -r '.env.ECC_DISABLED_HOOKS | split(",")[]' "$SETTINGS")"
  for id in "${DISABLED_SUB_HOOK_IDS[@]}"; do
    printf '%s\n' "$ids" | grep -qFx "$id" || {
      echo "ECC_DISABLED_HOOKS must disable '${id}' (#473 AC-010)"
      false
    }
  done
}

@test "#496: ECC_DISABLED_HOOKS names no hook whose wiring was deleted" {
  _require_jq
  # An id here that no longer has an entry is dead config: it reads like an active safety
  # decision while gating nothing, which is exactly what AC-011 removed for the Edit/Write
  # fact-forcing gate. Ids of sub-hooks (pre:bash:*, post:bash:*) never appear as entries, so
  # only compare the ones that address a settings.json entry.
  local ids id
  ids="$(jq -r '.env.ECC_DISABLED_HOOKS | split(",")[]' "$SETTINGS")"
  local entry_ids
  entry_ids="$(_hook_ids)"
  for id in $ids; do
    case "$id" in
      pre:bash:* | post:bash:*) continue ;;
    esac
    printf '%s\n' "$entry_ids" | grep -qFx "$id" || {
      echo "ECC_DISABLED_HOOKS names '${id}' but no hook entry has that id"
      false
    }
  done
}

@test "#496: SessionStart injects no context but keeps its entry for the observer lease" {
  _require_jq
  # session-start.js registers the CLV2 observer session lease before it evaluates the
  # context-injection gate, so dropping the entry would stop the learning-engine observation
  # that #496 must preserve. The env var is what actually silences the injection.
  jq -e '.env.ECC_SESSION_START_CONTEXT == "off"' "$SETTINGS" >/dev/null
  jq -e '[.hooks.SessionStart[] | select(.id=="session:start")] | length == 1' "$SETTINGS" >/dev/null
}

@test "#496: the routine Bash gate is disabled while destructive fact-forcing stays on" {
  _require_jq
  # AC-009 turns off only the gate on the session's first non-read-only Bash. The destructive
  # detector is a separate code path in gateguard-fact-force.js and keeps its extra pattern
  # set (task #12), so the safety half must survive the reduction.
  jq -e '.env.GATEGUARD_BASH_ROUTINE_DISABLED == "1"' "$SETTINGS" >/dev/null
  jq -e '.env.GATEGUARD_BASH_EXTRA_DESTRUCTIVE | type == "string" and length > 0' "$SETTINGS" >/dev/null
}

@test "#496: env vars whose only consumer was removed are gone" {
  _require_jq
  local var
  for var in ECC_GOVERNANCE_CAPTURE ECC_QUALITY_GATE_FIX; do
    jq -e --arg v "$var" '.env | has($v) | not' "$SETTINGS" >/dev/null || {
      echo "env.${var} has no consumer left after #496"
      false
    }
  done
}

@test "#473 AC-008: the retained safety and observer hooks are still wired" {
  _require_jq
  local ids id
  ids="$(_hook_ids)"
  for id in "${RETAINED_HOOK_IDS[@]}"; do
    printf '%s\n' "$ids" | grep -qFx "$id" || {
      echo "hook '${id}' must survive the #496 reduction"
      false
    }
  done
}

@test "#473 AC-008: the pre-Bash dispatcher keeps its safety sub-hooks enabled" {
  _require_jq
  # block-no-verify (commit-verification bypass), auto-tmux-dev (dev server) and the
  # gateguard's destructive fact-forcing must not be switched off alongside the advisories.
  local disabled id
  disabled="$(jq -r '.env.ECC_DISABLED_HOOKS' "$SETTINGS")"
  for id in pre:bash:block-no-verify pre:bash:auto-tmux-dev pre:bash:gateguard-fact-force; do
    if printf '%s\n' "$disabled" | grep -qF "$id"; then
      echo "'${id}' is a retained safety hook (#473 AC-008) but ECC_DISABLED_HOOKS disables it"
      false
    fi
  done
}

@test "#473 AC-016: the wave-orchestrator session events are untouched" {
  _require_jq
  # wave-orchestrator watches its children through these entries. They are listed by event
  # here so that removing one — or narrowing a matcher — fails loudly instead of silently
  # blinding the parent session.
  local expected="Notification PostToolUse PostToolUseFailure PreToolUse Stop StopFailure UserPromptSubmit"
  local actual
  actual="$(jq -r '[.hooks | to_entries[] | .key as $e | .value[]
                    | select(.hooks[].command | test("wave-session-event"))
                    | $e] | sort | unique | join(" ")' "$SETTINGS")"
  [ "$actual" = "$expected" ] || {
    echo "wave-session-event.sh events changed: expected [${expected}], got [${actual}]"
    false
  }
  jq -e '[.hooks | to_entries[] | .value[]
          | select(.hooks[].command | test("wave-session-event"))] | length == 7' "$SETTINGS" >/dev/null
  # Each one is async with a 10s timeout; a sync wave hook would add latency to every event.
  jq -e '[.hooks | to_entries[] | .value[]
          | select(.hooks[].command | test("wave-session-event"))
          | .hooks[] | select(.async == true and .timeout == 10)] | length == 7' "$SETTINGS" >/dev/null
}

@test "#496: the removed hook sources are gone from the chezmoi source tree" {
  local f
  for f in \
    "${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js" \
    "${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js" \
    "${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js" \
    "${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"; do
    [ ! -e "$f" ] || {
      echo "${f} was removed in #496 but is back in the source tree"
      false
    }
  done
}

@test "#496: prompt-conform-suggest is the only hook fork left" {
  local forks
  forks="$(find "${HOME_DIR}/dot_claude/hooks-fork" -maxdepth 1 -type f -exec basename {} \; | sort | tr '\n' ' ')"
  [ "$forks" = "prompt-conform-suggest.js " ] || {
    echo "unexpected hooks-fork contents: ${forks}"
    false
  }
}

@test "#496: .chezmoiremove reclaims the already-deployed copies" {
  # Deleting a file from the source tree does not delete the copy chezmoi already deployed,
  # so without these entries the scripts stay on disk as orphans.
  local remove_file="${HOME_DIR}/.chezmoiremove"
  local p
  for p in \
    ".claude/hooks-fork/governance-capture.js" \
    ".claude/hooks-fork/post-bash-command-log.js" \
    ".claude/hooks-fork/ecc-state-reader.js" \
    ".claude/clv2-session-notify.sh"; do
    grep -qFx "$p" "$remove_file" || {
      echo "${p} is removed from source but not registered in .chezmoiremove"
      false
    }
  done
}

@test "#496: accumulated hook data is NOT scheduled for deletion" {
  # #473 scopes this change to stopping new writes; deleting the accumulated state.db,
  # bash-commands.log and session-data is a separate explicit decision. A .chezmoiremove
  # entry is a standing per-apply deletion, so registering one of these paths here would
  # silently destroy history on every apply.
  local entries
  # Entry lines only — the file's comments explain what is deliberately NOT listed, and
  # matching those would fail on the very rationale that documents the decision.
  entries="$(grep -v '^[[:space:]]*#' "${HOME_DIR}/.chezmoiremove" | grep -v '^[[:space:]]*$')"
  local p
  for p in state.db bash-commands.log session-data; do
    if printf '%s\n' "$entries" | grep -qF "$p"; then
      echo ".chezmoiremove lists '${p}': deleting accumulated data is out of scope for #496"
      false
    fi
  done
}

@test "#496: claude.zsh no longer defines the removed ecc-* readers" {
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  local fn
  for fn in 'ecc-status()' 'ecc-sessions()' 'ecc-work-items()' 'ecc-state-reader.js'; do
    if grep -qF "$fn" "$zsh"; then
      echo "claude.zsh still references '${fn}', removed with the governance state.db in #496"
      false
    fi
  done
}

@test "#496: the claude-config alias names only hook ids that still exist" {
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -qF "alias claude-config='ECC_DISABLED_HOOKS_EXTRA=pre:config-protection CLAUDE_CONFIG_DIR=\"\$HOME/.claude\" claude'" "$zsh"
}

@test "#496: the deployed CLAUDE.md claims no guardrail that was switched off" {
  # The "hook による自動ガードレール" section tells every session it may skip a confirmation
  # because a hook covers it. Naming a disabled hook there is worse than saying nothing.
  local md="${HOME_DIR}/dot_claude/CLAUDE.md"
  local id
  for id in git-push-reminder tmux-reminder commit-quality; do
    if grep -qF "$id" "$md"; then
      echo "CLAUDE.md still cites '${id}' as an automatic guardrail, but #496 disabled it"
      false
    fi
  done
  # auto-tmux-dev is retained, so its claim must stay.
  grep -qF 'auto-tmux-dev' "$md"
}
