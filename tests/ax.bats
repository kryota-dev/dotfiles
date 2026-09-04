#!/usr/bin/env bats

load helpers/setup

# ax (yusukebe/ax) integration.
#
# ax arrives as two artifacts from one upstream release, and they are declared in four
# different files: the CLI pin in the mise config, the skill pin in .chezmoidata.toml, the
# external that reads it, and the Renovate managers that move both. None of those files
# fails loudly on its own when the relationship between them breaks:
#
#   - a version skew between the two pins ships a SKILL.md documenting flags the installed
#     CLI may not have (ax is v0.1.x with no stable-API declaration),
#   - a renamed external table silently demotes the skill to `unmanaged`,
#   - a deleted Renovate group rule does nothing at all until the next ax release, and
#     then splits the bump into two PRs that are each red and individually unmergeable.
#
# These tests assert the relationships rather than the files.

readonly AX_REPO='yusukebe/ax'
readonly AX_MISE_KEY='"github:yusukebe/ax"'

# The [ax] table's `version` / `commit` values, resolved without a TOML parser (CI's bats
# job installs only bats/shellcheck/zsh). Scoped to the table so a same-named key in a
# neighbouring one cannot be picked up by accident -- the same awk shape
# _phone_harness_pin() and _ecc_skill_list() already use.
_ax_pin() {
  awk -v key="$1" '
    /^\[ax\]$/ { in_table = 1; next }
    /^\[/      { in_table = 0 }
    in_table && $1 == key { print; exit }
  ' "${HOME_DIR}/.chezmoidata.toml" | grep -oE '"[^"]+"' | tr -d '"'
}

# The live `"github:yusukebe/ax"` declaration line, e.g.
#   "github:yusukebe/ax" = { version = "0.1.25", version_prefix = "v" }
#
# Commented-out lines are dropped first. Without that, commenting the declaration out while
# leaving its text behind satisfies every assertion below, and the config would stop
# installing ax with no test noticing.
_ax_mise_line() {
  grep -vE '^[[:space:]]*#' "${HOME_DIR}/dot_config/mise/config.toml" | grep -F "${AX_MISE_KEY}"
}

# The pinned version out of that line. The `[{,]` anchor requires `version` to open the
# inline table or follow a comma, so `version_prefix`'s own quoted value is never read as
# the version.
_ax_mise_version() {
  _ax_mise_line | sed -n 's/.*[{,][[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p'
}

# The single `{ ... }` object inside a top-level renovate.json5 array (`customManagers` /
# `packageRules`) that contains <needle>.
#
# Scoping to one object is the whole point: asserting depNameTemplate, datasourceTemplate,
# matchStrings and groupName independently against the file (or against the whole array)
# still passes when they have drifted into *different* managers or rules, which is exactly
# the state that would stop the two ax pins from moving together.
#
# Relies on the file's array-item indentation (4 spaces), which is uniform across this file.
_renovate_object_with() {
  local section="$1" needle="$2"
  awk -v sec="  ${section}: [" -v needle="$needle" '
    index($0, sec) == 1 { inside = 1; next }
    inside && /^  \],$/ { exit }
    !inside             { next }
    /^    \{$/          { buf = $0; inobj = 1; next }
    inobj               { buf = buf "\n" $0 }
    inobj && /^    \},?$/ {
      if (index(buf, needle) > 0) { print buf; exit }
      inobj = 0; buf = ""
    }
  ' "${REPO_ROOT}/.github/renovate.json5"
}

@test "ax: [ax] pins a semver release and a full-SHA commit" {
  local version commit
  version="$(_ax_pin version)"
  commit="$(_ax_pin commit)"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "[ax].version is not a three-part semver release: '${version}'"
    false
  }
  # A full 40-hex SHA, not a tag. A release tag can be force-moved upstream, and what is
  # fetched from this ref becomes skill text that steers an agent's web access.
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || {
    echo "[ax].commit is not a full 40-hex SHA: '${commit}'"
    false
  }
}

