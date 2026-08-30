#!/usr/bin/env bats

load helpers/setup

# Guards for the two #508 items that live outside the Node modules:
#
#   - the `fh` launcher must resolve node through mise's pin, and an environment variable
#     must not be able to substitute a different interpreter (the comment at the top of the
#     launcher states the pin as its purpose; an override silently defeated it)
#   - the harness directory the CLI creates inside a repository must be ignored by the
#     repository's own .gitignore, not by whatever each clone happens to have in
#     .git/info/exclude

LAUNCHER="${HOME_DIR}/dot_local/bin/executable_frontier-harness"

# A fake HOME holding a stub CLI module, plus a stub `mise` whose `which node` answers with a
# stub interpreter that prints its argv. Nothing here needs a real node or a real mise.
_launcher_fixture() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STUBBIN" "$FAKE_HOME/.local/lib/frontier-harness"
  : >"$FAKE_HOME/.local/lib/frontier-harness/cli.mjs"

  STUB_NODE="$BATS_TEST_TMPDIR/stub-node"
  cat >"$STUB_NODE" <<'STUBEOF'
#!/usr/bin/env bash
echo "mise-pinned node ran: $*"
STUBEOF
  chmod +x "$STUB_NODE"

  cat >"$STUBBIN/mise" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "which" ] && [ "\$2" = "node" ]; then
  if [ "\${STUB_MISE_FAILS:-0}" != "0" ]; then exit 1; fi
  echo "$STUB_NODE"
  exit 0
fi
exit 1
STUBEOF
  chmod +x "$STUBBIN/mise"
}

@test "fh launcher runs the mise-pinned node" {
  _launcher_fixture
  PATH="$STUBBIN:$PATH" HOME="$FAKE_HOME" run bash "$LAUNCHER" doctor --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise-pinned node ran:"* ]]
  [[ "$output" == *"doctor --json"* ]]
}

@test "fh launcher ignores an environment override of the node executable" {
  _launcher_fixture
  # A substituted interpreter would run the CLI module as its own argument -- exactly what the
  # pin exists to prevent, and a silent way to run harness code under an attacker's binary.
  IMPOSTOR="$BATS_TEST_TMPDIR/impostor-node"
  cat >"$IMPOSTOR" <<'STUBEOF'
#!/usr/bin/env bash
echo "impostor ran"
STUBEOF
  chmod +x "$IMPOSTOR"

  PATH="$STUBBIN:$PATH" HOME="$FAKE_HOME" FH_NODE_BIN="$IMPOSTOR" run bash "$LAUNCHER" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise-pinned node ran:"* ]]
  [[ "$output" != *"impostor ran"* ]]
}

@test "fh launcher fails closed when mise cannot resolve node" {
  _launcher_fixture
  PATH="$STUBBIN:$PATH" HOME="$FAKE_HOME" STUB_MISE_FAILS=1 run -127 bash "$LAUNCHER" doctor
  [ "$status" -eq 127 ]
  [[ "$output" == *"mise"* ]]
}

@test "the harness directory created inside a repository is ignored by the tracked .gitignore" {
  # .git/info/exclude is per-clone and untracked, so a fresh clone would offer .harness/ for
  # commit. The policy file is per-worktree runtime state bound to an approval in the state
  # root; committing it would carry an unapproved policy into every checkout.
  run grep -qE '^\.harness/$' "${REPO_ROOT}/.gitignore"
  [ "$status" -eq 0 ]
}
