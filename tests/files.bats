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

@test "shared agent skills exist" {
  [ -d "${HOME_DIR}/dot_agents/skills" ]
  local count
  count=$(find "${HOME_DIR}/dot_agents/skills" -type d -mindepth 1 | wc -l)
  [ "$count" -gt 0 ]
}

@test "claude and codex skills are symlinked" {
  [ -f "${HOME_DIR}/dot_claude/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex/symlink_skills.tmpl" ]
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
  # #10: the dev-server delegation rule is deleted.
  ! grep -q '開発サーバーの起動はユーザーに委任' "$agents"
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
  # The personal-account symlink was replaced by this real file.
  [ ! -f "${HOME_DIR}/dot_claude/symlink_CLAUDE.md.tmpl" ]
}

@test "claude-r06 CLAUDE.md symlink points at the shared Claude layer" {
  grep -q '/.claude/CLAUDE.md' "${HOME_DIR}/dot_claude-r06/symlink_CLAUDE.md.tmpl"
}

@test "codex AGENTS.md symlinks still point at the agnostic core" {
  grep -q '/AGENTS.md' "${HOME_DIR}/dot_codex/symlink_AGENTS.md.tmpl"
  grep -q '/AGENTS.md' "${HOME_DIR}/dot_codex-r06/symlink_AGENTS.md.tmpl"
}

@test "global gitleaks pre-commit hook is wired" {
  grep -q 'hooksPath = ~/.config/git/hooks' "${HOME_DIR}/dot_gitconfig.tmpl"
  local hook="${HOME_DIR}/dot_config/git/hooks/executable_pre-commit"
  [ -f "$hook" ]
  bash -n "$hook"
  grep -q 'gitleaks' "$hook"
  grep -q 'git --staged' "$hook"
  [ -f "${HOME_DIR}/dot_config/git/gitleaks.toml" ]
}
