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
    if grep -Eq "^\[\"\.agents/skills/${name}(/|\")" "${HOME_DIR}/.chezmoiexternal.toml" 2>/dev/null; then
      echo "skill '$name' is declared both curated (source) and external (.chezmoiexternal.toml)"
      false
    fi
  done
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
    # external: declared as a [".agents/skills/<name>"] or [".agents/skills/<name>/..."]
    # table header. Anchor to the path segment so a prefix name (e.g. "slack") is not
    # matched against a longer external entry ("slack-gif-creator").
    grep -Eq "^\[\"\.agents/skills/${name}(/|\")" "${HOME_DIR}/.chezmoiexternal.toml" 2>/dev/null && continue
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
