#!/usr/bin/env bats

load helpers/setup

@test "zsh syntax: aliases.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/aliases.zsh"
}

@test "zsh syntax: git.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/git.zsh"
}

@test "zsh syntax: docker.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/docker.zsh"
}

@test "zsh syntax: claude.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/claude.zsh"
}

@test "zsh syntax: functions.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/functions.zsh"
}

@test "zsh syntax: brew-helpers.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/brew-helpers.zsh"
}

@test "zsh syntax: completions.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/completions.zsh"
}

@test "zsh syntax: wtp.zsh" {
  zsh -n "${HOME_DIR}/dot_config/zsh/wtp.zsh"
}