@test "ax: the CLI is a github-backend mise tool at the same version as the skill pin" {
  local config="${HOME_DIR}/dot_config/mise/config.toml"

  # Exactly one LIVE declaration. `_ax_mise_line` drops commented-out lines, so a
  # declaration that was commented out (but left in place as text) fails here rather than
  # silently satisfying every assertion below.
  local declared
  declared="$(_ax_mise_line | grep -c .)"
  [ "$declared" -eq 1 ] || {
    echo "expected exactly 1 uncommented ${AX_MISE_KEY} declaration, found ${declared}"
    false
  }

  # The github backend, not ubi: mise 2026.4 warns that ubi is deprecated and removed in
  # 2027.1.0, and github additionally verifies the checksum and -- when the release carries
  # them -- artifact attestations and SLSA provenance.
  ! grep -qF '"ubi:yusukebe/ax"' "$config" || {
    echo "ax is declared on the deprecated ubi backend; use github: instead"
    false
  }

  # version_prefix strips the leading v from the upstream tag (v0.1.25 -> 0.1.25). mise
  # needs it to resolve the release, and Renovate's mise manager reads the same option to
  # build its extractVersion -- so losing it breaks tracking as well as the install.
  _ax_mise_line | grep -qF 'version_prefix = "v"' || {
    echo "${AX_MISE_KEY} is missing version_prefix = \"v\""
    false
  }

  # The relationship this whole file exists for. Both pins come from one upstream release,
  # so they must name the same version. If this fails on a Renovate PR, the group rule in
  # renovate.json5 stopped batching the two managers together (see the next test) and the
  # other pin needs bumping in the same branch.
  local pinned mise_version
  pinned="$(_ax_pin version)"
  mise_version="$(_ax_mise_version)"
  [ -n "$mise_version" ] || {
    echo "could not read a version out of the ${AX_MISE_KEY} line"
    false
  }
  [ "$pinned" = "$mise_version" ] || {
    echo "version skew: [ax].version is '${pinned}' but the mise config pins '${mise_version}'"
    echo "  both artifacts come from one ax release; bump them together"
    false
  }
}

