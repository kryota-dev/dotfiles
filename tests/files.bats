#!/usr/bin/env bats

load helpers/setup

@test "chezmoi source files exist: dot_zshrc.tmpl" {
  [ -f "${HOME_DIR}/dot_zshrc.tmpl" ]
}

@test "chezmoi source files exist: dot_zprofile.tmpl" {
  [ -f "${HOME_DIR}/dot_zprofile.tmpl" ]
}

@test "chezmoi source files exist: dot_gitconfig.tmpl" {
  [ -f "${HOME_DIR}/dot_gitconfig.tmpl" ]
}

@test "chezmoi source files exist: private_dot_ssh/config.tmpl" {
  [ -f "${HOME_DIR}/private_dot_ssh/config.tmpl" ]
}

@test "chezmoi source files exist: dot_vimrc" {
  [ -f "${HOME_DIR}/dot_vimrc" ]
}

@test "chezmoi source files exist: dot_tmux.conf" {
  [ -f "${HOME_DIR}/dot_tmux.conf" ]
}

@test "chezmoi source files exist: dot_inputrc" {
  [ -f "${HOME_DIR}/dot_inputrc" ]
}

@test "chezmoi source files exist: dot_Brewfile" {
  [ -f "${HOME_DIR}/dot_Brewfile" ]
}

@test "chezmoi source files exist: .chezmoiexternal.toml" {
  [ -f "${HOME_DIR}/.chezmoiexternal.toml" ]
}

@test "chezmoi source files exist: .chezmoidata.toml" {
  [ -f "${HOME_DIR}/.chezmoidata.toml" ]
}

@test "chezmoi source files exist: starship.toml" {
  [ -f "${HOME_DIR}/dot_config/starship.toml" ]
}

@test "chezmoi source files exist: ghostty config" {
  [ -f "${HOME_DIR}/dot_config/ghostty/config" ]
}

@test "chezmoi source files exist: sheldon plugins.toml" {
  [ -f "${HOME_DIR}/dot_config/sheldon/plugins.toml" ]
}

@test "zsh modules exist" {
  local modules=(git docker claude codex dmux functions completions wtp ghq)
  for mod in "${modules[@]}"; do
    [ -f "${HOME_DIR}/dot_config/zsh/${mod}.zsh" ]
  done
  # aliases.zsh is now a chezmoi template
  [ -f "${HOME_DIR}/dot_config/zsh/aliases.zsh.tmpl" ]
}

@test "chezmoi source files exist: dot_config/zsh/completions/_ghq" {
  [ -f "${HOME_DIR}/dot_config/zsh/completions/_ghq" ]
}

@test "ghq zsh completion has compdef directive on first line" {
  head -n1 "${HOME_DIR}/dot_config/zsh/completions/_ghq" | grep -q '^#compdef ghq'
}

@test "lifecycle scripts exist" {
  [ -f "${HOME_DIR}/run_once_before_00-install-prerequisites.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_before_10-brew-bundle.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_after_20-macos-defaults.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_after_40-setup-sheldon.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_16-migrate-claude-binary.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_50-set-login-shell.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_90-other-apps.sh.tmpl" ]
}

