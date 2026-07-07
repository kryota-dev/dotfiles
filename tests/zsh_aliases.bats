#!/usr/bin/env bats

load helpers/setup

# Behavioral regression guard for the happy (slopus/happy) multi-account wrappers and the
# _claude_with_home refactor: the helper now runs whatever command is passed after the
# account home dir ("claude ..." or "happy claude ..."), so the happy wrapper inherits the
# exact same per-account environment. zsh_syntax.bats only covers `zsh -n` (syntax).
#
# Aliases defined in a sourced file are NOT expanded for commands in the same parse unit,
# so these tests drive the underlying function directly and query alias definitions with
# the `alias` builtin instead of relying on alias expansion. `zsh -f` skips rc files.

@test "claude.zsh: _claude_with_home sets the account env and runs the given command" {
  run zsh -fc "
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    happy() { print -r -- \"happy|\$CLAUDE_CONFIG_DIR|\$ECC_AGENT_DATA_HOME|\$GATEGUARD_STATE_DIR|\$*\"; }
    _claude_with_home \"\$HOME/.claude-r06\" happy claude --resume
  "
  [ "$status" -eq 0 ]
  [ "$output" = "happy|$HOME/.claude-r06|$HOME/.claude-r06|$HOME/.claude-r06/.gateguard|claude --resume" ]
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

@test "claude.zsh: _claude_with_home defaults to claude when no command is given" {
  run zsh -fc "
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$CLAUDE_CONFIG_DIR|\$*\"; }
    _claude_with_home \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|$HOME/.claude|" ]
}

@test "claude.zsh: hcld/hcld-r06 wrap claude in happy per account" {
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/claude.zsh'; alias hcld hcld-r06"
  [ "$status" -eq 0 ]
  [[ "$output" == *"happy claude"* ]]
  [[ "$output" == *".claude-r06"* ]]
}

@test "codex.zsh: hcdx/hcdx-r06 wrap codex in happy with the work CODEX_HOME" {
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/codex.zsh'; alias hcdx hcdx-r06"
  [ "$status" -eq 0 ]
  [[ "$output" == *"happy codex --profile shared"* ]]
  [[ "$output" == *"CODEX_HOME=\$HOME/.codex-r06"* ]]
}
