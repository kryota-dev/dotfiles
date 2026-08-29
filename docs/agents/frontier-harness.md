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
| `<repo>/.harness/policy.json` | approved repository capability manifest (written by `fh onboard`, checked before every routed run) | repository policy |
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
vocabulary. Repository onboarding therefore does not rest on that column. It binds an
approval to a manifest by recording a `repository_manifest` row whose `subject_hash` is
the SHA-256 of the normalized manifest and whose `scope` is the resolved state root, then
re-deriving that hash from `.harness/policy.json` before every routed run. The two live in
different stores — the policy travels with the checkout, the ledger does not — so editing
the policy after approval no longer verifies, even if its self-reported hash is recomputed
to match. See [Repository onboarding](#repository-onboarding) for the boundary this does
and does not draw.

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

## Approval channel

`claude -p` only exposes `AskUserQuestion` when a `--permission-prompt-tool` is wired in, and
both permission requests and questions then arrive as **synchronous MCP tool calls**. `fh`
provides that endpoint so a wave child can reach the user without a terminal: nothing reads a
screen, nothing sends keystrokes, and nothing has to guess whether a prompt is still
unanswered — being called *is* the question, and the return value *is* the answer.

Wire it into a child session as its own MCP server, and keep the two hardening flags that make
the channel a trust boundary rather than a suggestion:

```bash
MCP='{"mcpServers":{"fh-approve":{"command":"fh","args":["approve-server","--session","<session-id>"]}}}'
claude -p --mcp-config "$MCP" --strict-mcp-config --setting-sources user \
  --permission-prompt-tool mcp__fh-approve__approve ...
```

`--strict-mcp-config` keeps a checked-out repository from injecting another MCP server beside
the approver, and `--setting-sources user` (or `--bare`) keeps its `.claude/settings.json`
hooks from running. Launching the child is the wave orchestrator's job and is not part of this
command.

### Escalation rules

Escalation rules live in **a different file from the repository capability manifest**, because
the two fail in opposite directions. A gap in the manifest is fail-closed — something does not
run, and you find out. A gap in the escalation rules is fail-open — something runs without
anyone being asked, and you do not. Keeping them in one file hides that asymmetry.

The consequence is a deliberately lopsided design:

- The **baseline rules are constants in `approval-rules.mjs`**, not data. They cover merges,
  force pushes, history rewrites, working-tree rollbacks, releases, outward-facing writes,
  credential access, deploys, database migrations, and writes aimed at the approval queue
  itself. No file can remove or weaken one.
- An optional `$HOME/.config/frontier-harness/approval-rules.json` (or an absolute
  `FH_APPROVAL_RULES_PATH`) may **only add** rules through `additionalRules`, and may only move
  the unmatched default in the stricter direction with `defaultDecision: "escalate"`. There is
  no key that subtracts.
- The path is never derived from the working directory, for the same reason `config.json`
  is not: a checked-out repository must not be able to supply its own escalation policy.
- A malformed rules file **refuses to start** rather than quietly falling back to the baseline.
  Silently dropping the rules a user deliberately added is the fail-open regression this whole
  arrangement exists to prevent.

Before a rule is matched, the command string is tokenized and its **global options are
skipped using a per-binary arity table**, so `git -C <path> merge` is recognized exactly
as `git merge` is. That table is what makes the two hard cases come out right: in
`git -C merge status` the word `merge` is the *value* of `-C` and the real subcommand is
the benign `status`, while in `git -p merge` the `-p` takes no value and the `merge` is
real. Backslash word-splitting and `${IFS}` substitution are normalized away. A command
whose name or subcommand is built dynamically, or that runs another command through a
shell or a wrapper like `sudo`, cannot be interpreted at all — those escalate rather
than falling through to the unmatched default.

Matching a rule does **not** deny. It escalates — the user is asked, synchronously.
`AskUserQuestion` escalates regardless of any rule, and the approver never answers one itself:
it cannot check a claim against a primary source, so it is not given the power to try.

Anything that matches no rule is allowed. That direction is fail-open by construction, and two
things bound it: read-only calls are auto-approved before they ever reach the prompt tool, so
the channel never sees them, and the baseline set cannot be shrunk. Matching over shell command
strings is a speed bump, not a boundary — normalization closes the cheap tricks and the
uninterpretable ones escalate, but a command determined to avoid the rules can still be spelled
in a way no static matcher will catch.

`fh approve-server` takes `--session`, `--approvals-dir`, `--rules`, `--timeout-ms`, and
`--progress-interval-ms`. Both path flags must be absolute, for the same reason the rules
file is never resolved from the working directory.

### Reaching the user

An escalation is written to the state root as one file per request, so several children
stopping at once never contend:

| File | Writer | Holds |
|---|---|---|
| `<state root>/frontier-harness/approvals/<id>.request.json` | `approve-server` | the tool call, the rule it matched, and the outcome once decided |
| `<state root>/frontier-harness/approvals/<id>.answer.json` | the responder | the user's decision |

Each file has exactly one writer, so nothing is ever lost to a concurrent update. The answer is
published with `O_EXCL` plus `link(2)` rather than a rename, so a request is answered once and a
second writer loses rather than silently overwriting the first.

Two responders are interchangeable, and the queue does not encode which one is in use:

```bash
fh approvals --json                                    # what is waiting, and why
fh approve --request <id> --allow                      # let it through
fh approve --request <id> --deny --message "..."       # refuse, with a reason for the model
fh approve --request <id> --allow --answers '{"Which colour?":"Red"}'   # AskUserQuestion
```

The wave orchestrator normally relays — it reads the queue, asks the user, and writes the answer
back — but the user can answer directly with the same commands. That matters: if the
orchestrator dies, the pending approvals stay decidable. Answers to `AskUserQuestion` are
validated against the offered options on **both** sides, so a decision the user never expressed
cannot reach the model through a typo or a hand-edited file.

### Waiting

A permission prompt tool blocks its caller, so the escalation window is bounded on two sides.

| Value | Setting |
|---|---|
| <!-- FACT:fh-approval-timeout-ms -->28800000<!-- /FACT --> ms (8 h) | how long an escalation waits before it denies itself (`--timeout-ms`, clamped to <!-- FACT:fh-approval-max-timeout-ms -->86400000<!-- /FACT --> ms, which stays under the `MCP_TOOL_TIMEOUT` default) |
| <!-- FACT:fh-approval-progress-interval-ms -->60000<!-- /FACT --> ms | how often a `notifications/progress` message is sent while waiting (`--progress-interval-ms`) |

The progress messages exist to reset `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, which is 30 minutes
for stdio; without them the call is cut off long before a sleeping user could answer. An
interval at or above that idle timeout is rejected at startup rather than accepted and
quietly useless.

When the window closes, the request is denied automatically and the record keeps the tool
input, session, and tool-use id, so the child ends cleanly and the escalation can be replayed
later. Closing stdin or signalling the server does the same thing under a different status. A
decision the user already recorded outranks all of them — an answer that lands together with
the shutdown is honoured, not converted into a denial.

### What this does not defend against

Every process running as the same user can write into the approval queue, including the child
whose request is waiting there. A child that wants to approve itself can, and no arrangement of
file permissions changes that; only running the responder under a different uid would. This is
the same caveat that applies to `approvals.granted_by` in the state schema — the record says
who granted an approval, it does not prove it. The baseline rule that escalates any command
referencing the approval directory is defence in depth, not a boundary: it is matched over a
command string, so it inherits the limits above and can be avoided by a command written to
avoid it.

## Repository onboarding

Approve a repository's command/domain/capability manifest once rather than
interrupting every task or every wave child. Approval takes **two runs**, and the
second must name the request the first issued:

```bash
fh onboard --manifest candidate.json                       # review; prints a request id
fh onboard --manifest candidate.json --approve --request <id> --json
```

`--approve` without `--request` is refused. The request id is unguessable and lives in the
state root, so a single invocation cannot both propose a manifest and approve it — the id
only exists once the review run has printed the manifest for a human to read. A request is
single use, expires after
<!-- FACT:fh-onboard-request-ttl-ms -->86400000<!-- /FACT --> ms (24 h), is rejected when
the process approving it is the one that created it, and stops verifying the moment the
manifest changes underneath it.

### What enforcement actually checks

`fh run` and `fh verify` load `.harness/policy.json`, re-derive its manifest hash, and
require a matching `repository_manifest` row in the approvals ledger for this state root.
A repository with no policy is treated as an **empty** manifest, so everything is
unapproved — the default is fail-closed, not fail-open. Then:

- **Commands** are tokenized with the same analyzer the approval channel uses, and matched
  as normalized segments. `npm run test; curl …` splits into two segments, and the second
  has no approved match, so it is refused. A command that cannot be interpreted statically
  — built dynamically, or run through a shell or wrapper — is refused rather than guessed at.
- **Domains** are matched exactly against the approved list, and a manifest can only
  approve a domain that is not an internal or metadata address. Every `inet_aton` spelling
  of an address is decoded first, so `169.254.169.254`, `2852039166`, `0251.0376.0251.0376`,
  `0xA9FEA9FE`, and `169.254.43518` are all rejected as the one address they are. Private,
  carrier-grade NAT, link-local, multicast, reserved, unspecified, IPv4-mapped and
  NAT64-embedded ranges are rejected the same way. `localhost`, `127.0.0.1`, and `::1` stay
  approvable **as literals**, because a local dev server is a legitimate target; a name that
  *resolves* to loopback is not. Approval resolves each name and refuses if any answer lands
  in a blocked range, and refuses names it cannot resolve at all.
- **Capabilities** are matched against the capability the router chose, so a manifest that
  does not list `executor.default` stops that route.

Anything unapproved is not executed. The route is recorded as an `escalation`, the request
is written to a gap queue in the state root (one file per item, created-only so concurrent
wave children never overwrite each other), and the command exits 2. Review the queue and
approve it at a wave boundary through the same two-step ceremony:

```bash
fh gaps --json
fh onboard --from-gaps                                     # review; prints a request id
fh onboard --from-gaps --approve --request <id> --json
```

`--from-gaps` proposes the approved manifest plus every queued item that a manifest is
allowed to hold, and reports the rest as `gapsRejected` rather than failing the whole
batch. Rejected items stay unapproved. Credentials, migrations, external contract changes,
deploys, force pushes, releases, and merges remain explicit escalations.

### How an approval is superseded

The approvals ledger is append-only — it is the audit trail, and `fh clean` never prunes it.
Authorization therefore cannot live in the ledger alone: "any recorded row matches" would
mean a manifest approved once stays approved forever, so narrowing a manifest would not
actually revoke anything and restoring an older `.harness/policy.json` would re-enable it.

So the two are separate. The ledger records **what was approved and when**; a pointer in the
state root records **which approval is in force**, and approving again replaces it. Checking
a policy means re-deriving its manifest hash and comparing it to that pointer, then
confirming the pointer's approval still has its ledger row.

The pointer is keyed by the **policy file's path**, not by the repository. A state root is
shared by every linked worktree of a repository while each worktree has its own
`.harness/policy.json`, so a repository-wide pointer would let the worktree that onboarded
most recently silently un-approve the others. Keying by path also removes any need to order
approvals by time, which the random ids in the ledger cannot do meaningfully.

### The boundary this does not draw

Binding a policy to the approval in force detects a policy edited, replaced, reverted to a
previously approved version, or copied in from another repository — the checkout carries the
policy, and never the state root. It does **not** draw these boundaries:

- **An attacker already running as the same uid.** They can rewrite the pointer and the
  ledger as easily as the policy. This is the same caveat that applies to
  `approvals.granted_by` and to the approval directory: the record says what was approved, it
  does not prove who approved it.
- **An autonomous agent approving its own request.** The two-step ceremony refuses an
  approval from the process that created the request, so a single invocation cannot approve
  itself. Two invocations can — anything with a shell can read the request id from the review
  run's output and pass it to a second run. What the ceremony guarantees is that the manifest
  was printed for review before it could be approved, not that a human read it.
- **A domain whose address changes after approval.** Names are resolved when the manifest is
  approved, not when a task runs, so `fh run` and `fh verify` match domain strings only. A
  name that resolves somewhere harmless at approval time can point at an internal address
  later. The layer that actually opens a connection must re-check at that moment; that layer
  arrives with the rollout promotion.
- **`fh review`.** It records a review plan without consulting the manifest. The deterministic
  verifier and review registry own that path, and gating it belongs with them.

Upgrading an existing repository requires re-running the ceremony, because a policy written
before enforcement has no approval in force behind it.

## Shadow commands

```bash
fh run --task task.json --json
fh verify --command "npm run test" --json
fh review --task task_example --json
fh status --json
fh clean --dry-run --json
fh gaps --json
```

A task declares what it needs: `requiresApproval` when a human has to decide something
mid-run, `requiresWrite` when the run modifies files. Both default to false, and both are
matched against what the chosen provider declares — see *The route is gated on approval
channel and write access* below.

In shadow mode `run`, `verify`, and `review` persist a normalized plan without
starting a provider or arbitrary shell command. `clean` reports and removes
expired raw records and expired aggregate telemetry on their own windows, and
leaves approvals alone; use `--dry-run` to inspect its impact first.

## Provider adapters

The three CLIs are not interchangeable. Their non-interactive capabilities are asymmetric, so each
provider gets its own adapter rather than one parameterised launcher:

| | Claude Code | Codex | Antigravity |
|---|---|---|---|
| launch | `-p` with `--output-format stream-json` | `codex exec --sandbox <mode> --json` | `-p --output-format json` |
| resume | `--resume <session id>` | `codex exec resume <thread id>` | `--conversation <id>` |
| sandbox | settings JSON via `--settings`; no `--sandbox` flag exists | `--sandbox` on launch, `-c sandbox_mode="…"` on resume | not expressible: `--sandbox` does not stop file writes |
| working-tree config | blocked by `--setting-sources user` and `--strict-mcp-config` | no flag adds a source; configuration comes from `$CODEX_HOME` | no flag adds a source (implicit discovery unmeasured) |
| approval channel | external round trip | agent review | none |
| success | `result` event, `is_error`, `permission_denials[]` | `turn.completed` and `error` events | **cannot be determined** from exit code and status alone |

Adapters are pure: they build an invocation and interpret a process result. They never import
Node's child-process API, which a test pins by reading their sources. `createAdapterExecutor`
therefore requires an injected runner and ships **no default** — starting real processes belongs to
the rollout promotion, not to this layer. The insertion point is the `executor` argument of
`runWithRolloutGuard`, so a `shadow` rollout still never reaches a provider.

An invocation carries a provider, an absolute executable path, an argv array, optional stdin, and
its phase. It has no environment or credential field at all: authentication stays with each CLI's
own launcher and keychain, and the harness never handles a token or a profile path.

Everything that reaches argv is shape-checked first. A capability's model and effort go inside
Codex's `-c key=value`, so a value carrying a quote or an equals sign could inject a different
setting — `sandbox_mode` included. Resume identifiers, session ids, and prompt-tool names get the
same treatment for a different reason: Codex takes its session id as a *positional* argument, so a
value beginning with `-` lands where a flag would. Codex additionally allows only the flags this
adapter itself emits, so a flag smuggled through any position fails the sandbox read-back rather
than relying on a denylist that has to chase every new CLI flag.

### The sandbox is sealed at construction

Codex accepts `-s/--sandbox` when it starts a run and rejects it when it resumes one; the only
sandbox-related flag `codex exec resume` accepts is the one that *weakens* containment. Writing that
asymmetry by hand produces a resumed run that silently falls back to the configured default.

Every invocation — launch or resume — is therefore built through `sealInvocation`, which reads the
effective sandbox back out of the argv it has just produced and throws when it does not match what
the caller asked for. A resume form that forgets the config override fails when it is built, not
when somebody reviews it. `resume` also takes the sandbox policy as a required argument, so "resume
without a policy" has no representation.

The policy vocabulary is deliberately small: `read-only` and `workspace-write`, with no value
meaning "no sandbox" — a resume path could otherwise fall into it — and no network axis, because the
allowlist syntax has never been measured. Network containment is *not* uniform across providers, and
the harness does not claim it is: Claude renders a strict allowlist in its settings blob and Codex
leaves `workspace-write` networking off by default, both measured, but Antigravity's network default
was never established and the adapter emits nothing that controls it.

### The working tree cannot configure the child

A child session runs inside a worktree with an issue's branch checked out, so
`.claude/settings.json`, `.claude/settings.local.json`, and `.mcp.json` reach it from outside the
trust boundary. The interactive CLI asks before it trusts a folder; `-p` does not. It also ignores a
settings file that fails validation without saying so, and a session's first hooks run before any
structured event is available to read. Detecting the problem from the output is late by
construction, so the blocking belongs in the launch flags.

Every Claude invocation carries `--setting-sources user` and `--strict-mcp-config`, and
`sealInvocation` reads that back the way it reads the sandbox back: `readEffectiveConfigIsolation`
is a required argument with no default, and an invocation whose reader does not return `true` is
never returned. Leaving the flags off is not a mistake somebody can make quietly — it has no
representation. There is no exception list and no ledger of trusted worktrees: a ledger would become
a trust boundary of its own, needing its own tamper detection. Work that genuinely needs a
worktree's hooks or skills belongs in an interactive session.

The check and the claim come from one derivation, so they cannot drift apart. `configSourcesFor`
turns an argv into the set of configuration files the child would consult — the user, project, and
local settings files that `--setting-sources` selects, plus the project `.mcp.json` that
`--strict-mcp-config` suppresses — and the isolation reader asserts that none of them sit inside the
working tree. A test writes real hostile files into a temporary worktree and asserts the derivation
excludes them; a negative control strips the two flags and asserts the same three files come back,
which is what keeps the first test from being a restatement of itself. Anything the argv walk cannot
parse — an unknown flag, a duplicated `--setting-sources`, a settings path where an inline blob was
expected — resolves to "every source is live", and so fails closed.

The approval channel is an allowlist rather than an exception to that. `--strict-mcp-config` admits
only the servers `--mcp-config` names, so wiring `--permission-prompt-tool` without declaring one
leaves the prompt tool pointing at nothing — the same silent loss of the gate as never wiring it.
The adapter therefore takes the prompt tool and the approval server together or not at all, declares
exactly one server as an inline JSON string (a file path could be swapped from the working tree),
and refuses a prompt tool that does not name that server. The declaration carries a command and its
arguments, never an env block.

`readInitHealth` reads a `system/init` event and reports whether `AskUserQuestion` is present when a
prompt tool was wired, whether the declared approval server connected, and whether the child
reported MCP or plugin errors. **This is a secondary check and not the boundary.** It catches
misconfiguration, but anything that connects and answers without error passes it, and a hook that
runs at startup has already run by the time the event can be read. Wiring it into a launch sequence
is separate work.

### Antigravity is implemented but stays read-only

When Antigravity soft-denies a tool it cannot approve, it exits 0 with a `SUCCESS` status and an
empty response, so a caller reading the exit code and status alone records work that never happened.
This adapter therefore never reports success. It reports the failures it *can* determine — a
non-zero exit, an explicit failure status — and returns *indeterminate* otherwise, which maps to a
`failed` adapter run carrying a reason rather than inventing a new status value. Implementing a real
success determination, from a non-empty response plus a stderr scan, is separate work.

Its `--sandbox` flag does not stop file writes; it only breaks shell execution. And
`--dangerously-skip-permissions` removes the one boundary it does have. The adapter emits neither,
refuses to build a write-capable invocation, and declares its write access `unenforceable`.

### The route is gated on approval channel and write access

The approval channel and write access in the table above were declared by each adapter from
the start, but for a while nothing read them at the routing stage: `chooseRoute` looked only at
availability, and the write axis was consulted just once, immediately before a run. So a task
that needed a human decision could still be routed to a provider that cannot ask for one — where
it would be soft-denied or waved through, and either way the gate was gone.

Both axes are now matched at the route stage. The values stay where they were measured: the
adapter declarations are the only copy, and `provider-capabilities.mjs` folds them into a
provider-keyed table the router reads. Nothing is duplicated into `config.json`, because the same
measured fact living in two places is how `providers.mjs` ended up with `agy` in one file and
`antigravity` in the other.

- A task marked `requiresApproval` routes only to a provider whose channel is `external`. An
  agent's own review is not a human gate, so `agent-review` does not qualify.
- A task marked `requiresWrite` routes only to a provider whose write access is `supported`.
- A provider with no registered adapter, or a declaration outside the vocabulary, resolves to
  the weakest pair — no channel, unenforceable writes — so forgetting to register an adapter
  closes the gate rather than opening it.

The requirement flags themselves default to *false*, the opposite direction from
`hasDeterministicOracle`, and deliberately so. Treating a missing oracle as "no oracle" only ever
*adds* a reviewer. Treating a missing approval flag as "needs approval" would escalate every
route, since the shipped registry has no executor with an external channel at all, and the axis
would be unusable. The fail-closed posture lives on the supply side instead.

**A blocked route is not silently re-pointed.** Where the router already has a fallback it uses
that one: a browser task that needs writes cannot go to Antigravity, so it takes the same path a
browser task takes when the frontend is unavailable and lands on `executor.default`. Where there
is no fallback — `executor.default` itself failing the requirement — the route escalates and no
provider starts. Roles are never crossed to satisfy an axis: the reviewer capability is not
drafted as a writer because it happens to have a channel, which would leave no way to explain
afterwards why a given provider ran.

The reviewer is not gated either. `semantic.judge` neither writes nor holds the human gate, so
refusing it on these axes would turn "add a reviewer" into "escalate" without buying any safety.

An escalated route also withholds the provider outright, whatever the rollout says. Without that,
"blocked routes are recorded, not run" would hold only because the rollout happens to be `shadow`,
and promoting it while wiring a real runner would let a blocked route reach a provider after all —
the gate passing at the routing stage and leaking at the execution one. The same guard covers the
risk-based escalation that predates these axes, and under `shadow` nothing changes, since the
rollout guard was already refusing to call the executor.

Every block is recorded. A decision carries the capability, provider, axis, required value and
declared value for each one, and `fh run` writes them as a `route_block` evidence row tied to the
task and route, inside the same transaction that records the route. The routes table has no
columns for that five-part tuple and adding them would be a migration, so the reason lives in
evidence — the risk-based escalation predates these axes and still explains itself with its kind
and reason alone, so it carries no block list.

### What an adapter checks before it runs

The router decides availability in provider-independent terms, and reads the two declared axes
above from the adapter registry rather than from a second copy in the config. The adapter re-checks
the exact model ID against the same discovery list immediately before running — the readiness cache can expire
between routing and execution — and adds the checks the router cannot make:

- `model` and `effort` must be safe tokens. Codex embeds both inside `-c key=value`, so a value
  carrying a quote or an equals sign could inject a different setting, `sandbox_mode` included.
- `effort` must belong to the vocabulary the harness already ships; adapters do not declare a
  second one. Per-provider accepted values have not been measured, so no per-provider set is
  claimed either.
- The capability's account scope must match the resolved scope. This is the router's rule too, and
  dropping it here would make the second line of defence asymmetric: the shipped registry really
  does declare a personal-only capability, and an `r06` session must never fall back to it.
- A write-capable run is refused when the adapter cannot enforce containment.

A refusal is a returned verdict rather than an exception: the runner is never called, the result
records that the provider did not run, and re-routing stays the caller's decision. Availability may
be passed as a function so the check reads it when the run happens rather than when the executor was
built — a value would freeze it at construction and quietly turn "re-checked before running" into a
convention. Nothing in this layer changes the capability registry schema.

## Worktrees and rollout

`pr-workflow` owns the primary worktree and PR branch. When a non-shadow route
needs independent writable candidates, the harness will create only disposable
child worktrees through `wtp`; read-only investigation does not create one.
A verified, cleanly applicable candidate may move into the primary worktree,
but merge and other irreversible external actions always remain with the user.

The promotion path is shadow → pilot → default. A `--legacy` rollback flag is
planned for that promotion work and is not implemented yet. Until then the
rollout stays on `shadow`, which the CLI enforces as an explicit guard rather
than relying on the provider adapter being absent. That guard is now the only thing standing
between a route and a provider, since the adapters exist; they ship no default runner, so promotion
has to wire one deliberately.
