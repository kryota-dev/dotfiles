#!/usr/bin/env bats

load helpers/setup

# Names declared external via the templated range over .chezmoidata.toml [ecc].skills.
# That range emits one [".agents/skills/<name>"] entry per list element, so a literal grep
# of .chezmoiexternal.toml (which only sees the `{{ $skill }}` template var) can't see the
# expanded names — resolve the list directly. Kept dependency-free on purpose: CI's bats
# job installs only bats/shellcheck/zsh, no chezmoi to render the template.
_ecc_skill_list() {
  awk '/^  skills = \[/{f=1;next} f&&/^  \]/{f=0} f' "${HOME_DIR}/.chezmoidata.toml" \
    | grep -oE '"[^"]+"' | tr -d '"'
}

# True if <name> is declared external: either a literal [".agents/skills/<name>..."] table
# header in .chezmoiexternal.toml, or an element of the [ecc].skills range source above.
_skill_is_external() {
  local name="$1"
  grep -Eq "^\[\"\.agents/skills/${name}(/|\")" "${HOME_DIR}/.chezmoiexternal.toml" 2>/dev/null && return 0
  _ecc_skill_list | grep -qFx "$name"
}

# Skill provenance enforcement (see ~/AGENTS.md "Skill provenance").
#
# Five categories:
#   curated   = home/dot_agents/skills/<name>/ (chezmoi SSOT, symlinked to each tool)
#   external  = declared in home/.chezmoiexternal.toml as [".agents/skills/<name>..."]
#   system    = ~/.agents/skills/.system/* (Anthropic-distributed; not ours)
#   evolved   = $CLV2_HOMUNCULUS_DIR/evolved/skills/* (CLV2; a separate location)
#   unmanaged = none of the above -> policy violation
#
# The source-side checks below are deterministic and run anywhere (CI included).
# The runtime check is informational: it only inspects ~/.agents/skills when present
# and never fails the suite (cleaning up leftover unmanaged skills is a runtime task).

# --- Deterministic source assertions ------------------------------------------

@test "skill provenance: agent-browser vendors only its discovery stub; specialized skills are CLI-served" {
  # Only the discovery stub is vendored (curated). It points the agent at
  # `agent-browser skills get <name>` for the version-matched specialized content.
  [ -f "${HOME_DIR}/dot_agents/skills/agent-browser/SKILL.md" ] || {
    echo "agent-browser discovery stub missing from source"
    false
  }
  # The specialized skills are loaded at runtime, not vendored (would go stale), and
  # their previously-deployed copies must be removed via .chezmoiremove.
  local s
  for s in electron slack dogfood; do
    [ ! -e "${HOME_DIR}/dot_agents/skills/${s}" ] || {
      echo "agent-browser skill '$s' should be CLI-served, not vendored in source"
      false
    }
    grep -qFx ".agents/skills/${s}" "${HOME_DIR}/.chezmoiremove" || {
      echo ".chezmoiremove is missing the runtime removal target for '$s'"
      false
    }
  done
}

@test "skill provenance: every curated skill dir in source is non-empty" {
  local dir name
  for dir in "${HOME_DIR}/dot_agents/skills"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    # Non-empty check (not strict structural validation): a skill must contain at
    # least one regular file. maxdepth 2 also counts files one level down
    # (references/, templates/), so discovery-only skills like wtp-workspace
    # (trigger-eval.json) and skills whose files live only in subdirs still pass.
    if [ -z "$(find "$dir" -maxdepth 2 -type f -print -quit)" ]; then
      echo "empty curated skill dir: $name"
      false
    fi
  done
}

@test "skill provenance: external skills are declared in .chezmoiexternal.toml" {
  [ -f "${HOME_DIR}/.chezmoiexternal.toml" ]
  # The ECC hook runtime must be declared as an external.
  grep -q '\.agents/skills/ecc' "${HOME_DIR}/.chezmoiexternal.toml" || {
    echo "ECC is not declared in .chezmoiexternal.toml"
    false
  }
  # Sanity: at least one [".agents/skills/<name>..."] external entry exists.
  # (<name> may carry a subpath such as ecc/scripts, hence the '/' in the class.)
  grep -qE '\[".agents/skills/[a-z0-9/_-]+' "${HOME_DIR}/.chezmoiexternal.toml" || {
    echo "no [\".agents/skills/...\"] external entries found"
    false
  }
}

