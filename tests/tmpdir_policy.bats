#!/usr/bin/env bats

load helpers/setup

# Why macOS mktemp needs an explicit template is documented once, on _mktemp_dir in
# tests/helpers/setup.bash. Both guards below enforce that rule; neither restates the mechanism.
#
# The scan is git grep rather than rg or the Grep tool on purpose: ripgrep-backed search
# silently skips gitignored paths and files containing raw NUL bytes, so it cannot back a
# "no occurrences anywhere" claim.

# Report every TMPDIR-ignoring mktemp call among the "path:lineno:content" lines on stdin.
#
# Extracted so the fixture test below can drive it directly: a scan that only ever runs against a
# clean tree proves the tree is clean, not that the predicate would catch anything. Both of the
# bugs this predicate had when first written (-td slipping through, -p's value being read as the
# template) were invisible to the scan and caught by the fixture.
_tmpdir_policy_violations() {
  awk '
    function bad(call,   n, tok, i, t) {
      n = split(call, tok, /[[:space:]]+/)
      for (i = 2; i <= n; i++) {
        t = tok[i]
        # -t, and any short-flag cluster carrying it (-dt, -td), builds its template from
        # _CS_DARWIN_USER_TEMP_DIR and never reaches TMPDIR.
        if (t ~ /^-[[:alpha:]]*t[[:alpha:]]*$/) return 1
        # -p DIR and --tmpdir DIR take a value. Skipping it keeps the value from being read as
        # the template, so `mktemp -p "$TMPDIR" x.XXXXXX` is accepted rather than reported.
        if (t == "-p" || t == "--tmpdir") { i++; continue }
        if (t ~ /^-/) continue
        # First non-flag token is the positional template.
        return (t ~ /XXXXXX/) ? 0 : 1
      }
      # No argument at all -- mktemp(1) documents this as equivalent to -t tmp.
      return 1
    }
    {
      content = $0
      sub(/^[^:]+:[0-9]+:/, "", content)
      if (content ~ /^[[:space:]]*#/) next
      start = 1
      while ((i = index(substr(content, start), "mktemp")) > 0) {
        abs = start + i - 1
        before = (abs > 1) ? substr(content, abs - 1, 1) : " "
        after = substr(content, abs + 6, 1)
        start = abs + 6
        # Word boundary, so mktempfile and _mktemp_dir are not read as calls to mktemp.
        if (before ~ /[[:alnum:]_]/ || after ~ /[[:alnum:]_]/) continue
        if (bad(substr(content, abs))) { print; break }
      }
    }
  '
}

# Two paths are excluded because they necessarily spell the word out: setup.bash defines
# the helper, and this file states the policy.
@test "tests/ contains no bare mktemp -- scratch dirs go through _mktemp_dir (#642)" {
  # git grep exits 1 for "no match" and >1 for a real failure (128 when $REPO_ROOT is not a
  # repository). Collapsing both to 0 with `|| true` would let a scan that never ran report a
  # clean tree -- the same silently-green failure this guard exists to prevent -- so the two
  # are kept apart and only exit 1 is treated as "no violations".
  local hits status=0
  hits="$(git -C "$REPO_ROOT" grep -n mktemp -- \
    tests/ ':!tests/helpers/setup.bash' ':!tests/tmpdir_policy.bats')" || status=$?
  if [ "$status" -gt 1 ]; then
    printf 'git grep failed (exit %s); the bare-mktemp policy was not verified\n' "$status" >&2
    return 1
  fi

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

  # The remedy differs by what the caller needs, so name both: _mktemp_dir only makes
  # directories, and pointing a file-scratch case at it would send the next contributor down
  # a dead end.
  if [ -n "$violations" ]; then
    printf 'bare mktemp in tests/ (#642). Scratch directory: use _mktemp_dir from
tests/helpers/setup.bash. Scratch file: pass an explicit template, e.g.
mktemp "${TMPDIR:-/tmp}/<name>.XXXXXX" -- macOS honours TMPDIR only when given one.
%s\n' "$violations" >&2
    return 1
  fi
}

# The same defect reaches home/, where it is not a false red but a shipped one: the chezmoi
# lifecycle scripts and the skill bodies that agents execute verbatim both run inside sandboxed
# sessions (#648). They cannot share _mktemp_dir -- chezmoi deploys each of these files to its own
# destination and none of them can source a bats helper -- so this guard enforces the underlying
# rule instead of the helper: every call carries an explicit positional template.
#
# The scanned set is "what a sandboxed session executes": chezmoi lifecycle scripts and curated
# skill bodies. Keeping it to those three prefixes means the scan needs no exclusion pathspec, so
# there is no exclusion list here to rot into a silently narrower check. home/dot_claude/ (launchd)
# and home/dot_config/zsh/ (interactive shells) are deliberately outside: neither runs under the
# sandbox, which is why #648 left the bare mktemp in claude.zsh alone.
#
# Scope notes -- what this deliberately does NOT check:
#   - A hardcoded /tmp path written without mktemp. Same defect, different spelling.
#   - Which directory the template names. `mktemp "/tmp/x.XXXXXX"` passes. That is not an
#     oversight to tighten: run_onchange_after_14-enable-clv2-observer.sh.tmpl legitimately
#     templates against its destination directory so the rename that follows stays atomic, so
#     "the template must mention TMPDIR" would be wrong. What is enforceable here is that the
#     caller names a directory at all rather than falling through to the Darwin default.
@test "home/ sandbox paths carry no TMPDIR-ignoring mktemp (#648)" {
  # Same exit-status discipline as the guard above: only exit 1 means "no violations".
  local hits status=0
  hits="$(git -C "$REPO_ROOT" grep -n mktemp -- \
    'home/run_onchange_*' 'home/run_once_*' 'home/dot_agents/skills/')" || status=$?
  if [ "$status" -gt 1 ]; then
    printf 'git grep failed (exit %s); the home/ mktemp policy was not verified\n' "$status" >&2
    return 1
  fi

  local violations
  violations="$(printf '%s\n' "$hits" | _tmpdir_policy_violations)"

  if [ -n "$violations" ]; then
    printf 'TMPDIR-ignoring mktemp under home/ (#648). Pass an explicit template, e.g.
mktemp "${TMPDIR:-/tmp}/<name>.XXXXXX" (add -d for a directory). Neither a bare call nor -t
reaches TMPDIR on macOS; see _mktemp_dir in tests/helpers/setup.bash for the mechanism.
%s\n' "$violations" >&2
    return 1
  fi
}

# Drives the predicate directly, because the scan above can only ever confirm that today's tree is
# clean. Markdown has no line-comment syntax, so prose that names mktemp without a template is
# reported (line 8 below) -- deliberately: a skill body reading "make a scratch repo with mktemp"
# is an instruction an agent executes, and that silent-deviation path is the layer-2 half of #648.
# To name the tool in prose, spell a compliant call.
#
# Known limitation, asserted rather than hidden: a call is read from its "mktemp" to the end of the
# line, so a trailing shell comment that names a non-compliant form is reported as if it were a
# second call. Put such a mention on its own comment line.
@test "the home/ mktemp predicate classifies flags and word boundaries correctly (#648)" {
  local violations
  violations="$(_tmpdir_policy_violations <<'FIXTURE'
f:1:# a full-line comment naming mktemp with no template
f:2:tmp=$(mktemp)
f:3:tmp=$(mktemp -d)
f:4:tmp=$(mktemp -t prefix)
f:5:tmp=$(mktemp -d -t prefix)
f:6:tmp=$(mktemp -td "${TMPDIR:-/tmp}/x.XXXXXX")
f:7:tmp=$(mktemp -dt "${TMPDIR:-/tmp}/x.XXXXXX")
f:8:prose naming mktemp as the way to make a scratch repo
f:9:tmp=$(mktemp "${TMPDIR:-/tmp}/x.XXXXXX")
f:10:tmp=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
f:11:tmp=$(mktemp -q -u "${TMPDIR:-/tmp}/x.XXXXXX")
f:12:tmp=$(mktemp -p "${TMPDIR:-/tmp}" x.XXXXXX)
f:13:tmp=$(mktemp --tmpdir "${TMPDIR:-/tmp}" x.XXXXXX)
f:14:tmp=$(mktemp --tmpdir="${TMPDIR:-/tmp}" x.XXXXXX)
f:15:path=$(mktempfile)
f:16:dir=$(_mktemp_dir)
f:17:a=$(mktemp "${TMPDIR:-/tmp}/a.XXXXXX"); b=$(mktemp "${TMPDIR:-/tmp}/b.XXXXXX")
f:18:a=$(mktemp "${TMPDIR:-/tmp}/a.XXXXXX"); b=$(mktemp -t z)
FIXTURE
)"

  local got expected='2 3 4 5 6 7 8 18'
  got="$(printf '%s\n' "$violations" | sed -n 's/^f:\([0-9]*\):.*/\1/p' | sort -n | tr '\n' ' ')"
  got="${got% }"

  if [ "$got" != "$expected" ]; then
    printf 'predicate misclassified fixture lines.
  expected violations on: %s
  got violations on:      %s
%s\n' "$expected" "$got" "$violations" >&2
    return 1
  fi
}