@test "ax: SKILL.md is a file external pinned to [ax].commit" {
  local ext="${HOME_DIR}/.chezmoiexternal.toml"
  # The table name doubles as the provenance signal: skill_provenance.bats'
  # _skill_is_external() greps for [".agents/skills/<name>/ — so this exact prefix is what
  # keeps the skill out of the `unmanaged` bucket.
  grep -qF '[".agents/skills/ax/SKILL.md"]' "$ext" || {
    echo "ax SKILL.md external entry is missing"
    false
  }

  # The entry's key/value lines only. The block ends at the next table header, a comment or
  # a blank line -- not just at `[` -- so a commented-out setting cannot keep satisfying the
  # assertions below from inside the extracted text.
  local block
  block="$(awk '
    /^\[".agents\/skills\/ax\/SKILL.md"\]$/ { in_block = 1; next }
    in_block && (/^\[/ || /^[[:space:]]*#/ || /^[[:space:]]*$/) { exit }
    in_block { print }
  ' "$ext")"

  printf '%s\n' "$block" | grep -qE '^[[:space:]]*type = "file"$' || {
    echo "ax external is not type = \"file\""
    false
  }
  # Full-line match on the URL, not a substring check on the ref template. What is fetched
  # here becomes skill text that steers an agent's web access, so the SOURCE has to be
  # pinned as tightly as the ref: a substring check on `{{ .ax.commit }}` alone would still
  # pass a URL pointing at some other repository's raw endpoint. Upstream also keeps the
  # skill at skills/ax/SKILL.md rather than at the repo root like phone-harness.
  printf '%s\n' "$block" \
    | grep -qE '^[[:space:]]*url = "https://raw\.githubusercontent\.com/yusukebe/ax/\{\{ \.ax\.commit \}\}/skills/ax/SKILL\.md"$' || {
    echo "ax external's url is not the [ax].commit-pinned yusukebe/ax skills/ax/SKILL.md raw URL:"
    printf '%s\n' "$block" | grep -E '^[[:space:]]*url =' || echo "  (no url line in the entry)"
    false
  }
  # Same refresh cadence as every other third-party skill external.
  printf '%s\n' "$block" | grep -qE '^[[:space:]]*refreshPeriod = "168h"$' || {
    echo "ax external is missing refreshPeriod = \"168h\""
    false
  }
}

@test "ax: Renovate tracks both pins and batches them into one PR" {
  local renovate="${REPO_ROOT}/.github/renovate.json5"

  # The skill pin: ONE custom manager, scoped to the [ax] table, capturing version and
  # commit together so a bump moves both in one hunk. Every property is asserted against
  # that single manager object -- checking them independently against the whole file passes
  # even when they have drifted into different managers.
  local mgr
  mgr="$(_renovate_object_with customManagers "depNameTemplate: '${AX_REPO}'")"
  [ -n "$mgr" ] || {
    echo "renovate.json5 has no customManagers entry naming ${AX_REPO}"
    false
  }
  [[ "$mgr" == *'\\[ax\\]'* ]] || {
    echo "the ${AX_REPO} custom manager is not scoped to the [ax] table"
    false
  }
  [[ "$mgr" == *'home/\\.chezmoidata\\.toml'* ]] || {
    echo "the ${AX_REPO} custom manager does not read home/.chezmoidata.toml"
    false
  }
  # github-tags, not the git-refs/main form the other skill pins use: the SKILL.md pin has
  # to land on the same RELEASE as the CLI pin, not on whatever main happens to be.
  [[ "$mgr" == *"datasourceTemplate: 'github-tags'"* ]] || {
    echo "the ${AX_REPO} custom manager does not use the github-tags datasource"
    false
  }
  # Both captures in one manager: version and commit have to move in a single hunk.
  local capture
  for capture in '(?<currentValue>' '(?<currentDigest>'; do
    [[ "$mgr" == *"$capture"* ]] || {
      echo "the ${AX_REPO} custom manager does not capture ${capture}...)"
      false
    }
  done

  # The CLI pin needs no custom manager -- the built-in mise manager reads the github
  # backend -- but it only reaches ax if the mise config is still in its file patterns.
  grep -qF '/^home/dot_config/mise/config\\.toml$/' "$renovate" || {
    echo "the mise manager no longer covers home/dot_config/mise/config.toml,"
    echo "so the ax CLI pin is not tracked at all"
    false
  }

  # The batching rule, asserted as ONE packageRule object. Without it the two managers open
  # two PRs, each half-applying the update, and the version-skew assertion above turns both
  # of them red. Deleting this rule breaks nothing until the next ax release, which is
  # exactly why it is asserted here.
  local rule
  rule="$(_renovate_object_with packageRules "'${AX_REPO}'")"
  [ -n "$rule" ] || {
    echo "no packageRule matches ${AX_REPO}; the two ax pins would bump as separate PRs"
    false
  }
  [[ "$rule" == *'matchPackageNames'* ]] || {
    echo "the ${AX_REPO} packageRule does not match on matchPackageNames"
    false
  }
  [[ "$rule" == *"groupName: 'ax'"* ]] || {
    echo "the ${AX_REPO} packageRule does not carry groupName: 'ax'"
    false
  }
  # And that rule must not smuggle an automerge lane back in alongside the grouping -- the
  # merge gate owns that decision (same guard as tests/phone_harness.bats).
  ! grep -qE '^\s*automerge: false,' "$renovate" || {
    echo "renovate.json5 pins automerge off again; the gate is meant to own this"
    false
  }
}

@test "ax: the skill is external only, never vendored as a curated skill" {
  # never-both: chezmoi would try to deploy a directory from source AND fetch an external
  # onto the same path. skill_provenance.bats asserts this across all curated skills; this
  # is the ax-specific pin so the intent is readable from this file too.
  [ ! -e "${HOME_DIR}/dot_agents/skills/ax" ] || {
    echo "ax must not be vendored in source; it is fetched as an external"
    false
  }
}
