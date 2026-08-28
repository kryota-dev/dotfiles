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

# Hook entries that stay wired but are switched off. stop:desktop-notify keeps its entry for
# the documented one-step rollback of #337, so its id legitimately appears in
# ECC_DISABLED_HOOKS alongside the sub-hook ids above.
DISABLED_ENTRY_IDS=(
  "stop:desktop-notify"
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

# Of the retained entries, these four have no field-level guard anywhere else in the suite, so
# an id-only check would accept moving one to another event, narrowing its matcher, or
# swapping its command for a no-op. The two CLV2 observer entries are deliberately absent:
# tests/files.bats already pins their event, matcher, command, async and timeout, and
# duplicating that here would just create two places to update.
STRUCTURALLY_PINNED_HOOK_IDS=(
  "session:start"
  "pre:bash:dispatcher"
  "pre:config-protection"
  "post:mcp-health-check"
)

_require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
}

_hook_ids() {
  jq -r '.hooks | to_entries[] | .value[] | .id' "$SETTINGS"
}

# One line per entry: event, id, matcher, command, async, timeout — sorted, tab-separated.
# Absent optional keys render as "null" (jq's tostring), and that is part of the contract: a
# hook that gains an async flag or a timeout has changed how it runs.
_manifest_by_command() {
  jq -r --arg pattern "$1" '
    .hooks | to_entries[] | .key as $event | .value[]
    | select(.hooks[].command | test($pattern))
    | [ $event, .id, (.matcher | tostring), .hooks[0].command,
        (.hooks[0].async | tostring), (.hooks[0].timeout | tostring) ]
    | @tsv
  ' "$SETTINGS" | sort
}

# Exact id-set selection (not substring containment, which would let one id match another
# that merely contains it).
_manifest_by_ids() {
  local ids_json
  ids_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r --argjson ids "$ids_json" '
    .hooks | to_entries[] | .key as $event | .value[]
    | select(.id as $i | $ids | index($i))
    | [ $event, .id, (.matcher | tostring), .hooks[0].command,
        (.hooks[0].async | tostring), (.hooks[0].timeout | tostring) ]
    | @tsv
  ' "$SETTINGS" | sort
}