@test "prerequisites installs Rosetta 2 behind an arm64 guard" {
  local tmpl="${HOME_DIR}/run_once_before_00-install-prerequisites.sh.tmpl"
  # Installs Rosetta 2 non-interactively (Intel-only casks need it).
  grep -Fq 'softwareupdate --install-rosetta --agree-to-license' "$tmpl"
  # Idempotent: skips when x86_64 binaries already run (Rosetta present).
  grep -Fq 'arch -x86_64' "$tmpl"
  # The install must sit inside an arm64 template guard, not just anywhere: the
  # Homebrew shellenv block also opens an arm64 guard, so a bare grep for the
  # guard string would pass even if the Rosetta block lost its own guard.
  awk '
    /\{\{ if eq \.chezmoi\.arch "arm64" -\}\}/ { guard = 1; next }
    /\{\{ (else|end)/ { guard = 0 }
    /softwareupdate --install-rosetta/ && guard { inside = 1 }
    END { exit !inside }
  ' "$tmpl"
}

@test "claude agents exist" {
  [ -d "${HOME_DIR}/dot_claude/agents" ]
  local count
  count=$(find "${HOME_DIR}/dot_claude/agents" -name "*.md" | wc -l)
  [ "$count" -gt 0 ]
}

@test "language specialist reviewer agents exist with expected frontmatter" {
  local lang agent
  for lang in typescript react python database; do
    agent="${HOME_DIR}/dot_claude/agents/${lang}-reviewer.md"
    [ -f "$agent" ]
    grep -q "^name: ${lang}-reviewer$" "$agent"
    grep -q "^model: sonnet$" "$agent"
    grep -q "^tools: Read, Glob, Grep, Bash$" "$agent"
  done
}

@test "reviewer agents steer to a valid gh pr diff filter idiom" {
  # gh pr diff has no include pathspec (only --exclude / --name-only), so every
  # reviewer agent must reference --name-only rather than the unsupported
  # `gh pr diff <n> -- <path>` form. Positive guard (the docs mention the bad form
  # only as a counter-example, so a negative grep would false-positive on it).
  local agent
  for agent in "${HOME_DIR}/dot_claude/agents"/{cc-code-review,typescript-reviewer,react-reviewer,python-reviewer,database-reviewer}.md; do
    grep -q -- "--name-only" "$agent"
  done
}

@test "shared agent skills exist" {
  [ -d "${HOME_DIR}/dot_agents/skills" ]
  local count
  count=$(find "${HOME_DIR}/dot_agents/skills" -type d -mindepth 1 | wc -l)
  [ "$count" -gt 0 ]
}

@test "retrospective-codify skill exists with valid frontmatter and structure" {
  local skill="${HOME_DIR}/dot_agents/skills/retrospective-codify/SKILL.md"
  [ -f "$skill" ]
  # Frontmatter delimiter on line 1, name matches the directory.
  head -n1 "$skill" | grep -q '^---$'
  grep -q '^name: retrospective-codify$' "$skill"
  grep -q '^description:' "$skill"
  grep -q '^argument-hint:' "$skill"
  # Args were split into --range/--target (the old --scope was overloaded).
  grep -q -- '--range=' "$skill"
  grep -q -- '--target=' "$skill"
  # Core sections are present.
  grep -q '## 実行フロー' "$skill"
}

@test "claude and codex skills are symlinked" {
  [ -f "${HOME_DIR}/dot_claude/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex/symlink_skills.tmpl" ]
}

@test "pr-workflow orchestrator skill exists with tier paths and gates" {
  local skill="${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
  [ -f "$skill" ]
  head -n1 "$skill" | grep -q '^---$'
  grep -q '^name: pr-workflow$' "$skill"
  grep -q '^argument-hint:' "$skill"
  grep -q '^user-invocable: true$' "$skill"
  # The four size tiers, the operation variants, and the three gates.
  local t
  for t in trivial small standard large; do grep -q "$t" "$skill"; done
  grep -q 'add-feature' "$skill"
  grep -q 'GATE 1' "$skill"; grep -q 'GATE 2' "$skill"; grep -q 'GATE 3' "$skill"
  # Merge stays the user's action; never auto-merge.
  grep -q '自動マージしない' "$skill"
  ! grep -q '自動マージする' "$skill"
  # Must not reference the removed sdd-worker agent (Phase 4-1, task #25).
  ! grep -q 'sdd-worker' "$skill"
  # Referenced curated skills that this orchestrator delegates to must exist.
  local s
  for s in sdd multi-review review-resolve-loop monitor-ci grill-me commit create-pr planning; do
    [ -f "${HOME_DIR}/dot_agents/skills/${s}/SKILL.md" ] || { echo "delegated skill missing: $s"; return 1; }
  done
  # tdd-workflow / santa-method are described as inline protocols, not skills;
  # they must NOT be referenced as if they were invokable curated skills.
  [ ! -d "${HOME_DIR}/dot_agents/skills/tdd-workflow" ]
  [ ! -d "${HOME_DIR}/dot_agents/skills/santa-method" ]
}

@test "Plan-PRD pipeline flags are wired into grill-me / planning / sdd (opt-in)" {
  local skills="${HOME_DIR}/dot_agents/skills"
  # grill-me emits the PRD; planning consumes it and emits the Plan; sdd
  # optionally consumes either or both (--prd / --plan are independent opt-ins).
  grep -q -- '--output-prd' "${skills}/grill-me/SKILL.md"
  grep -q -- '--input-prd' "${skills}/planning/SKILL.md"
  grep -q -- '--output-plan' "${skills}/planning/SKILL.md"
  grep -q -- '--prd' "${skills}/sdd/SKILL.md"
  grep -q -- '--plan' "${skills}/sdd/SKILL.md"
  grep -q -- '--mode' "${skills}/grill-me/SKILL.md"
  grep -q -- '--mode' "${skills}/planning/SKILL.md"
  # Each must declare the flags are opt-in (default behaviour preserved).
  grep -q '任意 / opt-in' "${skills}/grill-me/SKILL.md"
  grep -q '任意 / opt-in' "${skills}/planning/SKILL.md"
  grep -q '任意 / opt-in' "${skills}/sdd/SKILL.md"
  # Pipeline contract: PRD/Plan frontmatter + no-overwrite collision handling.
  grep -q 'grill_session:' "${skills}/grill-me/SKILL.md"
  grep -q 'planning_session:' "${skills}/planning/SKILL.md"
  grep -q '上書きしない\|上書き禁止' "${skills}/grill-me/SKILL.md"
  grep -q '上書きしない\|上書き禁止' "${skills}/planning/SKILL.md"
}

# The pipeline Plan (<slug>.plan.md) must be git-trackable while ad-hoc
# timestamp plans stay ignored — the handoff artifact would break otherwise.
@test "Plan-PRD pipeline plans are un-ignored in the global gitignore" {
  local gi="${HOME_DIR}/dot_gitignore_global"
  local tmp; tmp=$(mktemp -d)
  cd "$tmp"
  git init -q
  git config core.excludesfile "$gi"
  mkdir -p .claude/plans
  touch .claude/plans/20260101_adhoc.md .claude/plans/feat.plan.md
  # ad-hoc timestamp plan stays ignored, pipeline .plan.md is tracked.
  # Capture with && || so a non-zero check-ignore does not abort the test.
  local adhoc_ignored plan_ignored
  git check-ignore -q .claude/plans/20260101_adhoc.md && adhoc_ignored=yes || adhoc_ignored=no
  git check-ignore -q .claude/plans/feat.plan.md && plan_ignored=yes || plan_ignored=no
  cd "$REPO_ROOT"
  rm -rf "$tmp"
  [ "$adhoc_ignored" = yes ]
  [ "$plan_ignored" = no ]
}

@test "codex-r06 work profile sources exist" {
  [ -f "${HOME_DIR}/dot_codex-r06/symlink_AGENTS.md.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/private_shared.config.toml.tmpl" ]
}

@test "codex shared config SSOT exists" {
  [ -f "${HOME_DIR}/.chezmoitemplates/codex-shared-config.toml" ]
  [ -f "${HOME_DIR}/dot_codex/private_shared.config.toml.tmpl" ]
}

@test "claude-r06 work profile symlinks exist" {
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_CLAUDE.md.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_settings.json.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_agents.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_statusline.sh.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_commands.tmpl" ]
}

@test "aside command is fetched from ECC via chezmoi external and delivered to r06" {
  local ext="${HOME_DIR}/.chezmoiexternal.toml"
  # The aside command is referenced (not vendored): a chezmoi external file entry
  # targeting ~/.claude/commands/aside.md, fetched verbatim from ECC. Verbatim
  # external fetch means this public repo references rather than redistributes
  # the file, so it is NOT committed under home/dot_claude/commands/.
  [ ! -e "${HOME_DIR}/dot_claude/commands/aside.md" ]
  grep -q '\[".claude/commands/aside.md"\]' "$ext"
  grep -q 'raw.githubusercontent.com/affaan-m/ECC' "$ext"
  grep -q 'commands/aside.md' "$ext"
  # Pinned to the shared ECC commit (version-locked with the hook runtime), not a
  # mutable branch/tag.
  grep -q '{{ .ecc.commit }}/commands/aside.md' "$ext"
  # r06 work profile shares the commands dir via a symlink that points at the
  # DEFAULT profile (exact match: a self-referential ~/.claude-r06/commands
  # target would loop, and a loose grep would not catch it).
  [ "$(cat "${HOME_DIR}/dot_claude-r06/symlink_commands.tmpl")" = '{{ .chezmoi.homeDir }}/.claude/commands' ]
}

@test "claude statusline script exists" {
  [ -f "${HOME_DIR}/dot_claude/executable_statusline.sh" ]
}

@test "ecc hook launcher script exists" {
  [ -f "${HOME_DIR}/dot_claude/executable_ecc-hook.sh" ]
}

@test "settings.json suppresses AI attribution (Claude Code + happy) so no signatures leak" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # `attribution.commit`/`.pr` empty → Claude Code's own "Generated with…" + Co-Authored-By
  # trailer is suppressed. `includeCoAuthoredBy: false` is ALSO required: happy-cli reads only
  # this key from $CLAUDE_CONFIG_DIR/settings.json (not attribution, not project settings.local)
  # and defaults to true when absent — dropping it re-enables happy's "via [Happy]" commit
  # signature injection. Both keys must stay present; this guards against that regression.
  jq -e '.includeCoAuthoredBy == false' "$s" >/dev/null
  jq -e '.attribution.commit == "" and .attribution.pr == ""' "$s" >/dev/null
}

@test "settings.json wires the CLV2 observer as direct observe.sh hooks (pre + post)" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Structural assertion (not a substring grep): exactly one pre + one post observe entry,
  # each matcher "*", a command-type hook, async, timeout 10, invoking observe.sh directly
  # with the right phase — and NOT observe-runner.js (which can't resolve observe.sh under
  # this layout and would silently no-op).
  jq -e '
    [.hooks.PreToolUse[] | select(.id=="pre:observe:continuous-learning")] as $m
    | ($m|length)==1
      and $m[0].matcher=="*"
      and $m[0].hooks[0].type=="command"
      and $m[0].hooks[0].async==true
      and $m[0].hooks[0].timeout==10
      and ($m[0].hooks[0].command|endswith("/continuous-learning-v2/hooks/observe.sh pre"))
      and ($m[0].hooks[0].command|contains("observe-runner")|not)
  ' "$s" >/dev/null
  jq -e '
    [.hooks.PostToolUse[] | select(.id=="post:observe:continuous-learning")] as $m
    | ($m|length)==1
      and $m[0].matcher=="*"
      and $m[0].hooks[0].type=="command"
      and $m[0].hooks[0].async==true
      and $m[0].hooks[0].timeout==10
      and ($m[0].hooks[0].command|endswith("/continuous-learning-v2/hooks/observe.sh post"))
      and ($m[0].hooks[0].command|contains("observe-runner")|not)
  ' "$s" >/dev/null
}

@test "clv2 observer enable script is present and idempotently forces observer.enabled" {
  local script="${HOME_DIR}/run_onchange_after_14-enable-clv2-observer.sh.tmpl"
  [ -f "$script" ]
  bash -n "$script"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d)
  # Pin XDG_DATA_HOME inside the sandbox so the bare-`claude` fallback branch can never
  # touch the developer's real ~/.local/share/ecc-homunculus.
  local run=(env "HOME=$tmp" "XDG_DATA_HOME=$tmp/.local/share" bash "$script")
  # Seed a pre-existing config (disabled + unrelated keys) to exercise the jq-merge branch:
  # it must force enabled=true while preserving every other field, and stay stable on re-run.
  mkdir -p "$tmp/.claude/ecc-homunculus"
  printf '%s' '{"version":"2.1","observer":{"enabled":false,"run_interval_minutes":7},"custom":42}' \
    > "$tmp/.claude/ecc-homunculus/config.json"
  "${run[@]}" >/dev/null 2>&1
  "${run[@]}" >/dev/null 2>&1
  local cfg="$tmp/.claude/ecc-homunculus/config.json"
  [ "$(jq -r '.observer.enabled' "$cfg")" = "true" ]
  [ "$(jq -r '.observer.run_interval_minutes' "$cfg")" = "7" ]
  [ "$(jq -r '.custom' "$cfg")" = "42" ]
  # Fresh-write branch: an account dir with no prior config gets a fully-formed enabled config.
  mkdir -p "$tmp/.claude-r06"
  "${run[@]}" >/dev/null 2>&1
  [ "$(jq -r '.observer.enabled' "$tmp/.claude-r06/ecc-homunculus/config.json")" = "true" ]
  # Bare-`claude` fallback: not created speculatively, but enabled once it exists.
  [ ! -e "$tmp/.local/share/ecc-homunculus/config.json" ]
  mkdir -p "$tmp/.local/share/ecc-homunculus"
  "${run[@]}" >/dev/null 2>&1
  [ "$(jq -r '.observer.enabled' "$tmp/.local/share/ecc-homunculus/config.json")" = "true" ]
  rm -rf "$tmp"
}

@test "ecc governance-capture fork exists and passes node syntax check" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  [ -f "$fork" ]
  node --check "$fork"
}

