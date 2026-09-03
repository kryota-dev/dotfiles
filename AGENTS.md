# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A macOS dotfiles repository managed by **chezmoi** for deploying files to the home directory.
The chezmoi source directory is `home/` (configured via `.chezmoiroot`).

## Language policy

Written artifacts in this repository follow one of two rules:

**English required:**
- Documentation and markdown files under `docs/` and repo-root reference files (e.g. `README.md`) — the agent-facing Markdown files listed below are the exception

**Japanese required:**
- Commit messages — Conventional Commits with an English `type(scope):` prefix and a Japanese subject/body, e.g. `feat(ntfy): 認証を自動プロビジョニングする` (matches the existing `commit` / `sdd` skill defaults)
- Pull request titles and descriptions
- GitHub Issue titles and bodies
- Code review comments — matches the agent definition files' system prompts, which already steer Japanese-speaking review output (see below)
- Agent skill files (`SKILL.md`) and their script comments — except `agent-browser`, which stays English: it is an upstream-synced discovery stub whose specialized skills are fetched live via `agent-browser skills get <name>` rather than vendored (see `home/AGENTS.md.tmpl:19`)
- Agent definition files (`home/dot_claude/agents/*.md`) — their system prompts steer Japanese-speaking review output
- The Fable orchestrator system prompt (`home/dot_claude/fable-orchestrator-prompt.md`) — appended to Fable sessions launched via `cldf` / `cldf-r06`, so it must steer Japanese-speaking session output
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

# Sync vendored _ghq completion from the mise-pinned ghq version
make sync-ghq-completion
```

## Documentation

Deep reference, how-to, and design rationale live in [`docs/`](docs/README.md) — English
canonical with Japanese (`*.ja.md`) mirrors. `docs/` is the single home for the chezmoi
engine, the lifecycle apply timeline, the lint/CI internals, and the AI-agent layer; this
file stays short and points there.

- **Architecture:** [overview](docs/architecture/overview.md) · [chezmoi engine](docs/architecture/chezmoi-engine.md) · [externals & pinning](docs/architecture/externals-and-pinning.md) · [lifecycle scripts](docs/architecture/lifecycle-scripts.md) · [shell environment](docs/architecture/shell-environment.md) · [dev tooling](docs/architecture/dev-tooling.md) · [Renovate automation](docs/architecture/renovate-automation.md)
- **AI agents:** [overview](docs/agents/overview.md) · [account isolation](docs/agents/account-isolation.md) · [Claude Code](docs/agents/claude-code.md) · [Codex](docs/agents/codex.md) · [skill provenance](docs/agents/skills-provenance.md)
- **Contributing:** [local dev & the make contract](docs/contributing/local-dev.md) · [CI & tests](docs/contributing/ci-and-tests.md) · [worktrees & env](docs/contributing/worktrees-and-env.md)
- **Explanation:** [design rationale](docs/explanation/design-rationale.md) · [secrets & isolation](docs/explanation/secrets-and-isolation.md)

The chezmoi naming conventions, lint pipeline internals (shellcheck/shfmt flags, the
`{{`-line stripping trick), the numbered lifecycle timeline, and the test/CI architecture
are documented there, not duplicated here. Note: the chezmoi **behavior** config is
`home/dot_config/chezmoi/private_chezmoi.toml` (deploys to `~/.config/chezmoi/chezmoi.toml`,
0600); template **data** is `home/.chezmoidata.toml`.

## Dependency updates

Renovate pull requests merge unattended. The `renovate-gate` required status check
decides: `scripts/renovate-gate-classify.sh` clears ordinary version pins, everything
else (digest bumps, majors, security advisories) goes to an agent review, and a
missing check or missing verdict blocks the merge. Approve the PR to override,
Request changes to reject or redirect. See
[Renovate automation](docs/architecture/renovate-automation.md) — including the
ruleset setup, which is configured in the GitHub UI and not managed as code.

## Git config

Commit signing via 1Password SSH signatures is enabled (`home/dot_gitconfig.tmpl`). If a
1Password error occurs during `git commit`, notify the user with the `notify` command. See
[dev tooling](docs/architecture/dev-tooling.md) for signing and the gitleaks pre-commit hook.