_assert_manifest() {
  local label="$1" expected="$2" actual="$3"
  [ "$actual" = "$expected" ] || {
    echo "${label} wiring drifted (expected <-> actual):"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
    false
  }
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

@test "#496: ECC_DISABLED_HOOKS is exactly the set this change intends to disable" {
  _require_jq
  # Exact set, not "contains". A containment check would accept a dead id sneaking back in —
  # the three post:bash:* ids that went with the post-Bash dispatcher, or the Edit/Write
  # fact-forcing id whose entry AC-011 deleted. A dead id here reads like an active safety
  # decision while gating nothing, which is the exact failure AC-011 cleaned up. Comparing the
  # whole set also means the "must disable" half (#473 AC-010) and the "no dead id" half are
  # one invariant instead of two that can drift apart.
  local expected actual
  expected="$(printf '%s\n' "${DISABLED_SUB_HOOK_IDS[@]}" "${DISABLED_ENTRY_IDS[@]}" | sort)"
  actual="$(jq -r '.env.ECC_DISABLED_HOOKS | split(",")[]' "$SETTINGS" | sort)"
  _assert_manifest "ECC_DISABLED_HOOKS" "$expected" "$actual"
}

@test "#496: every disabled pre:bash sub-hook id exists in the ECC dispatcher" {
  # Sub-hook ids never appear as settings.json entries, so nothing else here can tell
  # `pre:bash:git-push-reminder` from `pre:bash:git-push-remider`. A typo passes every other
  # guard in this file and silently disables nothing — fail-open. The ECC runtime is an
  # external, so cross-check it only when it is actually deployed.
  local dispatcher="${HOME}/.agents/skills/ecc/scripts/hooks/bash-hook-dispatcher.js"
  [ -f "$dispatcher" ] || skip "ECC external not deployed"
  local id
  for id in "${DISABLED_SUB_HOOK_IDS[@]}"; do
    grep -qF "'${id}'" "$dispatcher" || {
      echo "ECC_DISABLED_HOOKS names '${id}' but PRE_BASH_HOOKS has no such id (typo = silent no-op)"
      false
    }
  done
}

@test "#473 AC-008: ECC_HOOK_PROFILE stays strict (the safety sub-hooks are profile-gated)" {
  _require_jq
  # ECC's isHookEnabled() ANDs ECC_DISABLED_HOOKS with ECC_HOOK_PROFILE. Flipping the profile
  # to "minimal" disables gateguard-fact-force (destructive-command detection), auto-tmux-dev
  # and pre:config-protection — all of which declare standard,strict — as surely as naming
  # them in ECC_DISABLED_HOOKS would, and nothing else in this file would catch it.
  jq -e '.env.ECC_HOOK_PROFILE == "strict"' "$SETTINGS" >/dev/null
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

@test "#473 AC-008/014/025: the load-bearing retained hooks keep their exact wiring" {
  _require_jq
  # "Still present" is not the requirement — "still fires the same way" is. Pin event, matcher,
  # command, async and timeout so that relocating an entry to another event, narrowing its
  # matcher, or pointing it at a different script fails here instead of silently weakening the
  # boundary. Note the CLI angle: `claude plugin install` and the interactive /plugin manager
  # rewrite settings.json with their own serializer and drop each hook's id and description
  # (docs/agents/claude-code.md), so an id-only guard is the one that goes blind during that
  # window — these five fields survive it.
  local expected actual
  expected="$(
    cat <<'MANIFEST'
PostToolUseFailure	post:mcp-health-check	*	CLAUDE_HOOK_EVENT_NAME=PostToolUseFailure $HOME/.claude/ecc-hook.sh scripts/hooks/run-with-flags.js post:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict	null	10
PreToolUse	pre:bash:dispatcher	Bash	$HOME/.claude/ecc-hook.sh scripts/hooks/pre-bash-dispatcher.js	null	15
PreToolUse	pre:config-protection	Write|Edit|MultiEdit	$HOME/.claude/ecc-hook.sh scripts/hooks/run-with-flags.js pre:config-protection scripts/hooks/config-protection.js standard,strict	null	5
SessionStart	session:start	*	$HOME/.claude/ecc-hook.sh scripts/hooks/session-start-bootstrap.js	null	null
MANIFEST
  )"
  actual="$(_manifest_by_ids "${STRUCTURALLY_PINNED_HOOK_IDS[@]}")"
  _assert_manifest "retained hook" "$expected" "$actual"
}

@test "#496: the hook surface is exactly the 18 entries this change leaves behind" {
  _require_jq
  # The removed-id list guards against a hook coming back under its old id. This guards the
  # other direction: a hook arriving under a new id, or an id being wired twice. Together they
  # make "the surface shrank to 18" a checked contract rather than a claim in the PR body.
  # Adding or removing a hook is expected to update this list — that edit is the review signal.
  local expected actual
  expected="$(
    cat <<'MANIFEST'
Notification	notification:ntfy-notify
Notification	notification:wave-session-event
PostToolUse	post:observe:continuous-learning
PostToolUse	posttooluse:wave-session-event
PostToolUseFailure	post:mcp-health-check
PostToolUseFailure	posttoolusefailure:wave-session-event
PreToolUse	pre:bash:dispatcher
PreToolUse	pre:config-protection
PreToolUse	pre:observe:continuous-learning
PreToolUse	pretooluse:wave-session-event
SessionStart	session:start
Stop	stop:cost-tracker
Stop	stop:desktop-notify
Stop	stop:ntfy-notify
Stop	stop:wave-session-event
StopFailure	stopfailure:wave-session-event
UserPromptSubmit	user-prompt-submit:prompt-conform-suggest
UserPromptSubmit	userpromptsubmit:wave-session-event
MANIFEST
  )"
  actual="$(jq -r '.hooks | to_entries[] | .key as $event | .value[] | [$event, .id] | @tsv' "$SETTINGS" | sort)"
  _assert_manifest "hook surface" "$expected" "$actual"

  # Ids must also be unique across the whole surface: two entries sharing an id would make
  # every id-keyed guard in this file ambiguous.
  local total unique
  total="$(_hook_ids | grep -c .)"
  unique="$(_hook_ids | sort -u | grep -c .)"
  [ "$total" = "18" ] || {
    echo "expected 18 hook entries, found ${total}"
    false
  }
  [ "$total" = "$unique" ] || {
    echo "hook ids are not unique: ${total} entries but ${unique} distinct ids"
    false
  }
}