# Regression guard: a bare process.exit() after stdout.write() truncates output
# larger than the OS pipe buffer (~64 KB), which would corrupt PostToolUse
# pass-through of large tool_response payloads. The fork must pass input through
# byte-for-byte regardless of size. No ECC runtime needed (a benign tool yields
# zero events, so the hook only passes stdin through).
@test "ecc governance-capture fork passes large input through without truncation" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  local tmp; tmp=$(mktemp -d)
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/x"},tool_response:"A".repeat(200000)}))' > "$tmp/in.json"
  local in_bytes out_bytes
  in_bytes=$(wc -c < "$tmp/in.json")
  out_bytes=$(ECC_GOVERNANCE_CAPTURE=1 ECC_AGENT_DATA_HOME="$tmp" node "$fork" < "$tmp/in.json" 2>/dev/null | wc -c)
  rm -rf "$tmp"
  [ "$in_bytes" -gt 65536 ]
  [ "$in_bytes" -eq "$out_bytes" ]
}

# Functional smoke: with the ECC runtime present and node:sqlite available, a
# governance-relevant tool call must persist a row to the per-account state.db.
# Skips in minimal CI (no ECC external / older Node without node:sqlite).
@test "ecc governance-capture fork persists an event to state.db" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  local ecc="${HOME}/.agents/skills/ecc/scripts/hooks/governance-capture.js"
  [ -f "$ecc" ] || skip "ECC external runtime not deployed"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main --force"},"session_id":"bats-gov"}' \
    | CLAUDE_PLUGIN_ROOT="${HOME}/.agents/skills/ecc" ECC_GOVERNANCE_CAPTURE=1 ECC_AGENT_DATA_HOME="$tmp" node "$fork" >/dev/null 2>&1
  local count
  count=$(node -e 'const{DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});process.stdout.write(String(db.prepare("SELECT count(*) c, session_id s FROM governance_events").get().c));db.close()' "$tmp/ecc/state.db" 2>/dev/null)
  rm -rf "$tmp"
  [ "$count" -ge 1 ]
}

@test "ecc post-bash-command-log fork exists and passes node syntax check" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  [ -f "$fork" ]
  node --check "$fork"
}

@test "ecc-state-reader aggregates pending governance events from a sandbox state.db" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  [ -f "$reader" ]
  node --check "$reader"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/ecc"
  # Seed 2 pending + 1 resolved event; the reader must count only the 2 pending ones.
  node -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});
    db.exec("CREATE TABLE governance_events(id TEXT PRIMARY KEY, session_id TEXT, event_type TEXT NOT NULL, payload TEXT NOT NULL, resolved_at TEXT, resolution TEXT, created_at TEXT NOT NULL)");
    const ins=db.prepare("INSERT INTO governance_events(id,session_id,event_type,payload,resolved_at,created_at) VALUES(?,?,?,?,?,?)");
    ins.run("1","s","approval_requested","{}",null,"2026-01-01T01:00:00Z");
    ins.run("2","s","secret_detected","{}",null,"2026-01-01T02:00:00Z");
    ins.run("3","s","approval_requested","{}","2026-01-01T03:00:00Z","2026-01-01T00:30:00Z");
    db.close();
  ' "$tmp/ecc/state.db"
  local out
  out=$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" status --json)
  [ "$(echo "$out" | jq -r '.pendingGovernanceEvents')" = "2" ]
  [ "$(echo "$out" | jq -r '[.governanceByType[].c] | add')" = "2" ]
  # sessions / work-items tables are absent in this sandbox → graceful empty, never a crash.
  [ "$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" sessions)" = "No sessions recorded." ]
  [ "$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" work-items)" = "No work items." ]
  rm -rf "$tmp"
}

@test "ecc-state-reader is graceful when state.db is absent and creates nothing" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  run env "ECC_AGENT_DATA_HOME=$tmp" node "$reader" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No state.db"* ]]
  # A read-only CLI must never materialize a database on a fresh account.
  [ ! -e "$tmp/ecc/state.db" ]
  rm -rf "$tmp"
}

@test "ecc-state-reader counts only non-closed work items (ECC status domain)" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d); mkdir -p "$tmp/ecc"
  # Only "open" is non-closed; resolved/merged/done/cancelled are all closed in ECC's domain.
  node -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});
    db.exec("CREATE TABLE work_items(id TEXT PRIMARY KEY, source TEXT NOT NULL, source_id TEXT, title TEXT NOT NULL, status TEXT NOT NULL, priority TEXT, url TEXT, owner TEXT, repo_root TEXT, session_id TEXT, metadata TEXT, created_at TEXT, updated_at TEXT NOT NULL)");
    const ins=db.prepare("INSERT INTO work_items(id,source,title,status,updated_at) VALUES(?,?,?,?,?)");
    for (const [id,st] of [["w1","open"],["w2","resolved"],["w3","merged"],["w4","done"],["w5","cancelled"]]) ins.run(id,"gh",id,st,"2026-01-01");
    db.close();
  ' "$tmp/ecc/state.db"
  local out; out=$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" status --json)
  [ "$(echo "$out" | jq -r '.openWorkItems')" = "1" ]
  rm -rf "$tmp"
}

@test "ecc-state-reader rejects an unknown subcommand with exit 2 even on a fresh account" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  # No state.db: validation must still fire before the graceful "no db" path.
  run env "ECC_AGENT_DATA_HOME=$tmp" node "$reader" bogus-subcommand
  [ "$status" -eq 2 ]
  rm -rf "$tmp"
}

@test "claude.zsh defines the ecc-* reader functions" {
  grep -q 'ecc-status()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-sessions()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-work-items()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-state-reader.js' "${HOME_DIR}/dot_config/zsh/claude.zsh"
}

# Regression guard: a bare process.exit() after stdout.write() truncates output
# larger than the OS pipe buffer (~64 KB). The fork must pass the PostToolUse Bash
# payload through byte-for-byte regardless of size. No ECC runtime needed (logging
# is best-effort; the pass-through is unconditional).
@test "ecc post-bash-command-log fork passes large input through without truncation" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  local tmp; tmp=$(mktemp -d)
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"echo "+"A".repeat(200000)}}))' > "$tmp/in.json"
  ECC_AGENT_DATA_HOME="$tmp" node "$fork" audit < "$tmp/in.json" > "$tmp/out.json" 2>/dev/null
  local in_bytes; in_bytes=$(wc -c < "$tmp/in.json")
  # Byte-exact pass-through: input exceeds the OS pipe buffer AND output is identical
  # (cmp catches reordering/corruption that an equal byte count would miss).
  run cmp "$tmp/in.json" "$tmp/out.json"
  local cmp_status=$status
  rm -rf "$tmp"
  [ "$in_bytes" -gt 65536 ]
  [ "$cmp_status" -eq 0 ]
}

# Functional smoke: with the ECC runtime present, the fork appends a sanitized, 0600
# line to the per-account bash-commands.log resolved via getClaudeDir()
# (ECC_AGENT_DATA_HOME), proving account isolation (task #11) — not the hardcoded
# ~/.claude of the ECC original — and that extraRedact() strips a secret ECC's own
# sanitizer misses. Assertions are split so a failure pinpoints which guarantee broke.
# Skips in minimal CI (no ECC external deployed).
@test "ecc post-bash-command-log fork appends a redacted 0600 line to the per-account log" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  local ecc="${HOME}/.agents/skills/ecc/scripts/hooks/post-bash-command-log.js"
  [ -f "$ecc" ] || skip "ECC external runtime not deployed"
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/bash-commands.log"
  # AWS_SECRET_ACCESS_KEY=... is a secret shape ECC's sanitizeCommand does not catch;
  # extraRedact() must strip it before the line is written.
  printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"AWS_SECRET_ACCESS_KEY=abcdEFGH1234 aws s3 ls"}}' \
    | CLAUDE_PLUGIN_ROOT="${HOME}/.agents/skills/ecc" ECC_AGENT_DATA_HOME="$tmp" node "$fork" audit >/dev/null 2>&1
  local file_exists=0 has_cmd=0 secret_leaked=0 perms=""
  [ -f "$log" ] && file_exists=1
  grep -q 'aws s3 ls' "$log" 2>/dev/null && has_cmd=1
  grep -q 'abcdEFGH1234' "$log" 2>/dev/null && secret_leaked=1
  perms=$(stat -f '%Lp' "$log" 2>/dev/null || stat -c '%a' "$log" 2>/dev/null)
  rm -rf "$tmp"
  [ "$file_exists" -eq 1 ]   # account-aware log created under ECC_AGENT_DATA_HOME
  [ "$has_cmd" -eq 1 ]       # command recorded
  [ "$secret_leaked" -eq 0 ] # extraRedact stripped the secret env value
  [ "$perms" = "600" ]       # owner-only permissions
}

@test "1password-backed secret template exists" {
  [ -f "${HOME_DIR}/private_dot_aws/config.tmpl" ]
}

@test "1password validation script exists" {
  [ -f "${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl" ]
}

@test "mise config exists" {
  [ -f "${HOME_DIR}/dot_config/mise/config.toml" ]
}

@test "mise setup script exists" {
  [ -f "${HOME_DIR}/run_onchange_after_12-setup-mise.sh.tmpl" ]
}

