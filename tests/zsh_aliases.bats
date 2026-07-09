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

@test "claude.zsh: _claude_fable pins the main model to claude-fable-5 and skips the prompt when absent" {
  # Regression guard: the fable orchestrator alias family (cldf/cldf-r06/hcldf/hcldf-r06)
  # must always pin the main model to the full ID `claude-fable-5` (not the "fable" alias),
  # and must NOT pass --append-system-prompt when the orchestrator prompt file is missing
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
  # and the prompt body stays out of argv.
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

@test "claude.zsh: _claude_fable passes fable flags through the happy wrapper" {
  # Regression guard for hcldf/hcldf-r06: verify the fable flags actually reach the happy
  # wrapper as CLI args instead of being silently swallowed. The four-alias definition test
  # below only string-matches the alias body; this executes the call path.
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    happy() { print -r -- \"happy|\$*\"; }
    _claude_fable \"\$HOME/.claude\" happy claude --resume
  "
  [ "$status" -eq 0 ]
  [ "$output" = "happy|claude --resume --model claude-fable-5" ]
}

@test "claude.zsh: _claude_fable inlines the orchestrator prompt via --append-system-prompt through happy" {
  # Regression guard for hcldf/hcldf-r06: the happy (slopus/happy) wrapper always injects its
  # own --append-system-prompt, and Claude Code >= 2.1.185 rejects mixing --append-system-prompt
  # with --append-system-prompt-file ("Cannot use both ... Please use only one."). So when
  # routing through happy, the orchestrator prompt must be inlined via --append-system-prompt
  # (repeating the same flag is allowed) instead of --append-system-prompt-file, which would
  # otherwise collide with happy's own flag and abort the launch. Direct (non-happy) launches
  # keep --append-system-prompt-file (covered by the readable-prompt-file test above).
  #
  # The fixture is intentionally multi-line with internal whitespace: the core guarantee is that
  # the whole prompt body reaches happy as a SINGLE argv element (not split on whitespace or
  # newlines). The happy mock asserts the arg count and the exact prompt arg. zsh's $(<file)
  # strips the trailing newline, so the expected value ($'line one\nline two with spaces') has
  # none. Asserting $4 == --append-system-prompt also rejects a stray --append-system-prompt-file.
  mkdir -p "$BATS_TEST_TMPDIR/.claude"
  printf 'line one\nline two with spaces\n' >"$BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md"
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    happy() {
      [[ \$# -eq 5 ]] || { print -r -- \"argc=\$#\"; return 1; }
      [[ \$4 == --append-system-prompt ]] || { print -r -- \"flag=\$4\"; return 1; }
      [[ \$5 == \$'line one\nline two with spaces' ]] || { print -r -- \"body=[\$5]\"; return 1; }
      print -r -- ok
    }
    _claude_fable \"\$HOME/.claude\" happy claude
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
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

@test "claude.zsh: cldf/cldf-r06/hcldf/hcldf-r06 wire the fable orchestrator per account and happy wrapper" {
  # Regression guard: all four fable aliases must go through _claude_fable, exactly two
  # must use the happy wrapper (hcldf/hcldf-r06), and exactly two must target the r06
  # account (cldf-r06/hcldf-r06).
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/claude.zsh'; alias cldf cldf-r06 hcldf hcldf-r06"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cldf="* ]]
  [[ "$output" == *"cldf-r06="* ]]
  [[ "$output" == *"hcldf="* ]]
  [[ "$output" == *"hcldf-r06="* ]]
  fable_count=$(printf '%s\n' "$output" | grep -c _claude_fable)
  [ "$fable_count" -eq 4 ]
  happy_count=$(printf '%s\n' "$output" | grep -c "happy claude")
  [ "$happy_count" -eq 2 ]
  r06_count=$(printf '%s\n' "$output" | grep -c '\.claude-r06')
  [ "$r06_count" -eq 2 ]
}

@test "codex.zsh: hcdx/hcdx-r06 wrap codex in happy with the work CODEX_HOME" {
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/codex.zsh'; alias hcdx hcdx-r06"
  [ "$status" -eq 0 ]
  [[ "$output" == *"happy codex --profile shared"* ]]
  [[ "$output" == *"CODEX_HOME=\$HOME/.codex-r06"* ]]
}
