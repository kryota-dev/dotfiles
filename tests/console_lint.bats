#!/usr/bin/env bats

load helpers/setup

# `make lint-console` is the machine guard that replaced the stop:check-console-log hook
# retired in #520 (#522). These tests drive the target instead of asserting on its text: a
# guard that still exists but no longer detects anything passes every textual assertion, and
# that silent no-op is the exact failure mode this issue was filed about.
#
# The target's CONSOLE_LINT_ROOTS variable exists so the scan can be pointed at a fixture
# tree, which is the only way to assert the failing cases without planting a violation in the
# repo itself.
#
# Nothing here skips when deno is missing. `make lint-console` is fatal without it (a guard
# that opts itself out when its tool is absent is how #522 happened), and the clean-fixture
# case below asserts exit 0, which cannot pass unless the linter actually ran.

setup() {
  FIXTURE="${BATS_TEST_TMPDIR}/fixture"
  mkdir -p "${FIXTURE}"
}

lint_console() {
  run make -C "${REPO_ROOT}" lint-console CONSOLE_LINT_ROOTS="${FIXTURE}"
}

@test "lint-console: a bare console.log fails the check" {
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function debugMe(value) {
  console.log(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-console"* ]]
}

@test "lint-console: console.error and console.warn fail too (console.*, not console.log alone)" {
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function warnMe(value) {
  console.warn(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]

  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function errorMe(value) {
  console.error(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]
}

@test "lint-console: a line-level ignore with a reason passes" {
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function banner(text) {
  // deno-lint-ignore no-console -- user-facing CLI output, not a debug leftover
  console.log(text);
}
EOF
  lint_console
  [ "$status" -eq 0 ]
}

@test "lint-console: the ignore is line-scoped, so a second call in the same file still fails" {
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function banner(text, value) {
  // deno-lint-ignore no-console -- user-facing CLI output, not a debug leftover
  console.log(text);
  console.log(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]
}

@test "lint-console: process.stdout.write is the intentional-output escape hatch and passes" {
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function emit(line) {
  process.stdout.write(`${line}\n`);
}
EOF
  lint_console
  [ "$status" -eq 0 ]
}

@test "lint-console: console.log inside a string literal passes (AST-based, not grep)" {
  # tests/agent_improvement.test.mjs plants executable source as a string; a grep-based
  # checker would report that as a violation.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export const PLANTED_SOURCE = "console.log('planted');\n";
// A comment mentioning console.log(...) must not trip the check either.
EOF
  lint_console
  [ "$status" -eq 0 ]
}

@test "lint-console: TypeScript sources are checked too" {
  cat >"${FIXTURE}/a.ts" <<'EOF'
export function debugMe(value: unknown): void {
  console.log(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-console"* ]]
}

@test "lint-console: plain .js is checked (the depth-1 lint-node glob misses these)" {
  mkdir -p "${FIXTURE}/hooks-fork"
  cat >"${FIXTURE}/hooks-fork/hook.js" <<'EOF'
console.log("debug");
EOF
  lint_console
  [ "$status" -ne 0 ]
}

@test "lint-console: nested directories at any depth are checked" {
  mkdir -p "${FIXTURE}/one/two/three"
  cat >"${FIXTURE}/one/two/three/deep.mjs" <<'EOF'
console.log("deep");
EOF
  lint_console
  [ "$status" -ne 0 ]
}

@test "lint-console: an empty tree fails rather than silently passing" {
  # A glob that matches nothing must not read as "no violations found" -- that is the
  # silent no-op this whole guard exists to prevent.
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"no JS/TS sources"* ]]
}

@test "lint-console: the repository itself passes the check" {
  # The guard is only safe to enable while the tree is already clean: enabling it with
  # violations in place would fail every open PR, not just the one that added them (#522).
  run make -C "${REPO_ROOT}" lint-console
  [ "$status" -eq 0 ]
}

@test "lint-console: is wired into make test so CI and local runs agree" {
  grep -qE '^test:.*\blint-console\b' "${REPO_ROOT}/Makefile"
}

@test "lint-console: CI runs the target and resolves deno from the mise pin, not a literal" {
  local ci="${REPO_ROOT}/.github/workflows/ci.yml"
  local mise="${HOME_DIR}/dot_config/mise/config.toml"
  local version
  version="$(sed -n 's/^deno = "\(.*\)"$/\1/p' "$mise")"
  [ -n "$version" ] || {
    echo "no deno pin in ${mise}"
    false
  }

  grep -qF 'make lint-console' "$ci" || {
    echo "ci.yml never runs make lint-console"
    false
  }

  # Same discipline as shellcheck/shfmt (#475): the pin is the only place the number lives.
  run grep -nF "$version" "$ci"
  [ "$status" -ne 0 ] || {
    echo "ci.yml hardcodes the deno version ${version}: ${output}"
    false
  }

  # Both jobs need deno: the lint job runs the target, and the test job runs this bats file,
  # which drives the target directly. A file-wide assertion would pass with both installs in
  # one job while the other silently lacks it.
  local job block
  for job in lint test; do
    block="$(awk -v j="  ${job}:" '$0 == j { on = 1; next } /^  [a-z]/ { on = 0 } on' "$ci")"
    [ -n "$block" ] || {
      echo "could not slice the ${job} job out of ${ci}"
      false
    }
    grep -qF 'deno = ' <<<"$block" || {
      echo "the ${job} job does not read the deno version from the mise pin"
      false
    }
    grep -qF 'denoland/deno/releases/download/v${VERSION}' <<<"$block" || {
      echo "the ${job} job does not install the pinned deno"
      false
    }
    grep -qF 'deno --version' <<<"$block" || {
      echo "the ${job} job does not assert the installed deno matches the pin"
      false
    }
  done
}
