# Frontier Harness

🌐 日本語: [frontier-harness.ja.md](frontier-harness.ja.md)

← [Agent overview](overview.md)

`frontier-harness` (`fh`) is the model-independent execution layer behind the
evolving `pr-workflow`. It routes a normalized task to a provider capability,
records evidence in repository-local runtime state, and makes deterministic
verification higher priority than any model's self-assessment.

The rollout is **pilot**, and its blast radius is deliberately narrow. `run` still
only records a route: it injects no runner, so it reaches no provider whatever the
rollout says. Four commands start a real process, and each is gated before it does.
`fh session` launches the child sessions the wave orchestrator drives. `fh verify`
runs an approved deterministic check. `fh candidate` creates and adopts disposable
child worktrees. `fh review packet` reads a diff out of git. Every one of them passes
through `runWithRolloutGuard`, so setting the rollout back to `shadow` stops all of
them — which is what makes the config value an emergency brake rather than a label.

## Installation and readiness

Homebrew installs the Antigravity CLI through the `antigravity-cli` cask. Its
global safety settings are deployed to `~/.gemini/antigravity-cli/settings.json`.
The user must start `agy` interactively once to complete keychain-backed login;
the harness never stores an API key or copies a credential.

The `fh` launcher runs the interpreter that mise has pinned and offers no environment
variable to substitute another one. `fh` starts child sessions and owns the approval
boundary, so which interpreter runs it is not a decision the calling environment gets to
make; change the pin (`mise use node@<version>`) instead. It exits 127 when mise cannot
resolve node, rather than falling back to whatever `node` is on `PATH`.

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

## The command line surface

Every command validates its flags before it touches anything — no state root resolved, no
config read, nothing pruned — and refuses one it does not know, by name:

```
$ fh clean --dryrun
frontier-harness: unknown flag --dryrun for `fh clean`
$ echo $?
64
```

This matters most for `clean`. A misspelled `--dry-run` used to be dropped silently, so the run
meant as a preview pruned for real, and raw evidence at 30 days and aggregate telemetry at 180
do not come back. Flags were the one fail-open surface in a CLI that is otherwise fail-closed:
`fh session` refuses an argv it cannot assemble, `fh onboard` exits 2 on an unapproved manifest,
and `fh bogus` has always exited 64.

The known set is a table in `flag-registry.mjs` with one entry per command and per subcommand,
so `--resume-key` is accepted by `fh session resume` and refused by `fh session launch`. A test
reads the flag literals back out of every command module and fails if the table does not cover
one, so the table cannot fall behind the implementation quietly. `--flag=value` is not
supported; that error names the separate-argument form rather than calling the whole token
unknown. Positional arguments are still the command's own business — `fh review` names the
subcommands it takes.

### A failure the caller can act on carries no stack trace

| Failure | Output | Exit |
|---|---|---|
| a wrong argument, a refused path, a file that cannot be read, invalid JSON, running outside a git working tree | one line saying what went wrong | 64 |
| anything else | the stack, because reproducing it needs one | 70 |

The split lives in `errors.mjs`: commands raise `TypeError` for an argument error and
`HarnessError` for a refused invariant, and Node's own system errors already name their path.
Both the synchronous and the asynchronous command paths go through it. The synchronous one
previously had no handler at all, so `fh clean --now bogus` printed a Node stack trace and
exited 1 instead of 64 — the exit-code contract only held for the commands that returned a
promise.

### Route history is paged, and a deletion is previewed

`fh status` returns the newest <!-- FACT:fh-status-default-limit -->50<!-- /FACT --> routes and
says what it left out; route history accumulates in the state root for the life of the
repository, so the default is not "all of it". `--limit` (capped at
<!-- FACT:fh-status-max-limit -->500<!-- /FACT -->) and `--offset` page through the rest.

```json
{"routes": ["..."], "page": {"limit": 50, "offset": 0, "total": 812, "returned": 50, "hasMore": true}}
```

