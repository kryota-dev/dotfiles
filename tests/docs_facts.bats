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

@test "docs_facts: every <!-- FACT:external-static-entry-count --> marker matches .chezmoiexternal.toml" {
  # The number of LITERAL external entries — the range-generated ECC skill entries are
  # excluded (their count is the volatile [ecc].skills length, pinned separately above).
  # This one drifted silently before it was pinned: drawio and supabase were added as
  # externals but the docs total stayed at its pre-existing value.
  local actual
  actual="$(grep -E '^\[".*"\]$' "${HOME_DIR}/.chezmoiexternal.toml" | grep -vF '{{' | grep -c .)"
  [ "$actual" -ge 10 ] || {
    echo "sanity: counted only $actual literal external entries (<10) — the extractor likely broke"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$actual" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:external-static-entry-count is $val but .chezmoiexternal.toml declares $actual literal entries"
        false
      }
    done < <(grep -oE 'FACT:external-static-entry-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:external-static-entry-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:external-static-entry-count markers found under ${DOCS_DIR} — the docs refactor regressed"
    false
  }
}

@test "docs_facts: every lifecycle script in home/ is documented in lifecycle-scripts.md (EN and JA)" {
  # Both mirrors are checked. The EN-only form let a script be documented in the canonical file
  # while the JA mirror silently lost it, which is exactly the parity the docs promise.
  local doc
  for doc in "${DOCS_DIR}/architecture/lifecycle-scripts.md" "${DOCS_DIR}/architecture/lifecycle-scripts.ja.md"; do
    [ -f "$doc" ]
    _assert_lifecycle_scripts_documented "$doc"
  done
}

_assert_lifecycle_scripts_documented() {
  local doc="$1"
  local f slug
  for f in "${HOME_DIR}"/run_*.sh.tmpl; do
    [ -e "$f" ] || continue
    slug="$(basename "$f")"
    # chezmoi's script attributes appear in a fixed order: run_, then an optional once_/onchange_,
    # then before_/after_. Peel them one at a time instead of matching whole combinations, so an
    # always-run script (run_before_NN-…, which carries no once_/onchange_) normalizes to the same
    # NN-slug shape as every other lifecycle script rather than leaking its raw filename into the
    # grep below. Peeling is a no-op for any attribute a given script does not use, so the derived
    # slug is unchanged for every pre-existing script.
    slug="${slug#run_}"
    slug="${slug#once_}"
    slug="${slug#onchange_}"
    slug="${slug#before_}"
    slug="${slug#after_}"
    slug="${slug%.sh.tmpl}"
    grep -qF "$slug" "$doc" || {
      echo "lifecycle script '$slug' exists in home/ but is not documented in ${doc##*/}"
      false
    }
  done
}

@test "docs_facts: the brew-bundle failure policy is documented in both mirrors" {
  # The policy that a partial brew bundle failure warns instead of aborting is the load-bearing
  # behaviour of the before phase; losing it from either mirror leaves the docs describing an
  # apply that stops on the first failed cask.
  local doc
  for doc in "${DOCS_DIR}/architecture/lifecycle-scripts.md" "${DOCS_DIR}/architecture/lifecycle-scripts.ja.md"; do
    [ -f "$doc" ]
    grep -qiE 'failure policy|失敗ポリシー' "$doc" || {
      echo "${doc##*/} does not document the brew-bundle failure policy"
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

# The markers above hold numbers, so they share a digit-only extractor. The model pin is a
# string, so it needs its own comparison: pull the value between the marker tags verbatim.
@test "docs_facts: every <!-- FACT:claude-model-pin --> marker matches settings.json .model" {
  # grep/sed rather than jq: the header above promises this suite stays dependency-free, and
  # CI's bats job installs only bats/shellcheck/zsh. A `skip` here would silently leave the
  # marker unguarded on any host without jq.
  local actual
  actual="$(grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]+"' "${HOME_DIR}/dot_claude/settings.json" | tail -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  [ -n "$actual" ] || {
    echo "sanity: settings.json has no \"model\" key — the pin moved or the file changed shape"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$actual" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:claude-model-pin is '$val' but settings.json pins '$actual'"
        false
      }
    done < <(grep -oE 'FACT:claude-model-pin -->[^<]+' "$f" | sed 's/.*-->//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  done < <(grep -rlF 'FACT:claude-model-pin' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:claude-model-pin markers found under ${DOCS_DIR} — add them or drop this test"
    false
  }
}

@test "docs_facts: every <!-- FACT:claude-agent-count --> marker matches the agent definition count" {
  local actual
  actual="$(find "${HOME_DIR}/dot_claude/agents" -maxdepth 1 -name '*.md' | grep -c .)"
  [ "$actual" -ge 5 ] || {
    echo "sanity: agent definition count resolved to $actual (<5) — the layout likely moved"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$actual" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:claude-agent-count is $val but home/dot_claude/agents has $actual definitions"
        false
      }
    done < <(grep -oE 'FACT:claude-agent-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:claude-agent-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:claude-agent-count markers found under ${DOCS_DIR} — add them or drop this test"
    false
  }
}

@test "docs_facts: every <!-- FACT:onepassword-vault-item-count --> marker matches the ITEMS array in validate-1password" {
  # SSOT: the ITEMS=(...) array in home/run_once_after_11-validate-1password.sh.tmpl.
  # _onepassword_item_list (helpers/setup.bash) parses it; this test ensures the docs
  # markers stay in sync with the script — adding/removing an op:// entry automatically
  # fails the test without touching this file.
  local expected
  expected="$(_onepassword_item_list | grep -c .)"
  [ "$expected" -ge 3 ] || {
    echo "sanity: _onepassword_item_list resolved to $expected (<3) — the extractor likely broke"
    false
  }
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$expected" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:onepassword-vault-item-count is $val but ITEMS array has $expected entries"
        false
      }
    done < <(grep -oE 'FACT:onepassword-vault-item-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:onepassword-vault-item-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:onepassword-vault-item-count markers found under ${DOCS_DIR} — add them to the secrets docs"
    false
  }
}

