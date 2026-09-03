#!/usr/bin/env bats

# Verdict recorder for the Renovate merge gate (scripts/renovate-gate-verdict.sh).
#
# This script is the review agent's only write tool, so the tests here are as much
# about what it CANNOT do as what it does: `gh` and `curl` are replaced with stubs
# that fail loudly, so any attempt to reach the network turns into a red test
# rather than a quietly widened write surface.

load helpers/setup

SCRIPT="${REPO_ROOT}/scripts/renovate-gate-verdict.sh"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  # Poisoned stubs: invoking either one writes a tripwire file and fails.
  TRIPWIRE="${BATS_TEST_TMPDIR}/tripwire"
  local cmd
  for cmd in gh curl wget nc; do
    cat >"${STUB_DIR}/${cmd}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${cmd}" "\$*" >>"${TRIPWIRE}"
exit 1
EOF
    chmod +x "${STUB_DIR}/${cmd}"
  done
  VERDICT_FILE="${BATS_TEST_TMPDIR}/verdict.json"
}

run_verdict() {
  run env PATH="${STUB_DIR}:${PATH}" \
    RENOVATE_GATE_VERDICT_FILE="$VERDICT_FILE" bash "$SCRIPT" "$@"
}

assert_no_network() {
  [ ! -f "$TRIPWIRE" ] || {
    echo "the script reached for the network: $(cat "$TRIPWIRE")"
    false
  }
}

@test "recorder exists, is executable, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "records a pass verdict as JSON" {
  run_verdict pass "バージョンピン更新"
  [ "$status" -eq 0 ]
  [ "$(jq -r .result "$VERDICT_FILE")" = "pass" ]
  [ "$(jq -r .reason "$VERDICT_FILE")" = "バージョンピン更新" ]
}

@test "records a fail verdict as JSON" {
  run_verdict fail "breaking change あり"
  [ "$status" -eq 0 ]
  [ "$(jq -r .result "$VERDICT_FILE")" = "fail" ]
}

@test "never invokes gh, curl or any other network client" {
  run_verdict pass "ok"
  assert_no_network
}

@test "does not contain a gh or curl invocation at all" {
  # Source-level guard: the runtime check above only covers the paths the tests
  # exercise, so also assert the strings are absent outside comments.
  run grep -nE '^[^#]*\b(gh|curl|wget|nc)\b' "$SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "network client referenced in code: ${output}"
    false
  }
}

@test "records a close verdict as JSON" {
  # `close` is a decision the workflow acts on, not an action the agent performs:
  # the agent has no way to close a PR itself.
  run_verdict close "却下されたため PR をクローズする"
  [ "$status" -eq 0 ]
  [ "$(jq -r .result "$VERDICT_FILE")" = "close" ]
}

@test "rejects an unknown verdict" {
  run_verdict maybe "hm"
  [ "$status" -eq 64 ]
  [ ! -f "$VERDICT_FILE" ]
}

@test "rejects wrong argument count" {
  run_verdict pass
  [ "$status" -eq 64 ]
}

@test "rejects an empty reason" {
  run_verdict pass ""
  [ "$status" -eq 64 ]
}

@test "fails when the destination is not set (never guesses a path)" {
  run env PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" pass "ok"
  [ "$status" -ne 0 ]
}

@test "the destination comes from the environment, not from argv" {
  # A third argument must not be accepted as an output path.
  run_verdict pass "ok" "${BATS_TEST_TMPDIR}/elsewhere.json"
  [ "$status" -eq 64 ]
  [ ! -f "${BATS_TEST_TMPDIR}/elsewhere.json" ]
}

@test "a reason containing quotes and newlines stays valid JSON" {
  run_verdict fail 'he said "no" \ and
then stopped'
  [ "$status" -eq 0 ]
  jq -e . "$VERDICT_FILE" >/dev/null
  [ "$(jq -r .result "$VERDICT_FILE")" = "fail" ]
}
