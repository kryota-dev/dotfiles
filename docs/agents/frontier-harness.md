# Frontier Harness

🌐 日本語: [frontier-harness.ja.md](frontier-harness.ja.md)

← [Agent overview](overview.md)

`frontier-harness` (`fh`) is the model-independent execution layer behind the
evolving `pr-workflow`. It routes a normalized task to a provider capability,
records evidence in repository-local runtime state, and makes deterministic
verification higher priority than any model's self-assessment.

The initial rollout is **shadow**. It records route, verification, and review
plans but does not start provider write runs. This keeps the existing
`pr-workflow` execution path intact while the router collects evidence.

## Installation and readiness

Homebrew installs the Antigravity CLI through the `antigravity-cli` cask. Its
global safety settings are deployed to `~/.gemini/antigravity-cli/settings.json`.
The user must start `agy` interactively once to complete keychain-backed login;
the harness never stores an API key or copies a credential.

Run the readiness check from a repository:

```bash
fh doctor --json
```

The report distinguishes a visible executable from a capability that can be
used in the active account scope. Antigravity is personal-only until a
vendor-supported work-account mapping is explicitly verified. In an `r06`
session, no automatic fallback to a personal `agy` credential is allowed.

The account scope is derived from the `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
suffixes that the `cld` and `codex` launchers set per invocation. When both
variables are absent, when they disagree, or when one carries an unrecognized
value, the scope resolves to `unknown` and every capability that declares an
`accountScope` stays unavailable. The launchers do not export those variables
globally, so `fh doctor` run from a plain shell reports
`accountScope: "unknown"`. That is the intended fail-closed default rather than
a misconfiguration.

## State and evidence

Configuration, policy, and mutable state have different owners:

| Location | Contents | Git state |
|---|---|---|
| `$HOME/.config/frontier-harness/config.json`, or an absolute `FH_CONFIG_PATH` | capability registry, rollout, retention | chezmoi-managed |
| `<repo>/.harness/policy.json` | approved repository capability manifest (written by `fh onboard`; enforcement lands with the onboarding step) | repository policy |
| the verified `git rev-parse --git-common-dir` + `frontier-harness/` | SQLite state and raw artifacts | runtime-only, shared by worktrees |

Both locations are resolved without consulting the working directory, because
`fh` is meant to run on untrusted checkouts:

- `HOME` must be an absolute path, and an `FH_CONFIG_PATH` override must be
  absolute too. A relative value resolves against the working directory, which
  would let a checked-out repository supply its own escalation policy.
- The git common directory is used only after it is confirmed absolute, not a
  symbolic link, a real git metadata directory, and **owned by the current
  working tree**: `<toplevel>/.git`, the common directory of a registered linked
  worktree, or a submodule directory inside the superproject's metadata.
  Containment inside the working tree is deliberately *not* required, because a
  linked worktree's common directory legitimately lives outside it.
- Readiness probes are cached per account scope as `readiness.<scope>.json`, so
  a result verified under one profile is never reused by another.

Evidence contains diffs, command results, logs, traces, screenshots, browser
recordings, and accepted decisions. It never uses a model transcript or hidden
reasoning as its interchange format. Raw evidence has a 30-day retention window;
aggregate telemetry has a 180-day window.

## Repository onboarding

Approve a repository's command/domain/capability manifest once rather than
interrupting every task or every wave child:

```bash
fh onboard --manifest candidate.json
fh onboard --manifest candidate.json --approve --json
```

Unknown commands and domains are not executed. Queueing them for a single
wave-level batch approval is planned for the onboarding step and is not part of
this shadow foundation: today `fh onboard` records an approved manifest and no
command consumes it yet. Credentials, migrations, external contract changes,
deploys, force pushes, releases, and merges remain explicit escalations.

## Shadow commands

```bash
fh run --task task.json --json
fh verify --command "npm run test" --json
fh review --task task_example --json
fh status --json
fh clean --dry-run --json
```

In shadow mode `run`, `verify`, and `review` persist a normalized plan without
starting a provider or arbitrary shell command. `clean` reports and removes
expired raw evidence; use `--dry-run` to inspect its impact first.

## Worktrees and rollout

`pr-workflow` owns the primary worktree and PR branch. When a non-shadow route
needs independent writable candidates, the harness will create only disposable
child worktrees through `wtp`; read-only investigation does not create one.
A verified, cleanly applicable candidate may move into the primary worktree,
but merge and other irreversible external actions always remain with the user.

The promotion path is shadow → pilot → default. A `--legacy` rollback flag is
planned for that promotion work and is not implemented yet. Until then the
rollout stays on `shadow`, which the CLI enforces as an explicit guard rather
than relying on the provider adapter being absent.