@test "docs_facts: every <!-- FACT:ci-both-exclusion-count --> marker matches the Ubuntu job exclusion count" {
  # SSOT: .github/workflows/setup-validation.yml (Ubuntu job's
  # "Exclude CI-incompatible files" step for f in \...; do block). Count is 7:
  # #337 added home/dot_config/ntfy/private_server.yml.tmpl on top of the earlier
  # 6 (PR #248 added private_gitleaks-own.toml.tmpl). The publisher-token
  # notify-env template that briefly pushed this to 8 was dropped once the setup
  # script began writing notify-env directly (runtime state, not a chezmoi target).
  # Update this constant AND every marker in docs/ when entries are added or removed.
  local expected=7
  local found=0 f val
  while IFS= read -r f; do
    while IFS= read -r val; do
      found=1
      [ "$val" = "$expected" ] || {
        echo "${f#"${REPO_ROOT}/"}: FACT:ci-both-exclusion-count is $val but expected $expected"
        false
      }
    done < <(grep -oE 'FACT:ci-both-exclusion-count[^0-9]*[0-9]+' "$f" | grep -oE '[0-9]+$')
  done < <(grep -rlF 'FACT:ci-both-exclusion-count' "${DOCS_DIR}")
  [ "$found" = 1 ] || {
    echo "no FACT:ci-both-exclusion-count markers found under ${DOCS_DIR} — add them to the CI docs"
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

@test "docs_facts: every <!-- FACT:fh-*-retention-days --> marker matches the shipped frontier-harness config" {
  # The two retention windows are load-bearing: `fh clean` deletes on them, and the
  # numbers live in both the shipped config and the docs. Pin the docs to the config
  # so a policy change cannot land with the prose left behind.
  local config="${HOME_DIR}/dot_config/frontier-harness/config.json"
  [ -f "$config" ] || {
    echo "missing ${config#"${REPO_ROOT}/"} — the frontier-harness config moved"
    false
  }

  local pair marker key actual found f val
  for pair in "fh-raw-retention-days:rawArtifactsDays" \
    "fh-telemetry-retention-days:aggregateTelemetryDays"; do
    marker="${pair%%:*}"
    key="${pair##*:}"
    actual="$(grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$config" | grep -oE '[0-9]+$')"
    [ -n "$actual" ] || {
      echo "sanity: could not read ${key} from ${config#"${REPO_ROOT}/"} — the extractor likely broke"
      false
    }
    found=0
    while IFS= read -r f; do
      while IFS= read -r val; do
        found=1
        [ "$val" = "$actual" ] || {
          echo "${f#"${REPO_ROOT}/"}: FACT:${marker} is $val but ${key} is $actual"
          false
        }
      done < <(grep -oE "FACT:${marker}[^0-9]*[0-9]+" "$f" | grep -oE '[0-9]+$')
    done < <(grep -rlF "FACT:${marker}" "${DOCS_DIR}")
    [ "$found" = 1 ] || {
      echo "no FACT:${marker} markers found under ${DOCS_DIR#"${REPO_ROOT}/"} — the docs refactor regressed"
      false
    }
  done
}
