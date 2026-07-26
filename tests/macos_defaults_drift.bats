#!/usr/bin/env bats

# macos-defaults-drift-check wrapper (home/dot_claude/executable_macos-defaults-drift-check.sh, #365).
# The wrapper is source-safe (side effects live in main() behind a BASH_SOURCE
# guard), so pure-parsing functions (parse_ssot/is_excluded/build_candidate)
# are sourced and exercised on any OS, while functions that shell out to the
# real `defaults` binary (build_expected/read_value/main()) are Darwin-only
# and use a throwaway, uniquely-named test domain that is deleted in
# teardown -- never a real macOS preference domain.

load helpers/setup

WRAPPER="${HOME_DIR}/dot_claude/executable_macos-defaults-drift-check.sh"
TEST_DOMAIN="com.kryota.dotfiles-bats-fixture-365"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  cat >"${STUB_DIR}/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${NTFY_TEST_STUB_DIR}/curl_args"
cat >"${NTFY_TEST_STUB_DIR}/curl_stdin"
exit "${NTFY_TEST_CURL_EXIT:-0}"
EOF
  chmod +x "${STUB_DIR}/curl"

  ENV_FILE="${BATS_TEST_TMPDIR}/notify-env"
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
NTFY_TOPIC_ATTENTION='claude-attention'
EOF
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/drift.log"

  # Fixture repo checkout: a minimal SSOT + .chezmoidata.toml, independent of
  # this repo's real run_onchange_after_20-macos-defaults.sh.tmpl content so
  # these tests don't churn every time that script's managed set changes.
  FIXTURE_REPO="${BATS_TEST_TMPDIR}/fixture-repo"
  mkdir -p "${FIXTURE_REPO}/home"
  cat >"${FIXTURE_REPO}/home/run_onchange_after_20-macos-defaults.sh.tmpl" <<EOF
{{ if eq .chezmoi.os "darwin" -}}
#!/bin/bash
set -euo pipefail
defaults write ${TEST_DOMAIN} TestBool -bool true
defaults write ${TEST_DOMAIN} TestInt -int 42
defaults write ${TEST_DOMAIN} TestFloat -float 0.5
defaults write ${TEST_DOMAIN} TestString -string "Hello World"
defaults write ${TEST_DOMAIN} TestArray -array 1 2 3
defaults write ${TEST_DOMAIN} TestNoisy -bool true
{{ end -}}
EOF
  cat >"${FIXTURE_REPO}/home/.chezmoidata.toml" <<EOF
[macos_defaults_drift]
  exclude_keys = [
    "${TEST_DOMAIN}:TestNoisy",
  ]
EOF
}

teardown() {
  if [ "$(uname)" = "Darwin" ]; then
    defaults delete "$TEST_DOMAIN" >/dev/null 2>&1 || true
  fi
}

# Source the wrapper (main() is guarded, so nothing runs) and call one of its
# functions with the fixture repo/env, mirroring tests/morning_radar.bats.
run_fn() {
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    NTFY_TEST_CURL_EXIT="${NTFY_TEST_CURL_EXIT:-0}" \
    MACOS_DEFAULTS_DRIFT_REPO_DIR="$FIXTURE_REPO" \
    MACOS_DEFAULTS_DRIFT_NTFY_ENV_FILE="$ENV_FILE" \
    MACOS_DEFAULTS_DRIFT_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; shift; fn="$1"; shift; "$fn" "$@"' _ "$WRAPPER" "$@"
}

@test "macos-defaults-drift-check.sh exists and passes bash -n" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "token hygiene: no -H/--header Authorization, no set -x, token via -K" {
  ! grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  ! grep -qF 'set -x' "$WRAPPER"
  grep -qF 'curl -fs -K' "$WRAPPER"
}

@test "never writes back to the repo or touches git (#365 hard constraint)" {
  ! grep -qE '(^|[^a-zA-Z_])git (add|commit|push)([^a-zA-Z_]|$)' "$WRAPPER"
  ! grep -qE '>[[:space:]]*"\$SSOT"' "$WRAPPER"
}

