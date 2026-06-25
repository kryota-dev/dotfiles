# Why it's built this way

🌐 日本語: [design-rationale.ja.md](design-rationale.ja.md)

← [Docs index](../README.md)

This document explains the load-bearing design decisions behind the repo — the WHYs that don't surface naturally in the how-to docs. Each section names a decision, explains the problem it solves, and links to the reference doc that covers the mechanics.

---

## Single-tarball caching over N individual downloads

**Decision:** All <!-- FACT:ecc-skill-count -->127<!-- /FACT --> adopted ECC skills, plus the ECC hook runtime, are declared as separate entries in `.chezmoiexternal.toml` — but every one of those entries points at the same tarball URL (the ECC archive pinned at `[ecc].commit`). Similarly, the 17 Anthropic system skills each point at the same `anthropics/skills` archive URL.

**Why:** chezmoi caches external archives keyed by URL SHA-256. When multiple entries share an identical URL, chezmoi downloads the tarball once and satisfies every entry from the cache. The alternative — fetching each skill from its own URL — would require one network round-trip per skill (hundreds in total) on every `chezmoi apply`, adding minutes of latency and making installs brittle on slow or metered connections.

The per-entry `include` glob and `stripComponents` value then act as a filter: they extract only the relevant subdirectory from the single cached archive without requiring a separate download. The cost of a larger tarball is paid once; the benefit of isolated per-skill paths is preserved.

See [externals-and-pinning.md](../architecture/externals-and-pinning.md) for the mechanics of how chezmoi cache keys work and how `include`/`stripComponents` interact.

---

## SHA-pin a commit, not a tag, for reproducibility

**Decision:** Every external URL interpolates an immutable commit hash (`[skills].anthropic_commit`, `[ecc].commit`) rather than a branch name or tag. ECC bumps are additionally blocked from auto-merging in Renovate (`packageRules` in `renovate.json5`).

**Why:** A Git tag can be force-pushed or deleted; a branch tip moves on every merge. Pinning to a commit hash means the bytes fetched by `chezmoi apply` are identical whether you run it today or in two years. A moved `v2.0.0` tag cannot silently change the hook code that executes inside `claude`.

ECC in particular ships executable JavaScript hooks that run with the permissions of the Claude Code session. An accidental or malicious tag move would deliver new hook code to every machine on next apply — a meaningful supply-chain risk. Blocking auto-merge means a human reviews every ECC bump before it lands.

The `refreshPeriod = "168h"` in each external entry adds a practical middle layer: within seven days, chezmoi serves the cached copy even without explicit version changes. After that window, it re-downloads — which is the right behavior for a repo that expects periodic `chezmoi apply` runs to stay current.

See [externals-and-pinning.md](../architecture/externals-and-pinning.md) for the Renovate `customManager` regex that bumps `version` and `commit` together.

---

## ECC adopted as an external, with forks over reimplementation

**Decision:** The ECC (Everything Claude Code) hook runtime is fetched as a chezmoi external (source-only, no `node_modules`) rather than installed as a plugin or reimplemented locally. Where ECC's upstream behavior needed augmenting — durable SQLite governance, account-aware audit logging, read-only state inspection CLIs — the extensions are written as thin forks that `require()` ECC's own modules from the pinned external.

**Why:** ECC provides a rich, maintained hook framework spanning governance capture, gateguard, CLV2 continuous learning, and dozens of other behaviors. Reimplementing any significant portion of that from scratch would be high maintenance cost with no benefit. Forking minimally and requiring upstream code means the forks stay thin and inherit upstream bug-fixes automatically when the pin is bumped.

The "source-only external" approach (no `node_modules` in the tarball) is deliberate: it avoids shipping a large binary tree into `~/.agents/skills/ecc/` and forces forks to use `node:sqlite` (Node ≥ 22.5, provided by mise) instead of ECC's `sql.js`/`ajv` dependencies, which are absent from the source-only external. The tradeoff is a Node version floor, guarded by the mise pin in `home/dot_config/mise/config.toml`.

