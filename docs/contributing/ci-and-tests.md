# CI and Tests

🌐 日本語: [ci-and-tests.ja.md](ci-and-tests.ja.md)

← [Docs index](../README.md)

CI is a mirror of the local `make` commands. There is no separate CI lint logic — `make lint`, `make lint-node`, `make lint-console`, `make test-node`, and `make test-bats` are the contract, and CI just calls them. Together they cover everything `make test` runs locally.

---

## CI == local

The `ci.yml` workflow runs three jobs:

| Job | Command | Runner |
|---|---|---|
| `lint` | `make lint`, `make lint-node`, then `make lint-console` | `ubuntu-latest` |
| `test` | `make test-node`, then `make test-bats` | `ubuntu-latest` (needs: lint) |
| `sync-ghq-completion` | `make sync-ghq-completion` (+ auto-commit if the vendored `_ghq` changed) | `ubuntu-latest`, same-repo PRs only |

Both jobs resolve their shell tooling from the mise pin: a `run` step reads the version out of `home/dot_config/mise/config.toml`, the install step fetches that exact GitHub release, and it then asserts the installed binary reports the pinned version. The lint job does this for shellcheck and shfmt; the test job does it for shellcheck, which `tests/shellcheck.bats` and `tests/brew_launcher.bats` invoke directly. Both jobs do it for deno: the lint job runs `make lint-console`, and the test job runs `tests/console_lint.bats`, which drives that target itself. Deno is installed here purely as the linter behind the console guard — `make lint-deno` and `make test-deno` remain opt-in and are still not run in CI. `zsh` still comes from `apt-get` in both jobs, as do `bats` and `jq` in the test job. Node.js follows the same read-the-pin pattern and is fed to `actions/setup-node`. The mise pin is therefore the only place any of these versions is declared. Until #475 the lint job installed no shellcheck at all and silently linted with the runner image's build, so a local `make lint` could pass while CI failed on the same diff; `tests/files.bats` now guards against a version literal coming back into the workflow. No other CI-specific logic exists; the `Makefile` is the single source of truth.

Contributors should run `make test` locally before pushing — it chains the same five targets CI runs.

### Triggers

`ci.yml` fires on push to `main` and on pull requests targeting `main`, but only when relevant paths change: `home/**`, `tests/**`, `scripts/**`, `Makefile`, or `.github/workflows/ci.yml`. It also supports `workflow_dispatch` for manual runs.

---

## Bats test suite

All tests live under `tests/` and are run together via `bats tests/*.bats`. The helper `tests/helpers/setup.bash` defines `REPO_ROOT` and `HOME_DIR` (= `<repo>/home`) for every test file.

It also defines `_mktemp_dir`, and every test must take its scratch directory from there rather than calling `mktemp -d` directly: macOS's `mktemp` consults `TMPDIR` only when given a template, so a bare call lands in `/var/folders/…/T` and fails under a sandboxed session, turning the whole suite red for reasons unrelated to the change under test. `tests/tmpdir_policy.bats` enforces this mechanically (#642).

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

### `tests/console_lint.bats`

Behavioural tests for `make lint-console`, the guard that replaced the `stop:check-console-log` hook retired in #520 (#522). The target's `CONSOLE_LINT_ROOTS` variable is overridden to point the scan at a fixture tree in `BATS_TEST_TMPDIR`, so the failing cases can be asserted without planting a violation in the repo. Covered: a bare `console.log` fails; `console.error` / `console.warn` fail too (the rule is `console.*`, not `console.log` alone); a `// deno-lint-ignore no-console` comment exempts its own line but not a second call in the same file; a directive that outlives its console call is reported as `ban-unused-ignore`; a whole-file `// deno-lint-ignore-file no-console` — and a bare one — is rejected, while one naming only unrelated rules is left alone; `process.stdout.write` passes; `console.log` inside a string literal passes (the check is AST-based, not textual); each of the eight declared extensions is individually confirmed to be scanned, at any depth; an empty tree fails rather than silently passing; the default roots really do cover both `home/` and `tests/` (driven against a throwaway copy of the `Makefile`, since every other case overrides the roots); a missing deno is fatal rather than a skip; the repository itself passes; the `server.ts` exemption does not break `make lint-deno`; the target is wired into `make test`; and both CI jobs resolve deno from the mise pin without repeating the version, with the target itself bound to the lint job.

