# CI and Tests

🌐 日本語: [ci-and-tests.ja.md](ci-and-tests.ja.md)

← [Docs index](../README.md)

CI is a mirror of the local `make` commands. There is no separate CI lint logic — `make lint`, `make lint-node`, `make test-node`, and `make test-bats` are the contract, and CI just calls them. Together they cover everything `make test` runs locally.

---

## CI == local

The `ci.yml` workflow runs three jobs:

| Job | Command | Runner |
|---|---|---|
| `lint` | `make lint`, then `make lint-node` | `ubuntu-latest` |
| `test` | `make test-node`, then `make test-bats` | `ubuntu-latest` (needs: lint) |
| `sync-ghq-completion` | `make sync-ghq-completion` (+ auto-commit if the vendored `_ghq` changed) | `ubuntu-latest`, same-repo PRs only |

Before running `make lint`, the lint job installs shfmt (`v3.13.1`) from the GitHub release and `zsh` via `apt-get`. The test job installs `bats`, `shellcheck`, and `zsh` via `apt-get`. Both jobs then set up Node.js for the `*-node` targets: a `run` step reads the pinned version out of `home/dot_config/mise/config.toml` and feeds it to `actions/setup-node`, so the mise pin stays the only place the version is declared. No other CI-specific logic exists; the `Makefile` is the single source of truth.

