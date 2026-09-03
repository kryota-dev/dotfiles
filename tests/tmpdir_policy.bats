#!/usr/bin/env bats

load helpers/setup

# macOS mktemp(1) reaches TMPDIR only when it is handed an explicit template. With -t -- and with
# no arguments at all, which mktemp(1) defines as equivalent to `-t tmp` -- it builds its template
# from _CS_DARWIN_USER_TEMP_DIR and names TMPDIR only as a fallback for when that is unavailable,
# which on macOS it never is. So a bare `mktemp -d` goes straight to the Darwin default
# /var/folders/.../T, which is outside the writable set of a sandboxed session. The whole suite
# then goes red with "mkdtemp failed ... Operation not permitted" for reasons that have nothing to
# do with the change under test, which is how #642 made the completion gate useless. _mktemp_dir
# (tests/helpers/setup.bash) always passes a template, so TMPDIR is honoured on both macOS and
# Linux.
#
# The scan is git grep rather than rg or the Grep tool on purpose: ripgrep-backed search
# silently skips gitignored paths and files containing raw NUL bytes, so it cannot back a
# "no occurrences anywhere" claim.
#
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
# Scope note: this checks mktemp only. A hardcoded /tmp path is the same defect with a different
# spelling and is not covered here.
@test "home/ sandbox paths carry no TMPDIR-ignoring mktemp (#648)" {
  # Same exit-status discipline as the guard above: only exit 1 means "no violations".
  local hits status=0
  hits="$(git -C "$REPO_ROOT" grep -n mktemp -- \
    'home/run_onchange_*' 'home/run_once_*' 'home/dot_agents/skills/')" || status=$?
  if [ "$status" -gt 1 ]; then
    printf 'git grep failed (exit %s); the home/ mktemp policy was not verified\n' "$status" >&2
    return 1
  fi

  # Markdown has no line-comment syntax, so the '#' rule only drops shell comments (and markdown
  # headings). Prose that mentions mktemp without an explicit template is therefore reported --
  # deliberately: a skill body that reads "make a scratch repo with mktemp" is an instruction an
  # agent executes, and that silent-deviation path is the layer-2 half of #648. To mention the
  # tool in prose here, spell a compliant call.
  #
  # Approximation: a call is taken to run from its "mktemp" to the end of the line, so the flags
  # of a second call on the same line are read as arguments of the first.
  local violations
  violations="$(printf '%s\n' "$hits" | awk '
    function bad(call,   n, tok, i) {
      n = split(call, tok, /[[:space:]]+/)
      for (i = 2; i <= n; i++) {
        # -t (and -dt, -qt, ...) resolves through _CS_DARWIN_USER_TEMP_DIR, never TMPDIR.
        if (tok[i] ~ /^-[[:alpha:]]*t$/) return 1
        if (tok[i] ~ /^-/) continue
        # First non-flag token is the positional template.
        return (tok[i] ~ /XXXXXX/) ? 0 : 1
      }
      # No argument at all -- mktemp(1) documents this as equivalent to -t tmp.
      return 1
    }
    {
      content = $0
      sub(/^[^:]+:[0-9]+:/, "", content)
      if (content ~ /^[[:space:]]*#/) next
      rest = content
      while ((i = index(rest, "mktemp")) > 0) {
        rest = substr(rest, i)
        if (bad(rest)) { print; break }
        rest = substr(rest, 7)
      }
    }
  ')"

  if [ -n "$violations" ]; then
    printf 'TMPDIR-ignoring mktemp under home/ (#648). Pass an explicit template, e.g.
mktemp "${TMPDIR:-/tmp}/<name>.XXXXXX" (add -d for a directory). Neither a bare call nor -t
reaches TMPDIR on macOS; see _mktemp_dir in tests/helpers/setup.bash for the mechanism.
%s\n' "$violations" >&2
    return 1
  fi
}