These drive the target rather than asserting on its text: a guard that still exists but no longer detects anything passes every textual assertion, which is the failure mode the issue was filed about. Nothing here skips when deno is absent, for the same reason.

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
- **Residual zsh helpers.** `_claude_fable` (pins `claude-fable-5-1`, appends the orchestrator prompt file when readable, passes the caller's own flags through before the fable flags), `cldf`/`cldf-r06` (wire the Fable orchestrator per account), and `claude-config` (prefixes the hook opt-out and pins the default account) are driven with `zsh -fc` sourcing `claude.zsh`, as before.

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

## `renovate-gate.yml` / `renovate-review-action.yml` / `renovate-digest.yml` — the Renovate merge gate

Renovate PRs merge unattended. These three workflows decide whether a given one may.
The design — the classifier's verdict table, the three-layer fail-closed argument, how
to approve or reject, and the ruleset that has to be created by hand in the GitHub UI —
lives in [Renovate automation](../architecture/renovate-automation.md). What belongs
here is the CI shape.

**`renovate-gate.yml`** runs on every `pull_request` (`opened` / `synchronize` /
`reopened`) and reports the `renovate-gate` commit status, registered as a required
status check on `main`. It resolves authorship from the webhook payload rather than a
`gh` call — an API failure has no safe answer, since "unknown means not Renovate"
reports success on an unreviewed update while "unknown means Renovate" blocks human PRs
during an outage. A PR that is not Renovate's gets `success` immediately, because a
required check that never reports would leave every human PR at pending. Renovate's own
PRs go through `scripts/renovate-gate-classify.sh` (shell only, no agent session) and
only the ones it cannot positively clear reach
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
The reporting step runs with `if: always()`, so a crashed or timed-out agent produces a
`failure`, never a silent pass. Fork PRs are the one gap: GitHub hands them a read-only
`GITHUB_TOKEN` that `permissions:` cannot widen, so the workflow explains that in the
job summary instead of dying on a 403.

**`renovate-review-action.yml`** runs on `pull_request_review`. Its **first** step
checks the reviewer's collaborator permission — this repository is public, so anyone can
submit an approving review and "a review exists" proves nothing. Every later step is
gated on that result (`tests/files.bats` walks the steps to prove it, rather than
checking that the condition merely appears somewhere).

**`renovate-digest.yml`** runs weekly (Monday 00:00 UTC = 09:00 JST) and on
`workflow_dispatch`, posting a catch-up digest to the Dependency Dashboard (issue #12).
It holds no `statuses` permission: it must never be able to influence the gate.

**The agent's write surface is structurally limited in all three.** It never gets
arbitrary Bash — the `--allowedTools` allowlist holds read-only `gh` subcommands plus
at most two wrappers: `scripts/renovate-gate-verdict.sh`, which writes one local JSON
file and never touches the network, and the create-only
`scripts/renovate-triage-comment.sh`, which comments only on issue #12 or an open
Renovate PR and never edits or deletes. `scripts/renovate-gate-status.sh` — the script
that actually reports the required status — is deliberately **absent** from every
allowlist and is invoked only by workflow steps, so an agent cannot mark its own review
as passing. `tests/files.bats` compares each allowlist against its expected set exactly;
a denylist of known-bad strings would still pass a grant widened to `Bash(gh:*)`. There
is no `issue_comment` trigger anywhere, because on a public repository that would take
orders from anyone who can type in the comment box. The prompts treat all fetched data
as untrusted and forbid emitting secrets. (The subprocess env scrub
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is intentionally not enabled: it hard-requires
bubblewrap, which the action installs only in its `allowed_non_write_users` mode, so
setting it made Claude Code fail to start.) Auth passes the job-scoped `github.token`
explicitly — without it the action falls back to an OIDC exchange needing
`id-token: write` — plus the `CLAUDE_CODE_OAUTH_TOKEN` repository secret (from
`claude setup-token`). The action ref is SHA-pinned and tracked like every other
`uses:`; a bump to it reaches the gate as a `digest` update, which the classifier always
routes to agent review.
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

`.github/renovate.json5` manages all dependency updates. A `customManager` regex bumps the ECC `version` and `commit` fields together in `.chezmoidata.toml`. ECC updates ship executable hook code that runs in every agent session, so they never take the merge gate's deterministic fast lane: `scripts/renovate-gate-classify.sh` names `affaan-m/ecc` in its always-review list, and an agent reviews every bump regardless of how small the diff looks. (This replaced an `automerge: false` packageRule, which could only key on updateType and so could not tell an ECC bump apart from any other tagged release.) The 168-hour external refresh interval (`refreshPeriod`) on `.chezmoiexternal.toml` entries is separate from the Renovate bump.

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
