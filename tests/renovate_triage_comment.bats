#!/usr/bin/env bats

# Create-only comment wrapper for the Renovate triage workflow
# (scripts/renovate-triage-comment.sh). `gh` is stubbed on PATH; no network, CI-safe.
# Covers the structural write-scope guarantees: fixed argc, dashboard-only-#12,
# open-Renovate-PR-only, create-only (never edit/delete), empty-body refusal.

load helpers/setup

SCRIPT="${REPO_ROOT}/scripts/renovate-triage-comment.sh"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  # gh stub: records argv, and for `pr list` prints a fixed set of open Renovate PRs.
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_STUB_LOG}"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '101\n102\n'
fi
exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
  GH_STUB_LOG="${BATS_TEST_TMPDIR}/gh_args"
  : >"$GH_STUB_LOG"
}

run_wrapper() {
  run env PATH="${STUB_DIR}:${PATH}" GH_STUB_LOG="$GH_STUB_LOG" \
    GITHUB_REPOSITORY="owner/repo" bash "$SCRIPT" "$@"
}

@test "wrapper exists, is executable, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "rejects wrong argument count" {
  run_wrapper dashboard 12
  [ "$status" -eq 64 ]
}

@test "rejects empty body" {
  run_wrapper dashboard 12 ""
  [ "$status" -eq 64 ]
}

@test "rejects unknown target" {
  run_wrapper wiki 12 "hi"
  [ "$status" -eq 64 ]
}

@test "dashboard target must be issue 12" {
  run_wrapper dashboard 13 "hi"
  [ "$status" -eq 64 ]
}

@test "dashboard posts to issue 12 (create-only)" {
  run_wrapper dashboard 12 "summary"
  [ "$status" -eq 0 ]
  grep -q 'issue comment 12 --repo owner/repo --body summary' "$GH_STUB_LOG"
}

@test "rejects a non-numeric PR number" {
  run_wrapper pr abc "hi"
  [ "$status" -eq 64 ]
}

@test "rejects a PR that is not an open Renovate PR" {
  run_wrapper pr 999 "hi"
  [ "$status" -eq 65 ]
  ! grep -q 'pr comment' "$GH_STUB_LOG"
}

@test "comments on an open Renovate PR (create-only)" {
  run_wrapper pr 101 "detail"
  [ "$status" -eq 0 ]
  grep -q 'pr comment 101 --repo owner/repo --body detail' "$GH_STUB_LOG"
}

@test "never invokes edit or delete flags" {
  run_wrapper pr 101 "detail"
  ! grep -qE 'edit-last|delete-last' "$GH_STUB_LOG"
}