`fh runs` answers the other half of the question. `fh status` records *what was chosen* — the
route decision — and never *how it ended*. The outcome was already persisted in `adapter_runs`
with a status, an exit code, a failure reason, and both timestamps, but nothing read it back, so
losing the terminal scrollback that carried the launch JSON meant losing the only account of
whether a child succeeded. That is worst exactly where it matters most: running children in
parallel, where no single scrollback holds all of them.

```
fh runs --json                       # newest first, same default and cap as `fh status`
fh runs --json --run <adapter run id>
```

An unknown id is an argument error, not an empty list — returning nothing would be
indistinguishable from "no run has happened yet". `--run` refuses `--limit` and `--offset`
rather than silently ignoring one of them.

**It does not return the whole launch JSON.** `resumeKey`, `denials`, `initHealth`, and
`evidenceId` are emitted by `fh session` but have no column in `adapter_runs`, so they are not
listed at all rather than shown as empty fields that would read as "recorded, and there was
nothing". The session id in particular still has to be kept by the caller at launch time.

**What it does return is whether the run passed a gate.** Every run carries a `verification`
count of the deterministic checks linked to it — `total`, and how many `passed`, `failed`, and
`errored` — and `--run` returns those results themselves alongside the record. A run with
`total: 0` has passed no gate at all, so its `status: "succeeded"` claims only that the turn
ended without an error. That distinction used to be unreadable from the record: three children
in one wave ended their turn saying they would move on to review once CI notified them, and all
three were recorded as `succeeded` with `exitCode: 0`, identical in shape to the children that
had actually finished. `denials` was empty for all three as well, because nothing had been
refused — they simply had not done it. The only thing that gave them away was the comment count
on their pull requests, which is not part of this record and never will be.

The `failureReason` names *which* signal decided the failure, because the two do not always
agree. An envelope that reports an error is described by its own subtype (`run reported
error_max_turns`); a run whose envelope claimed no error but whose process exited non-zero is
described by the exit code, keeping what the child claimed alongside it (`run exited with code 1
after reporting success`). Explaining the second case with the subtype alone used to produce
`run reported success` on a failed run — a reason that contradicts its own status and leaves the
caller unable to decide whether to retry.

`fh clean --dry-run` lists what it would delete, up to
<!-- FACT:fh-clean-target-preview-limit -->20<!-- /FACT --> entries per record class with
`targetsTruncated` set when there are more. An entry carries an id, a timestamp, and for
evidence its kind and artifact path — never the recorded content, because a retention preview
is not a place to re-read review findings. A real prune reports `targets: null`, so a target
list never means a deletion has already happened.

## State and evidence

Configuration, policy, and mutable state have different owners:

| Location | Contents | Git state |
|---|---|---|
| `$HOME/.config/frontier-harness/config.json`, or an absolute `FH_CONFIG_PATH` | capability registry, rollout, retention | chezmoi-managed |
| `<repo>/.harness/policy.json` | approved repository capability manifest (written by `fh onboard`, checked before every routed run) | untracked; `.gitignore` covers `.harness/` |
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

`.harness/` is ignored by the repository's own `.gitignore`, not by a per-clone
`.git/info/exclude`. The policy is per-worktree state bound to an approval recorded in the
state root, and the pointer that says which approval is in force is keyed by the policy
file's path — so a committed policy would arrive in every clone with no approval behind it,
which is precisely the state onboarding refuses to route on.

Evidence contains diffs, command results, logs, traces, screenshots, browser
recordings, and accepted decisions. It never uses a model transcript or hidden
reasoning as its interchange format.

### Normalized state schema

The SQLite state is at schema version 3. Every record class is normalized, and
each one belongs to exactly one retention class:

| Table | Holds | Retention |
|---|---|---|
| `tasks` | the normalized task a run was started from | kept |
| `route_decisions` | the chosen capability, provider, **model, effort**, and reviewer | kept |
| `evidence` | raw payload references, a SHA-256 `content_hash` over the record's content fields, and the task/route it belongs to | raw |
| `adapter_runs` | one adapter execution: capability, provider, model, effort, status, start/finish, exit code | raw |
| `verification_results` | one deterministic check that actually ran: kind, status, approved command, exit code, evidence reference, **and the candidate + tree hash it verified** | raw |
| `review_findings` | one finding: severity, uncertainty, one-line summary, discriminating experiment, evidence reference | raw |
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

