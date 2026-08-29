#!/usr/bin/env bats

load helpers/setup

# `make lint-console` is the machine guard that replaced the stop:check-console-log hook
# retired in #520 (#522). These tests drive the target instead of asserting on its text: a
# guard that still exists but no longer detects anything passes every textual assertion, and
# that silent no-op is the exact failure mode this issue was filed about.
#
# The target's CONSOLE_LINT_ROOTS variable exists so the scan can be pointed at a fixture
# tree, which is the only way to assert the failing cases without planting a violation in the
# repo itself. The default-roots case is covered separately, against a throwaway copy of the
# Makefile, because a fixture-only suite cannot notice a root dropping out of the default.
#
# Nothing here skips when deno is missing. `make lint-console` is fatal without it (a guard
# that opts itself out when its tool is absent is how #522 happened), and the clean-fixture
# cases below assert exit 0, which cannot pass unless the linter actually ran.

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
  [[ "$output" == *"no-console"* ]]

  cat >"${FIXTURE}/a.mjs" <<'EOF'
export function errorMe(value) {
  console.error(value);
}
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-console"* ]]
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

@test "lint-console: an exemption that outlives its console call is reported (ban-unused-ignore)" {
  # deno evaluates ignore directives of *enabled* rules, so a stale exemption fails here even
  # though only no-console is switched on. This is what keeps opt-outs from accumulating.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
// deno-lint-ignore no-console -- the call this excused was removed
export const value = 1;
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"ban-unused-ignore"* ]]
}

@test "lint-console: a whole-file opt-out naming no-console is rejected" {
  # deno honours `// deno-lint-ignore-file no-console` and would silently exempt every call
  # in the file, so the target rejects the directive before linting. Without this the guard
  # has a hole wide enough to drive any file through.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
// deno-lint-ignore-file no-console -- whole-file opt-out
console.log("hidden 1");
console.log("hidden 2");
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"file-level opt-out is not allowed"* ]]
}

@test "lint-console: a bare whole-file opt-out is rejected too" {
  # A directive with no rule list disables every rule, no-console included.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
// deno-lint-ignore-file
console.log("hidden");
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"file-level opt-out is not allowed"* ]]
}

@test "lint-console: a whole-file opt-out for an unrelated rule is left alone" {
  # Rejecting every file-level directive would be over-broad: one that names only other rules
  # does not weaken this guard. The fixture carries a console call on purpose -- without one,
  # an implementation that wrongly skipped the whole file would pass this test too.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
// deno-lint-ignore-file no-explicit-any -- unrelated to this guard
console.log("must still be reported");
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-console"* ]]
  [[ "$output" != *"file-level opt-out is not allowed"* ]]
}

@test "lint-console: a path containing a colon cannot smuggle a whole-file opt-out past the check" {
  # The first cut re-parsed `grep -H` output as <path>:<line>:<text>. A path holding
  # `:<digits>:` makes that strip match in the wrong place, and a bare directive then slips
  # through and exempts every call in the file (reproduced: exit 0 on this exact fixture).
  cat >"${FIXTURE}/weird:9:evil.mjs" <<'EOF'
// deno-lint-ignore-file
console.log("hidden 1");
console.log("hidden 2");
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"file-level opt-out is not allowed"* ]]
}

@test "lint-console: the opt-out check errs toward false positives, never a silent hole" {
  # deno keeps a file-level directive live through blank lines, `//` and `/* */` comments and
  # a shebang, and only the first statement ends that region -- so scanning just the region
  # risks missing a real bypass. Scanning whole files instead costs this: the directive's
  # exact text at the start of a line inside a template literal is rejected even though deno
  # reads it as a string. Pinned as the deliberate trade it is, not left as an accident.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
export const SAMPLE = `
// deno-lint-ignore-file
`;
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"file-level opt-out is not allowed"* ]]
}

@test "lint-console: the opt-out diagnostic reports file:line only, never the file's own text" {
  # The offending line is attacker-controlled text. Echoing it to stderr would let a file
  # smuggle terminal escapes into a developer's console or a CI log.
  cat >"${FIXTURE}/a.mjs" <<'EOF'
// deno-lint-ignore-file no-console -- SENTINELTEXT
console.log("x");
EOF
  lint_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"a.mjs:1"* ]]
  [[ "$output" != *"SENTINELTEXT"* ]]
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

