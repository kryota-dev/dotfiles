# docs/ — Reference index

> 🌐 日本語: [README.ja.md](README.ja.md)

This repo (`kryota-dev/dotfiles`) is a chezmoi-managed macOS-first dotfiles set that provisions a complete developer and AI-agent workstation from a single `curl | bash` bootstrap. The chezmoi source tree lives under `home/` and deploys to `$HOME` through chezmoi naming conventions. On `chezmoi apply`, a numbered set of lifecycle scripts installs Homebrew packages, validates 1Password secrets, sets up mise-managed toolchains, wires Claude Code MCP servers, and locks the zsh plugin set.

**This docs/ tree is deep on-demand reference.** The root `README.md` covers the happy-path quick-start. This router links every deeper doc and states what goes where.

---

## Table of contents

### Getting started

| Doc | Description |
|-----|-------------|
| [Installation & bootstrap](getting-started/installation.md) | Two entry points (`curl\|bash` vs `chezmoi init --apply`), per-OS prerequisites, the chezmoi download retry loop, and idempotency |
| [Verifying a fresh install](getting-started/verification.md) | Runnable convergence checklist mirroring what `setup-validation.yml` asserts |
| [1Password secrets onboarding](getting-started/secrets-1password.md) | Required vault items, field names, and the hard gate in `run_once_after_11` |

### Architecture

| Doc | Description |
|-----|-------------|
| [Architecture overview](architecture/overview.md) | Subsystem map and data-flow diagram spanning bootstrap → chezmoi engine → lifecycle → zsh/tooling → AI-agent layer → CI |
| [chezmoi engine: data, templates & name decoding](architecture/chezmoi-engine.md) | Name-decoding table, template-variable inventory, OS branching idiom, `includeTemplate`, and the two chezmoi config files |
| [Externals, SHA-pinning & the single-tarball cache](architecture/externals-and-pinning.md) | How 147 external entries collapse to a few cached downloads; the `range .ecc.skills` fan-out; refresh windows and Renovate bumps |
| [Lifecycle scripts: ordering & trigger model](architecture/lifecycle-scripts.md) | The two-phase before/after model, the full apply timeline (00→90), `run_once` vs `run_onchange` semantics, and the embedded-hash trick |
| [zsh startup, prompt & shell modules](architecture/shell-environment.md) | `.zprofile` → `.zshrc` → sheldon deferred loading; how to add a new `.zsh` module |
| [Developer toolchain: mise, Brewfile & git](architecture/dev-tooling.md) | mise version pins, `Brewfile` + `.brewfile-linux-exclude`, git 1Password signing, global gitleaks hook |

### Agents

| Doc | Description |
|-----|-------------|
| [AI-agent layer overview](agents/overview.md) | Dual-harness (Claude Code + Codex) × dual-account (default + r06) matrix; shared-rule and SSOT skill layers |
| [Account isolation: aliases, env & tmux sockets](agents/account-isolation.md) | Per-account env var table, full alias matrix, and `_claude_with_home` |
| [Claude Code harness config](agents/claude-code.md) | `settings.json`, ECC hook forks, CLV2 observer wiring, the 3-line statusline, and the Japanese review subagents |
| [Codex CLI harness config](agents/codex.md) | Dual `CODEX_HOME` accounts, `hooks.json`, `shared.config.toml` SSOT, and gateguard |
| [Skill library & provenance taxonomy](agents/skills-provenance.md) | The 5-category taxonomy (curated/external/system/evolved/unmanaged) and how to add a skill |

### Contributing

| Doc | Description |
|-----|-------------|
| [Local development & the make contract](contributing/local-dev.md) | Full `make` target table, lint pipeline internals, and the `{{`-line-stripping gotcha |
| [CI architecture & test suite](contributing/ci-and-tests.md) | `ci.yml` vs `setup-validation.yml`, bats suite map, Brewfile filter, and known rough edges |
| [Worktrees (wtp) & direnv/MCP env](contributing/worktrees-and-env.md) | `.wtp.yml` post-create hooks, direnv `.env` bootstrap, and the spec-workflow MCP server |

### Explanation

| Doc | Description |
|-----|-------------|
| [Why it's built this way](explanation/design-rationale.md) | Load-bearing WHYs: single-tarball caching, SHA-pin not tag, config-shared/state-isolated, sourced-not-exported secrets, no `make apply` |
| [Secrets & account-isolation design](explanation/secrets-and-isolation.md) | How `op://` refs render to `0600` files at apply, runtime-graceful vs apply-strict, and how this composes with account isolation |

---

## What goes where

| Surface | What belongs there | What does NOT belong |
|---------|-------------------|----------------------|
| Root `README.md` / `README.ja.md` | Landing page, happy-path quick-start, repo structure, dev-command table, CI summary | Deep prerequisite detail, troubleshooting, architecture narrative |
| `CLAUDE.md` / `AGENTS.md` in repo root | Mandatory skill rules, language policy, skill provenance policy, one-line pointers to docs/ | Mechanics (lint flags, lifecycle ordering, account env table) — those live in docs/ |
| Deployed `home/AGENTS.md.tmpl`, `home/dot_claude/CLAUDE.md` | Self-contained agent instructions that work on any machine **without the repo checked out** | Pointers into docs/ — deployed files must be self-sufficient |
| Per-skill `SKILL.md` (inside each skill dir) | Authoritative per-skill reference (purpose, usage, examples) | Taxonomy or "how to add a skill" — that lives in `docs/agents/skills-provenance.md` |
| `docs/` (this tree) | Deep on-demand reference, how-to, and explanation for humans and AI agents working IN the repo | Quick-start copy that duplicates README; content that must survive without the repo (use deployed files for that) |

---

## Language policy

English docs (`foo.md`) are canonical. Japanese mirrors (`foo.ja.md`) live next to their EN sibling. Each EN doc links to its JA mirror near the top; each JA doc links back to the EN canonical. This mirrors the repo's established `README.md` / `README.ja.md` convention.

[docs/README.ja.md →](README.ja.md)
