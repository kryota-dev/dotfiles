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

Exceptions — the following must be written in Japanese:
- Agent skill files (`SKILL.md`) and their script comments
- Agent definition files (`home/dot_claude/agents/*.md`) — their system prompts steer Japanese-speaking review output
- The global agent instructions deployed from this repo (`home/AGENTS.md.tmpl`, `home/dot_claude/CLAUDE.md`, `home/.chezmoitemplates/coding-standards.md`)

Note: Conversational responses to the user remain in Japanese as specified in the global `~/AGENTS.md`.

## Mandatory skill usage

- If changes affect shell scripts, zsh config, Makefile, or CI config, run `$code-change-verification`
- When committing changes, use `$commit`
- When creating a PR, use `$create-pr`
- When code changes are complete and ready for review, run `$pr-draft-summary`

## Commands

```bash
# List available targets (also the default `make` target)
make help

# Apply dotfiles (run chezmoi directly; no Make wrapper)
chezmoi apply -v

# Show diff (run chezmoi directly; no Make wrapper)
chezmoi diff

# Lint (shellcheck + shfmt + zsh syntax check)
make lint

# Test (lint + bats)
make test

# Run bats tests only
make test-bats      # bats tests/*.bats

# Run a single test file
bats tests/files.bats

# Format shell scripts (shfmt -w on .sh; .tmpl shown as diff only)
make fmt

# Benchmark zsh startup
make benchmark

# Update Brewfile
make dump-brewfile

# Sync vendored _ghq completion from the mise-pinned ghq version
make sync-ghq-completion
```

## Documentation

Deep reference, how-to, and design rationale live in [`docs/`](docs/README.md) — English
canonical with Japanese (`*.ja.md`) mirrors. `docs/` is the single home for the chezmoi
engine, the lifecycle apply timeline, the lint/CI internals, and the AI-agent layer; this
file stays short and points there.

- **Architecture:** [overview](docs/architecture/overview.md) · [chezmoi engine](docs/architecture/chezmoi-engine.md) · [externals & pinning](docs/architecture/externals-and-pinning.md) · [lifecycle scripts](docs/architecture/lifecycle-scripts.md) · [shell environment](docs/architecture/shell-environment.md) · [dev tooling](docs/architecture/dev-tooling.md)
- **AI agents:** [overview](docs/agents/overview.md) · [account isolation](docs/agents/account-isolation.md) · [Claude Code](docs/agents/claude-code.md) · [Codex](docs/agents/codex.md) · [skill provenance](docs/agents/skills-provenance.md)
- **Contributing:** [local dev & the make contract](docs/contributing/local-dev.md) · [CI & tests](docs/contributing/ci-and-tests.md) · [worktrees & env](docs/contributing/worktrees-and-env.md)
- **Explanation:** [design rationale](docs/explanation/design-rationale.md) · [secrets & isolation](docs/explanation/secrets-and-isolation.md)

The chezmoi naming conventions, lint pipeline internals (shellcheck/shfmt flags, the
`{{`-line stripping trick), the numbered lifecycle timeline, and the test/CI architecture
are documented there, not duplicated here. Note: the chezmoi **behavior** config is
`home/dot_config/chezmoi/private_chezmoi.toml` (deploys to `~/.config/chezmoi/chezmoi.toml`,
0600); template **data** is `home/.chezmoidata.toml`.

## Git config

Commit signing via 1Password SSH signatures is enabled (`home/dot_gitconfig.tmpl`). If a
1Password error occurs during `git commit`, notify the user with the `notify` command. See
[dev tooling](docs/architecture/dev-tooling.md) for signing and the gitleaks pre-commit hook.