@test "lint-console: every declared extension is actually scanned" {
  # The find expression lists eight extensions; assert each one individually so a name
  # dropping out of CONSOLE_LINT_NAMES cannot pass unnoticed.
  local ext
  for ext in mjs cjs js mts cts ts jsx tsx; do
    rm -f "${FIXTURE}"/probe.*
    printf 'console.log("debug");\n' >"${FIXTURE}/probe.${ext}"
    lint_console
    # Exit code alone is not enough: if an extension fell out of CONSOLE_LINT_NAMES the tree
    # would look empty, and the emptiness guard's non-zero exit would pass this test.
    [ "$status" -ne 0 ] && [[ "$output" == *"no-console"* ]] || {
      echo ".${ext} was not linted by no-console: ${output}"
      false
    }
  done
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

@test "lint-console: the default roots scan both home/ and tests/" {
  # Every other case overrides CONSOLE_LINT_ROOTS, so none of them would notice a root
  # falling out of the default. Drive the real recipe against a throwaway tree instead.
  local proj="${BATS_TEST_TMPDIR}/defaults"
  mkdir -p "${proj}/home" "${proj}/tests"
  cp "${REPO_ROOT}/Makefile" "${proj}/Makefile"
  printf 'export const ok = 1;\n' >"${proj}/home/clean.mjs"
  printf 'export const ok = 1;\n' >"${proj}/tests/clean.mjs"

  run make -C "${proj}" lint-console
  [ "$status" -eq 0 ] || {
    echo "the default roots do not lint cleanly on a clean tree: ${output}"
    false
  }

  printf 'console.log("planted");\n' >"${proj}/home/bad.mjs"
  run make -C "${proj}" lint-console
  [ "$status" -ne 0 ] || {
    echo "home/ is not covered by the default CONSOLE_LINT_ROOTS"
    false
  }
  rm -f "${proj}/home/bad.mjs"

  printf 'console.log("planted");\n' >"${proj}/tests/bad.mjs"
  run make -C "${proj}" lint-console
  [ "$status" -ne 0 ] || {
    echo "tests/ is not covered by the default CONSOLE_LINT_ROOTS"
    false
  }
}

@test "lint-console: a missing deno is fatal, not a skip" {
  # lint-deno opts itself out when deno is absent; this target must not, or the guard
  # silently disappears exactly the way the retired hook did (#522). Build a PATH holding
  # only what the recipe needs, rather than assuming a system dir happens to lack deno --
  # on a machine with deno in /usr/bin that assumption would make this pass for free.
  local bindir="${BATS_TEST_TMPDIR}/no-deno-bin"
  mkdir -p "$bindir"
  local tool resolved
  for tool in make find awk; do
    resolved="$(command -v "$tool")" || {
      echo "cannot build the probe PATH: ${tool} not found"
      false
    }
    ln -sf "$resolved" "${bindir}/${tool}"
  done

  # Prove the probe PATH really hides deno, so a pass cannot mean "the check never ran".
  # Deliberately not `run`: a 127 there is the expected result, and bats would warn about it.
  if env -i PATH="$bindir" sh -c 'command -v deno' >/dev/null 2>&1; then
    echo "the probe PATH still resolves deno; this test would prove nothing"
    false
  fi

  run env -i PATH="$bindir" make -C "${REPO_ROOT}" lint-console
  [ "$status" -ne 0 ]
  [[ "$output" == *"deno not found"* ]]
}

@test "lint-console: the repository itself passes the check" {
  # The guard is only safe to enable while the tree is already clean: enabling it with
  # violations in place would fail every open PR, not just the one that added them (#522).
  run make -C "${REPO_ROOT}" lint-console
  [ "$status" -eq 0 ]
}

@test "lint-console: the server.ts exemption does not break the existing lint-deno target" {
  # ban-unused-ignore is on by default, and a directive for a rule that default lint leaves
  # disabled must not read as unused there. Asserted rather than reasoned about, because the
  # two targets enable different rule sets.
  run make -C "${REPO_ROOT}" lint-deno
  [ "$status" -eq 0 ]
  [[ "$output" == *"deno check/lint/fmt"* ]] || {
    echo "lint-deno skipped instead of running; this assertion proves nothing"
    false
  }
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

  # Bind the target to the lint job specifically: a file-wide grep would still pass if the
  # step drifted into the test job, which the design does not intend.
  block="$(awk -v j="  lint:" '$0 == j { on = 1; next } /^  [a-z]/ { on = 0 } on' "$ci")"
  grep -qF 'make lint-console' <<<"$block" || {
    echo "the lint job does not run make lint-console"
    false
  }
}
