#!/usr/bin/env bats

# Deterministic classifier for the Renovate merge gate
# (scripts/renovate-gate-classify.sh). `gh` is stubbed on PATH; no network, CI-safe.
#
# The assertions that matter most are the negative ones: a one-line diff must NOT
# be enough to reach the fast lane when the update is a digest / docker tag /
# action bump, because those hide arbitrary upstream change behind that one line.

load helpers/setup

SCRIPT="${REPO_ROOT}/scripts/renovate-gate-classify.sh"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  # gh stub: prints whatever payload the test placed in $GH_STUB_PAYLOAD, or
  # exits non-zero when the test asked for a failed fetch.
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${GH_STUB_FAIL:-}" = "1" ]; then
  exit 1
fi
if [ "$2" = "diff" ]; then
  if [ "${GH_STUB_DIFF_FAIL:-}" = "1" ]; then
    exit 1
  fi
  cat "${GH_STUB_DIFF}"
  exit 0
fi
cat "${GH_STUB_PAYLOAD}"
EOF
  chmod +x "${STUB_DIR}/gh"
  GH_STUB_PAYLOAD="${BATS_TEST_TMPDIR}/payload.json"
  GH_STUB_DIFF="${BATS_TEST_TMPDIR}/diff.txt"
  # Default diff: an ordinary patch bump, so tests that are not about version
  # comparison keep exercising the branch they mean to.
  make_diff "2.98.0" "2.99.0"
}

# Build a version-pin diff. $1=old version, $2=new version.
make_diff() {
  cat >"$GH_STUB_DIFF" <<EOF
diff --git a/f0 b/f0
--- a/f0
+++ b/f0
@@ -1 +1 @@
-tool = "$1"
+tool = "$2"
EOF
}

# Build a gh pr view payload. $1=title, $2=additions, $3=deletions, $4=file count,
# $5=mergeable, $6=labels (space separated), $7=author.
make_payload() {
  local title="$1" add="${2:-1}" del="${3:-1}" files="${4:-1}"
  local mergeable="${5:-MERGEABLE}" labels="${6:-}" author="${7:-app/renovate}"
  local file_json='' i
  for ((i = 0; i < files; i++)); do
    [ -n "$file_json" ] && file_json+=','
    file_json+="{\"path\":\"f${i}\",\"additions\":${add},\"deletions\":${del}}"
  done
  local label_json='' l
  for l in $labels; do
    [ -n "$label_json" ] && label_json+=','
    label_json+="{\"name\":\"${l}\"}"
  done
  cat >"$GH_STUB_PAYLOAD" <<EOF
{"author":{"login":"${author}"},"title":"${title}",
 "mergeable":"${mergeable}","files":[${file_json}],"labels":[${label_json}]}
EOF
}

run_classify() {
  run env PATH="${STUB_DIR}:${PATH}" GH_STUB_PAYLOAD="$GH_STUB_PAYLOAD" \
    GH_STUB_DIFF="$GH_STUB_DIFF" GH_STUB_FAIL="${GH_STUB_FAIL:-0}" \
    GH_STUB_DIFF_FAIL="${GH_STUB_DIFF_FAIL:-0}" GITHUB_REPOSITORY="owner/repo" \
    bash "$SCRIPT" "${1:-101}"
}

# Assert the verdict field (first tab-separated column) of the single output line.
assert_verdict() {
  [ "$status" -eq 0 ]
  local got="${output%%$'\t'*}"
  [ "$got" = "$1" ] || {
    echo "expected verdict '$1', got '$got' (full: $output)"
    false
  }
}

@test "classifier exists, is executable, and passes bash -n" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
  bash -n "$SCRIPT"
}

@test "rejects wrong argument count" {
  run env GITHUB_REPOSITORY="owner/repo" bash "$SCRIPT"
  [ "$status" -eq 64 ]
}

@test "rejects a non-numeric PR number" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  run_classify abc
  [ "$status" -eq 64 ]
}

@test "passes a three-part semver version pin with a +1/-1 single-file diff" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  run_classify
  assert_verdict pass
}

@test "passes a scoped npm dependency pin" {
  make_payload "chore(deps): update dependency npm:agent-browser to v0.36.1"
  make_diff "0.36.0" "0.36.1"
  run_classify
  assert_verdict pass
}

# --- the negative assertions this gate exists for -------------------------------

@test "a git-refs digest bump is needs-agent even with a one-line diff" {
  make_payload "chore(deps): update anthropics/skills digest to 5304866"
  run_classify
  assert_verdict needs-agent
}

@test "a docker digest bump is needs-agent even with a one-line diff" {
  make_payload "chore(deps): update nginx:1.31-alpine docker digest to a9ae6f6"
  run_classify
  assert_verdict needs-agent
}

@test "a docker tag bump is needs-agent even with a one-line diff" {
  make_payload "chore(deps): update binwiederhier/ntfy docker tag to v2.28.0"
  run_classify
  assert_verdict needs-agent
}

@test "a GitHub Actions bump is needs-agent even with a one-line diff" {
  make_payload "chore(deps): update anthropics/claude-code-action action to v1.0.214"
  run_classify
  assert_verdict needs-agent
}

@test "a pin action bump is needs-agent" {
  make_payload "chore(deps): pin anthropics/claude-code-action action to v1.0.183"
  run_classify
  assert_verdict needs-agent
}

@test "a bare-major bump is needs-agent (no three-part semver)" {
  make_payload "chore(deps): update dependency java to v25"
  run_classify
  assert_verdict needs-agent
}

@test "a monorepo group bump is needs-agent" {
  make_payload "chore(deps): update deno monorepo to v2.8.3"
  run_classify
  assert_verdict needs-agent
}

