# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A macOS dotfiles repository managed by **chezmoi** for deploying files to the home directory.
The chezmoi source directory is `home/` (configured via `.chezmoiroot`).

## Language policy

All written artifacts in this repository must be in English:
- Commit messages
- Pull request titles and descriptions
- Code review comments
- Documentation and markdown files

Note: Conversational responses to the user remain in Japanese as specified in the global `~/AGENTS.md`.

## Mandatory skill usage

- If changes affect shell scripts, zsh config, Makefile, or CI config, run `$code-change-verification`
- When committing changes, use `$commit`
- When creating a PR, use `$create-pr`
- When code changes are complete and ready for review, run `$pr-draft-summary`

## Commands

```bash
# Apply dotfiles
make apply          # chezmoi apply -v

# Show diff
make diff           # chezmoi diff

# Lint (shellcheck + shfmt + zsh syntax check)
make lint

# Test (lint + bats)
make test

# Run bats tests only
make test-bats      # bats tests/*.bats

# Run a single test file
bats tests/files.bats

# Auto-fix with shfmt
make fmt

# Benchmark zsh startup
make benchmark

# Update Brewfile
make dump-brewfile

# Re-lock sheldon plugins
make sheldon-lock
```

## Architecture

### chezmoi source structure (`home/`)

Follows chezmoi naming conventions (`dot_` → `.`, `.tmpl` → template, `run_once_`/`run_onchange_` → scripts, `symlink_` → symlinks, `private_` → permission-restricted).

- **Lifecycle scripts** (executed in numbered order):
  - `run_once_before_00-install-prerequisites.sh.tmpl` — Xcode CLI tools, Homebrew
  - `run_once_after_11-validate-1password.sh.tmpl` — validates 1Password CLI and required secret items
  - `run_onchange_before_10-brew-bundle.sh.tmpl` — runs brew bundle when `dot_Brewfile` hash changes
  - `run_onchange_after_20-macos-defaults.sh.tmpl` — macOS system preferences
  - `run_once_after_30-setup-fonts.sh.tmpl` — font installation
  - `run_once_after_40-setup-sheldon.sh.tmpl` — sheldon lock
  - `run_once_after_90-other-apps.sh.tmpl` — other app configurations

- **zsh config**: `dot_zshrc.tmpl` → loads `dot_config/zsh/*.zsh` via sheldon with deferred loading
- **Template variables**: `.chezmoi.toml` defines `email` and `signingkey`
- **1Password secrets**: `private_dot_aws/config.tmpl`, `dot_agents/skills/daily-planning/SKILL.md.tmpl` — rendered from 1Password Secure Notes via `onepasswordRead`
- **AI agent config**: `dot_claude/`, `dot_codex/`, `dot_agents/skills/` — shared skills are centralized in `dot_agents/skills/` and distributed to each tool via symlinks

### Lint conventions

- shellcheck: `--shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329`
- shfmt: `-i 2 -ci` (2-space indent, case indent)
- chezmoi template lines (containing `{{`) are stripped with `sed` before linting
- zsh files (`*.zsh`) are syntax-checked with `zsh -n`

### Tests

Uses Bats (Bash Automated Testing System) in the `tests/` directory.
- `files.bats` — verifies chezmoi source files exist
- `shellcheck.bats` — verifies shellcheck passes
- `zsh_syntax.bats` — verifies zsh syntax

### CI

GitHub Actions (`.github/workflows/ci.yml`): lint → test → benchmark (main only)

### Git config

Commit signing via 1Password SSH signatures is enabled (`dot_gitconfig.tmpl`). If a 1Password error occurs during `git commit`, notify the user with the `notify` command.
