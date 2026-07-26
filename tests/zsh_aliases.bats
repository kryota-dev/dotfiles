#!/usr/bin/env bats

load helpers/setup

# Behavioral regression guard for the multi-account claude/codex alias families and the
# _claude_with_home refactor: the helper runs whatever command is passed after the account
# home dir, so that command inherits the exact same per-account environment.
# zsh_syntax.bats only covers `zsh -n` (syntax).
#
# Aliases defined in a sourced file are NOT expanded for commands in the same parse unit,
# so these tests drive the underlying function directly and query alias definitions with
# the `alias` builtin instead of relying on alias expansion. `zsh -f` skips rc files.

@test "claude.zsh: _claude_with_home sets the account env and runs the given command" {
  # The mock stands in for an arbitrary command: _claude_with_home shifts off the account
  # home dir and execs the rest verbatim, so a multi-token command must survive intact.
  run zsh -fc "
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    wrapper() { print -r -- \"wrapper|\$CLAUDE_CONFIG_DIR|\$ECC_AGENT_DATA_HOME|\$GATEGUARD_STATE_DIR|\$*\"; }
    _claude_with_home \"\$HOME/.claude-r06\" wrapper claude --resume
  "
  [ "$status" -eq 0 ]
  [ "$output" = "wrapper|$HOME/.claude-r06|$HOME/.claude-r06|$HOME/.claude-r06/.gateguard|claude --resume" ]
}

@test "claude.zsh: _claude_with_home raises the observer timeout with an overridable default" {
  run zsh -fc "
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"\$ECC_OBSERVER_TIMEOUT_SECONDS\"; }
    _claude_with_home \"\$HOME/.claude\"
    ECC_OBSERVER_TIMEOUT_SECONDS=45 _claude_with_home \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "300" ]
  [ "${lines[1]}" = "45" ]
}

@test "claude.zsh: _claude_with_home keeps the CLV2 homunculus dir out of the config dir" {
  # Regression guard for #336: Claude Code classifies every path under the Claude config dir as
  # a sensitive file, so the headless CLV2 analysis pass (claude --model haiku --print) can
  # never get an instinct write there approved — instinct generation stayed at exactly zero for
  # as long as this pointed at <account>/ecc-homunculus. Pin the real values, then pin the
  # property that made them necessary, so moving the dir back under ~/.claude* fails here.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"\$CLV2_HOMUNCULUS_DIR\"; }
    _claude_with_home \"\$HOME/.claude\"
    _claude_with_home \"\$HOME/.claude-r06\"
  "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-default" ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-r06" ]
  # Neither account may resolve under the config dir.
  [[ "${lines[0]}" != "$BATS_TEST_TMPDIR/.claude"* ]]
  [[ "${lines[1]}" != "$BATS_TEST_TMPDIR/.claude"* ]]
  # The accounts stay distinct from each other and from the bare-`claude` fallback, which
  # carries no account suffix.
  [ "${lines[0]}" != "${lines[1]}" ]
  [ "${lines[0]}" != "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus" ]
  [ "${lines[1]}" != "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus" ]
}

@test "claude.zsh: _claude_with_home disables the observer clock gate and lifts its turn ceiling" {
  # #336: the CLV2 session-guardian clock gate (default 800-2300) skipped ~90 analysis cycles
  # per project because sessions here run past midnight, and the auto-scaled --max-turns floor
  # of 20 cut the Read -> dedup-check -> Write pass off mid-write. BOTH halves of the window
  # must be 0 — the guardian only skips the gate when START and END are both zero — and all
  # three values must stay overridable.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"\$OBSERVER_ACTIVE_HOURS_START|\$OBSERVER_ACTIVE_HOURS_END|\$ECC_OBSERVER_MAX_TURNS\"; }
    _claude_with_home \"\$HOME/.claude\"
    OBSERVER_ACTIVE_HOURS_START=900 OBSERVER_ACTIVE_HOURS_END=2200 ECC_OBSERVER_MAX_TURNS=40 _claude_with_home \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0|0|100" ]
  [ "${lines[1]}" = "900|2200|40" ]
}

