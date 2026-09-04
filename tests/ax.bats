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

# The version inside the mise inline table, e.g.
#   "github:yusukebe/ax" = { version = "0.1.25", version_prefix = "v" }
# Reads the first quoted value after `version =` on that line only, so version_prefix's
# own quoted value cannot be mistaken for it.
_ax_mise_version() {
  grep -F "${AX_MISE_KEY}" "${HOME_DIR}/dot_config/mise/config.toml" \
    | sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p'
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

  # The github backend, not ubi: mise 2026.4 warns that ubi is deprecated and removed in
  # 2027.1.0, and github additionally verifies checksum + artifact attestations + SLSA
  # provenance on install.
  grep -qF "${AX_MISE_KEY}" "$config" || {
    echo "the mise config does not declare ${AX_MISE_KEY}"
    false
  }
  ! grep -qF '"ubi:yusukebe/ax"' "$config" || {
    echo "ax is declared on the deprecated ubi backend; use github: instead"
    false
  }

  # version_prefix strips the leading v from the upstream tag (v0.1.25 -> 0.1.25). mise
  # needs it to resolve the release, and Renovate's mise manager reads the same option to
  # build its extractVersion -- so losing it breaks tracking as well as the install.
  grep -F "${AX_MISE_KEY}" "$config" | grep -qF 'version_prefix = "v"' || {
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

  local block
  block="$(awk '
    /^\[".agents\/skills\/ax\/SKILL.md"\]$/ { in_block = 1; next }
    in_block && /^\[/ { in_block = 0 }
    in_block { print }
  ' "$ext")"

  [[ "$block" == *'type = "file"'* ]] || {
    echo "ax external is not type = \"file\""
    false
  }
  [[ "$block" == *'{{ .ax.commit }}'* ]] || {
    echo "ax external does not read the pin from [ax].commit"
    false
  }
  # Upstream keeps the skill at skills/ax/SKILL.md, not at the repo root like
  # phone-harness. A wrong subpath 404s at apply time rather than deploying stale text,
  # but the failure names only the URL, so pin the path here.
  [[ "$block" == *'/skills/ax/SKILL.md'* ]] || {
    echo "ax external does not fetch skills/ax/SKILL.md from the repo"
    false
  }
  # Same refresh cadence as every other third-party skill external.
  [[ "$block" == *'refreshPeriod = "168h"'* ]] || {
    echo "ax external is missing refreshPeriod = \"168h\""
    false
  }
}

@test "ax: Renovate tracks both pins and batches them into one PR" {
  local renovate="${REPO_ROOT}/.github/renovate.json5"

  # The skill pin: a custom manager scoped to the [ax] table, capturing version and commit
  # together so a bump moves both in one hunk.
  grep -qF '\\[ax\\]' "$renovate" || {
    echo "renovate.json5 has no custom manager scoped to the [ax] table"
    false
  }
  grep -qF "depNameTemplate: '${AX_REPO}'" "$renovate" || {
    echo "renovate.json5's [ax] manager does not name ${AX_REPO} as the dependency"
    false
  }
  # github-tags, not the git-refs/main form the other skill pins use: the SKILL.md pin has
  # to land on the same RELEASE as the CLI pin, not on whatever main happens to be.
  grep -qF "datasourceTemplate: 'github-tags'" "$renovate" || {
    echo "renovate.json5 has no github-tags datasource (the [ax] manager needs one)"
    false
  }

  # The CLI pin needs no custom manager -- the built-in mise manager reads the github
  # backend -- but it only reaches ax if the mise config is still in its file patterns.
  grep -qF '/^home/dot_config/mise/config\\.toml$/' "$renovate" || {
    echo "the mise manager no longer covers home/dot_config/mise/config.toml,"
    echo "so the ax CLI pin is not tracked at all"
    false
  }

  # The batching rule. Without it the two managers open two PRs, each half-applying the
  # update, and the version-skew assertion above turns both of them red. Deleting this rule
  # breaks nothing until the next ax release, which is exactly why it is asserted here.
  local block
  block="$(awk '
    /^  packageRules: \[/ { in_rules = 1 }
    in_rules { print }
    in_rules && /^  \],/ { exit }
  ' "$renovate")"
  [[ "$block" == *"'${AX_REPO}'"* ]] || {
    echo "no packageRule matches ${AX_REPO}; the two ax pins would bump as separate PRs"
    false
  }
  [[ "$block" == *"groupName: 'ax'"* ]] || {
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
