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

## State and evidence

Configuration, policy, and mutable state have different owners:

| Location | Contents | Git state |
|---|---|---|
| `~/.config/frontier-harness/config.json` | capability registry, rollout, retention | chezmoi-managed |
| `<repo>/.harness/policy.json` | approved repository capability manifest | repository policy |
| `git rev-parse --git-common-dir` + `frontier-harness/` | SQLite state and raw artifacts | runtime-only, shared by worktrees |

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

Unknown commands and domains are not executed. They enter a queue that a wave
can approve in one batch. Credentials, migrations, external contract changes,
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

The promotion path is shadow → pilot → default. `--legacy` remains the rollback
path until telemetry and representative skill evaluations demonstrate that the
new route is reliable.
