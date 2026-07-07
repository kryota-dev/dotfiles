# CI and Tests

🌐 日本語: [ci-and-tests.ja.md](ci-and-tests.ja.md)

← [Docs index](../README.md)

CI is a mirror of the local `make` commands. There is no separate CI lint logic — `make lint` and `make test-bats` are the contract, and CI just calls them.

---

## CI == local

The `ci.yml` workflow runs three jobs:

| Job | Command | Runner |
|---|---|---|
| `lint` | `make lint` | `ubuntu-latest` |
| `test` | `make test-bats` | `ubuntu-latest` (needs: lint) |
| `sync-ghq-completion` | `make sync-ghq-completion` (+ auto-commit if the vendored `_ghq` changed) | `ubuntu-latest`, same-repo PRs only |

Before running `make lint`, the lint job installs shfmt (`v3.13.1`) from the GitHub release and `zsh` via `apt-get`. The test job installs `bats`, `shellcheck`, and `zsh` via `apt-get`. No other CI-specific logic exists; the `Makefile` is the single source of truth.

Contributors should run `make lint` and `make test-bats` locally before pushing — CI will run the exact same commands.

### Triggers

`ci.yml` fires on push to `main` and on pull requests targeting `main`, but only when relevant paths change: `home/**`, `tests/**`, `scripts/**`, `Makefile`, or `.github/workflows/ci.yml`. It also supports `workflow_dispatch` for manual runs.

---

## Bats test suite

All tests live under `tests/` and are run together via `bats tests/*.bats`. The helper `tests/helpers/setup.bash` defines `REPO_ROOT` and `HOME_DIR` (= `<repo>/home`) for every test file.

### `tests/files.bats`

Asserts that chezmoi source files exist in `home/`. Key categories:

- Core dotfiles are present: `dot_zshrc.tmpl`, `dot_zprofile.tmpl`, `dot_gitconfig.tmpl`, `private_dot_ssh/config.tmpl`, `dot_vimrc`, `dot_tmux.conf`, `dot_inputrc`, `dot_Brewfile`
- chezmoi data files: `.chezmoiexternal.toml`, `.chezmoidata.toml`
- Config files: `starship.toml`, ghostty config, sheldon `plugins.toml`
- zsh modules exist (`git`, `docker`, `claude`, `codex`, `functions`, `completions`, `wtp`, `ghq`); `aliases.zsh.tmpl` is present
- Vendored `_ghq` completion starts with `#compdef ghq`
- Lifecycle scripts exist at their expected paths
- Claude and Codex agent definitions, reviewer agents, shared skills
- r06 work-profile symlink sources exist for both `dot_claude-r06/` and `dot_codex-r06/`
- 1Password-backed secret templates reference `onepasswordRead` (never literal keys)
- ECC hook forks pass `node --check` syntax
- Project `.mcp.json` declares only `spec-workflow` (not `context7` or `deepwiki`, which were moved to user scope)
- Bootstrap script exists at `install/install.sh`

### `tests/shellcheck.bats`

- Runs shellcheck (same flags as `make lint`) on all `run_*.sh.tmpl` lifecycle scripts after stripping `{{`-containing lines.
- Asserts that all `home/dot_config/zsh/*.zsh` and `*.zsh.tmpl` files exist.

### `tests/zsh_syntax.bats`

Runs `zsh -n` on each zsh module individually. Covered modules: `aliases.zsh.tmpl` (after `sed '/{{/d'`), `git.zsh`, `docker.zsh`, `claude.zsh`, `codex.zsh`, `functions.zsh`, `completions.zsh`, `wtp.zsh`, `ghq.zsh`.

### `tests/statusline.bats`

Behavioral tests for `dot_claude/executable_statusline.sh`. Pipes mock JSON through the script and asserts:

- The script exits 0 and renders the model name.
- The context remaining percentage appears.
- Effort and cost segments render as independent tokens (guards against a field-delimiter regression).
- The r06 profile badge appears when `CLAUDE_CONFIG_DIR` points at `~/.claude-r06`.
- The harness-cost cache file is written with the correct session-keyed filename.

### `tests/zsh_aliases.bats`

Behavioral regression guard for the `_claude_with_home` helper and the per-account wrappers. Sources `claude.zsh` in a minimal `zsh -f` environment (no rc files) and drives the underlying functions directly. Key assertions:

- `_claude_with_home` sets several env vars rooted at the given home dir and runs the given command. The test asserts three of them: `CLAUDE_CONFIG_DIR`, `ECC_AGENT_DATA_HOME`, and `GATEGUARD_STATE_DIR`. (`_claude_with_home` also sets `CLV2_HOMUNCULUS_DIR` and `ECC_MCP_HEALTH_STATE_PATH` at runtime, but the bats test does not assert those.)
- MCP API keys (`EXA_API_KEY`, `FIRECRAWL_API_KEY`) are exported into the subprocess env but are not exported into the parent shell.

### `tests/skill_provenance.bats`

Deterministic source-side enforcement of the 5-category skill provenance policy. Does not require chezmoi or any external tool beyond `awk` and `grep`. Key assertions:

- Every directory under `home/dot_agents/skills/` is either non-empty (curated) or declared in `.chezmoiexternal.toml` (external).
- No skill is simultaneously curated and external.
- `AGENTS.md.tmpl` documents all five categories.
- ECC is declared external (not curated).
- The `[ecc].skills` list in `.chezmoidata.toml` contains at least 100 unique entries.
- The `.chezmoiexternal.toml` range block for ECC skills retains its `url`, `include`, and `stripComponents=3` structure.

The awk parser scopes strictly to the `[ecc]` table's `skills` array — reformatting that section's indentation or relocating the table header could change what the test sees. The `>=100` count and no-duplicates checks act as guards.

---

## `setup-validation.yml` — end-to-end apply

This workflow runs a real `chezmoi init --apply` on two platforms and asserts the deployed state.

### Matrix

| Job | Runner | Homebrew | Cache path |
|---|---|---|---|
| `setup-validation-macos` | `macos-latest` | System Homebrew | `/opt/homebrew/Cellar`, `/opt/homebrew/opt`, `/opt/homebrew/Library/Taps`, `~/Library/Caches/Homebrew` (followed by a "Relink cached Homebrew formulas" step) |
| `setup-validation-ubuntu` | `ubuntu-latest` | Linuxbrew (`/home/linuxbrew/.linuxbrew`) | Entire Linuxbrew install |

### Step: Exclude CI-incompatible files

Before `chezmoi apply`, both jobs move a set of files to `/tmp/chezmoi-excluded/` so that apply never attempts to call `op` or run interactive/install steps in the CI environment. Each file is moved inside a `for f in …; do if [ -f "$f" ]; then mv …; fi; done` loop so that a missing entry does not abort the step.

Files excluded by **both** jobs (<!-- FACT:ci-both-exclusion-count -->6<!-- /FACT --> files):

