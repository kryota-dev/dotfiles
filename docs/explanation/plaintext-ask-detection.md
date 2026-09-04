# Detecting a turn that ends by asking in plain text

🌐 日本語: [plaintext-ask-detection.ja.md](plaintext-ask-detection.ja.md)

← [Docs index](../README.md)

The deployed agent instructions require that a decision be requested through the
`AskUserQuestion` tool, never as a sentence at the end of a reply. Instructions alone did not
hold: the same violation happened three times in one session, twice after the user pointed it
out, and once more after the rule itself had been merged and deployed. [`#616`][issue] asked a
narrower question first — **can this be detected mechanically at all?** — with an explicit
instruction not to design as if the answer were yes.

This document records what was measured, how to reproduce it, and what the resulting hook does
and deliberately does not do.

## Answer: yes, and here is the evidence

The `Stop` hook payload carries the reply text, and it carries enough identity to locate the
same turn in the transcript. Both halves are needed: the text alone cannot tell a compliant
"I asked properly and then summarised" from a violation.

### The payload, as captured on a real machine

Claude Code writes hook payloads into its own debug log. This instance was recovered from
`~/.claude/debug/<session>.txt` (session id redacted, transcript path shortened):

```json
{
  "session_id": "[REDACTED]",
  "transcript_path": "/Users/<user>/.claude/projects/-private-tmp/<session>.jsonl",
  "cwd": "/private/tmp",
  "prompt_id": "835ed30b-6fea-4886-b00e-917807befe28",
  "permission_mode": "auto",
  "effort": { "level": "xhigh" },
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "了解しました。何かお手伝いできることがあれば教えてください。",
  "background_tasks": [],
  "session_crons": []
}
```

To capture a fresh one, run any session with `claude --debug-file <path>` and grep that file
for `stop_hook_active`. A `Stop` hook that writes its stdin to a file works too, but note that
this needs a settings file the CLI will accept, which sandboxed environments may forbid.

### What each field is for

The runtime's own schema descriptions are the authority here, not this table:

| Field | Why the detector uses it |
|-------|--------------------------|
| `last_assistant_message` | The reply text. Documented in the runtime as existing so that hooks "avoid the need to read and parse the transcript file". Optional — a turn that ends on tool calls alone has none. |
| `transcript_path` | Path to the session's JSONL transcript, which does record every tool call. |
| `prompt_id` | "UUID correlating a user prompt with all subsequent events until the next prompt." This is what makes "in *this* turn" expressible. |
| `background_tasks` | Documented as letting hooks "distinguish 'session is done' from 'session is paused waiting for background work to wake it'". Empty array when nothing is in flight. |
| `stop_hook_active` | True when a hook already blocked this turn ending; used to avoid re-firing. |
| `agent_id` | Present only when the event fires from inside a subagent. |

### The transcript half, verified against real data

Two properties were checked against transcripts this repo's own sessions produced, not against
synthetic fixtures:

1. The payload's `prompt_id` equals the `promptId` of the `user` entry that opened the turn.
   Assistant entries carry `promptId: null`, and the `tool_result` entries that come back
   during the turn carry the same `promptId` as the opening prompt — so "everything at or
   after the first line bearing this id" is a sound window for the turn.
2. `AskUserQuestion` appears as an ordinary `tool_use` block on an `assistant` entry, with
   `isSidechain: false` for the main agent.

So the detector's second stage is: project the transcript to markers, and ask whether an
`AskUserQuestion` marker appears at or after the turn's opening marker.

## `Stop` does not mean the turn ended

This is the trap the design has to survive. A parent that delegates to a subagent emits `Stop`
mid-turn and then resumes **under the same `prompt_id`** — the `wave-orchestrator` skill
carries that measurement, and an earlier design that assumed one `Stop` per turn misreported
children that were genuinely waiting.

`background_tasks` is the field that resolves it, and it is why this became detectable now
rather than earlier: a non-empty array means the session is paused waiting for background
work, not finished. The detector skips those payloads outright.

That guard is not a proof of completeness. It is backed up by the phrase stage: a mid-turn
`Stop` while delegating reads like "I have started the reviewers", which matches nothing in
the phrase list.

## What the hook does

[`home/dot_claude/executable_plaintext-ask-check.sh`](../../home/dot_claude/executable_plaintext-ask-check.sh),
wired as `stop:plaintext-ask-check`.

**Stage 1 — cheap, runs on every turn.** Look only at a tail window of
`last_assistant_message` (`TAIL_SCAN_BYTES`, about 400 Japanese characters) and test it against
an explicitly enumerated list of decision-seeking phrases. A tail window rather than the final
line, because the observed violation shape often puts the choices *under* the question, which
would leave `- B: ...` as the last line.

**Stage 2 — only when stage 1 matched.** Read the transcript and decide whether
`AskUserQuestion` was called in this turn. Because stage 1 almost never matches, an ordinary
turn never pays for the transcript scan.

### The phrase list is deliberately narrow

The tolerated direction of error is "do not stop": missing a violation is acceptable, warning
on an ordinary report is not — a noisy detector gets switched off, and then it protects
nothing. So the list enumerates concrete decision-seeking closings and excludes general
question forms and the ordinary closings a report ends with. The list is a named constant in
the script, and the false-positive cases are pinned in `tests/claude_hooks.bats`.

### Three-valued output, so a broken detector cannot look clean

A silent detector failure is indistinguishable from "no violations found" — which is exactly
the failure mode this repo treats as worst. The hook therefore always writes one machine-
readable line to stderr:

| status | stdout | meaning |
|--------|--------|---------|
| `ok` | — | Evaluated. No violation. |
| `skipped` | — | Out of scope (mid-turn `Stop`, subagent, re-entrant, no reply text). |
| `violation` | `{"systemMessage": …}` | Detected. |
| `error` | `{"systemMessage": …}` when stage 1 already matched | **Could not evaluate** (no jq, unreadable transcript, unparseable line, `prompt_id` not found). |

`ok` and `error` are different values, and a test asserts that they stay different. Where the
sibling `Stop` hooks treat a missing `jq` as a silent no-op, this one reports `error`: for a
detector, "cannot evaluate" is not "nothing found".

The exit code is always 0. This is a warning, not a gate: it emits no `decision`, `continue`
or `stopReason`, and a test pins that.

### Why it is synchronous when the other `Stop` hooks are not

An `async` hook's stdout is collected later and delivered as a model-facing attachment. The
message here is for the user, at the moment the turn ends — so the entry omits `async` and
takes a short timeout instead. The repo already has synchronous hook entries; this is not a new
shape.

## Limits

- **Phrase-based, so it is bounded by its list.** A decision requested in wording nobody
  enumerated is missed. That is the chosen direction of error, not an oversight.
- **It cannot see the future of a turn.** If a `Stop` arrives mid-turn with no background work
  registered, and the agent would have called `AskUserQuestion` afterwards, the warning is
  spurious. It costs a line of text and blocks nothing.
- **The payload contract is not a public API.** If a future release drops
  `last_assistant_message` or renames `prompt_id`, the hook reports `error` rather than
  quietly passing — re-verify with the capture recipe above.

[issue]: https://github.com/kryota-dev/dotfiles/issues/616
