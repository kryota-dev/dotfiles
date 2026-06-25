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
  local modules=(git docker claude codex functions completions wtp ghq)
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

@test "mcp setup registers both servers as user scope for every account config dir" {
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

  # Both servers are add-json'd with user scope for both account config dirs. The trailing
  # " :::" anchors ".claude" so it does not also match ".claude-r06".
  local d
  for d in '\.claude' '\.claude-r06'; do
    grep -qE "/home/${d} ::: claude mcp add-json context7 .* --scope user" "$tmp/log"
    grep -qE "/home/${d} ::: claude mcp add-json deepwiki .* --scope user" "$tmp/log"
  done
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
  [ "$count" -ge 2 ]
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
