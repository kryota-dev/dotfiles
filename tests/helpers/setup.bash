#!/usr/bin/env bash

# Common test helpers
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
HOME_DIR="${REPO_ROOT}/home"
DOCS_DIR="${REPO_ROOT}/docs"

# Resolve the [ecc].skills array from .chezmoidata.toml. Shared by skill_provenance.bats
# and docs_facts.bats so the two suites can't diverge on how they count ECC skills.
#
# The .chezmoiexternal.toml range over [ecc].skills emits one [".agents/skills/<name>"]
# entry per element, so a literal grep of that file (which only sees the `{{ $skill }}`
# template var) can't see the expanded names — resolve the list directly here. Scoped
# strictly to the [ecc] table's `skills = [ ... ]` array so an unrelated section gaining a
# `skills` key (or a formatter changing the indent) can't perturb the result. Kept
# dependency-free on purpose: CI's bats job installs only bats/shellcheck/zsh, no chezmoi.
_ecc_skill_list() {
  awk '
    /^\[ecc\]$/        { in_ecc = 1; next }
    /^\[/              { in_ecc = 0; in_list = 0 }
    in_ecc && /^[[:space:]]*skills[[:space:]]*=[[:space:]]*\[/ { in_list = 1; next }
    in_ecc && in_list && /^[[:space:]]*\]/ { in_list = 0; next }
    in_ecc && in_list  { print }
  ' "${HOME_DIR}/.chezmoidata.toml" | grep -oE '"[^"]+"' | tr -d '"'
}

# Resolve the ITEMS=(...) array in run_once_after_11-validate-1password.sh.tmpl.
# Each entry is a "op://kryota.dev/..." string; comments inside the array (starting
# with #) are ignored. Kept dependency-free (no yq / no chezmoi).
_onepassword_item_list() {
  awk '
    /^ITEMS=\(/                { in_arr = 1; next }
    in_arr && /^\)/            { in_arr = 0 }
    in_arr && /"op:\/\//      { print }
  ' "${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
}