@test "mise config declares dmux as a pinned npm-backed CLI" {
  local config="${HOME_DIR}/dot_config/mise/config.toml"
  # dmux backs the dmux-workflows skill; provisioned via the npm backend. The trailing
  # quote pins a fixed SemVer core (X.Y.Z) — ranges and pre-releases are intentionally
  # rejected so mise resolves a single immutable version. The leading [[:space:]]* keeps
  # the guard robust if the key is ever indented under [tools].
  grep -Eq '^[[:space:]]*"npm:dmux"[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$config"
}

@test "mcp setup registers all servers as user scope for every account config dir" {
  local script="${HOME_DIR}/run_onchange_after_13-setup-mcp.sh.tmpl"
  [ -f "$script" ]
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  # Fake mise that emulates `mise exec -- <cmd...>` by logging the wrapped command together
  # with the CLAUDE_CONFIG_DIR it ran under. Lets us assert the script's real behaviour
  # (per-account loop + --scope user) instead of just matching strings in the source.
  cat >"$tmp/bin/mise" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "exec" ] && [ "$2" = "--" ]; then
  shift 2
  printf '%s ::: %s\n' "${CLAUDE_CONFIG_DIR:-NONE}" "$*" >>"$MISE_FAKE_LOG"
fi
exit 0
FAKE
  chmod +x "$tmp/bin/mise"

  run env HOME="$tmp/home" PATH="$tmp/bin:$PATH" MISE_FAKE_LOG="$tmp/log" \
    bash "$script"
  [ "$status" -eq 0 ]

  # Every server is add-json'd with user scope for both account config dirs. The trailing
  # " :::" anchors ".claude" so it does not also match ".claude-r06".
  local d name
  for d in '\.claude' '\.claude-r06'; do
    for name in context7 deepwiki exa firecrawl; do
      grep -qE "/home/${d} ::: claude mcp add-json ${name} .* --scope user" "$tmp/log"
    done
  done

  # exa/firecrawl carry the literal env placeholder (expanded by Claude Code at spawn, never
  # baked here): the ${EXA_API_KEY} / ${FIRECRAWL_API_KEY} text must survive verbatim into the
  # logged add-json invocation.
  grep -qF '"EXA_API_KEY":"${EXA_API_KEY}"' "$tmp/log"
  grep -qF '"FIRECRAWL_API_KEY":"${FIRECRAWL_API_KEY}"' "$tmp/log"

  # The key-bearing servers are version-pinned to shrink the npx supply-chain surface.
  grep -qE 'exa-mcp-server@[0-9]+\.[0-9]+\.[0-9]+' "$tmp/log"
  grep -qE 'firecrawl-mcp@[0-9]+\.[0-9]+\.[0-9]+' "$tmp/log"
}

@test "mcp setup script declares valid JSON server configs" {
  local script="${HOME_DIR}/run_onchange_after_13-setup-mcp.sh.tmpl"
  local json count=0
  # Each server config is a single-quoted JSON literal; ensure every one parses.
  while IFS= read -r json; do
    [ -n "$json" ] || continue
    echo "$json" | jq -e . >/dev/null
    count=$((count + 1))
  done < <(grep -oE "'\{[^']*\}'" "$script" | tr -d "'")
  [ "$count" -ge 4 ]
}

@test "claude MCP secrets are a private 1Password template, never committed in clear" {
  # The keys are rendered from 1Password into a 0600 file; the source must be a private_
  # template that reads via onepasswordRead and must not contain a literal key.
  local tmpl="${HOME_DIR}/dot_config/zsh/private_claude-secrets.zsh.tmpl"
  [ -f "$tmpl" ]
  grep -q 'onepasswordRead' "$tmpl"
  grep -qE 'EXA_API_KEY=.*onepasswordRead' "$tmpl"
  grep -qE 'FIRECRAWL_API_KEY=.*onepasswordRead' "$tmpl"
  # Not exported in the secrets file (scoping is done by _claude_with_home).
  ! grep -qE '^export ' "$tmpl"
}

@test "claude.zsh sources the MCP secrets and scopes the keys to the claude subprocess" {
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  # Sourced only when present, so a machine without the 1Password items still works.
  grep -qF 'claude-secrets.zsh' "$zsh"
  grep -qE '\[\[ -r .* \]\] && source' "$zsh"
  # _claude_with_home re-exports both keys (with :- defaults) into the launched command's env.
  grep -qE 'EXA_API_KEY="\$\{EXA_API_KEY:-\}"' "$zsh"
  grep -qE 'FIRECRAWL_API_KEY="\$\{FIRECRAWL_API_KEY:-\}"' "$zsh"
}

@test "claude.zsh injects MCP keys into the subprocess but not the parent shell" {
  command -v zsh >/dev/null || skip "zsh not available"
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.config/zsh"
  # Stand in for the 1Password-rendered secrets file (non-exported assignments, single-quoted).
  cat >"$tmp/.config/zsh/claude-secrets.zsh" <<'SECRETS'
EXA_API_KEY='exa-test-key'
FIRECRAWL_API_KEY='fc-test-key'
SECRETS

  # -f: no rc files. Source claude.zsh, then check (a) the keys do NOT leak into the parent
  # shell's exported env, and (b) they DO reach a subprocess launched via _claude_with_home.
  run zsh -fc "
    export HOME='$tmp'
    source '$zsh'
    printf 'PARENT_EXA=[%s]\n' \"\$(printenv EXA_API_KEY)\"
    printf 'SUB_EXA=[%s]\n' \"\$(_claude_with_home '$tmp' printenv EXA_API_KEY)\"
    printf 'SUB_FC=[%s]\n' \"\$(_claude_with_home '$tmp' printenv FIRECRAWL_API_KEY)\"
  "
  [ "$status" -eq 0 ]
  # Non-exported in the parent: printenv finds nothing.
  echo "$output" | grep -qF 'PARENT_EXA=[]'
  # Exported (scoped) into the subprocess: the values come through.
  echo "$output" | grep -qF 'SUB_EXA=[exa-test-key]'
  echo "$output" | grep -qF 'SUB_FC=[fc-test-key]'
}

@test "1Password validation requires the exa and firecrawl API keys" {
  local script="${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
  grep -qF 'op://kryota.dev/Dotfiles - Exa API/credential' "$script"
  grep -qF 'op://kryota.dev/Dotfiles - Firecrawl API/credential' "$script"
}

@test "project .mcp.json keeps only project-scoped servers" {
  # context7/deepwiki were moved to user scope (run_onchange_after_13); the repo's own
  # .mcp.json must keep the project-specific spec-workflow but no longer declare them.
  local mcp="${REPO_ROOT}/.mcp.json"
  [ -f "$mcp" ]
  grep -q 'spec-workflow' "$mcp"
  ! grep -q 'context7' "$mcp"
  ! grep -q 'deepwiki' "$mcp"
}

@test "bootstrap script exists" {
  [ -f "${REPO_ROOT}/install/install.sh" ]
}

@test "chezmoi source files exist: VS Code settings.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/settings.json" ]
}

@test "chezmoi source files exist: VS Code keybindings.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/keybindings.json" ]
}

# --- Cross-harness gateguard: Codex PreToolUse Bash gate (task #26) ---

@test "codex cross-harness gateguard script exists and passes node syntax check" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  [ -f "$gate" ]
  node --check "$gate"
}

@test "codex hooks.json registers the gateguard as a PreToolUse Bash hook for both accounts" {
  local shared="${HOME_DIR}/.chezmoitemplates/codex-hooks.json"
  [ -f "$shared" ]
  # Shared template is valid JSON once the homeDir placeholder is filled.
  HOME_RENDER="/home/test" \
    node -e 'const fs=require("fs");let s=fs.readFileSync(process.argv[1],"utf8").replace(/\{\{[^}]*\}\}/g,process.env.HOME_RENDER+"/.config/gateguard/codex-bash-gate.js");const j=JSON.parse(s);const m=j.hooks.PreToolUse[0];if(m.matcher!=="^Bash$")throw new Error("matcher");if(m.hooks[0].type!=="command")throw new Error("type");if(!/codex-bash-gate\.js/.test(m.hooks[0].command))throw new Error("command")' "$shared"
  # Both accounts include the shared template (config.toml itself is unmanaged).
  [ -f "${HOME_DIR}/dot_codex/hooks.json.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/hooks.json.tmpl" ]
  grep -q 'includeTemplate "codex-hooks.json"' "${HOME_DIR}/dot_codex/hooks.json.tmpl"
  grep -q 'includeTemplate "codex-hooks.json"' "${HOME_DIR}/dot_codex-r06/hooks.json.tmpl"
}

# Drive the gate with an ISOLATED HOME (empty BATS_TEST_TMPDIR, no .claude)
# so an empty GATEGUARD_BASH_EXTRA_DESTRUCTIVE does not silently fall back to
# the developer's real ~/.claude/settings.json. Echoes "deny" or "allow".
_gate_decision() {
  local gate="$1" cmd="$2" json
  json=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")
  if printf '%s' "$json" | HOME="$BATS_TEST_TMPDIR" GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null \
      | grep -q '"permissionDecision":"deny"'; then
    echo deny
  else
    echo allow
  fi
}

