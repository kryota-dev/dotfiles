# ADR 0001: Keep the MCP permission-prompt tool as fh's approval channel

← [Docs index](../README.md)

🌐 日本語: [0001-fh-approval-channel.ja.md](0001-fh-approval-channel.ja.md)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-09-04 |
| **Issue** | kryota-dev/dotfiles#630 |
| **Scope** | Decision only. This ADR changes no code and authorises no implementation. |

## Context

Frontier Harness runs each wave child as a `claude -p` process and wires `fh approve-server`
into it as an MCP server, naming that server's tool with `--permission-prompt-tool`. Permission
escalations and `AskUserQuestion` both arrive as **synchronous MCP tool calls**: being called is
the question, and the return value is the answer. Each escalation is persisted as one file per
request under the state root, a responder answers it with `fh approve`, and the Leader polls
`fh approvals --json`.

[Frontier Harness → Approval channel](../agents/frontier-harness.md#approval-channel) is the
reference for how that works and is the single source of truth for its load-bearing constants.
This ADR deliberately does not restate those numbers, so they cannot drift out of sync here.

Issue #630 asked whether two official Claude Code mechanisms could replace the arrangement:

- the `PreToolUse` hook's `defer` permission decision, and
- the `PermissionRequest` hook.

The issue's description of both turned out to be partly wrong, so everything below is grounded
in sources a reader can re-check rather than in the issue text.

## How these claims were verified

Three kinds of source were used, because the first one alone proved unreliable.

**1. Published documentation** at `code.claude.com/docs`. Treat prose fetched through a
summarising tool as a lead, not as evidence. One such fetch of the hooks reference returned a
`permissionDecision` table listing `allow`, `deny` and `dontAsk` — wrong in both directions:
`ask` and `defer` were missing, and `dontAsk` is a *permission mode*, not a hook decision. Quotes
in this ADR were taken from pages small enough to come back whole, and cross-checked below.

**2. The shipped CLI binary**, which carries the authoritative decision vocabulary, the guard
conditions and their diagnostics as embedded strings. Re-derive with a byte-oriented grep — the
harness `grep` wrapper hides binary files unless you pass `-a`:

```bash
claude --version
grep -a -c -F 'permissionDecision' "$(mise which claude)"
grep -a -b -o -F 'tool_deferred' "$(mise which claude)" | head
```

**3. The published changelog** (`anthropics/claude-code`, `CHANGELOG.md`) for the release that
introduced a behaviour.

For the Codex side there is a stronger source still: the pinned CLI generates its own protocol
schema. Invoke the real binary rather than this repo's launcher, which injects `--profile` and is
rejected by `app-server`:

```bash
codex --version
/opt/homebrew/bin/codex app-server generate-json-schema --out "$OUTDIR"
grep -o '"[a-z][a-zA-Z]*/[A-Za-z/]*"' "$OUTDIR/ServerRequest.json" | sort -u
```

The tool versions named in this ADR (Claude Code 2.1.259, Codex CLI 0.150.1) record *what was
checked and when*. They are provenance for a dated decision record, not pins that this repo
asserts elsewhere, which is why they carry no `<!-- FACT -->` marker.

## Considered options

### Option A — keep `--permission-prompt-tool` and the MCP approval server *(chosen)*

The status quo described under Context.

### Option B — the `PermissionRequest` hook

**Rejected: not available in fh's execution mode.** The hooks guide says, under Limitations:

> `PermissionRequest` hooks fire when Claude Code is about to ask you for permission.
>
> * In non-interactive mode with the `-p` flag, that prompt only exists when the Agent SDK's
>   `canUseTool` callback supplies it. **In plain `-p` runs or with `--permission-prompt-tool`,
>   use `PreToolUse` hooks for automated permission decisions instead.**

An fh child is exactly a plain `-p` run with `--permission-prompt-tool`. The permission *mode* is
not the obstacle — a `-p` session does start in `default` — the obstacle is that no prompt exists
for the event to intercept, so there is nothing for the hook to fire on.

The issue also expected `PermissionRequest` to auto-deny when nothing answers. That behaviour is
real but narrower than stated; the same Limitations list scopes it to background subagents:

> Background subagents can't show a prompt in non-interactive mode. Claude Code still runs the
> hooks for their tool calls, and if no hook returns a decision, it denies the call.

Two further properties would have disqualified it regardless. Its decision vocabulary is
allow/deny with no "still waiting" state, so it cannot represent an escalation that is pending;
and it carries a verdict only, so it could not deliver an `AskUserQuestion` answer.

### Option C — a `PreToolUse` hook returning `defer`

**`defer` is real, and it is documented.** From the hooks guide:

> A fourth value, `"defer"`, is available in non-interactive mode with the `-p` flag. It exits
> the process with the tool call preserved so an Agent SDK wrapper can collect input and resume.

and, on combining several hooks:

> For `PreToolUse` permission decisions, the most restrictive answer applies, in the order
> `deny`, `defer`, `ask`, `allow`.

The changelog entry that introduced it (2.1.89):

> Added `"defer"` permission decision to `PreToolUse` hooks — headless sessions can pause at a
> tool call and resume with `-p --resume` to have the hook re-evaluate

The shipped binary agrees on all of it. Its rejection message for an unknown value reads
`Valid types are: allow, deny, ask, defer`; the same precedence appears as an explicit chain in
which `deny` wins over `defer`, `defer` over `ask`, and `ask` over `allow`; a deferred run
terminates with `stop_reason: "tool_deferred"` and the result message carries a
`deferred_tool_use` payload, with a distinct `tool_deferred_unavailable` reason for the failure
case.

**What it would genuinely buy fh.** Two real benefits, worth recording so the rejection is not
read as "the alternative had nothing going for it":

- *No in-process wait.* Today an escalation blocks an MCP tool call for the whole escalation
  window, kept alive by periodic progress notifications so the stdio idle timeout does not kill
  it first. With `defer` the child exits instead. None of that machinery would be needed, and a
  child waiting on a human would hold no resources and survive a Leader restart.
- *The exit is the notification.* A child stopping is directly observable, so the Leader's
  polling of `fh approvals` could become event-driven — the "push to the Leader" axis the issue
  asked about.

**Why it does not replace the current channel.**

1. **A deferral is silently dropped for batched tool calls, and the hook cannot compensate.**
   The runtime refuses to defer when the assistant emitted more than one tool call in the same
   batch, on the grounds that the siblings would be orphaned on resume; it logs a warning and
   discards the decision. The check runs in the code that *consumes* the hook's output, so it
   happens after the hook has already returned — a hook therefore has no way to fall back to
   `deny` when its deferral is about to be dropped, because it never learns that it was. The call
   then resolves through the remaining permission machinery **without the user**, which is
   exactly the escalation a wave depends on.

   This is not an edge case. Issuing independent tool calls together in one batch is the normal,
   encouraged shape, so the gate would go missing on the common path and be visible only as a
   warning in the child's log.

2. **It is print-mode only.** The runtime ignores a deferral in an interactive session. That is
   harmless for wave children, but it means one hook cannot serve both interactive and headless
   sessions, so the policy would have to exist twice.

3. **It does not apply to calls served to a cloud session**, which the runtime refuses outright
   for want of resume machinery.

4. **The pre-launch positive control is lost.** `approval-channel.mjs` starts the declared
   approval server and completes a real MCP handshake *before* the child is launched, and
   `child-runner.mjs` then re-checks `system/init` and terminates a child whose channel is
   missing. Hooks offer no equivalent: a misdeclared hook is silent, and the child simply runs
   without ever escalating. That is the precise failure the current design was built to make
   impossible — a child that cannot reach the user starting anyway.

5. **Hook delivery works against fh's isolation.** The approval server is declared per child on
   the command line with `--mcp-config`, and `--strict-mcp-config` together with
   `--setting-sources user` stop a checked-out repository from adding its own. Hooks arrive
   through settings sources instead, so putting the approval hook in the user settings file would
   make it global to every Claude session on the machine rather than scoped to fh children. A
   per-invocation `--settings` payload may be able to carry it — **this is unverified** — and it
   would not restore point 4 in any case.

### Option D — `defer` alongside the existing prompt tool

The only arrangement that closes gap 1: keep `--permission-prompt-tool` so the batched calls that
`defer` drops still reach the user, and use `defer` only where it applies. Hooks are evaluated
before the permission-prompt tool, so the two compose without ambiguity, and this would deliver
the "no in-process hold" benefit.

**Rejected for now** because it is additive. Issue #630's motivation was to *reduce* the polling
and the bespoke server; Option D keeps both and adds a second escalation path with different
semantics beside them, with the escalation rules now needing to agree across the two. The
complexity moves rather than disappearing.

## Decision

**Keep Option A.** fh continues to route approvals and `AskUserQuestion` through
`--permission-prompt-tool` and the MCP approval server.

The current channel is not kept because the alternatives are poor. `PermissionRequest` is simply
unavailable in the mode fh runs children in. `defer` is a well-designed mechanism aimed at very
nearly this problem, but it cannot carry the whole gate on its own, and the one arrangement that
can (Option D) costs more than the problem it solves.

## Consequences

Costs that are accepted by keeping Option A:

- A bespoke MCP server stays in the tree, with its protocol-version negotiation, progress
  notifications and idle-timeout budgeting.
- An escalation holds an MCP tool call open for the whole waiting period, so a child waiting on a
  human stays resident.
- The Leader polls `fh approvals` rather than being pushed to.
- Child sessions remain claude-only. `approval-channel.mjs` pins `SESSION_PROVIDER` to `claude`
  as a deliberate fail-closed boundary, and this decision does not widen it.

Guarantees that are retained:

- A child cannot start unless its approval channel has answered a real MCP handshake, and is
  terminated if `system/init` shows the channel missing.
- `AskUserQuestion` answers round-trip as values, validated by the same routine on the writing
  and reading side.
- The escalation queue has exactly one writer per file and publishes answers with `O_EXCL` plus
  `link(2)`, so a request is answered once.
- Escalation rules live outside the working tree and cannot be weakened by a checked-out
  repository.

## Revisit triggers

This decision should be re-opened when any of these becomes true. They are written to be
checkable, not aspirational.

- **T1 — `defer` becomes usable for batched calls.** Either the runtime stops discarding a
  deferral when siblings share the batch, or the `PreToolUse` payload exposes enough about the
  batch for a hook to fail closed on its own. Re-check the guard in the shipped binary and the
  "Defer a tool call for later" section of the hooks reference.
- **T2 — a child-scoped hook delivery path is verified.** An approval hook can be injected per
  invocation without loosening `--strict-mcp-config` or `--setting-sources user`, **and** a
  pre-launch positive control equivalent to the current handshake probe exists for it. Both
  halves are required; the first alone only relocates the problem in point 4.
- **T3 — the retained cost becomes concrete.** An incident traced to the in-process escalation
  hold or to the MCP idle-timeout machinery, rather than a hypothetical about it.

Adopting `defer` after a trigger fires is an implementation change and needs its own issue. This
ADR does not authorise one.

## Codex app-server re-evaluation

`adapter-codex.mjs` declares `approvalChannel: "agent-review"`, meaning fh will not route a task
that requires a human decision to Codex. Issue #630 asked whether that judgement still holds now
that the Codex app-server has server-initiated approval requests.

**The declaration is correct for the transport the adapter actually uses.** `adapter-codex.mjs`
drives `codex exec`, which has no channel for handing an approval request to an external process.
The declaration should not be read as a claim about Codex as a product.

**On the `codex app-server` transport the picture is different, and this was verified against the
pinned CLI rather than upstream prose.** The schema that Codex CLI 0.150.1 generates for itself
lists these among `ServerRequest` — the requests the server initiates toward its client:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`

That is a genuine external approval channel: the client answers with a decision and the turn
resumes or declines, and `item/tool/requestUserInput` carries a blocking flag for input that
should wait for a person. Under that transport the axis value would be `external` rather than
`agent-review`.

**Unverified:** `thread/queue/add`, which the issue also named, is described in upstream's
app-server README but is **absent from the pinned CLI's generated schema**; upstream marks it
experimental and gates it behind an `experimentalApi` capability. Nothing here depends on it, and
it should not be treated as available.

**No declaration is changed by this ADR.** Moving fh onto app-server would make it a JSON-RPC
client owning thread and turn lifecycles — a far larger change than a capability string — and
`approval-channel.mjs` already records what a second session provider must bring: the wiring, the
sealed-argv verification and a provider-specific startup health check, not merely a capability
value. That belongs in its own issue.

## Assumptions recorded without user confirmation

This ADR was written in a non-interactive session. The approval gate that would normally have
settled the open choices reached its waiting limit and returned `denied automatically`, so no
person answered them. Three decisions were therefore taken on their recommended defaults and are
recorded here so they can be reversed in review rather than discovered later:

1. **The conclusion** — keep the current channel and record revisit triggers, rather than adopting
   `defer` or adopting Option D.
2. **The location and format** — a new numbered ADR under `docs/decisions/`, rather than a section
   in `design-rationale.md` or a page under `docs/explanation/`. The repository had no prior ADR
   convention, so this establishes one.
3. **The Codex scope** — record the verification result and note that following up belongs in a
   separate issue, without creating that issue and without touching the capability declaration.

## Sources

| Claim | Source |
|---|---|
| `PermissionRequest` is unavailable in plain `-p` runs; background-subagent auto-deny | [Hooks guide → Limitations](https://code.claude.com/docs/en/hooks-guide) |
| `defer` exists, is print-mode only, and precedence is `deny` → `defer` → `ask` → `allow` | [Hooks guide](https://code.claude.com/docs/en/hooks-guide); [Hooks reference → Defer a tool call for later](https://code.claude.com/docs/en/hooks#defer-a-tool-call-for-later) |
| `defer` introduced, resumed with `-p --resume` | `anthropics/claude-code` `CHANGELOG.md`, 2.1.89 |
| Decision vocabulary, solo-only and print-mode guards, `tool_deferred` / `deferred_tool_use` | Embedded strings of the shipped Claude Code binary (2.1.259 at the time of writing) |
| `-p` sessions start in `default` mode | [Permission modes → Which mode a session starts in](https://code.claude.com/docs/en/permission-modes) |
| Hooks run before the permission-prompt tool / `canUseTool` | [Agent SDK → Configure permissions](https://code.claude.com/docs/en/agent-sdk/permissions) |
| Codex server-initiated approval requests | Protocol schema generated by the pinned Codex CLI (0.150.1 at the time of writing) |
| `thread/queue/add` described but absent from the pinned schema | [`codex-rs/app-server/README.md`](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) vs. the generated schema |
