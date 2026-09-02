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
# dependency-free on purpose so it keeps working even where chezmoi is unavailable
# (_render_script_template below is the one helper that does need it).
_ecc_skill_list() {
  awk '
    /^\[ecc\]$/        { in_ecc = 1; next }
    /^\[/              { in_ecc = 0; in_list = 0 }
    in_ecc && /^[[:space:]]*skills[[:space:]]*=[[:space:]]*\[/ { in_list = 1; next }
    in_ecc && in_list && /^[[:space:]]*\]/ { in_list = 0; next }
    in_ecc && in_list  { print }
  ' "${HOME_DIR}/.chezmoidata.toml" | grep -oE '"[^"]+"' | tr -d '"'
}

# Emit the full prose of a curated skill: SKILL.md plus any references/*.md it splits into.
#
# #503 moved the execution protocol of multi-review and sdd out of SKILL.md and into
# references/ (progressive disclosure). Norm-presence assertions have to follow the norm, not
# the filename, or splitting a skill silently disarms every guard that was grepping SKILL.md.
# Concatenation (rather than per-file greps) keeps `^`-anchored patterns working: each file
# ends with a newline, so line starts survive.
#
# Using this for *negative* assertions is strictly stronger than grepping SKILL.md alone --
# a duplicated SSOT body hidden in references/ still gets caught.
# Fails (rather than emitting nothing) when SKILL.md is missing: a silent empty result would
# make every *negative* assertion pass, which is the exact failure this helper exists to prevent.
# A trailing newline is emitted after each file so `^`-anchored patterns cannot be broken by a
# file that happens to lack its final newline.
_skill_text() {
  local dir="${HOME_DIR}/dot_agents/skills/$1"
  local skill="${dir}/SKILL.md"
  [ -f "$skill" ] || {
    echo "_skill_text: no SKILL.md for skill '$1'" >&2
    return 1
  }
  cat "$skill" || return 1
  printf '\n'
  local ref
  for ref in "${dir}"/references/*.md; do
    [ -f "$ref" ] || continue
    cat "$ref" || return 1
    printf '\n'
  done
}

# Render a chezmoi script template for a specific OS/arch into $out, so behavioural tests can
# execute it instead of grepping its source. `chezmoi execute-template` always reports the *host's*
# os/arch, so the guard conditions are rewritten to literal true/false first; everything else
# (branch balancing, `include`, `.chezmoi.sourceDir`) still goes through chezmoi's real engine,
# which is what makes an unbalanced if/end or a bad expansion show up here.
#
# --source pins the source dir to this repo so `include "dot_Brewfile"` resolves regardless of
# whether the machine running the tests has chezmoi initialised.
#
# Returns 1 without writing anything when chezmoi is unavailable, so callers can `skip`. CI's bats
# job installs chezmoi for exactly this reason (.github/workflows/ci.yml); the other helpers here
# stay dependency-free so they keep working without it.
_render_script_template() {
  local tmpl="$1" os="$2" arch="$3" out="$4"
  command -v chezmoi >/dev/null 2>&1 || return 1
  local is_darwin is_linux is_arm64
  if [ "$os" = "darwin" ]; then is_darwin=true; is_linux=false; else is_darwin=false; is_linux=true; fi
  if [ "$arch" = "arm64" ]; then is_arm64=true; else is_arm64=false; fi
  sed \
    -e "s/eq \.chezmoi\.os \"darwin\"/${is_darwin}/g" \
    -e "s/eq \.chezmoi\.os \"linux\"/${is_linux}/g" \
    -e "s/eq \.chezmoi\.arch \"arm64\"/${is_arm64}/g" \
    "$tmpl" | chezmoi execute-template --source "${HOME_DIR}" >"$out"
}

# Render a chezmoi *target* template (as opposed to the script templates above) to stdout.
#
# `chezmoi cat <target>` renders the same bytes, but it has to build the whole source state
# first: the 26 external declarations expand to ~1.3k managed paths, so every call costs
# ~16.4s where this one costs ~0.03s (#517 -- three tests spent 64.5s of a 329.5s `make test`
# between them). Verified byte-identical for AGENTS.md and both codex profiles before the
# swap.
#
# Use it whenever the assertion is about rendered *content*. It is NOT a drop-in for
# `chezmoi cat` when the point of the test is chezmoi's own target resolution -- source-path
# to target-path naming, .chezmoiignore exclusions, or attributes like private_ -- because
# it is handed the source file directly and never consults the target state.
#
# Returns 1 without output when chezmoi is unavailable, matching _render_script_template so
# callers can `skip`. stderr is deliberately not silenced: a template that fails to render
# should surface the reason rather than look like an empty file.
_render_target_template() {
  local tmpl="$1"
  command -v chezmoi >/dev/null 2>&1 || return 1
  chezmoi execute-template --source "${HOME_DIR}" <"$tmpl"
}

# Octal permission bits of a file or directory (e.g. 700), on both CI platforms.
#
# The obvious `stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"` chain is wrong on GNU: there
# `-f` means --file-system, so stat prints a multi-line filesystem report to stdout AND exits
# non-zero, and the command substitution ends up capturing that report concatenated with the
# fallback's output. Detect the implementation instead — only GNU stat understands --version.
_file_mode() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
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