@test "codex gateguard denies a built-in destructive command (rm -rf)" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  [ "$(_gate_decision "$gate" 'rm -rf build')" = deny ]
}

@test "codex gateguard allows benign commands without false positives" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js" c
  # Each must pass through. A destructive phrase inside quotes, a safe
  # --force-with-lease, and env-assignment prefixes must not trip the gate.
  for c in \
    'ls -la && git status' \
    'git commit -m "drop table notes from the agenda"' \
    'git push --force-with-lease origin main' \
    'git checkout -b feature/x' \
    'env FOO=bar npm run build' \
    'dd --help'; do
    [ "$(_gate_decision "$gate" "$c")" = allow ] || { echo "false positive: $c"; return 1; }
  done
}

# Regression guard for the evasion vectors surfaced by multi-review (cc-code /
# cc-security / codex): wrappers, subshell/brace/process-substitution groups,
# quoted command substitution, sh -c / psql -c bodies, dd arg order, and the
# ECC git-parity gaps. Each MUST be blocked.
@test "codex gateguard resists destructive-command evasion vectors" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js" c
  for c in \
    'dd if=/dev/zero of=/dev/sda' \
    'dd of=/dev/disk1 if=/dev/zero' \
    'env rm -rf /tmp/x' \
    'command rm -rf /tmp/x' \
    'sudo rm -rf /tmp/x' \
    '/bin/rm -rf /tmp/x' \
    '(rm -rf /tmp/x)' \
    '{ rm -rf /tmp/x; }' \
    'cat <(rm -rf /tmp/x)' \
    'echo "$(rm -rf /tmp/x)"' \
    'sh -c "rm -rf /tmp/x"' \
    'bash -c "rm -rf /tmp/x"' \
    'psql -c "drop table users"' \
    'git push --force --force-with-lease origin main' \
    'git push origin +main' \
    'git --git-dir .git reset --hard' \
    'git checkout -- .' \
    'git commit --amend' \
    'git rm -r src/'; do
    [ "$(_gate_decision "$gate" "$c")" = deny ] || { echo "bypass: $c"; return 1; }
  done
}

@test "codex gateguard consumes the task #12 EXTRA regex from the environment" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local out
  # chezmoi destroy is NOT a built-in; only the operator EXTRA set covers it.
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chezmoi destroy"}}' \
    | GATEGUARD_BASH_EXTRA_DESTRUCTIVE='chezmoi\s+destroy\b' node "$gate" 2>/dev/null)
  echo "$out" | grep -q '"permissionDecision":"deny"'
}

# Proves the single-source-of-truth path: with no env override, the gate reads
# GATEGUARD_BASH_EXTRA_DESTRUCTIVE out of ~/.claude/settings.json (task #12 SSOT).
@test "codex gateguard reads the EXTRA regex from settings.json when no env override" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude"
  printf '%s' '{"env":{"GATEGUARD_BASH_EXTRA_DESTRUCTIVE":"chezmoi\\s+destroy\\b"}}' > "$tmp/.claude/settings.json"
  local out
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chezmoi destroy"}}' \
    | HOME="$tmp" GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null)
  rm -rf "$tmp"
  echo "$out" | grep -q '"permissionDecision":"deny"'
}

# Guard against quoted-string false positives: a destructive phrase inside a
# commit message must not trip the gate.
@test "codex gateguard does not false-positive on a destructive phrase inside quotes" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local out
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"drop table notes from the agenda\""}}' \
    | GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null)
  [ -z "$out" ]
}

@test "chezmoi source files exist: VS Code mcp.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/mcp.json" ]
}

# --- PR9: secret-scan + AGENTS.md split + house coding-standards ---

@test "AGENTS.md is templated and inlines the house coding-standards" {
  local agents="${HOME_DIR}/AGENTS.md.tmpl"
  [ -f "$agents" ]
  # Old plain path must be gone (renamed via git mv).
  [ ! -f "${HOME_DIR}/AGENTS.md" ]
  grep -q 'includeTemplate "coding-standards.md"' "$agents"
  # Agnostic core keeps provenance; Claude-only sections must have moved out.
  grep -q 'Skill provenance' "$agents"
  ! grep -q 'Mandatory skill usage' "$agents"
  ! grep -q 'memory への記録ポリシー' "$agents"
  # The agnostic core must NOT reference Claude-only hooks or the @-import
  # mechanism — Codex reads this file and has neither.
  ! grep -q 'git-push-reminder' "$agents"
  ! grep -q 'auto-tmux-dev' "$agents"
  ! grep -q '@~/AGENTS.md' "$agents"
}

@test "house coding-standards SSOT exists" {
  local cs="${HOME_DIR}/.chezmoitemplates/coding-standards.md"
  [ -f "$cs" ]
  grep -q 'Coding standards (house)' "$cs"
}

@test "Claude layer CLAUDE.md imports the agnostic core and holds Claude-only rules" {
  local claude="${HOME_DIR}/dot_claude/CLAUDE.md"
  [ -f "$claude" ]
  grep -q '@~/AGENTS.md' "$claude"
  grep -q 'Mandatory skill usage' "$claude"
  grep -q 'memory への記録ポリシー' "$claude"
  # The Claude-only relaxations of the conservative core rules live here.
  grep -q 'git-push-reminder' "$claude"
  grep -q 'auto-tmux-dev' "$claude"
  # The personal-account symlink was replaced by this real file.
  [ ! -f "${HOME_DIR}/dot_claude/symlink_CLAUDE.md.tmpl" ]
}

@test "claude-r06 CLAUDE.md symlink points at the shared Claude layer" {
  grep -q '/.claude/CLAUDE.md' "${HOME_DIR}/dot_claude-r06/symlink_CLAUDE.md.tmpl"
}

@test "codex AGENTS.md symlinks still point at the agnostic core (not the .tmpl source)" {
  # Target must be the deployed ~/AGENTS.md, never the source AGENTS.md.tmpl.
  grep -qE '/AGENTS\.md$' "${HOME_DIR}/dot_codex/symlink_AGENTS.md.tmpl"
  grep -qE '/AGENTS\.md$' "${HOME_DIR}/dot_codex-r06/symlink_AGENTS.md.tmpl"
}

@test "global gitleaks pre-commit hook is wired and well-behaved" {
  grep -q 'hooksPath = ~/.config/git/hooks' "${HOME_DIR}/dot_gitconfig.tmpl"
  local hook="${HOME_DIR}/dot_config/git/hooks/executable_pre-commit"
  [ -f "$hook" ]
  bash -n "$hook"
  grep -q 'gitleaks' "$hook"
  grep -q 'git --staged' "$hook"
  # Prefers a repo-local gitleaks config over the global one.
  grep -q '.gitleaks.toml' "$hook"
  # Chains the repo's own pre-commit so core.hooksPath does not silently drop it,
  # WITHOUT self-recursion: `git rev-parse --git-path hooks/pre-commit` respects
  # core.hooksPath and would resolve back to THIS global hook (infinite loop), so
  # the hook must resolve the default hooks dir via --git-common-dir (ignores
  # core.hooksPath and also works in linked worktrees) and guard self-reference
  # with -ef against ${BASH_SOURCE[0]}.
  ! grep -q 'git-path hooks/pre-commit' "$hook"
  grep -q 'git-common-dir' "$hook"
  grep -q 'BASH_SOURCE' "$hook"
  grep -q -- '-ef' "$hook"
  [ -f "${HOME_DIR}/dot_config/git/gitleaks.toml" ]
  # The global config must not carry a path allowlist (it would blind every repo).
  ! grep -qE '^[[:space:]]*paths[[:space:]]*=' "${HOME_DIR}/dot_config/git/gitleaks.toml"
}

# Regression (this PR): the chain step must not infinite-loop when core.hooksPath
# points at the global hook's own dir. Drives a real commit through a temp repo
# whose core.hooksPath is the hook dir; the buggy idiom would exec itself forever.
@test "global pre-commit hook does not self-recurse under core.hooksPath" {
  local to
  if command -v timeout >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  else skip "timeout not available"; fi
  local hooksdir repo
  hooksdir=$(mktemp -d)
  cp "${HOME_DIR}/dot_config/git/hooks/executable_pre-commit" "${hooksdir}/pre-commit"
  chmod +x "${hooksdir}/pre-commit"
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath "$hooksdir"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf 'x\n' >"${repo}/f"
  git -C "$repo" add f
  # timeout returns 124 if the hook loops; a clean commit returns 0.
  run "$to" 15 git -C "$repo" commit -q -m regression
  rm -rf "$hooksdir" "$repo"
  [ "$status" -eq 0 ]
}

