#!/usr/bin/env bats

# Commit-status reporter for the Renovate merge gate
# (scripts/renovate-gate-status.sh). `gh` is stubbed on PATH; no network, CI-safe.
#
# The point of these tests is that the caller cannot widen what this script does:
# the context is a constant, the state is a closed set, and the sha has to look
# like a sha. A caller that could choose the context could report under some other
# check's name and satisfy a required check it never actually ran.

load helpers/setup

SCRIPT="${REPO_ROOT}/scripts/renovate-gate-status.sh"

# The required-check name, duplicated here on purpose: if someone changes the
# constant in the script without re-registering the required status check in the
# ruleset, the gate stops blocking merges and nothing else would notice.
EXPECTED_CONTEXT="renovate-gate"
SHA="0123456789abcdef0123456789abcdef01234567"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_STUB_LOG}"
exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
  GH_STUB_LOG="${BATS_TEST_TMPDIR}/gh_args"
  : >"$GH_STUB_LOG"
}

run_status() {
  run env PATH="${STUB_DIR}:${PATH}" GH_STUB_LOG="$GH_STUB_LOG" \
    GITHUB_REPOSITORY="owner/repo" bash "$SCRIPT" "$@"
}

@test "reporter exists, is executable, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "posts a success status to the statuses endpoint" {
  run_status "$SHA" success "ok"
  [ "$status" -eq 0 ]
  grep -qF "api repos/owner/repo/statuses/${SHA}" "$GH_STUB_LOG"
  grep -qF "state=success" "$GH_STUB_LOG"
}

@test "always reports under the fixed context" {
  run_status "$SHA" failure "ng"
  grep -qF "context=${EXPECTED_CONTEXT}" "$GH_STUB_LOG"
}

@test "the script pins the context as a readonly constant, not an argument" {
  grep -qE "^readonly STATUS_CONTEXT='${EXPECTED_CONTEXT}'\$" "$SCRIPT"
}

@test "accepts all three valid states" {
  local s
  for s in success failure pending; do
    : >"$GH_STUB_LOG"
    run_status "$SHA" "$s" "d"
    [ "$status" -eq 0 ]
    grep -qF "state=${s}" "$GH_STUB_LOG"
  done
}

@test "rejects an unknown state" {
  run_status "$SHA" error "d"
  [ "$status" -eq 64 ]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "rejects a malformed sha" {
  run_status "not-a-sha" success "d"
  [ "$status" -eq 64 ]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "rejects wrong argument count" {
  run_status "$SHA" success
  [ "$status" -eq 64 ]
}

@test "rejects an empty description" {
  run_status "$SHA" success ""
  [ "$status" -eq 64 ]
}

@test "truncates an over-long description to the API limit" {
  local long
  long="$(printf 'あ%.0s' $(seq 1 300))"
  run_status "$SHA" success "$long"
  [ "$status" -eq 0 ]
  # The recorded argv must not carry more than 140 characters of description.
  local desc
  desc="$(sed -n 's/.*description=//p' "$GH_STUB_LOG")"
  [ "${#desc}" -le 140 ]
}

@test "flattens newlines so the argv stays one field" {
  run_status "$SHA" failure "line one
line two"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$GH_STUB_LOG" | tr -d ' ')" = "1" ]
}

@test "never invokes a merge, review or comment subcommand" {
  run_status "$SHA" success "d"
  ! grep -qE 'pr (merge|review|comment)' "$GH_STUB_LOG"
}
