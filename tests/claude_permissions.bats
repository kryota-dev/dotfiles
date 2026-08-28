#!/usr/bin/env bats

load helpers/setup

# Claude Code permission rule form checks.
#
# Since v2.1.210 the file permission checks match only `Edit(path)` and `Read(path)` rules.
# A `Write(path)`, `NotebookEdit(path)` or `Glob(path)` rule is still ACCEPTED — it just never
# matches, so the rule is silently inert and every session warns at startup. That failure mode
# (config is accepted but does nothing) is invisible in review, which is what these tests are
# for. `Edit` rules cover all file-editing tools, so `Edit(path)` is the correct replacement.
# A bare tool name with no path (`Write`, `Glob`) is unaffected and must NOT be flagged.
#
# Dependency-free on purpose. CI's bats job DOES install jq (.github/workflows/ci.yml, added
# later for the wave-orchestrator suite), so the older reason given here — that a jq assertion
# would `skip` in CI — no longer holds. The reason that does: a jq assertion skips on a machine
# without jq, and these guards are the ones you most want green locally before pushing a
# settings change. What genuinely needs a real JSON parse is already covered — tests/files.bats
# has a whole family of tests that parse this same file with jq, so a malformed settings.json
# fails loudly there in CI. (Deliberately not stating how many: that count drifts with every
# edit to files.bats, and a number that goes stale is the failure this block just corrected.)
# These guards stay parser-free rather than duplicate that coverage.
#
# See: https://code.claude.com/docs/en/permissions

# Anchor radius (issue #320).
#
# A file permission rule only matches under its anchor, and the rule's own path syntax picks
# which KIND of anchor it gets. Only the single-leading-slash form's anchor then depends on
# the settings file the rule is declared in. Measured on CLI 2.1.247, one deny rule per probe
# session, verdict read from the tool result rather than from prose. NOT PROBED marks a
# combination this run did not measure — it is not a claim about that combination:
#
#   rule form         | in cwd     | under $HOME, outside cwd | outside $HOME
#   ------------------|------------|--------------------------|--------------
#   Read(**/.env*)    | DENIED     | ALLOWED                  | ALLOWED
#   Read(~/**/.env*)  | DENIED     | DENIED                   | ALLOWED
#   Read(//**/.env*)  | DENIED     | DENIED                   | DENIED
#   Read(/**/.env*)   | NOT PROBED | ALLOWED                  | NOT PROBED
#   Read(~/.env*)     | NOT PROBED | ALLOWED                  | ALLOWED
#
# Read(/**/.env*): a single leading slash anchors at the settings source, so in user settings
# it resolves under ~/.claude and reaches nothing else.
# Read(~/.env*): a ~/-anchored single trailing segment did not match at depth, while an exact
# ~/-anchored path to the same file DID deny it — so `~/` anchoring works and the depth
# semantics are what differ. This row is that measurement, not an extrapolation from the
# documented "bare filenames match at any depth" rule, which is stated for the cwd-relative
# form.
#
# Across the probed conditions above, `//` was the only form that held wherever the session
# was started, and the cwd-anchored form did not reach even the parent of the working
# directory — it missed sibling worktrees, the main checkout, other repositories, directories
# added with --add-dir, and the repository root whenever a session starts in a subdirectory.
# That is why every Read/Edit deny rule is written with `//` and why the anchor guard below
# enforces it. Inside the working directory the two forms match the same files, so widening
# the anchor changed nothing there.
#
# The harness does not already cover this. Its `protected paths` are a write-only check over
# repository and tool config (.git, .claude, .zshrc, .npmrc, ...) and list no credential file
# at all, and `critical paths` only gate rm/rmdir targets. The auto-mode classifier does ship
# credential rules, but they are soft (clearable once the user names specifics), model-judged,
# and auto-mode only - not a deterministic deny. So these rules are not redundant with it.
#
# Not established by observation, and deliberately not asserted here: whether /cd relocates
# the anchor, and whether the permissions.additionalDirectories settings key behaves like the
# --add-dir flag (only the flag was probed).
#
# See: https://code.claude.com/docs/en/permission-modes#protected-paths

# Emit permission rules from the Claude Code settings SSOT — every rule across allow/deny/ask,
# or only one array's rules when a section name is passed. Scoped to the top-level
# "permissions" object so an unrelated block gaining an "allow" key can't perturb the result.
# One rule per line is the file's own layout. Only this one settings file is inspected: it is
# the SSOT that both profiles receive (~/.claude-r06/settings.json symlinks to it), so a second
# settings source would need to be added here explicitly.
_claude_permission_rules() {
  awk -v want="${1:-}" '
    /^  "permissions"[[:space:]]*:/                                       { in_perms = 1; next }
    in_perms && !in_list && /^[[:space:]]*[}]/                            { in_perms = 0 }
    in_perms && /^[[:space:]]*"(allow|deny|ask)"[[:space:]]*:[[:space:]]*\[/ {
      match($0, /"(allow|deny|ask)"/)
      section = substr($0, RSTART + 1, RLENGTH - 2)
      in_list = 1
      next
    }
    in_perms && in_list && /^[[:space:]]*\]/                              { in_list = 0; next }
    in_perms && in_list && (want == "" || want == section)                { print }
  ' "${HOME_DIR}/dot_claude/settings.json" |
    sed -e 's/^[[:space:]]*"//' -e 's/",*[[:space:]]*$//' |
    grep -v '^[[:space:]]*$'
}