# Regression (this PR): in a linked worktree the chain must still reach the
# common-dir repo-local hook. The earlier --git-dir idiom resolved the
# per-worktree gitdir (which has no hooks/) and silently dropped the chain;
# --git-common-dir points at the shared .git so the repo-local hook still runs.
@test "global pre-commit chains the common-dir hook from a linked worktree" {
  local to
  if command -v timeout >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  else skip "timeout not available"; fi
  local hooksdir repo wt
  hooksdir=$(mktemp -d)
  cp "${HOME_DIR}/dot_config/git/hooks/executable_pre-commit" "${hooksdir}/pre-commit"
  chmod +x "${hooksdir}/pre-commit"
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath "$hooksdir"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  git -C "$repo" commit --allow-empty -qm init
  wt=$(mktemp -d)
  git -C "$repo" worktree add -q "$wt" -b wt
  # Repo-local hook that drops a marker into the shared .git dir when it runs.
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf ran >"$(git rev-parse --path-format=absolute --git-common-dir)/local-hook-ran"' \
    >"${repo}/.git/hooks/pre-commit"
  chmod +x "${repo}/.git/hooks/pre-commit"
  printf 'x\n' >"${wt}/f"
  git -C "$wt" add f
  run "$to" 15 git -C "$wt" commit -q -m wt
  local marker=no
  [ -f "${repo}/.git/local-hook-ran" ] && marker=yes
  rm -rf "$hooksdir" "$repo" "$wt"
  [ "$status" -eq 0 ]
  [ "$marker" = yes ]
}

# Rendered-target checks (codex review): verify the template actually produces
# the intended files, not just that the source greps right.
@test "AGENTS.md renders with the coding-standards inlined" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  chezmoi cat "${HOME}/AGENTS.md" --source "${REPO_ROOT}/home" 2>/dev/null | grep -q 'Coding standards (house)'
}

# ---------------------------------------------------------------------------
# PR-F: CLV2 instinct→skill flow wiring (SessionStart producer + statusline +
# retrospective-codify input mode).
# ---------------------------------------------------------------------------

@test "clv2-session-notify hook exists, is valid bash, and degrades gracefully" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  [ -f "$hook" ]
  bash -n "$hook"
  # Reads the pinned engine and parses its cluster-count line.
  grep -q 'instinct-cli.py' "$hook"
  grep -q 'Potential skill clusters found' "$hook"
  # Caches the count for the statusline and throttles notifications for 7 days.
  grep -q '.review-ready-clusters' "$hook"
  grep -q '604800' "$hook"
  grep -q 'osascript' "$hook"
  # No-op guards: needs a python interpreter and macOS notifier before acting.
  grep -q 'command -v python3' "$hook"
}

# Behavioral: drive the hook with fake python/osascript so it never touches the
# real engine or fires a real notification, then assert it caches the parsed
# count and that the 7-day throttle suppresses a second notification.
@test "clv2-session-notify caches the cluster count and throttles notifications" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh hb
  td=$(mktemp -d)
  hh=$(mktemp -d)
  hb=$(mktemp -d)
  # Fake engine file: only needs to be readable; the fake python ignores it.
  mkdir -p "${hh}/.agents/skills/continuous-learning-v2/scripts"
  printf 'x\n' >"${hh}/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py"
  # Fake python3: emit canned evolve output with N=3.
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Potential skill clusters found: 3"' >"${hb}/python3"
  chmod +x "${hb}/python3"
  # Fake osascript: record each notification call.
  printf '%s\n' '#!/usr/bin/env bash' "echo call >>\"${td}/.osa-calls\"" >"${hb}/osascript"
  chmod +x "${hb}/osascript"

  # First run: cache == 3, exactly one notification (no throttle stamp yet).
  # CLV2_PYTHON_CMD is pinned to the fake so an inherited value cannot bypass it.
  HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$(cat "${td}/.review-ready-clusters")" = "3" ]
  [ -f "${td}/.last-instinct-notify" ]
  [ "$(wc -l <"${td}/.osa-calls")" -eq 1 ]

  # Second run immediately after: still caches, but throttle suppresses notify #2.
  HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$(cat "${td}/.review-ready-clusters")" = "3" ]
  [ "$(wc -l <"${td}/.osa-calls")" -eq 1 ]

  rm -rf "$td" "$hh" "$hb"
}

# Regression: a corrupt throttle stamp that looks octal ("09") must not abort the
# arithmetic (10# base-10 coercion). The hook must still exit 0 and refresh the cache.
@test "clv2-session-notify tolerates a corrupt octal-looking throttle stamp" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh hb
  td=$(mktemp -d)
  hh=$(mktemp -d)
  hb=$(mktemp -d)
  mkdir -p "${hh}/.agents/skills/continuous-learning-v2/scripts"
  printf 'x\n' >"${hh}/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Potential skill clusters found: 2"' >"${hb}/python3"
  chmod +x "${hb}/python3"
  printf '%s\n' '#!/usr/bin/env bash' ':' >"${hb}/osascript"
  chmod +x "${hb}/osascript"
  printf '09\n' >"${td}/.last-instinct-notify"
  run env HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$status" -eq 0 ]
  [ "$(cat "${td}/.review-ready-clusters")" = "2" ]
  rm -rf "$td" "$hh" "$hb"
}

# Graceful no-op when the CLV2 engine is not deployed: no cache, clean exit.
@test "clv2-session-notify is a no-op when the engine is absent" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh
  td=$(mktemp -d)
  hh=$(mktemp -d)
  run env HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" bash "$hook"
  [ "$status" -eq 0 ]
  [ ! -f "${td}/.review-ready-clusters" ]
  rm -rf "$td" "$hh"
}

@test "settings.json wires the clv2 SessionStart notify hook (async)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local s="${HOME_DIR}/dot_claude/settings.json"
  run jq -e '.hooks.SessionStart[]
    | select(.id=="session:start:clv2-notify")
    | .hooks[0]
    | select(.command=="$HOME/.claude/clv2-session-notify.sh" and .async==true)' "$s"
  [ "$status" -eq 0 ]
}

@test "statusline renders the instinct-cluster segment from the cache" {
  local sl="${HOME_DIR}/dot_claude/executable_statusline.sh"
  grep -q 'I_INSTINCT=' "$sl"
  grep -q 'clv2_cluster_count' "$sl"
  grep -q '.review-ready-clusters' "$sl"
  grep -qF '${I_INSTINCT} ${icc}' "$sl"
}

@test "retrospective-codify documents the instinct-cluster input mode" {
  local sk="${HOME_DIR}/dot_agents/skills/retrospective-codify/SKILL.md"
  grep -q 'instinct-cluster 入力モード' "$sk"
  grep -q -- '--input=instinct-clusters' "$sk"
  grep -q 'instinct-cli.py' "$sk"
  grep -q 'clv2-session-notify' "$sk"
}

@test "dmux OpenRouter secret is a private 1Password template, never committed in clear" {
  local tmpl="${HOME_DIR}/dot_config/zsh/private_dmux-secrets.zsh.tmpl"
  [ -f "$tmpl" ]
  grep -qE 'OPENROUTER_API_KEY=.*onepasswordRead' "$tmpl"
  # Single-quoted (squote, not quote) so a key with $ or a backtick cannot expand when sourced.
  grep -qE 'OPENROUTER_API_KEY=.*\| squote' "$tmpl"
  ! grep -qE 'OPENROUTER_API_KEY=.*\| quote' "$tmpl"
  # Not exported in the secrets file (scoping is done by the dmux wrapper).
  ! grep -qE '^export ' "$tmpl"
}

@test "dmux.zsh sources the OpenRouter secret and scopes it to the dmux subprocess" {
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  [ -f "$zsh" ]
  grep -qF 'dmux-secrets.zsh' "$zsh"
  grep -qE '\[\[ -r .* \]\] && source' "$zsh"
  grep -qE 'OPENROUTER_API_KEY="\$\{OPENROUTER_API_KEY:-\}"' "$zsh"
  # Must reach the real binary, not recurse into the function.
  grep -qF 'command dmux' "$zsh"
}

@test "dmux.zsh injects OPENROUTER_API_KEY into the dmux subprocess but not the parent shell" {
  command -v zsh >/dev/null || skip "zsh not available"
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.config/zsh" "$tmp/bin"
  # Stand in for the 1Password-rendered secrets file (non-exported, single-quoted).
  cat >"$tmp/.config/zsh/dmux-secrets.zsh" <<'SECRETS'
OPENROUTER_API_KEY='or-test-key'
SECRETS
  # Stub dmux binary that reports what it received.
  cat >"$tmp/bin/dmux" <<'STUB'
#!/usr/bin/env bash
printf 'SUB_OR=[%s]\n' "$(printenv OPENROUTER_API_KEY)"
STUB
  chmod +x "$tmp/bin/dmux"
  run zsh -fc "
    export HOME='$tmp'
    export PATH=\"$tmp/bin:\$PATH\"
    source '$zsh'
    printf 'PARENT_OR=[%s]\n' \"\$(printenv OPENROUTER_API_KEY)\"
    dmux
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'PARENT_OR=[]'
  echo "$output" | grep -qF 'SUB_OR=[or-test-key]'
}