@test "parse_ssot extracts domain/key/type/value for bool/int/float/string/array" {
  run_fn parse_ssot
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "$(printf '%s\tTestBool\tbool\ttrue' "$TEST_DOMAIN")"
  printf '%s\n' "$output" | grep -qF "$(printf '%s\tTestInt\tint\t42' "$TEST_DOMAIN")"
  printf '%s\n' "$output" | grep -qF "$(printf '%s\tTestFloat\tfloat\t0.5' "$TEST_DOMAIN")"
  # Quoted, multi-word string value round-trips with its quotes stripped.
  printf '%s\n' "$output" | grep -qF "$(printf '%s\tTestString\tstring\tHello World' "$TEST_DOMAIN")"
  # Array keeps its space-separated tokens raw (build_expected word-splits them).
  printf '%s\n' "$output" | grep -qF "$(printf '%s\tTestArray\tarray\t1 2 3' "$TEST_DOMAIN")"
}

@test "is_excluded matches domain:key entries from .chezmoidata.toml" {
  run_fn is_excluded "$TEST_DOMAIN" "TestNoisy"
  [ "$status" -eq 0 ]
  run_fn is_excluded "$TEST_DOMAIN" "TestBool"
  [ "$status" -ne 0 ]
}

@test "is_excluded is fail-open (not excluded) when .chezmoidata.toml is missing" {
  rm -f "${FIXTURE_REPO}/home/.chezmoidata.toml"
  run_fn is_excluded "$TEST_DOMAIN" "TestNoisy"
  [ "$status" -ne 0 ]
}

@test "build_candidate reconstructs a defaults write line per type" {
  run_fn build_candidate "$TEST_DOMAIN" "TestBool" "bool" "0"
  [ "$output" = "defaults write ${TEST_DOMAIN} TestBool -bool false" ]

  run_fn build_candidate "$TEST_DOMAIN" "TestInt" "int" "7"
  [ "$output" = "defaults write ${TEST_DOMAIN} TestInt -int 7" ]

  run_fn build_candidate "$TEST_DOMAIN" "TestString" "string" "changed"
  [ "$output" = "defaults write ${TEST_DOMAIN} TestString -string changed" ]
}

@test "build_candidate does not auto-regenerate array types (documented limitation)" {
  run_fn build_candidate "$TEST_DOMAIN" "TestArray" "array" "1 2 9"
  [[ "$output" == "# ${TEST_DOMAIN} TestArray is array-typed"* ]]
  [[ "$output" == *"defaults read ${TEST_DOMAIN} TestArray" ]]
}

@test "ntfy_publish sends to topic_attention with the drift count and body (token via -K, never logged)" {
  [ "$(uname)" = "Darwin" ] || skip "ntfy_publish's stat -f is BSD-only"
  run_fn ntfy_publish 2 "domain key: expected [1] actual [0]"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "4" ]
  jq -e '.title | test("2")' <"${STUB_DIR}/curl_stdin" >/dev/null
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "domain key: expected [1] actual [0]" ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -qE -- '-K' "${STUB_DIR}/curl_args"
}

@test "ntfy_publish is fail-open: no env file -> silent no-op" {
  MACOS_DEFAULTS_DRIFT_NTFY_ENV_FILE_ORIG="$ENV_FILE"
  ENV_FILE="${BATS_TEST_TMPDIR}/does-not-exist"
  run_fn ntfy_publish 1 "drift body"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_args" ]
}