The thin `ecc-hook.sh` launcher exists specifically to keep `settings.json` readable: ECC's default distribution embeds a ~1.5 KB minified `node -e` blob per hook entry, doing a runtime filesystem scan for the plugin root. Since the external is at a fixed chezmoi-managed path, that scan is unnecessary; replacing every blob with a one-line `ecc-hook.sh` invocation that sets `CLAUDE_PLUGIN_ROOT` directly makes the hook graph comprehensible at a glance.

See [claude-code.md](../agents/claude-code.md) for the full hook graph and the three fork files.

---

## Config shared, state isolated, for the dual-account model

**Decision:** The r06 work account (`~/.claude-r06`) is implemented as six symlinks pointing back to `~/.claude` for all configuration files (settings, statusline, agents, commands, skills, CLAUDE.md). Runtime state diverges via per-account environment variables set in the zsh launcher aliases.

**Why:** The alternative — maintaining two parallel config directories — would require every settings change to be applied twice and would inevitably create drift between accounts. Since the only thing that legitimately differs between personal and work sessions is runtime state (session history, governance database, ECC state, CLV2 instincts, caches), the right split is: one SSOT for config, two isolated trees for state.

The env var mechanism (`CLAUDE_CONFIG_DIR`, `ECC_AGENT_DATA_HOME`, `CLV2_HOMUNCULUS_DIR`, `GATEGUARD_STATE_DIR`) is the lightest possible seam: it requires no changes to Claude Code itself, no per-account copy of any config file, and no runtime config-merging logic. The same env pattern extends to dmux (`dmux-r06` sets a dedicated `TMUX_TMPDIR` so sessions on the two accounts never collide).

The one risk of this model is that three places define the per-account env set (`_claude_with_home` in `claude.zsh`, `dmux-r06` in `dmux.zsh`, and `cdx-r06` in `codex.zsh`). The `dmux.zsh` source comments explicitly call this out as a sync requirement. This is accepted duplication — the alternative (a shared env-building function called by all three) would add indirection for a set that changes rarely.

See [account-isolation.md](../agents/account-isolation.md) for the reference table of all per-account env vars and the full alias matrix.

---

## Secrets sourced-not-exported, then re-exported scoped to the subprocess

**Decision:** 1Password-rendered key files (`~/.config/zsh/claude-secrets.zsh`, `dmux-secrets.zsh`) are sourced into the interactive shell without `export`. The launcher functions (`_claude_with_home`, `dmux`, `dmux-r06`) then re-export the keys inline, scoped to the specific subprocess invocation.

**Why:** An `export` in a sourced file leaks the key into every child process of the interactive shell — every subshell, every external command, every background job — for the lifetime of the session. If a rogue process or accidental `env` log captures the process environment, the key is exposed.

Sourcing without export keeps the variable in the shell's local scope (accessible by name in the same shell process) without propagating it to child processes. The subprocess-scoped re-export (`EXA_API_KEY="${EXA_API_KEY:-}" claude`) means the key is available exactly where Claude Code needs it (to resolve MCP server env placeholders) and nowhere else.

The `${VAR:-}` default in each re-export is the runtime graceful-degradation path: if `chezmoi apply` has not yet been run on the machine (so the secrets file does not exist), the MCP servers launch without a key rather than the wrapper function erroring out.

See [secrets-and-isolation.md](secrets-and-isolation.md) for the full secrets lifecycle, and [secrets-1password.md](../getting-started/secrets-1password.md) for the onboarding how-to.

---

## mise pins every tool version exactly

**Decision:** All language runtimes and CLI tools are pinned to exact versions in `home/dot_config/mise/config.toml`. No ranges (`>=`), no `latest`.

**Why:** The machine-provisioning model assumes that `chezmoi apply` plus `mise install` produces a working, reproducible environment. Floating versions break this: a `mise install` run six months later could pick up a Node major version that breaks ECC's `node:sqlite` usage, a Python minor that changes import resolution for CLV2, or a `gh` CLI version that renames a subcommand a lifecycle script uses.

Exact pins also mean that CI's `setup-validation.yml` and a local `chezmoi apply` install identical tools, so CI failures are reproducible locally. The mise cache key in CI is the SHA-256 of `config.toml`, so any pin bump triggers a fresh install.