@test "dmux codex shim deploys as ~/.config/dmux/bin/codex and re-injects --profile shared" {
  local shim="${HOME_DIR}/dot_config/dmux/bin/executable_codex"
  [ -f "$shim" ]
  # executable_ prefix → chezmoi deploys 0755 as `codex` (no extension), which dmux invokes.
  head -1 "$shim" | grep -qE '^#!/bin/sh'
  # Execs the resolved real codex (never the bare name) with the SSOT profile re-injected.
  grep -qF 'exec "$real" --profile shared "$@"' "$shim"
}

@test "dmux codex shim passes shellcheck and shfmt as POSIX sh" {
  local shim="${HOME_DIR}/dot_config/dmux/bin/executable_codex"
  # make lint only globs *.sh/*.sh.tmpl, so the extension-less shim needs explicit coverage.
  if command -v shellcheck >/dev/null; then
    shellcheck --shell=sh --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 "$shim"
  fi
  if command -v shfmt >/dev/null; then
    shfmt -d -i 2 -ci "$shim"
  fi
}

@test "dmux codex shim injects --profile shared and drops its own dir to avoid recursion" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_codex"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/codex"
  chmod +x "$tmp/shim/codex"
  # Real codex stub (in a separate dir) reports the args it was handed.
  cat >"$tmp/real/codex" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CODEX_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/codex"
  # shim dir first, real dir second: the shim must skip its own dir, then resolve the real codex.
  run env PATH="$tmp/shim:$tmp/real:/usr/bin:/bin" "$tmp/shim/codex" exec --foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'REAL_CODEX_ARGS=[--profile shared exec --foo]'
}

@test "dmux codex shim resolves correctly via PATH lookup (dmux's real sh -c launch path)" {
  # dmux runs `sh -c "codex …"`, so codex is found by PATH lookup and $0 becomes the resolved
  # full path. This exercises that path (vs the direct-invocation test above) to guard the
  # verbatim self-skip premise against regressions.
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_codex"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/codex"
  chmod +x "$tmp/shim/codex"
  cat >"$tmp/real/codex" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CODEX_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/codex"
  run env PATH="$tmp/shim:$tmp/real:/usr/bin:/bin" sh -c 'codex exec --foo'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'REAL_CODEX_ARGS=[--profile shared exec --foo]'
}

@test "dmux codex shim exits non-zero (no fork bomb) when no real codex is on PATH" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_codex"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim"
  cp "$shimsrc" "$tmp/shim/codex"
  chmod +x "$tmp/shim/codex"
  # Only the shim is reachable as `codex`: it must fail cleanly, never recurse into itself.
  run env PATH="$tmp/shim:/usr/bin:/bin" "$tmp/shim/codex" exec
  [ "$status" -eq 127 ]
  echo "$output" | grep -qF 'no real codex found on PATH'
}

@test "dmux claude shim deploys as ~/.config/dmux/bin/claude and is opt-in via DMUX_HAPPY" {
  local shim="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  [ -f "$shim" ]
  # executable_ prefix → chezmoi deploys 0755 as `claude` (no extension), which dmux invokes.
  head -1 "$shim" | grep -qE '^#!/bin/sh'
  # Opt-in is strict (=1), not just "non-empty", so DMUX_HAPPY=0 does not enable happy.
  grep -qF '[ "${DMUX_HAPPY:-}" = "1" ]' "$shim"
  # Opt-in branch launches happy (resolved to an absolute path); default branch passes through.
  grep -qF 'exec "$happy_bin" claude "$@"' "$shim"
  grep -qF 'exec "$real" "$@"' "$shim"
  # Recursion break: HAPPY_CLAUDE_PATH pins the real claude so happy never re-enters the shim,
  # and DMUX_HAPPY is cleared before exec as belt-and-suspenders.
  grep -qF 'export HAPPY_CLAUDE_PATH="$real"' "$shim"
  grep -qF 'unset DMUX_HAPPY' "$shim"
}

@test "dmux claude shim passes shellcheck and shfmt as POSIX sh" {
  local shim="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  # make lint only globs *.sh/*.sh.tmpl, so the extension-less shim needs explicit coverage.
  if command -v shellcheck >/dev/null; then
    shellcheck --shell=sh --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 "$shim"
  fi
  if command -v shfmt >/dev/null; then
    shfmt -d -i 2 -ci "$shim"
  fi
}

@test "dmux claude shim is a transparent passthrough when DMUX_HAPPY is unset" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # Real claude stub (in a separate dir) reports the args it was handed — verbatim, no flags.
  cat >"$tmp/real/claude" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CLAUDE_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/claude"
  # shim dir first, real dir second: the shim must skip its own dir, then resolve the real claude.
  run env -u DMUX_HAPPY PATH="$tmp/shim:$tmp/real:/usr/bin:/bin" sh -c 'claude --resume foo'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'REAL_CLAUDE_ARGS=[--resume foo]'
}

@test "dmux claude shim wraps in happy, pins HAPPY_CLAUDE_PATH and clears DMUX_HAPPY when opted in" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/bin" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # Real claude stub: the shim must resolve it and pin it via HAPPY_CLAUDE_PATH.
  cat >"$tmp/real/claude" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CLAUDE_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/claude"
  # happy stub reports its args, whether DMUX_HAPPY survived, and the pinned HAPPY_CLAUDE_PATH.
  cat >"$tmp/bin/happy" <<'STUB'
#!/usr/bin/env bash
printf 'HAPPY_ARGS=[%s]\n' "$*"
printf 'HAPPY_DMUX_HAPPY=[%s]\n' "${DMUX_HAPPY-<unset>}"
printf 'HAPPY_CLAUDE_PATH=[%s]\n' "${HAPPY_CLAUDE_PATH-<unset>}"
STUB
  chmod +x "$tmp/bin/happy"
  run env DMUX_HAPPY=1 PATH="$tmp/shim:$tmp/bin:$tmp/real:/usr/bin:/bin" sh -c 'claude --permission-mode plan'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'HAPPY_ARGS=[claude --permission-mode plan]'
  # The nested claude that happy would spawn must NOT see DMUX_HAPPY (else it would re-wrap).
  echo "$output" | grep -qF 'HAPPY_DMUX_HAPPY=[<unset>]'
  # HAPPY_CLAUDE_PATH must point at the resolved real claude so happy bypasses the shim.
  echo "$output" | grep -qF "HAPPY_CLAUDE_PATH=[$tmp/real/claude]"
}

@test "dmux claude shim treats DMUX_HAPPY=0 as off (strict =1 opt-in, not just non-empty)" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/real" "$tmp/bin"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # A happy stub that would shout if (wrongly) invoked, plus a real claude for the passthrough.
  cat >"$tmp/bin/happy" <<'STUB'
#!/usr/bin/env bash
printf 'HAPPY_WAS_CALLED=[%s]\n' "$*"
STUB
  chmod +x "$tmp/bin/happy"
  cat >"$tmp/real/claude" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CLAUDE_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/claude"
  # DMUX_HAPPY=0 must NOT enable happy: a non-empty-but-not-1 value falls through to passthrough.
  run env DMUX_HAPPY=0 PATH="$tmp/shim:$tmp/bin:$tmp/real:/usr/bin:/bin" sh -c 'claude --resume foo'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'REAL_CLAUDE_ARGS=[--resume foo]'
  ! echo "$output" | grep -qF 'HAPPY_WAS_CALLED'
}

@test "dmux claude shim fails with a clear diagnostic when DMUX_HAPPY=1 but happy is absent" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # A real claude exists (so the shim gets past real-resolution), but no happy is on PATH.
  cat >"$tmp/real/claude" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CLAUDE_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/claude"
  # Opt-in requested but no happy on PATH: must exit non-zero with an explicit message, not recurse.
  run env DMUX_HAPPY=1 PATH="$tmp/shim:$tmp/real:/usr/bin:/bin" sh -c 'claude --permission-mode plan'
  [ "$status" -eq 127 ]
  echo "$output" | grep -qF 'DMUX_HAPPY=1 but no happy found on PATH'
}

@test "dmux claude shim exits non-zero (no fork bomb) when no real claude is on PATH" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # Only the shim is reachable as `claude`: it must fail cleanly, never recurse into itself.
  run env -u DMUX_HAPPY PATH="$tmp/shim:/usr/bin:/bin" "$tmp/shim/claude" --resume
  [ "$status" -eq 127 ]
  echo "$output" | grep -qF 'no real claude found on PATH'
}

