#!/usr/bin/env bats

load helpers/setup

# macOS mktemp(1) only consults TMPDIR when it is handed a template (or -t): a bare
# `mktemp -d` goes straight to the Darwin default /var/folders/.../T, which is outside the
# writable set of a sandboxed session. The whole suite then goes red with "mkdtemp failed
# ... Operation not permitted" for reasons that have nothing to do with the change under
# test, which is how #642 made the completion gate useless. _mktemp_dir (tests/helpers/
# setup.bash) always passes a template, so TMPDIR is honoured on both macOS and Linux.
#
# The scan is git grep rather than rg or the Grep tool on purpose: ripgrep-backed search
# silently skips gitignored paths and files containing raw NUL bytes, so it cannot back a
# "no occurrences anywhere" claim.
#
# Two paths are excluded because they necessarily spell the word out: setup.bash defines
# the helper, and this file states the policy.
@test "tests/ contains no bare mktemp -- scratch dirs go through _mktemp_dir (#642)" {
  local hits
  hits="$(git -C "$REPO_ROOT" grep -n mktemp -- \
    tests/ ':!tests/helpers/setup.bash' ':!tests/tmpdir_policy.bats' || true)"

  # git grep -n prints "path:lineno:content". Anchor the '#' to the start of the *content*
  # so only genuine comment lines are dropped -- counting comment lines as call sites is
  # exactly what made #642 report 34 occurrences where there were 31. Call sites are then
  # dropped by the helper's name (which contains the search word) rather than by a generic
  # mktemp filter, so a line carrying both a helper call and a bare call still reports.
  local violations
  violations="$(printf '%s\n' "$hits" | awk '
    {
      content = $0
      sub(/^[^:]+:[0-9]+:/, "", content)
      if (content ~ /^[[:space:]]*#/) next
      gsub(/_mktemp_dir/, "", content)
      if (content ~ /mktemp/) print
    }
  ')"

  if [ -n "$violations" ]; then
    printf 'bare mktemp in tests/; use _mktemp_dir from tests/helpers/setup.bash (#642):\n%s\n' \
      "$violations" >&2
    return 1
  fi
}
