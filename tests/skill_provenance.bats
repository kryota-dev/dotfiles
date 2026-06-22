#!/usr/bin/env bats

load helpers/setup

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

@test "skill provenance: newly curated skills (electron, slack, dogfood) are in source" {
  local s
  for s in electron slack dogfood; do
    [ -f "${HOME_DIR}/dot_agents/skills/${s}/SKILL.md" ] || {
      echo "missing curated skill: dot_agents/skills/${s}/SKILL.md"
      false
    }
  done
}

@test "skill provenance: every curated skill dir in source is non-empty" {
  local dir name
  for dir in "${HOME_DIR}/dot_agents/skills"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    # A well-formed skill has at least one regular file (SKILL.md, or a
    # trigger-eval.json for discovery-only skills such as wtp-workspace).
    if [ -z "$(find "$dir" -maxdepth 2 -type f -print -quit)" ]; then
      echo "empty curated skill dir: $name"
      false
    fi
  done
}

@test "skill provenance: external skills are declared in .chezmoiexternal.toml" {
  [ -f "${HOME_DIR}/.chezmoiexternal.toml" ]
  # The ECC runtime and the Anthropic skill set are fetched as externals.
  grep -q '\.agents/skills/ecc' "${HOME_DIR}/.chezmoiexternal.toml"
  grep -qE '\[".agents/skills/[a-z0-9-]+' "${HOME_DIR}/.chezmoiexternal.toml"
}

@test "skill provenance: AGENTS.md documents all five categories" {
  local agents="${HOME_DIR}/AGENTS.md"
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
    # external: declared in .chezmoiexternal.toml (matches "ecc" in ".agents/skills/ecc/scripts" too)
    grep -q "\.agents/skills/${name}\b" "${HOME_DIR}/.chezmoiexternal.toml" 2>/dev/null && continue
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