- `home/private_dot_aws/config.tmpl`
- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl`
- `home/run_once_before_00-install-prerequisites.sh.tmpl`
- `home/run_onchange_before_10-brew-bundle.sh.tmpl`
- `home/run_once_after_11-validate-1password.sh.tmpl`
- `home/dot_config/git/private_gitleaks-own.toml.tmpl`

Files excluded by the **macOS job only**:

- `home/run_once_after_90-other-apps.sh.tmpl`
- `home/run_once_after_30-setup-fonts.sh.tmpl` — **stale**: this script no longer exists; the `if [ -f ]` guard tolerates the missing file silently (see Known Issues)

When adding a new 1Password-backed secret template, add it to the exclusion list in both jobs.

### Brewfile handling

Only `tap` and `brew` lines are extracted from `dot_Brewfile` for CI (`grep -E '^(tap |brew )'`). The Ubuntu job additionally filters Linux-incompatible formulas by passing the extracted lines through `grep -v -E -f .brewfile-linux-exclude`. The macOS job does not apply this filter.

### Verification steps (both jobs)

After apply, both jobs assert:

1. **Deployed files**: `~/.zshrc`, `~/.zprofile`, `~/.gitconfig`, `~/.ssh/config`, `~/.config/starship.toml`, `~/.config/sheldon/plugins.toml`, `~/.config/mise/config.toml` exist.
2. **zsh modules deployed**: `~/.config/zsh/{aliases,git,docker,claude,functions,completions,wtp,ghq}.zsh` exist.
3. **ghq config**: `ghq.root = ~/ghq`, `ghq.user = kryota-dev`, `~/.config/zsh/completions/_ghq` exists.
4. **mise tools**: `node`, `python`, and `go` resolve under `~/.local/share/mise/installs`.
5. **Clean zsh start**: `zsh -i -c exit` produces no output matching `command not found`, `parse error`, or `not found` on stderr.

The macOS job also verifies `~/.config/ghostty/config`.

---

## `benchmark.yml` — weekly cron

Runs on a `schedule` (every Monday at 00:00 UTC) and on `workflow_dispatch`. Runs on `macos-latest`.

The job installs chezmoi, sheldon, and starship via Homebrew, copies `home/dot_config/sheldon/plugins.toml` and all `home/dot_config/zsh/*.zsh` files into `~/.config/`, renders `.zsh.tmpl` modules with `chezmoi execute-template`, runs `sheldon lock`, then times 10 iterations of `/usr/bin/time zsh -i -c exit`.

### Known divergence from local benchmark

`benchmark.yml` does **not** call `scripts/benchmark.sh`. It inlines a 10-iteration loop directly in the workflow YAML and reconstructs the sheldon/zsh environment manually. Local `make benchmark` calls `scripts/benchmark.sh`, which uses `bc` for averaging and supports a configurable iteration count. The CI and local implementations measure the same thing (zsh interactive startup cost) but diverge in implementation. This is tracked for a future fix.

---

## Reusable workflows and SHA pinning

Three additional workflows delegate to reusable workflows in `kryota-dev/actions`, all pinned by commit SHA:

| Workflow | Reusable target | Trigger |
|---|---|---|
| `actions-lint.yml` | `kryota-dev/actions/.github/workflows/actions-lint.yml@<sha>` | PRs touching `.github/workflows/**` |
| `codeql.yml` | `kryota-dev/actions/.github/workflows/codeql.yml@<sha>` | push/PR to main |
| `setup-pr.yml` | `kryota-dev/actions/.github/workflows/…@<sha>` | PR opened |

All workflows set `permissions: {}` at the top level and grant only the minimum permissions per job. Checkouts use `persist-credentials: false` (ghalint policy 013).

### Renovate and ECC pinning

`.github/renovate.json5` manages all dependency updates. A `customManager` regex bumps the ECC `version` and `commit` fields together in `.chezmoidata.toml`. A `packageRule` forces the ECC package to **never auto-merge** because ECC updates ship executable hook code that requires manual review. The 168-hour external refresh interval (`refreshPeriod`) on `.chezmoiexternal.toml` entries is separate from the Renovate bump.

---

## Known issues (do not fix here)

**1. `home/.chezmoi.toml` does not exist in the source tree.**

The Ubuntu `setup-validation` job runs:

```yaml
cp home/.chezmoi.toml ~/.config/chezmoi/chezmoi.toml
```

The file `home/.chezmoi.toml` does not exist in the source tree. The `cp` runs unguarded (no `if [ -f ]` check) under GitHub Actions' default `set -e -o pipefail`, so the missing file causes `cp` to error and **abort the step** — apply does not proceed. `setup-validation.yml` has been failing on recent runs as a result. The `cp` is unnecessary because `.chezmoidata.toml` auto-loads without explicit configuration. This is tracked as a real bug for a separate fix.

**2. `benchmark.yml` reimplements the startup loop inline.**

As noted above, the CI benchmark inlines a 10-iteration `/usr/bin/time zsh -i -c exit` loop instead of calling `scripts/benchmark.sh`. This means improvements to the local script (e.g. configurable iterations, cold-start measurement) do not automatically apply to CI. Tracked for a separate fix.

**3. `setup-validation.yml` references a stale `run_once_after_30-setup-fonts.sh.tmpl`.**

The macOS exclusion list in `setup-validation.yml` still references `home/run_once_after_30-setup-fonts.sh.tmpl`. That script no longer exists — fonts are now deployed by the chezmoi engine itself via a `["Library/Fonts"]` external in `home/.chezmoiexternal.toml`. The `if [ -f "$f" ]` guard in the exclusion loop prevents this from causing a CI failure. Tracked for a separate cleanup.

---

## Cross-references

- Makefile targets and lint flags: [local-dev.md](local-dev.md)
- Worktree environment setup: [worktrees-and-env.md](worktrees-and-env.md)
- Skill provenance policy and ECC external management: [../agents/skills-provenance.md](../agents/skills-provenance.md)