@test "claude permissions: settings.json declares no rule in an unmatched form" {
  [ -f "${HOME_DIR}/dot_claude/settings.json" ]

  local allow_count deny_count total
  allow_count="$(_claude_permission_rules allow | grep -c . || true)"
  deny_count="$(_claude_permission_rules deny | grep -c . || true)"
  total="$(_claude_permission_rules | grep -c . || true)"

  # Assert PER ARRAY, not just on the total. A parser break that drops one whole array —
  # reformatted JSON, a renamed key — leaves the other array's rules behind, and a total-only
  # floor can be satisfied by that remainder alone while every dropped rule goes unread. The
  # guard would then pass on rules it never looked at, which is the exact failure this suite
  # exists to catch.
  [ "$allow_count" -ge 1 ] || {
    echo "sanity: permissions.allow yielded no rules — the extractor broke"
    false
  }
  [ "$deny_count" -ge 1 ] || {
    echo "sanity: permissions.deny yielded no rules — the extractor broke"
    false
  }
  [ "$total" -ge 20 ] || {
    echo "sanity: permissions.allow/deny/ask resolved to $total rules (<20) — the extractor broke"
    false
  }

  local offenders
  offenders="$(_claude_permission_rules | grep -E '^(Write|NotebookEdit|Glob)\(' || true)"
  [ -z "$offenders" ] || {
    echo "settings.json declares rules that are accepted but never matched by file permission checks:"
    echo "$offenders"
    echo "use Edit(<path>) for Write(<path>)/NotebookEdit(<path>), Read(<path>) for Glob(<path>)"
    false
  }
}

@test "claude permissions: file deny rules are anchored at the filesystem root" {
  [ -f "${HOME_DIR}/dot_claude/settings.json" ]

  local file_rules count offenders
  file_rules="$(_claude_permission_rules deny | grep -E '^(Read|Edit)\(' || true)"
  count="$(printf '%s' "$file_rules" | grep -c . || true)"

  # Vacuous-pass floor, same as the first test: if the extractor stops yielding rules this
  # must fail rather than report a clean sheet it never looked at. Scope note: it catches the
  # extractor going silent, NOT the file's JSON structure — a malformed settings.json fails
  # the jq-based assertions in tests/files.bats, which run in CI. And it is only a floor: the
  # test below is what keeps the individual credential rules from disappearing.
  [ "$count" -ge 1 ] || {
    echo "sanity: permissions.deny yielded no Read/Edit rules — the extractor broke"
    false
  }

  offenders="$(printf '%s\n' "$file_rules" | grep -vE '^(Read|Edit)\(//' || true)"
  [ -z "$offenders" ] || {
    echo "settings.json declares file deny rules whose anchor is narrower than it looks:"
    echo "$offenders"
    echo "a rule only matches under its anchor: '//path' is the filesystem root, '~/path' is"
    echo "the home directory, '/path' is the settings source (~/.claude for user settings),"
    echo "and a bare 'path' or '**/path' is the session's working directory — which leaves"
    echo "sibling worktrees, other repos and --add-dir targets unguarded."
    echo "write //<pattern> so the rule holds wherever the session was started (issue #320)"
    false
  }
}

# The credential paths this configuration is responsible for denying. The anchor guard above
# only checks the SHAPE of whatever rules remain, so on its own it stays green after eight of
# these nine are deleted, and the `total >= 20` floor in the first test does not save you
# either: the file currently holds 59 allow + 20 deny = 79 rules, so removing all nine still
# leaves 70. Losing a credential rule is exactly the silent-guardrail failure this suite
# exists to catch, so name them. This is a subset check — adding rules is always fine.
_CLAUDE_REQUIRED_FILE_DENY_RULES=(
  'Read(//**/.env*)'
  'Read(//**/id_rsa)'
  'Read(//**/id_ed25519)'
  'Read(//**/*.pem)'
  'Read(//**/*.key)'
  'Read(//**/*credentials*)'
  'Read(//**/*secret*)'
  'Edit(//**/.env*)'
  'Edit(//**/secrets/**)'
)

@test "claude permissions: every credential file deny rule is still declared" {
  [ -f "${HOME_DIR}/dot_claude/settings.json" ]

  local deny_rules rule
  local missing=()
  deny_rules="$(_claude_permission_rules deny)"

  # -x -F: whole-line, fixed-string. The patterns contain `*`, `(` and `.`, so a regex match
  # here would quietly compare something other than the literal rule.
  for rule in "${_CLAUDE_REQUIRED_FILE_DENY_RULES[@]}"; do
    printf '%s\n' "$deny_rules" | grep -qxF -- "$rule" || missing+=("$rule")
  done

  [ "${#missing[@]}" -eq 0 ] || {
    echo "settings.json no longer denies these credential paths:"
    printf '  %s\n' "${missing[@]}"
    echo "restore the rule, or — if the pattern was deliberately replaced — update"
    echo "_CLAUDE_REQUIRED_FILE_DENY_RULES in this file so the change is a visible one."
    false
  }
}

@test "claude permissions: headless --allowedTools lists declare no rule in an unmatched form" {
  local found=0 f offenders
  while IFS= read -r f; do
    found=1
    # Comment lines are stripped so a script can still DESCRIBE the deprecated form in prose.
    offenders="$(grep -v '^[[:space:]]*#' "$f" | grep -oE '(Write|NotebookEdit|Glob)\([^)]*\)' || true)"
    [ -z "$offenders" ] || {
      echo "${f#"${REPO_ROOT}/"}: --allowedTools declares rules that are never matched:"
      echo "$offenders"
      echo "use Edit(<path>) for Write(<path>)/NotebookEdit(<path>), Read(<path>) for Glob(<path>)"
      false
    }
  done < <(grep -rlF -- '--allowedTools' "${HOME_DIR}")
  [ "$found" = 1 ] || {
    echo "no script under ${HOME_DIR} declares --allowedTools — this guard lost its subject"
    false
  }
}
