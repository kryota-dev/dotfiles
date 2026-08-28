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

`fh` is meant to run on untrusted checkouts, so neither location is taken at
face value. The two are resolved differently:

- **Config path — never derived from the working directory.** `HOME` must be an
  absolute path, and an `FH_CONFIG_PATH` override must be absolute too. A
  relative value resolves against the working directory, which would let a
  checked-out repository supply its own escalation policy.
- **State root — derived from the working directory's git topology, then
  verified.** The common directory is used only after it is confirmed absolute,
  not a symbolic link, a real git metadata directory, and **owned by the current
  working tree**. Ownership requires the working tree's `.git` to point at the
  reported git directory, plus one of: it is `<toplevel>/.git`; it is the common
  directory of a linked worktree whose admin directory links back to this
  working tree; or it is a submodule directory inside the superproject's
  metadata. Containment inside the working tree is deliberately *not* required,
  because a linked worktree's common directory legitimately lives outside it.
  `git init --separate-git-dir` is not supported: its topology cannot be
  distinguished from a repository redirecting `.git` at somebody else's
  metadata.
- **Readiness cache — partitioned per account scope** as `readiness.<scope>.json`,
  so a result verified under one profile is never reused by another.

Evidence contains diffs, command results, logs, traces, screenshots, browser
recordings, and accepted decisions. It never uses a model transcript or hidden
reasoning as its interchange format.

### Normalized state schema

The SQLite state is at schema version 2. Every record class is normalized, and
each one belongs to exactly one retention class:

| Table | Holds | Retention |
|---|---|---|
| `tasks` | the normalized task a run was started from | kept |
| `route_decisions` | the chosen capability, provider, **model, effort**, and reviewer | kept |
| `evidence` | raw payload references, a SHA-256 `content_hash` over the record's content fields, and the task/route it belongs to | raw |
| `adapter_runs` | one adapter execution: capability, provider, model, effort, status, start/finish, exit code | raw |
| `verification_results` | one deterministic check: kind, status, command, exit code, evidence reference | raw |
| `review_findings` | one finding: severity, uncertainty, summary, discriminating experiment, evidence reference | raw |
| `approvals` | what was authorized: kind, subject hash, scope, grantor, grant/expiry | **never pruned** |
| `telemetry_events` | content-free aggregate measurements (category, risk, provider/model/effort, timings, token counts, outcome) | aggregate |

`adapter_runs` deliberately records **no launch-mechanism detail** — no argv,
sandbox settings, profile path, interactive/non-interactive mode, conversation
ID, working directory, or environment. Those belong to the adapter, not to the
schema, so a later change in how adapters are started does not force a second
migration.

`content_hash` identifies the evidence **record**, not the artifact it points at. Its
input includes the artifact *path*, never the artifact's bytes, so rewriting a file on
disk does not change the hash. It is a deduplication and record-identity key, not
tamper-evidence; anything that needs byte-level integrity must carry its own digest
produced by the adapter that wrote the file.

`approvals.granted_by` is a recorded label, not proof of provenance: any code in the
harness can write `granted_by = 'user'`, and the column constraint only pins the
vocabulary. A consumer that exempts an escalation on the strength of an approval row
therefore must establish provenance itself — the schema does not carry it. Deciding how
an approval is proved and verified belongs to the onboarding work that will write these
rows, not to the schema that stores them.

`telemetry_events` has no free-form column at all. Every text column is either a
closed enum or a short lowercase token, so "aggregate telemetry contains no
content" is enforced by the schema rather than by convention. That is what makes
the longer aggregate window safe.

### Retention

Raw evidence and the per-run record classes have a
<!-- FACT:fh-raw-retention-days -->30<!-- /FACT -->-day window; content-free
aggregate telemetry has a <!-- FACT:fh-telemetry-retention-days -->180<!-- /FACT -->-day
window. Both values are configurable in `config.json` and are checked against the
named defaults in `retention.mjs`. Approvals are an audit trail and belong to
neither window: `fh clean` never deletes them.

Migrations run as ordered steps inside a single transaction. A failure rolls the
database back to its previous version *and* column layout, so an interrupted
upgrade cannot leave a half-migrated state. The version that decides which steps to
apply is read **after** the write lock is taken, because the state is shared by every
worktree: a version read before the lock can be stale by the time the steps run.

Every command that opens the state migrates it, `fh clean --dry-run` included. Dry run
means "delete nothing", not "open nothing" — a dry run against a v1 database could not
otherwise count the record classes v2 introduces.

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
expired raw records and expired aggregate telemetry on their own windows, and
leaves approvals alone; use `--dry-run` to inspect its impact first.

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
