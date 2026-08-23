#!/usr/bin/env bats

load helpers/setup

# Behavioral guard for the brew PATH-shim wrapper (#360),
# home/dot_local/launchers/executable_brew. The wrapper runs the real brew, preserves its exit
# code, and — only after a package-set-mutating subcommand (install/uninstall/remove/rm/reinstall/
# tap/untap) — regenerates the chezmoi source dot_Brewfile via `brew bundle dump`.
#
# These tests exercise the wrapper directly with a stub "real" brew (via BREW_LAUNCHER_BIN, mirroring
# the CLAUDE_LAUNCHER_BIN seam) and a stub chezmoi, so no real brew/chezmoi install is needed
# (CI-safe). The stub brew logs its argv to $BREW_CALLS, writes a small but realistic Brewfile to
# the --file= target on `bundle dump` (unless $STUB_DUMP_EXIT is non-zero, which simulates a dump
# failure), and otherwise exits with $STUB_BREW_EXIT. The dump payload deliberately contains both
# Go standard-library entries and a genuine module so the wrapper's post-dump sanitizing can be
# exercised. The stub chezmoi fails `source-path` when $STUB_CHEZMOI_SP_FAIL is set.

WRAPPER="${HOME_DIR}/dot_local/launchers/executable_brew"

# Build the stub brew + stub chezmoi + fake chezmoi source dir under the per-test tmpdir, and export
# the paths the assertions read back.
_stubs() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  SRC="$BATS_TEST_TMPDIR/src"
  BREW_CALLS="$BATS_TEST_TMPDIR/brew-calls"
  mkdir -p "$STUBBIN"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  : >"$BREW_CALLS"

  STUB_BREW="$BATS_TEST_TMPDIR/stub-brew"
  cat >"$STUB_BREW" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BREW_CALLS"
if [ "${1:-}" = "bundle" ] && [ "${2:-}" = "dump" ]; then
  if [ "${STUB_DUMP_EXIT:-0}" != "0" ]; then
    echo "stub brew: simulated dump failure" >&2
    exit "${STUB_DUMP_EXIT}"
  fi
  for a in "$@"; do
    case "$a" in
    --file=*)
      cat >"${a#--file=}" <<'DUMPEOF'
brew "coreutils"
go "cmd/go"
go "cmd/gofmt"
go "github.com/owner/repo/cmd/tool"
mas "Xcode", id: 497799835
DUMPEOF
      ;;
    esac
  done
  exit 0
fi
exit "${STUB_BREW_EXIT:-0}"
STUBEOF
  chmod +x "$STUB_BREW"

  # Stub chezmoi on PATH so `command -v chezmoi` and `chezmoi source-path` resolve to our fake source.
  # It fails `source-path` when $STUB_CHEZMOI_SP_FAIL is set, to exercise the AC3 guard.
  cat >"$STUBBIN/chezmoi" <<STUBEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "source-path" ]; then
  if [ -n "\${STUB_CHEZMOI_SP_FAIL:-}" ]; then
    echo "stub chezmoi: simulated source-path failure" >&2
    exit 1
  fi
  printf '%s\n' "$SRC"
  exit 0
fi
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
    STUB_DUMP_EXIT="${STUB_DUMP_EXIT:-0}" \
    STUB_CHEZMOI_SP_FAIL="${STUB_CHEZMOI_SP_FAIL:-}" \
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

@test "brew wrapper: every mutating subcommand (incl. the remove/rm aliases) triggers a dump" {
  local sub
  for sub in install uninstall remove rm reinstall tap untap; do
    _stubs
    _run_wrapper "$sub" foo
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_Brewfile" ] || {
      echo "expected a dump for subcommand: $sub"
      false
    }
  done
}

@test "brew wrapper: a chezmoi source-path failure preserves the real brew exit code (AC3)" {
  _stubs
  STUB_CHEZMOI_SP_FAIL=1 _run_wrapper install foo
  # real brew succeeded (0); the chezmoi failure must not mask it (unguarded assignment would).
  [ "$status" -eq 0 ]
  [ ! -f "$SRC/dot_Brewfile" ]
  printf '%s\n' "$output" | grep -qF 'chezmoi source-path'
}