The downside — pins become stale — is handled deliberately: Renovate watches mise-managed versions (via the `mise` datasource) and opens PRs for tool bumps, which are reviewed and merged like any other dependency change.

See [dev-tooling.md](../architecture/dev-tooling.md) for the full mise config structure, the `npm:<pkg>` pattern for CLI tools without registry entries, and the `python.precompiled_flavor` / `ruby.compile` settings that prevent install failures.

---

## macOS is the real target; Linux exists only to keep CI green

**Decision:** The repo is macOS-first. Every OS-conditional branch (in templates and lifecycle scripts) treats `darwin` as the primary case and `linux` as a fallback for CI compatibility only. Linux support is implemented only far enough to let `setup-validation.yml` pass on Ubuntu/Linuxbrew.

**Why:** The owner's actual working environment is macOS. Making Linux a fully supported target would require handling `brew cask`, `mas`, macOS system preferences, the 1Password desktop SSH agent socket path, Ghostty terminal, font installation via cask, and dozens of other macOS-specific concerns in a dual-branch way. That cost exceeds the benefit when the only Linux consumer is the CI validation job.

The `.brewfile-linux-exclude` file is the SSOT for this boundary: it lists the `grep -E` patterns that filter out Linux-incompatible Brewfile lines before the Ubuntu CI job runs `brew bundle`. Both the lifecycle script and the CI workflow reference this file so the two never drift.

Templates use `{{ if ne .chezmoi.os "darwin" }}` to skip Linux-incompatible blocks (e.g., `Library/` ignore patterns, the Moralerspace font external, macOS defaults, font lifecycle scripts) — so the repo applies cleanly on Ubuntu without attempting macOS-only operations.

See [dev-tooling.md](../architecture/dev-tooling.md) for the `.brewfile-linux-exclude` SSOT pattern and [ci-and-tests.md](../contributing/ci-and-tests.md) for the CI matrix.

---

## No `make apply`; the default target is help

**Decision:** The Makefile does not expose an `apply` target. Running bare `make` prints the target list (help is the default). Applying the dotfiles requires running `chezmoi apply -v` directly.

**Why:** `chezmoi apply` mutates `$HOME`. It writes, moves, and potentially removes files in the home directory of the user running it. A `make apply` target — especially one that could be triggered accidentally by a contributor running `make` to explore the project — represents an unacceptable risk of unintended home-directory mutation. Requiring the explicit `chezmoi apply` invocation forces intent.

The `make help` default also serves as documentation: contributors can discover the available targets without reading the Makefile. The targets that exist (`lint`, `test`, `benchmark`, `dump-brewfile`, `sync-ghq-completion`) are all read-only or scoped to the repo tree, not the home directory.

See [local-dev.md](../contributing/local-dev.md) for the full `make` target table.

---

## ECC as a fork rather than a plugin installation

**Decision:** ECC is not installed via `npm install -g` or as a Claude Code plugin. It is fetched as a chezmoi external (source-only tarball), placed at a fixed path (`~/.agents/skills/ecc/`), and invoked via the `ecc-hook.sh` launcher that sets `CLAUDE_PLUGIN_ROOT` explicitly.

**Why:** The plugin installation path (`npm install -g`) would place ECC outside chezmoi's management, making its version uncontrolled and its updates opaque. Using chezmoi externals gives the same SHA-pin + refresh-period + Renovate-bump workflow as every other external dependency in the repo: the version is declared in `.chezmoidata.toml`, the tarball URL is fixed, and bumps go through PR review.

The "source-only" nature of the external (the ECC tarball contains JavaScript source, not a built `node_modules` tree) is an accepted tradeoff: it means forks must use only Node built-ins (`node:sqlite`) or modules they `require()` from within the ECC source tree itself. In practice this constraint has driven simpler, more auditable fork code.

This decision composes with the SHA-pin rationale above: the ECC source that runs inside the hook subprocess is exactly the bytes at the pinned commit, verified by chezmoi's URL-SHA256 cache. There is no npm registry, no version negotiation, no `package-lock.json` drift.

See [externals-and-pinning.md](../architecture/externals-and-pinning.md) for the external declaration and [claude-code.md](../agents/claude-code.md) for how the launcher and forks work.