Contributors should run `make test` locally before pushing — it chains the same four targets CI runs.

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
- The rate-limits snapshot is per-profile, per-field validated, 0600 under a lax umask, and never carries `effort` (#449).
- The [billable-delta contract](../agents/claude-code.md#billable-delta-cost): an `incl.` marker inside quota, raw totals when stdin carries no `rate_limits`, and increments above the baseline once a window is exhausted. The baseline anchors on the later-resetting window, hands over before that window rolls over, is re-taken when its window rolls over, is dropped when the windows have room again, carries the daily remainder across a day change, clamps negative deltas to zero, stays session-scoped, and is written 0600.

The USD→JPY rate and the `ccusage` daily total are seeded into the throwaway `XDG_CACHE_HOME` before the billing assertions run. That pins the rendered amounts *and* keeps the background rate/usage refreshes from firing, so the suite needs no network.

### `tests/zsh_aliases.bats`

Behavioral regression guard for the unified claude/codex launcher wrapper scripts (`home/dot_local/launchers/executable_{claude,codex}`) and the residual zsh helpers left in `claude.zsh`. The wrappers are exercised directly: the test builds a launcher dir mirroring the chezmoi layout (the two wrapper scripts plus the `cld`/`cld-r06`/`cdx`/`cdx-r06` `$0`-dispatch symlinks) and a stub "real" binary — `CLAUDE_LAUNCHER_BIN`/`CODEX_LAUNCHER_BIN` override the real-binary resolution so the wrapper execs the stub, which dumps the env and argv it received — so no mise/brew/codex install is needed (CI-safe). Key assertions:

- **Account selection.** `claude`/`cld` derive the per-account env (`CLAUDE_CONFIG_DIR`, `ECC_AGENT_DATA_HOME`, `CLV2_HOMUNCULUS_DIR`, `GATEGUARD_STATE_DIR`) for the personal account and behave identically to each other; `cld-r06` selects the work account unconditionally. A dedicated test pins the fill-gaps/override isolation invariant: a bare `claude` keeps an inherited r06 `CLAUDE_CONFIG_DIR` (a hook-spawned child stays on its parent session's account), while `cld-r06` overrides an inherited personal account back to r06. Another test asserts `CLV2_HOMUNCULUS_DIR` never resolves under the config dir for either account (#336).
- **Observer knobs and secrets.** `ECC_OBSERVER_TIMEOUT_SECONDS`, `OBSERVER_ACTIVE_HOURS_START`/`END`, and `ECC_OBSERVER_MAX_TURNS` default correctly and stay overridable. The wrapper sources the MCP keys file itself and exports the keys, but a caller-set key (even an empty one, as `morning-radar` uses to opt out of web search) is not overwritten. `claude-config`'s `ECC_DISABLED_HOOKS_EXTRA` prefix reaches the execed process through the wrapper's full env inheritance.
- **Fail-loud.** Both wrappers exit non-zero with a diagnostic message when the real binary cannot be resolved, rather than silently doing nothing.
- **Codex account selection.** `codex`/`cdx` follow `CLAUDE_CONFIG_DIR` (including the case where a mismatched inherited `CODEX_HOME` must not leak across accounts — the cross-account leak #345 closes); `cdx-r06` overrides `CODEX_HOME` unconditionally; an explicit `CODEX_HOME` is respected only when no `CLAUDE_CONFIG_DIR` is in scope.
- **`--profile shared` injection.** Injected only when argv carries no `--profile`/`-p` flag (all forms: `--profile x`, `--profile=x`, `-p x`, `-px`); a `--profile` substring inside a prompt argument does not falsely suppress injection; the scan stops at a literal `--`; the flag is always inserted ahead of any subcommand (`exec`, `exec review`).
- **Residual zsh helpers.** `_claude_fable` (pins `claude-fable-5`, appends the orchestrator prompt file when readable, passes the caller's own flags through before the fable flags), `cldf`/`cldf-r06` (wire the Fable orchestrator per account), and `claude-config` (prefixes the hook opt-out and pins the default account) are driven with `zsh -fc` sourcing `claude.zsh`, as before.

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

Files excluded by **both** jobs (<!-- FACT:ci-both-exclusion-count -->7<!-- /FACT --> files):

- `home/private_dot_aws/config.tmpl`
- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl`
- `home/run_once_before_00-install-prerequisites.sh.tmpl`
- `home/run_onchange_before_10-brew-bundle.sh.tmpl`
- `home/run_once_after_11-validate-1password.sh.tmpl`
- `home/dot_config/git/private_gitleaks-own.toml.tmpl`
- `home/dot_config/ntfy/private_server.yml.tmpl`

Files excluded by the **macOS job only**:

- `home/run_once_after_90-other-apps.sh.tmpl`
- `home/run_once_after_30-setup-fonts.sh.tmpl` — **stale**: this script no longer exists; the `if [ -f ]` guard tolerates the missing file silently (see Known Issues)

Most entries are 1Password-backed templates (they call `op` at apply time). `home/dot_config/ntfy/private_server.yml.tmpl` is the exception: since base-url was dropped (#337) it no longer reads 1Password, but it stays excluded because it is a 0600 config of container-only paths with no CI value in rendering. When adding a new template that calls `op` at apply time (or is otherwise CI-incompatible), add it to the exclusion list in both jobs.

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

## `renovate-triage.yml` — weekly Renovate triage

Runs on a `schedule` (every Monday at 00:00 UTC = 09:00 JST) and on `workflow_dispatch`, on `ubuntu-latest`. It runs [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) in automation mode (a `prompt` input, no `@claude` mention) to triage open Renovate PRs **read-only**: it collects them with `gh`, classifies each by risk / CI state / semver, analyzes the risky ones, then posts a consolidated summary comment to the Dependency Dashboard (issue #12) and a per-PR detail comment on each analyzed PR. The inlined prompt is written in Japanese so the posted comments are in Japanese (the same convention as agent definitions and the Fable orchestrator prompt).

The workflow **never merges** — merging stays local and human-approved via the `renovate-sweep` skill (`home/dot_agents/skills/renovate-sweep/SKILL.md`), the conceptual source of truth for the classification rules inlined in the prompt. Read-only is enforced by defense-in-depth: the job grants only `contents: read` + `issues: write` + `pull-requests: write` (no `contents: write`); the `--allowedTools` allowlist holds only read-only `gh` subcommands plus one create-only comment wrapper (`scripts/renovate-triage-comment.sh`, which posts a comment only to issue #12 or an open Renovate PR and never edits/deletes — covered by `tests/renovate_triage_comment.bats`); the agent has no arbitrary Bash (only read-only `gh` subcommands and the wrapper — no `echo`/`printenv`/`cat`); and the prompt treats all fetched data as untrusted and forbids emitting secrets. (The subprocess env scrub `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is intentionally not enabled: it hard-requires bubblewrap, which the action installs only in its `allowed_non_write_users` mode, so setting it made Claude Code fail to start.) Auth passes the job-scoped `github.token` explicitly (so the action does not fall back to an OIDC path needing `id-token: write`) and the `CLAUDE_CODE_OAUTH_TOKEN` repository secret (from `claude setup-token`); the action ref is SHA-pinned, `automerge: false` in Renovate, and tracked like every other `uses:`.

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