Disposable candidate worktrees are deliberately **not** in this table set; see
[Candidate worktrees](#candidate-worktrees) for why a retention window is the wrong
lifetime for them.

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
fh approvals --all --json                              # decided requests too
fh approve --request <id> --allow                      # let it through
fh approve --request <id> --deny --message "..."       # refuse, with a reason for the model
fh approve --request <id> --allow --answers '{"Which colour?":"Red"}'   # AskUserQuestion
fh approvals --purge --json                            # drop decided requests once a wave ends
```

`fh approvals` returns an envelope, not an array of requests:

```json
{"approvals": [{"id": "...", "status": "pending", "sessionId": "...", "toolName": "...", "...": "..."}], "skipped": []}
```

Reading it as a top-level array is a type error, not an empty result — a monitor that swallows the
error reports "nothing is waiting" for as long as it runs. `skipped` holds requests whose files
could not be read, quarantined so that one corrupt file does not hide the rest; **those requests do
not appear in `approvals`**, so anything polling `.approvals[]` alone misses them silently. Treat a
non-empty `skipped` as a warning, not as noise.

The wave orchestrator normally relays — it reads the queue, asks the user, and writes the answer
back — but the user can answer directly with the same commands. That matters: if the
orchestrator dies, the pending approvals stay decidable. Answers to `AskUserQuestion` are
validated against the offered options on **both** sides, so a decision the user never expressed
cannot reach the model through a typo or a hand-edited file.

A request holds the question and its options, because answering it needs them. Nothing else
retains that text, so `fh approvals --purge` is how a finished wave stops keeping it: it deletes
requests that already reached a terminal status along with their answers. Pending requests survive,
and so does anything the queue could not read — deleting a record whose status you could not
confirm would silently discard a child that is still waiting.

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
- **`fh review`.** Neither subcommand consults the capability manifest. `record` only writes
  normalized findings into the registry, and `packet` only reads — it starts no provider and
  runs no repository command. What `packet` does read is the *approved* manifest, so an
  unapproved repository hands the reviewer an empty constraint list rather than the raw
  `.harness/policy.json`.

Upgrading an existing repository requires re-running the ceremony, because a policy written
before enforcement has no approval in force behind it.

## Recording a route

```bash
fh run --task task.json --json
fh status --json
fh clean --dry-run --json
fh gaps --json
```

A task declares what it needs: `requiresApproval` when a human has to decide something
mid-run, `requiresWrite` when the run modifies files. Both default to false, and both are
matched against what the chosen provider declares — see *The route is gated on approval
channel and write access* below.

`run` persists a normalized route without starting a provider, at every rollout and not only
under `shadow`, because it passes no runner to `runWithRolloutGuard`. It records the route
inside a write transaction and then leaves that transaction before the guard runs, so a future
executor cannot hold `BEGIN IMMEDIATE` for the length of a provider call and stall every other
`fh` in the repository. `clean` reports and removes expired raw records and expired aggregate
telemetry on their own windows, and leaves approvals alone; use `--dry-run` to inspect its
impact first.

## Deterministic verification

```bash
fh verify --task <task id> --command "npm run test" --json
fh verify --task <task id> --command "npm run lint" --kind lint --json
fh verify --task <task id> --candidate <candidate id> --command "npm run test" --json
```

`fh verify` runs the check and records what happened. It used to write a
`verification_plan` row and stop, which meant a completion claim rested on nothing sturdier
than a model saying the tests passed.

Four properties make the result worth more than that claim:

- **The command must already be approved.** It is matched against the repository capability
  manifest before anything is spawned, and a miss is queued by `fh gaps` and exits 2. The
  approvable grammar is a project task runner with arguments drawn from a narrow character
  set, and `check-runner.mjs` re-checks that grammar immediately before executing — so the
  string cannot be rebuilt into something else between matching and running.
- **No shell is involved.** The approved string splits into argv, the binary resolves to an
  absolute PATH entry, and `spawn` receives the array. There is no stage at which `;`, `&&`,
  `$(…)`, or a glob could be reinterpreted.
- **The harness never sees the output.** The child's stdout and stderr are inherited by the
  terminal, not piped. The only thing the harness learns is the exit code, so "no free text
  reaches the state database" is a property of what was captured rather than a rule about
  what gets written.
- **The exit code is the verdict.** 0 records `passed`, anything else records `failed`. A check
  that could not be started at all — the binary is not on `PATH`, or `spawn` failed — is recorded
  as `errored` rather than raised, so "we tried to verify and could not" still leaves a trace. And
  a check that outlives
  <!-- FACT:fh-check-timeout-ms -->900000<!-- /FACT --> ms (overridable with `--timeout-ms`, itself
  capped at <!-- FACT:fh-check-max-timeout-ms -->3600000<!-- /FACT --> ms, because the check window
  is the one interval in which a candidate can change without being noticed)
  is terminated — SIGTERM, then SIGKILL after a grace period — and recorded as `errored` with
  exit code 124. `fh verify` itself exits 0 only when the check passed.

The check runs in `--worktree` (default: the working directory), and the state, the manifest,
and the gap queue all resolve from that same tree, for the reason `fh session` resolves them
from its `--worktree`: resolving them from the caller's directory would let a caller inside an
approved repository point at another tree and keep the approval.

Verifying inside a candidate uses `--candidate` rather than pointing `--worktree` at its
directory. A candidate is a detached checkout of a base commit, so if `.harness/policy.json`
is not committed it does not exist in that tree, and aiming `--worktree` at it means the
approval boundary correctly concludes the repository has approved nothing — which is
fail-closed but leaves isolate → verify → adopt with no way through. `--candidate` resolves
the tree **through the registry**, which is what establishes that the tree belongs to this
repository: the approval comes from the owning repository while only the check runs in the
candidate. No caller-supplied path is trusted, so the `--worktree` boundary is not weakened.

**What "approved" actually authorizes.** The approvable grammar is a project task runner, but
those runners hand off to scripts the repository controls — `npm run test` runs whatever
`package.json` currently says, and that file changes with the diff. The check also inherits the
caller's environment and has no network or filesystem confinement of its own; the sandbox that
`fh session` seals around a provider does not apply here. So approving a command is closer to
"this repository's task runner may execute, with my environment, whenever a check runs" than to
"this exact program is safe". That is the sharpest edge in this path, and it matters most when
the tree being checked is a candidate holding a diff nobody has read yet.

Killing a check reaches the process the harness started, not its descendants. A test runner
that spawns its own children and ignores SIGTERM can leave them behind. Putting the check in
its own process group would fix that and introduce a worse failure — orphans that outlive the
harness by the full timeout — so the timeout stays a safety valve rather than a guarantee.

### What `make` may be approved as

`make` is an approvable runner, but only as `make <target>` — one or more target names, each
starting with a letter, digit, or underscore and drawn from `[A-Za-z0-9_./-]`. Options and
command-line variable assignments are not approvable, so `make -f /tmp/evil.mk all`,
`make --file=… all`, `make -C /tmp/evil all`, and `make SHELL=/tmp/evil test` are all rejected
as not being in an approvable form. `make` on its own is rejected too, for the reason every
other runner requires arguments: the default target leaves the approved string saying nothing
about what will run.

The narrower character set is deliberate and applies to `make` alone. The paragraph above
already grants that an approved runner dispatches to something the repository controls —
`make test` reads the `Makefile` exactly as `npm run test` reads `package.json`, so the
indirection itself is nothing new. `-f`, `--file`, and `-C` are different in kind: they aim
`make` at a makefile *outside* the repository, which is the one assumption that paragraph
rests on. Variable overrides such as `SHELL=` change what a recipe expands to, with the same
effect. `npm run <script>` has no argument that does either, so this is the one place where
`make` genuinely needs to be held tighter rather than merely differently.

The tokenised exact match is untouched by this. Approving `make lint` approves that string and
nothing else: `make test-node` still misses, `make lint; curl …` still splits into a second
segment that no approval covers, and `/tmp/evil/make lint` is still refused for not being in
an approvable form.

## Review registry

```bash
fh review packet --task <task id> --out <abs path> [--base <rev>] --json
fh review record --task <task id> --findings <abs path> --json
```

Reviews are handled as normalized findings rather than prose. `packet` builds what a reviewer
is allowed to receive; `record` takes findings back and returns a verdict. The two are separate
because they have different powers: `packet` reads git and starts nothing, `record` writes state
and touches no repository. Neither starts a provider — running one is `fh session`'s job, and a
second path into a provider is exactly what #537 decided not to build.

**A packet carries four things: the task, the constraints, the diff, and the verification
results.** The writer's conversation is not among them, and the guarantee is structural rather
than a rule: `buildReviewPacket` takes a task id, a worktree, and a base revision, and has no
parameter through which a prompt, a transcript, or an adapter's output could arrive. The four
sections come from places the writer does not control — the normalized task row, the approved
manifest, `verification_results`, and git.

`--out` is written without re-permissioning a directory that already exists: the 0700 the state
root requires is imposed only on directories the harness itself creates, so pointing `--out` at
an existing shared directory does not quietly close it to anybody else.

The diff includes tracked modifications and untracked new files, and it is produced through a
throwaway `GIT_INDEX_FILE` seeded from the base commit. The worktree's own index is never
touched, because staging state belongs to `pr-workflow`. That scratch index is placed inside
the worktree's git directory, where `git add -A` will not find it. A packet larger than
<!-- FACT:fh-review-diff-max-bytes -->1048576<!-- /FACT --> bytes is truncated with `truncated: true` set, so a reviewer cannot be told it saw a whole change it
did not. The packet is written to `--out` and never printed, so the diff does not travel
through stdout and into a log.

A findings document declares a version, the reviewer capability, and the findings; each
finding carries a severity, an uncertainty, a one-line summary, and optionally a
discriminating experiment. Unknown keys are refused rather than dropped, so a `transcript` or
`rationale` field is a loud error instead of a silent one. The summary is bounded at
<!-- FACT:fh-review-text-max-length -->300<!-- /FACT --> characters and must be a single line
of printable text — which rejects `Zl` and `Zp` (U+2028, U+2029) as well as the control and
format categories, because those two are line breaks nearly everywhere they are rendered while
belonging to neither `Cc` nor `Cf`; that bound is what keeps the column from becoming a place to paste a review
body. The task id comes from `--task`, never from the document, so a reviewer cannot attach
findings to somebody else's task.

Evidence records counts and a verdict, never the findings themselves. One `must` finding makes
the verdict `blocked` and `fh review record` exits non-zero, so a calling script cannot read an
unresolved `must` as success.

## Child sessions

`fh session` is the one command that starts a provider process. It exists for the wave
orchestrator, whose children are full `pr-workflow` sessions that must be able to ask the user.

```bash
fh session launch --worktree <abs> --prompt-file <abs> --label feat-537-child
fh session resume --worktree <abs> --prompt-file <abs> --resume-key <session id>
```

It does **not** go through the router. `chooseRoute` picks `executor.default`, whose provider
declares no external approval channel, so every task that needs a human decision would become an
escalation and no child would ever start. Adding a Claude fallback there would change routing
semantics; a child's model and effort come from the `model-fitness-check` contract instead, so
the capability is named explicitly (`--capability`, default `session.child`). Everything else
still applies: the capability registry supplies provider, model, and effort; the repository
capability manifest must approve that capability or the command queues a gap and exits 2;
`checkCapabilityExecutable` re-checks account scope, model discovery, and write containment; and
the rollout guard decides whether anything runs at all.

The approval channel is verified in three layers, each of which refuses rather than warns:

1. **Structural.** `sealInvocation` will not assemble an argv that lacks
   `--permission-prompt-tool` and exactly one inline `--mcp-config` server. A missing wiring
   therefore starts no process at all.
2. **Before launch.** The declared approval server is started once and handed an MCP handshake
   (`initialize`, then `tools/list`). If it does not publish the `approve` tool — because it is
   missing, unreadable, slow, or the wrong program — no child is started.
3. **On the first init event.** The child's structured output is read as a stream, and
   `readInitHealth` is applied to its `system/init` event. If `AskUserQuestion` is absent, the
   approval server did not connect, or the child reports MCP or plugin errors, the child is
   terminated immediately and the run is recorded as failed. Reading the stream rather than the
   finished output is what keeps this a startup check: a child whose gate silently disappeared
   is stopped in the first second, not diagnosed after it has done a task's worth of work.

A run whose init event never arrives is treated the same way. Not being able to read the check
is not evidence that it passed.

What the run leaves behind carries no conversation. `adapter_runs` has no column for a prompt or
an argv by design, and the evidence row's claims are a fixed vocabulary plus the resume key, the
health verdict, and the **names** of denied tools. The prompt is read from a file rather than an
argument so it never reaches `fh`'s own `ps` entry, the child's stdout is interpreted in memory
and never written to disk, and the only thing **`fh` itself** writes to stderr is the type name of
each event, as a liveness heartbeat.

The child's own stderr is a different stream, and it is inherited rather than filtered. That is
deliberate: a pane running `fh session` is the window a person looks through, which is the one
guard the move away from tmux was never willing to give up. `fh` does not control what goes into
it, and what a `claude -p` writes there has not been measured, so treat it as capable of carrying
conversation: watch it, do not persist it. Redirecting a child's stderr into a log file is how
this design's one non-negotiable — no conversation in the record — gets broken from the outside.

`fh session` also does not carry an account selection. The child resolves `claude` from PATH,
and that launcher keeps an inherited `CLAUDE_CONFIG_DIR`, so a child always runs on the account
of the session that launched it. Pinning a child to a specific account is done the existing way —
by declaring `accountScope` on its capability, which `checkCapabilityExecutable` enforces — not
by passing a launcher name through this command.

### The completion condition is declared, not asserted

`outcome` says whether the turn ended without an error. It has never said whether the child did
what it was told, and separating those two questions was deliberate (PRD 493 AC-005, PRD 537
AC-012). What was missing was the line back: neither the launch output nor `adapter_runs`
referred to a verification, so a child that skipped its instructions looked exactly like one
that followed them.

```bash
fh session launch --worktree <abs> --prompt-file <abs> \
  --gate "npm run test" --gate "lint:npm run lint"
```

`--gate` declares a completion condition as an approved deterministic check, and repeats for
more than one. A declaration is `<kind>:<command>`, or just `<command>` with the kind defaulting
to `test`. The prefix is read as a kind only when it matches the closed check vocabulary, which
cannot collide with a command because an approvable command always begins with a task runner's
name — `npm run test -- --grep=a:b` is a command, not a `npm run test -- --grep=a` gate.

Five things follow from reusing `fh verify`'s machinery instead of building a second one:

- **The gate is checked before the child starts.** Its command goes through the same manifest
  match as the capability, so an unapproved gate queues a gap and exits 2 rather than being
  discovered after a child has run for hours.
- **The child is told what it will be measured by.** The declared commands are prepended to the
  prompt in the same fixed-vocabulary briefing that carries the sandbox constraints. A gate the
  child cannot see is a trap rather than a condition.
- **The harness still never sees the output.** The checks run through `check-runner.mjs`, whose
  stdout and stderr are inherited by the terminal, so a gate adds an exit code to the record and
  no free text — the property described under deterministic verification is not weakened by
  being reached from a second command.
- **The result is linked to the run.** Each check is recorded as a `verification_results` row
  whose `adapter_run_id` is the session's own run. That column existed from the beginning and
  nothing had ever written it; writing it is what lets `fh runs` answer "did this run pass
  anything" from the record alone.
- **The verdict only moves downward.** A gate that fails makes the session `failed` even when
  the child's envelope reported success, and a gate that could not be started at all makes it
  `indeterminate` — which `adapter_runs` still stores as `failed` with a reason, so the status
  vocabulary does not grow. A gate never turns a failed child into a passing one, and one
  definitely red check is not softened into "could not tell" by another check that never ran.

A child that did not succeed runs no gate. The question a gate answers — "the turn ended
cleanly, but did it pass?" — only arises when the turn ended cleanly, and running checks against
a tree that already failed would add red results that describe the earlier failure rather than a
missed condition. Each check is bounded by `--gate-timeout-ms`, which is the check timeout
described under deterministic verification, with the same default and the same ceiling, and is
resolved before the child starts rather than just before the check runs — reading it late meant
an invalid value raised *after* a child had already run, leaving no `adapter_runs` row at all,
which is the one failure this command is built to avoid. It is a separate flag from
`--timeout-ms` because that one is how long the approval channel waits, and one name cannot
carry two limits. The number of gates is capped as well: each has a time limit, but without a
limit on how many may be declared, "count × ceiling" reopens the window the time limit closed.

### What a gate does not protect you from

A gate does not run inside the sandbox the child ran in. `check-runner.mjs` spawns the approved
command directly, with no network or filesystem confinement of its own — the property described
under deterministic verification, unchanged, because a gate reuses that runner rather than
building a second one. What *is* new here is the reachability: `fh verify` is a command a person
types, while a gate is started by the harness, unattended, moments after an agent finished
writing to that same tree. The approved string `npm run test` resolves to whatever `package.json`
says at that moment, and that file is part of the diff nobody has read yet.

Two things follow, and neither is closed by approving the command:

- **The gate check does not inherit the caller's environment.** Only a fixed allowlist reaches
  it — `PATH`, `HOME`, the temp and locale variables, and the XDG directories. Anything else,
  including every token the harness itself was launched with, is dropped. This is an allowlist
  rather than a denylist because a denylist misses the next secret's name, and a check that
  needs a variable it cannot see fails loudly rather than passing quietly. `fh verify` is left
  as it was: its reachability is not what this changed.
- **The verdict is still only an exit code.** A gate says the approved command was run by the
  harness and returned zero. It does not say the command tested anything. A child that rewrote
  its own test script would produce `verification.total > 0` with everything `passed`, and the
  record cannot tell that apart from a real pass. What it *can* do is leave the rewrite in the
  diff — the review packet stages the whole worktree, so a neutered test script is visible to a
  reviewer even though it is invisible to the gate. Treat a green gate as "the harness ran this
  and it returned zero", which is strictly more than a model saying so, and strictly less than
  "the change is verified". Unlike `fh verify --candidate`, a session gate records no tree hash,
  so the result does not pin which tree it described; that stays a candidate-adoption mechanism.

Declaring no gate leaves the outcome exactly as it was. Turning a missing gate into
`indeterminate` would be the strictest reading of "do not call it a success if you cannot tell",
but it would also fail every existing caller at once, and the same fact is legible without it: a
run with no linked verification result has passed nothing, and `succeeded` there means the turn
ended and nothing more. Reading it as "the work is done" is the monitor's error to avoid, and
the record now gives the monitor something to read instead of a pull request's comment count.

A repository's approval is bound to the worktree the child will run in, not to the directory the
command was invoked from. The manifest, the approval scope, the state root, and the child's
working directory all resolve from `--worktree`. Resolving them from the caller's cwd would let
an approved repository launch a child into an unapproved one, which is the capability gate
answering a question nobody asked.

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
therefore requires an injected runner and ships **no default** — starting real processes belongs
outside this layer. The only injection site is `fh session`, whose runner lives in
`child-runner.mjs`; the insertion point is the `executor` argument of `runWithRolloutGuard`, so a
`shadow` rollout still never reaches a provider. That runner is asynchronous, because reading the
child's first `system/init` event is the only way to stop a session whose approval channel
vanished before it does any work. `createAdapterExecutor` returns a promise only when the runner
does, so the synchronous contract every other caller relies on is unchanged.

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

## Candidate worktrees

```bash
fh candidate create --task <task id> [--base <rev>] [--label <l>] --json
fh candidate list --json
fh candidate adopt --candidate <id> --json
fh candidate discard --candidate <id> --json
```

A write-capable diversification route needs somewhere to write that is not the branch under
review. `fh candidate` gives it a disposable child worktree and decides, on evidence, whether
what it produced is allowed back out.

**`pr-workflow` keeps the primary worktree and the PR branch.** A candidate is a detached
checkout with no branch of its own, so it cannot stand in for the PR branch, and adoption
applies a patch and stops — it does not commit, and it does not push. Merge and every other
irreversible external action stay with the user.

**Candidates do not come from `wtp`.** The repository's `.wtp.yml` symlinks `.env` into every
worktree it creates. That is right for a worktree a person will work in and wrong for one an
autonomous route writes to, so candidates use `git worktree add --detach`, which runs no
post-create hooks. The tree lives under the state root, inside the git common directory, where
it stays out of the primary worktree's `git status`.

**Adoption is gated on measurement, not on a claim.** Run the check with
`fh verify --candidate <id>`; a candidate is adopted only when `verification_results` holds at
least one check **recorded for that candidate** and every one of them passed.

Three things have to line up, and each closes a way of faking the first:

- **The check must name this candidate.** Results carry `candidate_id`, and adoption matches on
  it. Matching on the task alone is not enough: two candidates can share a task, so a pass
  earned by one would authorize adopting the other, which was never checked at all.
- **The check must post-date the candidate.** A green run from before it existed says nothing
  about what is in it.
- **The tree must not have moved since.** Results also carry `tree_hash`, the git tree the check
  actually saw. It is derived **both before and after** the check and the two must agree: hashing
  only afterwards would record whatever the tree became, not what was measured, and a check may
  run for many minutes. If the tree moves mid-check the result is recorded as `errored` with no
  hash, because it then describes no single tree. Adoption re-derives the hash and refuses on a
  mismatch, so writing to the candidate after it passed does not smuggle unverified changes in
  under the old verdict. A result with no `tree_hash` is not an adoption basis — treating a
  missing hash as "fine" would be the easiest way to switch this gate off.

Adoption reads the hash and builds the patch from **one** staging pass, so the thing that was
checked and the thing that gets applied cannot drift apart between two separate reads.

An unverified, red, or stale candidate is refused with exit 2 and its tree is left alone. The whole
judgement — hashing, verdict, diff, apply — sits inside the rollout guard, so `shadow` reaches no
git process here either.

`discard` keys off whether the tree still exists rather than the recorded status, which makes it
idempotent: a removal that failed halfway leaves an orphaned tree, and a status-only check would
leave no way to clean it up.

**A conflict retains the work.** If the patch does not apply cleanly to the target worktree,
the candidate moves to `conflicted`, **the tree is kept**, and the command exits 2 — the same
code the approval boundary uses, because both mean "a person has to look". Nothing is rebased
and no conflict is auto-resolved: doing either would quietly turn the verified content into
something that was never verified. Once the user clears the conflict, the retained candidate
adopts normally. A candidate that applies cleanly is adopted and its tree is then removed,
since its contents now live in the target.

The registry is files under the state root, not a table. A candidate is a fact about a
directory on disk, so putting it in a retention window would eventually delete the row and
leave the tree — the registry would report nothing while `git worktree add` kept failing on a
path collision. At most
<!-- FACT:fh-candidate-max-live -->8<!-- /FACT --> candidates may be live at once; each is a
full checkout, so the limit is far lower than the gap queue's.

## Rollout

The promotion path is shadow → pilot → default. The rollout is now `pilot`, which the CLI
enforces as an explicit guard rather than relying on the provider adapter being absent. That
guard is the only thing standing between the harness and a process it starts, and `pilot` opens
exactly four paths: `fh session` (a child provider), `fh verify` (an approved check),
`fh candidate` (a disposable worktree and its adoption), and the git call behind
`fh review packet`. `fh run` still passes no runner. The surface grows one deliberate command
at a time rather than by a config value.

Rolling back is editing `rollout` to `shadow`: the guard then returns `executed: false` before
any process starts — no check is spawned, no worktree is created, and nothing is recorded as
though it had run. Promoting to `default`, adding a `--legacy` rollback flag, and defining the
telemetry that justifies the next promotion are still open work.