@test "#473 AC-008: the pre-Bash dispatcher keeps its safety sub-hooks enabled" {
  _require_jq
  # block-no-verify (commit-verification bypass), auto-tmux-dev (dev server) and the
  # gateguard's destructive fact-forcing must not be switched off alongside the advisories.
  # Split on commas and match whole ids: a substring match would flag a future
  # `pre:bash:auto-tmux-dev-debug` as if it disabled `pre:bash:auto-tmux-dev`, and it would
  # also disagree with the exact-match style the removed-id guard above uses.
  local disabled id
  disabled="$(jq -r '.env.ECC_DISABLED_HOOKS | split(",")[]' "$SETTINGS")"
  for id in pre:bash:block-no-verify pre:bash:auto-tmux-dev pre:bash:gateguard-fact-force; do
    if printf '%s\n' "$disabled" | grep -qFx "$id"; then
      echo "'${id}' is a retained safety hook (#473 AC-008) but ECC_DISABLED_HOOKS disables it"
      false
    fi
  done
}

@test "#473 AC-016: the wave-orchestrator session events are untouched" {
  _require_jq
  # wave-orchestrator watches its children through these seven entries, so this pins the whole
  # wiring — event, id, matcher, command, async, timeout — rather than just which events are
  # present. Narrowing a matcher blinds the parent exactly as deleting an entry would:
  # dropping idle_prompt from Notification, or widening PreToolUse past AskUserQuestion, keeps
  # the event set intact while breaking detection. Same structural bar the ntfy and CLV2
  # observer guards in tests/files.bats already apply. "null" in the matcher column is real:
  # UserPromptSubmit does not support a matcher (official Hooks reference), so its entry
  # legitimately omits the key.
  local expected actual
  expected="$(
    cat <<'MANIFEST'
Notification	notification:wave-session-event	permission_prompt|idle_prompt|agent_needs_input	$HOME/.claude/wave-session-event.sh	true	10
PostToolUse	posttooluse:wave-session-event	AskUserQuestion	$HOME/.claude/wave-session-event.sh	true	10
PostToolUseFailure	posttoolusefailure:wave-session-event	AskUserQuestion	$HOME/.claude/wave-session-event.sh	true	10
PreToolUse	pretooluse:wave-session-event	AskUserQuestion	$HOME/.claude/wave-session-event.sh	true	10
Stop	stop:wave-session-event	*	$HOME/.claude/wave-session-event.sh	true	10
StopFailure	stopfailure:wave-session-event	*	$HOME/.claude/wave-session-event.sh	true	10
UserPromptSubmit	userpromptsubmit:wave-session-event	null	$HOME/.claude/wave-session-event.sh	true	10
MANIFEST
  )"
  actual="$(_manifest_by_command "wave-session-event")"
  _assert_manifest "wave-session-event" "$expected" "$actual"
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

@test "#496: the orphaned bash-commands.log stays out of chezmoi's reach" {
  # #496 removed the writer (hooks-fork/post-bash-command-log.js) but deliberately keeps the
  # accumulated log. That combination — a large, unredacted-by-best-effort command history that
  # nothing updates any more — is precisely what a broad `chezmoi add` under ~/.claude could
  # sweep into this public repo, so both accounts' copies must stay ignored.
  local ignore_file="${HOME_DIR}/.chezmoiignore"
  local p
  for p in ".claude/bash-commands.log" ".claude-r06/bash-commands.log"; do
    grep -qFx "$p" "$ignore_file" || {
      echo "${p} is an orphaned command history but .chezmoiignore does not exclude it"
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