@test "dmux/dmux-r06 inject the DMUX_HAPPY toggle into the tmux server env" {
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  # A reused tmux server fixes its env at start, so the toggle is set/removed on the running
  # server before launch; otherwise DMUX_HAPPY never reaches new agent panes.
  grep -qF 'tmux set-environment -g DMUX_HAPPY 1' "$zsh"
  grep -qF 'tmux set-environment -g -u DMUX_HAPPY' "$zsh"
  # dmux-r06 must target its dedicated socket, not the default one.
  grep -qF 'TMUX_TMPDIR="$tmpdir" tmux set-environment -g DMUX_HAPPY 1' "$zsh"
}

@test "zshrc re-prepends the dmux shim dir after mise activate, scoped to dmux sessions" {
  local zshrc="${HOME_DIR}/dot_zshrc.tmpl"
  # Without this the claude/codex shims never intercept inside dmux panes (mise wins on PATH).
  grep -qF 'export PATH="$HOME/.config/dmux/bin:$PATH"' "$zshrc"
  # Gated to tmux first…
  grep -qF '[[ -n "$TMUX" && -d "$HOME/.config/dmux/bin" ]]' "$zshrc"
  # …and narrowed to dmux-* sessions so plain tmux panes keep the documented bare-binary
  # behaviour (no --profile shared on bare codex, no accidental happy wrapping of claude).
  grep -qF "tmux display-message -p '#{session_name}'" "$zshrc"
  grep -qE 'dmux-\*\)' "$zshrc"
  # Ordering is load-bearing: the prepend must come AFTER `mise activate` (which re-prepends the
  # real binaries) or the shim dir would be buried behind mise's claude/codex again.
  local mise_line shim_line
  mise_line="$(grep -n 'mise activate zsh' "$zshrc" | head -1 | cut -d: -f1)"
  shim_line="$(grep -nF '.config/dmux/bin:$PATH' "$zshrc" | head -1 | cut -d: -f1)"
  [ -n "$mise_line" ]
  [ -n "$shim_line" ]
  [ "$shim_line" -gt "$mise_line" ]
}

@test "dmux claude shim: even if happy re-spawns bare claude, DMUX_HAPPY is cleared (no re-wrap)" {
  local shimsrc="${HOME_DIR}/dot_config/dmux/bin/executable_claude"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/shim" "$tmp/bin" "$tmp/real"
  cp "$shimsrc" "$tmp/shim/claude"
  chmod +x "$tmp/shim/claude"
  # happy stub that IGNORES HAPPY_CLAUDE_PATH and re-invokes bare `claude` (worst case): the
  # nested claude hits the shim again but must fall through to the real binary, not re-wrap.
  cat >"$tmp/bin/happy" <<'STUB'
#!/usr/bin/env bash
shift # drop the leading "claude" arg happy was given
exec claude "$@"
STUB
  chmod +x "$tmp/bin/happy"
  cat >"$tmp/real/claude" <<'STUB'
#!/usr/bin/env bash
printf 'REAL_CLAUDE_ARGS=[%s]\n' "$*"
STUB
  chmod +x "$tmp/real/claude"
  run env DMUX_HAPPY=1 PATH="$tmp/shim:$tmp/bin:$tmp/real:/usr/bin:/bin" sh -c 'claude --resume foo'
  [ "$status" -eq 0 ]
  # The real claude must run exactly once with the original args — no happy recursion loop.
  echo "$output" | grep -qF 'REAL_CLAUDE_ARGS=[--resume foo]'
}

@test "dmux (default account) prepends the codex shim dir to PATH and passes the MCP keys" {
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  grep -qF '_DMUX_SHIM_DIR="${HOME}/.config/dmux/bin"' "$zsh"
  # The default dmux wrapper must put the shim dir on PATH so its bare codex loads the SSOT.
  grep -qE 'PATH="\$\{_DMUX_SHIM_DIR\}:\$\{PATH\}"' "$zsh"
  # MCP keys re-passed for parity with cld (claude expands the placeholders at spawn).
  grep -qF 'EXA_API_KEY="${EXA_API_KEY:-}"' "$zsh"
  grep -qF 'FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"' "$zsh"
  # claude's MCP keys are sourced here too so the wrapper does not depend on plugin load order.
  grep -qF 'claude-secrets.zsh' "$zsh"
}

@test "dmux-r06 binds the r06 account env, a dedicated tmux socket and the codex shim" {
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  grep -qE '^dmux-r06\(\) \{' "$zsh"
  # Dedicated tmux server (own session namespace) so dmux-r06 never attaches to a default-account
  # session of the same project; socket dir created 0700 to match tmux's default privacy.
  grep -qF 'TMUX_TMPDIR="$tmpdir"' "$zsh"
  grep -qF 'mkdir -m 700 -p "$tmpdir"' "$zsh"
  # Full per-account env set (mirrors _claude_with_home + CODEX_HOME + the MCP keys).
  grep -qF 'CLAUDE_CONFIG_DIR="${HOME}/.claude-r06"' "$zsh"
  grep -qF 'ECC_AGENT_DATA_HOME="${HOME}/.claude-r06"' "$zsh"
  grep -qF 'CLV2_HOMUNCULUS_DIR="${HOME}/.claude-r06/ecc-homunculus"' "$zsh"
  grep -qF 'ECC_MCP_HEALTH_STATE_PATH="${HOME}/.claude-r06/mcp-health-cache.json"' "$zsh"
  grep -qF 'GATEGUARD_STATE_DIR="${HOME}/.claude-r06/.gateguard"' "$zsh"
  grep -qF 'CODEX_HOME="${HOME}/.codex-r06"' "$zsh"
  grep -qF 'EXA_API_KEY="${EXA_API_KEY:-}"' "$zsh"
  grep -qF 'FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"' "$zsh"
  grep -qF 'command dmux "$@"' "$zsh"
}

@test "dmux-r06 injects the r06 account env and MCP keys into the subprocess but not the parent" {
  command -v zsh >/dev/null || skip "zsh not available"
  local zsh="${HOME_DIR}/dot_config/zsh/dmux.zsh"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.config/zsh" "$tmp/bin"
  # Stand in for the 1Password-rendered claude secrets (non-exported, sourced by dmux.zsh).
  cat >"$tmp/.config/zsh/claude-secrets.zsh" <<'SECRETS'
EXA_API_KEY='exa-test-key'
FIRECRAWL_API_KEY='fc-test-key'
SECRETS
  # Stub dmux binary that reports the per-account env it received.
  cat >"$tmp/bin/dmux" <<'STUB'
#!/usr/bin/env bash
printf 'SUB_CC=[%s]\n' "$(printenv CLAUDE_CONFIG_DIR)"
printf 'SUB_CODEX=[%s]\n' "$(printenv CODEX_HOME)"
printf 'SUB_TMPDIR=[%s]\n' "$(printenv TMUX_TMPDIR)"
printf 'SUB_EXA=[%s]\n' "$(printenv EXA_API_KEY)"
printf 'SUB_FIRE=[%s]\n' "$(printenv FIRECRAWL_API_KEY)"
case ":$PATH:" in
*":$HOME/.config/dmux/bin:"*) printf 'SUB_SHIM=[yes]\n' ;;
*) printf 'SUB_SHIM=[no]\n' ;;
esac
STUB
  chmod +x "$tmp/bin/dmux"
  run zsh -fc "
    export HOME='$tmp'
    export PATH=\"$tmp/bin:\$PATH\"
    # Start from a clean baseline: the outer test environment may already export these.
    unset CLAUDE_CONFIG_DIR CODEX_HOME TMUX_TMPDIR EXA_API_KEY FIRECRAWL_API_KEY
    source '$zsh'
    dmux-r06
    printf 'PARENT_CC=[%s]\n' \"\$(printenv CLAUDE_CONFIG_DIR)\"
    printf 'PARENT_CODEX=[%s]\n' \"\$(printenv CODEX_HOME)\"
    printf 'PARENT_EXA=[%s]\n' \"\$(printenv EXA_API_KEY)\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "SUB_CC=[$tmp/.claude-r06]"
  echo "$output" | grep -qF "SUB_CODEX=[$tmp/.codex-r06]"
  echo "$output" | grep -qF "SUB_TMPDIR=[$tmp/.dmux-r06]"
  echo "$output" | grep -qF 'SUB_EXA=[exa-test-key]'
  echo "$output" | grep -qF 'SUB_FIRE=[fc-test-key]'
  echo "$output" | grep -qF 'SUB_SHIM=[yes]'
  # Parent shell must stay clean (env was scoped to the dmux subprocess only).
  echo "$output" | grep -qF 'PARENT_CC=[]'
  echo "$output" | grep -qF 'PARENT_CODEX=[]'
  # EXA was sourced (non-exported) into the parent, but must NOT be exported to child env leak-style;
  # printenv in the parent reflects the sourced shell var only if exported — it is not, so empty.
  echo "$output" | grep -qF 'PARENT_EXA=[]'
}

@test "1Password validation requires the OpenRouter API key" {
  local script="${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
  grep -qF 'op://kryota.dev/Dotfiles - OpenRouter API/credential' "$script"
}
