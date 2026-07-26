#!/usr/bin/env bats

load helpers/setup

# Behavioral guard for the brew PATH-shim wrapper (#360),
# home/dot_local/launchers/executable_brew. The wrapper runs the real brew, preserves its exit
# code, and — only after a package-set-mutating subcommand (install/uninstall/reinstall/tap/untap) —
# regenerates the chezmoi source dot_Brewfile via `brew bundle dump`.
#
# These tests exercise the wrapper directly with a stub "real" brew (via BREW_LAUNCHER_BIN, mirroring
# the CLAUDE_LAUNCHER_BIN seam) and a stub chezmoi, so no real brew/chezmoi install is needed
# (CI-safe). The stub brew logs its argv to $BREW_CALLS, writes a marker to the --file= target on
# `bundle dump`, and otherwise exits with $STUB_BREW_EXIT.

WRAPPER="${HOME_DIR}/dot_local/launchers/executable_brew"

# Build the stub brew + stub chezmoi + fake chezmoi source dir under the per-test tmpdir, and export
# the paths the assertions read back.
_stubs() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  SRC="$BATS_TEST_TMPDIR/src"
  BREW_CALLS="$BATS_TEST_TMPDIR/brew-calls"
  mkdir -p "$STUBBIN" "$SRC"
  : >"$BREW_CALLS"

  STUB_BREW="$BATS_TEST_TMPDIR/stub-brew"
  cat >"$STUB_BREW" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BREW_CALLS"
if [ "${1:-}" = "bundle" ] && [ "${2:-}" = "dump" ]; then
  for a in "$@"; do
    case "$a" in --file=*) printf 'dumped\n' >"${a#--file=}" ;; esac
  done
  exit 0
fi
exit "${STUB_BREW_EXIT:-0}"
STUBEOF
  chmod +x "$STUB_BREW"

  # Stub chezmoi on PATH so `command -v chezmoi` and `chezmoi source-path` resolve to our fake source.
  cat >"$STUBBIN/chezmoi" <<STUBEOF
#!/usr/bin/env bash
[ "\${1:-}" = "source-path" ] && { printf '%s\n' "$SRC"; exit 0; }
exit 0
STUBEOF
  chmod +x "$STUBBIN/chezmoi"
}

# Run the wrapper with the stub brew wired in and the stub chezmoi ahead on PATH. Invoked via
# `bash` (not executed directly) because the chezmoi source file is committed non-executable — the
# executable bit is applied at apply time by the `executable_` name prefix, not stored in git.
_run_wrapper() {
  run env \
    PATH="$STUBBIN:$PATH" \
    BREW_LAUNCHER_BIN="$STUB_BREW" \
    BREW_CALLS="$BREW_CALLS" \
    STUB_BREW_EXIT="${STUB_BREW_EXIT:-0}" \
    bash "$WRAPPER" "$@"
}

@test "brew wrapper exists and has valid bash syntax" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "brew wrapper: a mutating subcommand (install) triggers a Brewfile dump" {
  _stubs
  _run_wrapper install foo
  [ "$status" -eq 0 ]
  # The dump wrote the marker to the chezmoi source Brewfile...
  [ -f "$SRC/dot_Brewfile" ]
  # ...via `brew bundle dump`, and the original passthrough ran too.
  grep -qE '^bundle dump ' "$BREW_CALLS"
  grep -qxF 'install foo' "$BREW_CALLS"
}

@test "brew wrapper: a global flag before the subcommand still triggers a dump" {
  _stubs
  _run_wrapper --verbose install foo
  [ "$status" -eq 0 ]
  [ -f "$SRC/dot_Brewfile" ]
}

@test "brew wrapper: a non-mutating subcommand (list) does not dump" {
  _stubs
  _run_wrapper list
  [ "$status" -eq 0 ]
  [ ! -f "$SRC/dot_Brewfile" ]
  ! grep -qE '^bundle dump ' "$BREW_CALLS"
}

@test "brew wrapper: the real brew's exit code is preserved, and it still dumps on a trigger" {
  _stubs
  STUB_BREW_EXIT=42 _run_wrapper install foo
  [ "$status" -eq 42 ]
  [ -f "$SRC/dot_Brewfile" ]
}

@test "brew wrapper: chezmoi absent skips the dump and keeps the real brew's exit code" {
  _stubs
  # A minimal PATH without the chezmoi stub (and without a system chezmoi under /usr/bin:/bin).
  run env \
    PATH="/usr/bin:/bin" \
    BREW_LAUNCHER_BIN="$STUB_BREW" \
    BREW_CALLS="$BREW_CALLS" \
    bash "$WRAPPER" install foo
  [ "$status" -eq 0 ]
  [ ! -f "$SRC/dot_Brewfile" ]
  printf '%s\n' "$output" | grep -qF 'chezmoi not found'
}

@test "brew wrapper: an unresolvable real brew fails loudly (exit 127)" {
  _stubs
  run -127 env \
    PATH="$STUBBIN:$PATH" \
    BREW_LAUNCHER_BIN="$BATS_TEST_TMPDIR/does-not-exist" \
    bash "$WRAPPER" install foo
  printf '%s\n' "$output" | grep -qF 'could not resolve the real brew'
}