@test "claude.zsh: _claude_with_home defaults to claude when no command is given" {
  run zsh -fc "
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$CLAUDE_CONFIG_DIR|\$*\"; }
    _claude_with_home \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|$HOME/.claude|" ]
}

@test "claude.zsh: cld/cld-r06 launch claude per account" {
  # Pin each alias body exactly instead of counting matches. Counting ".claude-r06" once
  # still passes if the two accounts are swapped, and a substring check for
  # _claude_with_home still passes if cld degrades to a bare `claude` — the swap is
  # precisely what this guards. HOME is redirected so sourcing claude.zsh cannot pick up
  # the real ~/.config/zsh/claude-secrets.zsh; alias bodies keep $HOME unexpanded, so the
  # expected strings are unaffected.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    alias cld cld-r06
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "cld='_claude_with_home \"\$HOME/.claude\" claude'"
  printf '%s\n' "$output" | grep -qFx "cld-r06='_claude_with_home \"\$HOME/.claude-r06\" claude'"
}

@test "claude.zsh: _claude_fable pins the main model to claude-fable-5 and skips the prompt when absent" {
  # Regression guard: the fable orchestrator alias family (cldf/cldf-r06) must always pin
  # the main model to the full ID `claude-fable-5` (not the "fable" alias), and must NOT
  # pass --append-system-prompt-file when the orchestrator prompt file is missing
  # (chezmoi apply hasn't run yet or the file was removed).
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$*\"; }
    _claude_fable \"\$HOME/.claude\" claude
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|--model claude-fable-5" ]
}

@test "claude.zsh: _claude_fable appends the orchestrator prompt file when it is readable" {
  # Regression guard: when the orchestrator prompt file exists, its path (not its content)
  # must be passed via --append-system-prompt-file so the CLI reads it at process start
  # and the prompt body stays out of argv. The exact-output assertion also rejects a
  # regression to the inline --append-system-prompt form.
  mkdir -p "$BATS_TEST_TMPDIR/.claude"
  : >"$BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md"
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$*\"; }
    _claude_fable \"\$HOME/.claude\" claude
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|--model claude-fable-5 --append-system-prompt-file $BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md" ]
}

@test "claude.zsh: _claude_fable passes the caller's own flags through alongside the fable flags" {
  # Regression guard: user flags given to the alias must reach the CLI instead of being
  # silently swallowed by the fable flag append. The alias-definition test below only
  # string-matches the alias body; this executes the call path.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$*\"; }
    _claude_fable \"\$HOME/.claude\" claude --resume
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|--resume --model claude-fable-5" ]
}

@test "claude.zsh: _claude_fable defaults to claude when no command is given" {
  # Symmetry with _claude_with_home's own default-command fallback: bare invocation
  # (e.g. `_claude_fable "$HOME/.claude"`) must launch `claude` rather than exec'ing
  # `--model` as the command.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$*\"; }
    _claude_fable \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|--model claude-fable-5" ]
}

@test "claude.zsh: cldf/cldf-r06 wire the fable orchestrator per account" {
  # Regression guard: both fable aliases must go through _claude_fable, and exactly one
  # must target the r06 account (cldf-r06).
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/claude.zsh'; alias cldf cldf-r06"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cldf="* ]]
  [[ "$output" == *"cldf-r06="* ]]
  fable_count=$(printf '%s\n' "$output" | grep -c _claude_fable)
  [ "$fable_count" -eq 2 ]
  r06_count=$(printf '%s\n' "$output" | grep -c '\.claude-r06')
  [ "$r06_count" -eq 1 ]
}

@test "codex.zsh: cdx/cdx-r06 inject --profile shared and scope CODEX_HOME to the work account" {
  # Regression guard: both aliases must inject --profile shared (bare `codex` silently
  # ignores shared.config.toml), and only cdx-r06 may set CODEX_HOME — cdx deliberately
  # leaves it unset so Codex falls back to the default ~/.codex. Pinning both bodies
  # exactly is what rejects an account swap; counting occurrences would not.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/codex.zsh'
    alias cdx cdx-r06
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "cdx='codex --profile shared'"
  printf '%s\n' "$output" | grep -qFx "cdx-r06='CODEX_HOME=\$HOME/.codex-r06 codex --profile shared'"
}