@test "skill provenance: no skill is both curated and external" {
  local dir name
  for dir in "${HOME_DIR}/dot_agents/skills"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if _skill_is_external "$name"; then
      echo "skill '$name' is declared both curated (source) and external (.chezmoiexternal.toml / [ecc].skills)"
      false
    fi
  done
}

@test "skill provenance: AGENTS.md documents all five categories" {
  local agents="${HOME_DIR}/AGENTS.md.tmpl"
  grep -q 'Skill provenance' "$agents"
  local c
  for c in curated external system evolved unmanaged; do
    grep -q "\`${c}\`" "$agents" || {
      echo "AGENTS.md provenance policy missing category: $c"
      false
    }
  done
}

@test "skill provenance: retired unmanaged skills are absent from source" {
  # Removed as unmanaged in Phase 3-6; none should be curated back in by mistake.
  local s
  for s in agentcore vercel-sandbox patch-remote-control find-skills; do
    [ ! -e "${HOME_DIR}/dot_agents/skills/${s}" ] || {
      echo "unmanaged skill leaked into source: $s"
      false
    }
  done
}

@test "skill provenance: orphaned sdd-* agents are absent from source" {
  # Removed in Phase 4-1 (orphaned + active CLAUDE.md conflicts).
  local a
  for a in sdd-designer sdd-worker sdd-work-reviewer sdd-design-reviewer; do
    [ ! -e "${HOME_DIR}/dot_claude/agents/${a}.md" ] || {
      echo "orphaned agent still present: ${a}.md"
      false
    }
  done
}

@test "skill provenance: adopted ECC skills are range-declared external (no literal drift)" {
  # PR-A deploys the reconciled ECC skill set via a {{ range .ecc.skills }} block in
  # .chezmoiexternal.toml. Assert the mechanism is wired so the runtime classifier — which
  # resolves the [ecc].skills list, not the template text — stays correct.
  local n
  n="$(_ecc_skill_list | grep -c .)"
  [ "$n" -ge 100 ] || {
    echo "expected >=100 [ecc].skills entries, got $n"
    false
  }
  # The range entry must exist in .chezmoiexternal.toml, keyed on the template var.
  grep -qF '[".agents/skills/{{ $skill }}"]' "${HOME_DIR}/.chezmoiexternal.toml" || {
    echo "ECC skills range entry missing from .chezmoiexternal.toml"
    false
  }
  # No adopted ECC skill may also be curated in source (would double-manage the path:
  # chezmoi would try to both symlink the curated dir and external-fetch the same name).
  local s
  while IFS= read -r s; do
    [ ! -e "${HOME_DIR}/dot_agents/skills/${s}" ] || {
      echo "ECC skill '$s' collides with a curated skill of the same name"
      false
    }
  done < <(_ecc_skill_list)
}

# --- Informational runtime check ----------------------------------------------

@test "skill provenance: runtime ~/.agents/skills has no unmanaged skill (informational)" {
  local runtime="${HOME}/.agents/skills"
  [ -d "$runtime" ] || skip "runtime skills dir not deployed"

  local dir name unmanaged=()
  for dir in "$runtime"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    # curated: present in the chezmoi source tree
    [ -d "${HOME_DIR}/dot_agents/skills/${name}" ] && continue
    # external: a literal [".agents/skills/<name>"] / [".agents/skills/<name>/..."] table
    # header in .chezmoiexternal.toml, OR a [ecc].skills element fanned out by the range
    # (whose literal text is only `{{ $skill }}`). _skill_is_external covers both.
    _skill_is_external "$name" && continue
    # system (.system) is a dotfile and not matched by */ ; anything else is unmanaged
    unmanaged+=("$name")
  done

  if [ "${#unmanaged[@]}" -gt 0 ]; then
    echo "# informational: ${#unmanaged[@]} unmanaged runtime skill(s) to classify or remove:" >&3
    echo "#   ${unmanaged[*]}" >&3
  fi
  # Informational only: the deterministic source assertions above are the gate.
  return 0
}