@test "brew wrapper: a dump failure warns (with cause) but preserves the real brew exit code (AC3)" {
  _stubs
  STUB_DUMP_EXIT=1 _run_wrapper install foo
  [ "$status" -eq 0 ]
  [ ! -f "$SRC/dot_Brewfile" ]
  printf '%s\n' "$output" | grep -qF "'brew bundle dump' failed"
  # the dump's own stderr is forwarded, not swallowed
  printf '%s\n' "$output" | grep -qF 'simulated dump failure'
}

@test "brew wrapper: a non-standard HOMEBREW_PREFIX is not trusted (allowlist)" {
  _stubs
  local evil="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$evil/bin"
  cat >"$evil/bin/brew" <<'E'
#!/usr/bin/env bash
echo "EVIL-BREW-RAN"
exit 0
E
  chmod +x "$evil/bin/brew"
  # No BREW_LAUNCHER_BIN; HOMEBREW_PREFIX points at an attacker dir. A non-mutating subcommand keeps
  # the fall-through harmless even if it reaches a real system brew (plain `--version`).
  run env PATH="/usr/bin:/bin" HOMEBREW_PREFIX="$evil" bash "$WRAPPER" --version
  ! printf '%s\n' "$output" | grep -qF 'EVIL-BREW-RAN'
}

@test "brew wrapper: brew bundle (non-mutating) does not dump — no recursion" {
  _stubs
  _run_wrapper bundle
  [ "$status" -eq 0 ]
  [ ! -f "$SRC/dot_Brewfile" ]
  ! grep -qE '^bundle dump ' "$BREW_CALLS"
}

@test "brew wrapper: the dump is sanitized of Go stdlib entries, keeping real ones" {
  _stubs
  _run_wrapper install foo
  [ "$status" -eq 0 ]
  # `go install` refuses standard-library packages, so a go "cmd/..." entry makes every later
  # `brew bundle` fail forever. brew bundle dump regenerates them from $GOBIN (mise points it at
  # the Go toolchain's own bin dir), so removing them from the Brewfile only sticks if the wrapper
  # strips them on the way out of every dump.
  ! grep -q '^go "cmd/' "$SRC/dot_Brewfile"
  # A genuine module whose import path merely *contains* /cmd/ must survive: only the cmd/ root is
  # reserved for the standard library.
  grep -qF 'go "github.com/owner/repo/cmd/tool"' "$SRC/dot_Brewfile"
  # Nothing else may be dropped on the way through.
  grep -qF 'brew "coreutils"' "$SRC/dot_Brewfile"
  grep -qF 'mas "Xcode", id: 497799835' "$SRC/dot_Brewfile"
}

@test "brew wrapper: sanitizing leaves no staging file in the chezmoi source" {
  _stubs
  _run_wrapper install foo
  [ "$status" -eq 0 ]
  # The staging file is dot-prefixed so chezmoi would ignore a leftover rather than deploy it, but
  # the happy path must not leave one at all.
  local strays
  strays=$(find "$SRC" -maxdepth 1 -name '.brewfile-sanitize.*' | wc -l)
  [ "$strays" -eq 0 ]
}

@test "brew wrapper: a dump failure skips sanitizing entirely" {
  _stubs
  STUB_DUMP_EXIT=1 _run_wrapper install foo
  [ "$status" -eq 0 ]
  # Nothing was written, so there is nothing to sanitize — and no sanitize warning to emit either.
  [ ! -f "$SRC/dot_Brewfile" ]
  ! printf '%s\n' "$output" | grep -qF 'could not strip stdlib go entries'
}

@test "brew wrapper: sanitizing does not mask a failing real brew (AC3)" {
  _stubs
  STUB_BREW_EXIT=3 _run_wrapper install foo
  [ "$status" -eq 3 ]
  # The dump still runs after a failed install (the package set may have changed before the
  # failure) and is still sanitized, but the caller must see brew's own status.
  ! grep -q '^go "cmd/' "$SRC/dot_Brewfile"
}

@test "brew wrapper: passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 "$WRAPPER"
}
