#!/usr/bin/env bats

load helpers/setup

# phone-harness (ShawnPana/phone-harness) integration.
#
# The pieces live in four different files — a pin in .chezmoidata.toml, a file
# external, a darwin-gated lifecycle script, and a ~/.zprofile export — and each
# is only correct in relation to the others. These tests assert those relations,
# because none of them fails loudly at apply time: a drifted agent-workspace path
# silently loses the agent's helpers, and a formula/cask mixup silently leaks a
# macOS-only package into the Ubuntu CI job.

SETUP_SCRIPT="run_onchange_after_19-setup-phone-harness.sh.tmpl"

# The [phone_harness] table's `version` / `commit` values, resolved without a TOML
# parser (CI's bats job installs only bats/shellcheck/zsh). Scoped to the table so
# a same-named key elsewhere in the file cannot be picked up by accident.
_phone_harness_pin() {
  awk -v key="$1" '
    /^\[phone_harness\]$/ { in_table = 1; next }
    /^\[/                 { in_table = 0 }
    in_table && $1 == key { print; exit }
  ' "${HOME_DIR}/.chezmoidata.toml" | grep -oE '"[^"]+"' | tr -d '"'
}

@test "phone-harness: [phone_harness] pins a semver PyPI version and a full-SHA commit" {
  local version commit
  version="$(_phone_harness_pin version)"
  commit="$(_phone_harness_pin commit)"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "[phone_harness].version is not a semver release: '${version}'"
    false
  }
  # A full 40-hex SHA, not a tag or short SHA: a moveable ref would let the
  # fetched SKILL.md drift under a plain `chezmoi apply`.
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || {
    echo "[phone_harness].commit is not a full 40-hex SHA: '${commit}'"
    false
  }
}

