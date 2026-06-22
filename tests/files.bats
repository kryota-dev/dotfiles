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
