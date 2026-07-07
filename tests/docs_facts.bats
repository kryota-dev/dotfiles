#!/usr/bin/env bats

load helpers/setup

# Documentation freshness checks: keep the docs/ tree from silently drifting out of sync
# with the source it describes, the same way skill_provenance.bats keeps the skill taxonomy
# honest. Dependency-free on purpose — CI's bats job installs only bats/shellcheck/zsh (no
# chezmoi), so every assertion parses source with awk/grep.
#
# Scope is deliberately narrow: only IDENTITY facts that change on intentional restructuring
# are pinned. Volatile, Renovate-bumped values (tool versions, the ECC commit SHA, the
# externals total) are NOT asserted — they live as source pointers in the docs so a
# dependency bump never fails this suite. Load-bearing counts are wrapped in
# `<!-- FACT:name -->VALUE<!-- /FACT -->` markers, so only the numbers a human marked
# authoritative are pinned; everything else is implicitly illustrative.

@test "docs_facts: every <!-- FACT:ecc-skill-count --> marker matches the [ecc].skills length" {
  local actual
  actual="$(_ecc_skill_list | grep -c .)"
  [ "$actual" -ge 100 ] || {
    echo "sanity: [ecc].skills resolved to $actual (<100) — the extractor likely broke"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$actual" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:ecc-skill-count is $val but [ecc].skills has $actual entries"
        false
      }
    done < <(grep -oE 'FACT:ecc-skill-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:ecc-skill-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:ecc-skill-count markers found under ${DOCS_DIR} — the docs refactor regressed"
    false
  }
}

@test "docs_facts: every lifecycle script in home/ is documented in lifecycle-scripts.md" {
  local doc="${DOCS_DIR}/architecture/lifecycle-scripts.md"
  [ -f "$doc" ]
  local f slug
  for f in "${HOME_DIR}"/run_*.sh.tmpl; do
    [ -e "$f" ] || continue
    slug="$(basename "$f")"
    slug="${slug#run_once_}"
    slug="${slug#run_onchange_}"
    slug="${slug#before_}"
    slug="${slug#after_}"
    slug="${slug%.sh.tmpl}"
    grep -qF "$slug" "$doc" || {
      echo "lifecycle script '$slug' exists in home/ but is not documented in lifecycle-scripts.md"
      false
    }
  done
}

@test "docs_facts: every Makefile target is documented in contributing/local-dev.md" {
  local doc="${DOCS_DIR}/contributing/local-dev.md"
  [ -f "$doc" ]
  local t
  while IFS= read -r t; do
    # `all` is the meta default (-> help); it is not a user-facing command in the table.
    [ "$t" = "all" ] && continue
    grep -qF "\`${t}\`" "$doc" || {
      echo "Makefile target '$t' is not documented in local-dev.md"
      false
    }
  done < <(grep -oE '^[a-z][a-z-]*:' "${REPO_ROOT}/Makefile" | sed 's/:$//')
}

@test "docs_facts: every relative .md link in docs resolves to an existing file" {
  local f dir target broken=0
  while IFS= read -r f; do
    dir="$(dirname "$f")"
    while IFS= read -r target; do
      target="${target%%#*}" # drop #anchor
      [ -z "$target" ] && continue
      case "$target" in
      http://* | https://* | mailto:*) continue ;;
      esac
      case "$target" in
      *.md) ;;
      *) continue ;;
      esac
      # The OS resolves any ../ in the joined path at access time.
      [ -f "${dir}/${target}" ] || {
        echo "broken relative link in ${f#"${REPO_ROOT}/"}: ${target}"
        broken=1
      }
    done < <(grep -oE '\]\([^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
  done < <(find "${DOCS_DIR}" -name '*.md')
  [ "$broken" -eq 0 ]
}

@test "docs_facts: every <!-- FACT:curated-skill-count --> marker matches the curated skill dir count" {
  local actual
  actual="$(find "${HOME_DIR}/dot_agents/skills" -mindepth 1 -maxdepth 1 -type d | grep -c .)"
  [ "$actual" -ge 10 ] || {
    echo "sanity: curated skill dir count resolved to $actual (<10) — the layout likely moved"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$actual" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:curated-skill-count is $val but home/dot_agents/skills has $actual dirs"
        false
      }
    done < <(grep -oE 'FACT:curated-skill-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:curated-skill-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:curated-skill-count markers found under ${DOCS_DIR} — add them or drop this test"
    false
  }
}

@test "docs_facts: every EN doc has a .ja.md mirror and vice versa" {
  local f sibling missing=0
  while IFS= read -r f; do
    case "$f" in
    *.ja.md)
      sibling="${f%.ja.md}.md"
      [ -f "$sibling" ] || {
        echo "JA doc without an EN canonical sibling: ${f#"${REPO_ROOT}/"}"
        missing=1
      }
      ;;
    *.md)
      sibling="${f%.md}.ja.md"
      [ -f "$sibling" ] || {
        echo "EN doc without a JA mirror: ${f#"${REPO_ROOT}/"}"
        missing=1
      }
      ;;
    esac
  done < <(find "${DOCS_DIR}" -name '*.md')
  [ "$missing" -eq 0 ]
}