@test "a phone-harness version pin is needs-agent despite the ordinary shape" {
  # Ships executable Python that drives a real, unlocked phone. Its title is
  # indistinguishable from a `gh` bump, so shape alone must not clear it.
  make_payload "chore(deps): update dependency phone-harness to v1.2.3"
  run_classify
  assert_verdict needs-agent
}

@test "an ECC version pin is needs-agent despite the ordinary shape" {
  # Third-party hook code that runs in every agent session.
  make_payload "chore(deps): update dependency affaan-m/ecc to v2.2.0"
  run_classify
  assert_verdict needs-agent
}

@test "the always-review list matches whole names, not substrings" {
  # A dependency whose name merely contains one of the entries must still pass.
  make_payload "chore(deps): update dependency phone-harness-viewer to v1.2.3"
  make_diff "1.2.2" "1.2.3"
  run_classify
  assert_verdict pass
}

# --- version comparison ---------------------------------------------------------

@test "a major bump is needs-agent even though the title shape matches" {
  # The title carries only the new version, so shape alone cannot tell v2.99.0
  # from v3.0.0. The old version comes from the diff.
  make_payload "chore(deps): update dependency somelib to v3.0.0"
  make_diff "2.9.0" "3.0.0"
  run_classify
  assert_verdict needs-agent
  [[ "$output" == *"メジャー更新"* ]]
}

@test "a patch bump within the same major passes" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  make_diff "2.98.0" "2.99.0"
  run_classify
  assert_verdict pass
}

@test "a minor bump within the same major passes" {
  make_payload "chore(deps): update dependency yazi to v26.9.1"
  make_diff "26.8.15" "26.9.1"
  run_classify
  assert_verdict pass
}

@test "a 0.x minor bump is needs-agent (semver lets it break)" {
  make_payload "chore(deps): update dependency npm:agent-browser to v0.36.0"
  make_diff "0.35.2" "0.36.0"
  run_classify
  assert_verdict needs-agent
  [[ "$output" == *"0.x"* ]]
}

@test "a 0.x patch bump passes" {
  make_payload "chore(deps): update dependency npm:agent-browser to v0.35.2"
  make_diff "0.35.1" "0.35.2"
  run_classify
  assert_verdict pass
}

@test "an unreadable old version is needs-agent, never pass" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  printf 'diff --git a/f b/f\n@@ -1 +1 @@\n+tool = "2.99.0"\n' >"$GH_STUB_DIFF"
  run_classify
  assert_verdict needs-agent
}

@test "a failed diff fetch is needs-agent, never pass" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  GH_STUB_DIFF_FAIL=1
  run_classify
  assert_verdict needs-agent
}

# --- narrowing checks -----------------------------------------------------------

@test "a multi-file change is needs-agent even when the totals stay +1/-1" {
  # Two files whose additions/deletions sum to exactly +1/-1, so the line-count
  # condition cannot be what rejects this. If the file_count check were removed,
  # this case would reach `pass`.
  cat >"$GH_STUB_PAYLOAD" <<'EOF'
{"author":{"login":"app/renovate"},"title":"chore(deps): update dependency gh to v2.99.0",
 "mergeable":"MERGEABLE",
 "files":[{"path":"a","additions":1,"deletions":0},{"path":"b","additions":0,"deletions":1}],
 "labels":[]}
EOF
  run_classify
  assert_verdict needs-agent
  [[ "$output" == *"1 つではない"* ]] || {
    echo "rejected for the wrong reason: $output"
    false
  }
}

@test "a diff larger than +1/-1 is needs-agent" {
  make_payload "chore(deps): update dependency gh to v2.99.0" 4 2 1
  run_classify
  assert_verdict needs-agent
}

@test "a CONFLICTING branch is needs-agent" {
  make_payload "chore(deps): update dependency gh to v2.99.0" 1 1 1 CONFLICTING
  run_classify
  assert_verdict needs-agent
}

@test "an UNKNOWN mergeable is not treated as a conflict" {
  make_payload "chore(deps): update dependency gh to v2.99.0" 1 1 1 UNKNOWN
  run_classify
  assert_verdict pass
}

@test "a [SECURITY] title is needs-agent" {
  make_payload "chore(deps): [SECURITY] update dependency gh to v2.99.0"
  run_classify
  assert_verdict needs-agent
}

@test "a lowercase [security] title is needs-agent" {
  make_payload "chore(deps): [security] update dependency gh to v2.99.0"
  run_classify
  assert_verdict needs-agent
}

@test "a security label is needs-agent" {
  make_payload "chore(deps): update dependency gh to v2.99.0" 1 1 1 MERGEABLE security
  run_classify
  assert_verdict needs-agent
}

@test "a non-Renovate author is needs-agent, never pass" {
  make_payload "chore(deps): update dependency gh to v2.99.0" 1 1 1 MERGEABLE "" someone
  run_classify
  assert_verdict needs-agent
}

# --- unclassifiable input always falls to the agent, never to pass --------------

@test "a failed gh fetch is needs-agent" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  GH_STUB_FAIL=1
  run_classify
  assert_verdict needs-agent
}

@test "an unparsable payload is needs-agent" {
  printf 'not json' >"$GH_STUB_PAYLOAD"
  run_classify
  assert_verdict needs-agent
}

@test "an empty payload is needs-agent" {
  : >"$GH_STUB_PAYLOAD"
  run_classify
  assert_verdict needs-agent
}

@test "emits exactly one line" {
  make_payload "chore(deps): update dependency gh to v2.99.0"
  run_classify
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
}