@test "phone-harness: SKILL.md is a file external pinned to [phone_harness].commit" {
  local ext="${HOME_DIR}/.chezmoiexternal.toml"
  # The table name doubles as the provenance signal: skill_provenance.bats'
  # _skill_is_external() greps for [".agents/skills/<name>/ — so this exact
  # prefix is what keeps the skill out of the `unmanaged` bucket.
  grep -qF '[".agents/skills/phone-harness/SKILL.md"]' "$ext" || {
    echo "phone-harness SKILL.md external entry is missing"
    false
  }

  local block
  block="$(awk '
    /^\[".agents\/skills\/phone-harness\/SKILL.md"\]$/ { in_block = 1; next }
    in_block && /^\[/ { in_block = 0 }
    in_block { print }
  ' "$ext")"

  [[ "$block" == *'type = "file"'* ]] || {
    echo "phone-harness external is not type = \"file\""
    false
  }
  [[ "$block" == *'{{ .phone_harness.commit }}'* ]] || {
    echo "phone-harness external does not read the pin from [phone_harness].commit"
    false
  }
  # Same refresh cadence as every other third-party skill external.
  [[ "$block" == *'refreshPeriod = "168h"'* ]] || {
    echo "phone-harness external is missing refreshPeriod = \"168h\""
    false
  }
}

@test "phone-harness: the setup script is wrapped in a darwin guard" {
  local script="${HOME_DIR}/${SETUP_SCRIPT}"
  [ -f "$script" ] || {
    echo "missing lifecycle script: ${SETUP_SCRIPT}"
    false
  }

  # The guard must wrap the WHOLE script (first line / last line), not just a
  # section: the CLI depends on pyobjc, which cannot build on the Ubuntu CI job.
  # A fully-empty render is what stops chezmoi from running it there at all.
  [ "$(head -1 "$script")" = '{{ if eq .chezmoi.os "darwin" -}}' ] || {
    echo "${SETUP_SCRIPT} does not open with a darwin guard"
    false
  }
  [ "$(tail -1 "$script")" = '{{ end -}}' ] || {
    echo "${SETUP_SCRIPT} does not close its darwin guard on the last line"
    false
  }
}

@test "phone-harness: the setup script re-runs when the version pin moves" {
  # run_onchange hashes the RENDERED script, so the pin has to appear in the
  # rendered text or a version bump would never reinstall anything.
  grep -qF '{{ .phone_harness.version }}' "${HOME_DIR}/${SETUP_SCRIPT}" || {
    echo "${SETUP_SCRIPT} does not embed {{ .phone_harness.version }}"
    false
  }
}

@test "phone-harness: the setup script degrades to a warning instead of failing apply" {
  local script="${HOME_DIR}/${SETUP_SCRIPT}"
  # A missing mise, or a failed install, must not abort `chezmoi apply` — every
  # other tool this repo installs behaves that way (see the agent-browser setup).
  grep -q 'command -v mise' "$script" || {
    echo "${SETUP_SCRIPT} does not guard on mise being present"
    false
  }
  # Two degradation paths (no mise, failed install), both exiting 0. Matched
  # loosely on purpose: what matters is that two paths exit 0, not how deeply
  # they happen to be indented or whether a trailing comment follows.
  local exits
  exits="$(grep -cE '^[[:space:]]*exit 0([[:space:]]*#.*)?$' "$script")"
  [ "$exits" -ge 2 ] || {
    echo "${SETUP_SCRIPT} has ${exits} 'exit 0' degradation paths, expected at least 2"
    false
  }
  # --force would reinstall on every re-run; uv already no-ops on a matching
  # version and swaps versions when the pin moves.
  ! grep -q 'uv tool install.*--force' "$script" || {
    echo "${SETUP_SCRIPT} passes --force to uv tool install; it is unnecessary"
    false
  }
}

@test "phone-harness: PH_AGENT_WORKSPACE and the created directory are the same path" {
  local script="${HOME_DIR}/${SETUP_SCRIPT}"
  local zprofile="${HOME_DIR}/dot_zprofile.tmpl"

  # The export tells phone-harness where the agent's helpers live; the script
  # creates that directory. If the two drift, the agent silently writes into a
  # directory nothing else knows about and its accumulated helpers vanish.
  # `[^"]*` rather than a greedy `.*`, so trailing text after the closing quote
  # (the `|| echo ...` degradation on the mkdir line) is not captured as part of
  # the path.
  local exported created
  exported="$(grep 'export PH_AGENT_WORKSPACE=' "$zprofile" | sed 's/.*="\([^"]*\)".*/\1/')"
  created="$(grep 'mkdir -p "\$HOME/.local/share/phone-harness' "$script" | sed 's/.*mkdir -p "\([^"]*\)".*/\1/')"

  [ -n "$exported" ] || {
    echo "dot_zprofile.tmpl does not export PH_AGENT_WORKSPACE"
    false
  }
  [ "$exported" = "$created" ] || {
    echo "PH_AGENT_WORKSPACE ('${exported}') != the directory the setup script creates ('${created}')"
    false
  }

  # Requirements 4-2 / 4-4: apply creates the directory but must never touch its
  # contents. That guarantee currently rests on `mkdir -p` being the only thing
  # the script does to this path, so assert the destructive case away directly
  # rather than leaving it implicit.
  ! grep -qE '(^|[^a-z-])rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^|;&]*phone-harness/agent-workspace' "$script" || {
    echo "${SETUP_SCRIPT} must never remove the agent workspace (requirements 4-2 / 4-4)"
    false
  }
}

@test "phone-harness: the PH_AGENT_WORKSPACE export is darwin-only" {
  # Guard placement, not just presence: exporting it on Linux would advertise a
  # tool that is never installed there.
  #
  # Nesting-aware on purpose. dot_zprofile.tmpl already opens with a darwin guard
  # that *contains* an arm64 if/else, so a flat toggle would close on the inner
  # `{{ end }}` and only get the right answer by accident of line order. Track
  # depth instead: remember the depth at which the darwin branch opened, and drop
  # out of it on the matching `{{ end }}` — or on an `{{ else }}` at that same
  # depth, since the else side is the non-darwin branch.
  local guarded
  guarded="$(awk '
    /^\{\{[[:space:]]*if / {
      depth++
      if (darwin_at == 0 && $0 ~ /\.chezmoi\.os "darwin"/) darwin_at = depth
      next
    }
    /^\{\{[[:space:]]*else/ {
      if (darwin_at == depth) darwin_at = 0
      next
    }
    /^\{\{[[:space:]]*end/ {
      if (darwin_at == depth) darwin_at = 0
      depth--
      next
    }
    darwin_at > 0 && /export PH_AGENT_WORKSPACE=/ { print }
  ' "${HOME_DIR}/dot_zprofile.tmpl")"
  [ -n "$guarded" ] || {
    echo "PH_AGENT_WORKSPACE is exported outside a darwin guard in dot_zprofile.tmpl"
    false
  }
}

@test "phone-harness: the agent workspace is ignored by chezmoi" {
  # The agent writes agent_helpers.py here mid-session. chezmoi must not collect
  # it into this public repo, nor deploy over it.
  grep -qFx '.local/share/phone-harness' "${HOME_DIR}/.chezmoiignore" || {
    echo ".chezmoiignore is missing .local/share/phone-harness"
    false
  }
}

@test "phone-harness: adb comes from a cask, so the Ubuntu job never sees it" {
  local brewfile="${HOME_DIR}/dot_Brewfile"
  grep -qFx 'cask "android-platform-tools"' "$brewfile" || {
    echo "Brewfile is missing cask \"android-platform-tools\" (adb for the Android path)"
    false
  }
  # The Linux CI job extracts `^(tap |brew )` lines from this Brewfile, so a
  # formula entry would install a macOS-only Android toolchain on Ubuntu.
  ! grep -qFx 'brew "android-platform-tools"' "$brewfile" || {
    echo "android-platform-tools is declared as a formula; it must stay a cask"
    false
  }
}

@test "phone-harness: Renovate tracks both pins and routes both to agent review" {
  local renovate="${REPO_ROOT}/.github/renovate.json5"

  # Two datasources, because the CLI (PyPI release) and SKILL.md (git commit)
  # move independently upstream.
  grep -q "datasourceTemplate: 'pypi'" "$renovate" || {
    echo "renovate.json5 has no pypi custom manager for the phone-harness CLI"
    false
  }
  # Both managers must carry the table anchor, not just one of them: a single
  # `grep -q` would still pass if one lost its prefix and started matching a
  # `version =` / `commit =` in a neighbouring table.
  local scoped
  scoped="$(grep -cF '\\[phone_harness\\]' "$renovate")"
  [ "$scoped" -ge 2 ] || {
    echo "only ${scoped} phone-harness custom manager(s) are scoped to the [phone_harness] table, expected 2"
    false
  }
  grep -qF 'https://github.com/ShawnPana/phone-harness' "$renovate" || {
    echo "renovate.json5 has no git-refs manager for the phone-harness SKILL.md pin"
    false
  }

  # This ships executable code that drives a real phone, so neither pin may reach
  # the merge gate's deterministic fast lane.
  #
  # The guarantee used to be an `automerge: false` packageRule. It is now the gate
  # (scripts/renovate-gate-classify.sh), which is strictly stronger: the old rule
  # could only key on updateType, and a PyPI patch bump of this package is shaped
  # exactly like an ordinary CLI bump. The gate names the dependency instead.
  local classifier="${REPO_ROOT}/scripts/renovate-gate-classify.sh"
  grep -qE "^readonly ALWAYS_REVIEW_DEPS=.*phone-harness" "$classifier" || {
    echo "phone-harness is not in the classifier's always-review list"
    false
  }
  # The SKILL.md pin is a git-refs digest, which the shape allowlist already sends
  # to the agent -- assert the allowlist still cannot match a digest title.
  local pass_re
  pass_re="$(sed -n "s/^readonly PASS_TITLE_RE='\(.*\)'\$/\1/p" "$classifier")"
  [ -n "$pass_re" ] || {
    echo "could not read PASS_TITLE_RE from the classifier"
    false
  }
  [[ ! "update ShawnPana/phone-harness digest to abc1234" =~ $pass_re ]] || {
    echo "the classifier's fast lane matches a phone-harness digest bump"
    false
  }
  # And no config-level automerge lane may quietly come back for this dep.
  ! grep -qE '^\s*automerge: false,' "$renovate" || {
    echo "renovate.json5 pins automerge off again; the gate is meant to own this"
    false
  }
}