@test "ntfy_publish is fail-open: curl failure returns 0, token never logged" {
  [ "$(uname)" = "Darwin" ] || skip "ntfy_publish's stat -f is BSD-only"
  NTFY_TEST_CURL_EXIT=1
  run_fn ntfy_publish 1 "drift body"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG_FILE" ] || ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

# --- build_expected / read_value / main() integration (Darwin only: these
# shell out to the real `defaults` binary against the throwaway TEST_DOMAIN) --

@test "build_expected + read_value round-trip matches for bool/int/float/string/array" {
  [ "$(uname)" = "Darwin" ] || skip "defaults(1) is macOS-only"
  # Seed the real (throwaway) domain to exactly match the fixture SSOT.
  defaults write "$TEST_DOMAIN" TestBool -bool true
  defaults write "$TEST_DOMAIN" TestInt -int 42
  defaults write "$TEST_DOMAIN" TestFloat -float 0.5
  defaults write "$TEST_DOMAIN" TestString -string "Hello World"
  defaults write "$TEST_DOMAIN" TestArray -array 1 2 3
  defaults write "$TEST_DOMAIN" TestNoisy -bool true

  run env MACOS_DEFAULTS_DRIFT_REPO_DIR="$FIXTURE_REPO" bash -c '
    source "$1"
    tmp_dir="$(mktemp -d)"
    trap "rm -rf \"$tmp_dir\"" EXIT
    build_expected "$tmp_dir"
    while IFS=$'"'"'\t'"'"' read -r domain key type value; do
      expected="$(read_value "$tmp_dir/$domain" "$key")"
      actual="$(read_value "$domain" "$key")"
      if [ "$expected" != "$actual" ]; then
        echo "MISMATCH: $domain $key expected=[$expected] actual=[$actual]"
        exit 1
      fi
    done < <(parse_ssot)
    echo "all matched"
  ' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$output" = "all matched" ]
}

@test "read_value returns (unset) for a key that does not exist" {
  [ "$(uname)" = "Darwin" ] || skip "defaults(1) is macOS-only"
  defaults delete "$TEST_DOMAIN" NoSuchKey >/dev/null 2>&1 || true
  run_fn read_value "$TEST_DOMAIN" "NoSuchKey"
  [ "$status" -eq 0 ]
  [ "$output" = "(unset)" ]
}

@test "main(): no drift when the real domain matches the SSOT -> no ntfy publish" {
  [ "$(uname)" = "Darwin" ] || skip "macos-defaults-drift-check main() is Darwin-only"
  defaults write "$TEST_DOMAIN" TestBool -bool true
  defaults write "$TEST_DOMAIN" TestInt -int 42
  defaults write "$TEST_DOMAIN" TestFloat -float 0.5
  defaults write "$TEST_DOMAIN" TestString -string "Hello World"
  defaults write "$TEST_DOMAIN" TestArray -array 1 2 3
  defaults write "$TEST_DOMAIN" TestNoisy -bool true

  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    MACOS_DEFAULTS_DRIFT_REPO_DIR="$FIXTURE_REPO" \
    MACOS_DEFAULTS_DRIFT_NTFY_ENV_FILE="$ENV_FILE" \
    MACOS_DEFAULTS_DRIFT_LOG_FILE="$LOG_FILE" \
    bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_stdin" ]
  grep -qF "no drift detected" "$LOG_FILE"
}

@test "main(): drift on a non-excluded key publishes a candidate; excluded key drift is silent" {
  [ "$(uname)" = "Darwin" ] || skip "macos-defaults-drift-check main() is Darwin-only"
  defaults write "$TEST_DOMAIN" TestBool -bool true
  # Drifted: SSOT says 42.
  defaults write "$TEST_DOMAIN" TestInt -int 99
  defaults write "$TEST_DOMAIN" TestFloat -float 0.5
  defaults write "$TEST_DOMAIN" TestString -string "Hello World"
  defaults write "$TEST_DOMAIN" TestArray -array 1 2 3
  # Also drifted, but excluded -- must not appear in the notification.
  defaults write "$TEST_DOMAIN" TestNoisy -bool false

  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    MACOS_DEFAULTS_DRIFT_REPO_DIR="$FIXTURE_REPO" \
    MACOS_DEFAULTS_DRIFT_NTFY_ENV_FILE="$ENV_FILE" \
    MACOS_DEFAULTS_DRIFT_LOG_FILE="$LOG_FILE" \
    bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  jq -e '.title | test("1")' <"${STUB_DIR}/curl_stdin" >/dev/null
  jq -r .message <"${STUB_DIR}/curl_stdin" | grep -qF "TestInt"
  jq -r .message <"${STUB_DIR}/curl_stdin" | grep -qF "defaults write ${TEST_DOMAIN} TestInt -int 99"
  ! (jq -r .message <"${STUB_DIR}/curl_stdin" | grep -qF "TestNoisy")
}
