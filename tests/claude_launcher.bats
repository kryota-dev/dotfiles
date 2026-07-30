#!/usr/bin/env bats

load helpers/setup

# Behavioral guard for the per-account Chatshelf isolation env the claude wrapper injects
# (home/dot_local/launchers/executable_claude): each account must get its own explanation store
# (CODE_EXPL_STORE_ROOT) and viewer port (CODE_EXPL_PORT), following the same "state isolated via
# env" rule as CLAUDE_CONFIG_DIR et al. The hook and SessionStart viewer inherit this env because
# they run as children of the exec'd claude, so asserting the wrapper's exports is the seam.
#
# The wrapper is exercised directly with a stub "real" claude wired in via CLAUDE_LAUNCHER_BIN
# (mirroring brew_launcher.bats' BREW_LAUNCHER_BIN seam), so `mise which claude` is never called and
# no real claude/mise install is needed (CI-safe). The stub prints the isolation env it inherited.

WRAPPER="${HOME_DIR}/dot_local/launchers/executable_claude"

setup() {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_HOME" "$BINDIR"

  # Stub claude: print the per-account isolation env the wrapper exported, then exit 0.
  STUB_CLAUDE="$BATS_TEST_TMPDIR/stub-claude"
  cat >"$STUB_CLAUDE" <<'STUBEOF'
#!/usr/bin/env bash
printf 'CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
printf 'CODE_EXPL_STORE_ROOT=%s\n' "$CODE_EXPL_STORE_ROOT"
printf 'CODE_EXPL_PORT=%s\n' "$CODE_EXPL_PORT"
exit 0
STUBEOF
  chmod +x "$STUB_CLAUDE"
}

# Run the wrapper invoked as $1 (claude / cld / cld-r06) so its $0 dispatch fires, with a controlled
# HOME and the stub claude wired in. Extra args are VAR=VAL env assignments (e.g. an inherited
# CLAUDE_CONFIG_DIR for the fill-gaps case). env -i isolates from the runner's own environment;
# EXA_API_KEY=/FIRECRAWL_API_KEY= are present-but-empty so the wrapper's ${VAR+x} guard skips
# sourcing the 0600 secrets file (absent under the fake HOME).
_run_as() {
  local name="$1"
  shift
  local link="$BINDIR/$name"
  ln -sf "$WRAPPER" "$link"
  run env -i \
    HOME="$FAKE_HOME" \
    PATH="/usr/bin:/bin" \
    EXA_API_KEY= \
    FIRECRAWL_API_KEY= \
    CLAUDE_LAUNCHER_BIN="$STUB_CLAUDE" \
    "$@" \
    bash "$link"
}

@test "claude launcher exists and has valid bash syntax" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "claude launcher: personal account (cld) derives the ~/.claude store and port 7788" {
  _run_as cld
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "CLAUDE_CONFIG_DIR=$FAKE_HOME/.claude"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_STORE_ROOT=$FAKE_HOME/.claude/code-explanations"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_PORT=7788"
}

@test "claude launcher: bare 'claude' matches the personal account (#345 parity)" {
  _run_as claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_STORE_ROOT=$FAKE_HOME/.claude/code-explanations"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_PORT=7788"
}

@test "claude launcher: work account (cld-r06) derives the ~/.claude-r06 store and port 7789" {
  _run_as cld-r06
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "CLAUDE_CONFIG_DIR=$FAKE_HOME/.claude-r06"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_STORE_ROOT=$FAKE_HOME/.claude-r06/code-explanations"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_PORT=7789"
}

@test "claude launcher: cld fills gaps — an inherited r06 config dir keeps store/port on r06" {
  _run_as cld "CLAUDE_CONFIG_DIR=$FAKE_HOME/.claude-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_STORE_ROOT=$FAKE_HOME/.claude-r06/code-explanations"
  printf '%s\n' "$output" | grep -qxF "CODE_EXPL_PORT=7789"
}

@test "claude launcher passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 "$WRAPPER"
}
