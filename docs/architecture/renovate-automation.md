# Renovate automation: the merge gate

[Japanese mirror](renovate-automation.ja.md)

Dependency updates merge without a human in the loop. Roughly 55 Renovate pull
requests land per month; none of them wait for an approval unless something about
the update cannot be cleared mechanically.

This page describes what clears them, why the safety net cannot silently switch
itself off, and the one piece of setup that lives in the GitHub UI rather than in
this repository.

## The path an update takes

```
Renovate opens a PR
  └─ enqueues GitHub's native auto-merge (platformAutomerge defaults to true)
  └─ renovate-gate.yml runs
       ├─ author is not Renovate ──────────────► status: success (never block a human PR)
       ├─ renovate-gate-classify.sh says pass ─► status: success
       └─ says needs-agent ─► agent reviews ─► records a verdict to a local file
                                              └─ workflow turns that into a status
                                                   ├─ pass    ► success
                                                   ├─ fail    ► failure + @mention comment
                                                   └─ missing ► failure
  └─ ruleset holds the merge until every required check passes
       └─ all green ► auto-merge fires
       └─ blocked   ► the owner reviews the PR
            ├─ Approve         ► status flips to success
            └─ Request changes ► body decides: close the PR, or stay blocked
```

Weekly, `renovate-digest.yml` posts a catch-up summary to the Dependency
Dashboard (issue #12) covering what merged and what is actually worth knowing.

## What the deterministic classifier will and will not clear

`scripts/renovate-gate-classify.sh` decides, using shell only, whether an update
is ordinary enough to skip agent review. It is an **allowlist keyed on the shape
of the update**, not a risk score, and never on how small the diff looks.

| Update | Verdict | Why |
| --- | --- | --- |
| `update dependency gh to v2.99.0` | `pass` | Tagged three-part semver release of a named dependency, one file, `+1/-1` |
| `update anthropics/skills digest to 5304866` | `needs-agent` | Digest bumps follow a moving `main`; one line hides arbitrary upstream change |
| `update nginx:… docker digest to a9ae6f6` | `needs-agent` | Same, for container images |
| `update …/claude-code-action action to v1.0.214` | `needs-agent` | Runs in CI holding a long-lived token |
| `update dependency java to v25` | `needs-agent` | Bare major, no three-part semver |
| `update deno monorepo to v2.8.3` | `needs-agent` | Grouped update, not a single named dependency |
| Anything unparsable, or a failed `gh` call | `needs-agent` | Unclassifiable is never "safe" |

**A one-line diff is not evidence of a small change.** The skill archives this
repository pins by digest track upstream `main` with no release step at all, and
their content is Markdown that instructs agents — the prompt-injection path the
`renovate.json5` comments call out. That is why the fast lane is an allowlist:
a title form Renovate invents later falls to the agent by default.

**CI state is deliberately not part of the classifier.** The gate starts the
moment the PR opens while the Test job takes minutes, so reading the check
rollup would report "still running" for nearly every PR and push the whole
deterministic lane into the agent — and it is self-referential, because the
gate's own status appears in that rollup. CI checks are registered as required
checks alongside the gate instead, so a merge needs all of them. *Passing the
gate is not merging.*

## Why the safety net cannot switch itself off

Three independent things must fail before an unreviewed update can merge.

1. **A missing check is not a passing check.** The `renovate-gate` status is a
   required status check. If the workflow never runs — broken YAML, a disabled
   workflow, an outage — nothing is reported and the ruleset holds the PR at
   pending.
2. **A missing verdict is a failure.** The reporting step runs with
   `if: always()`. If the agent crashes or times out without recording anything,
   the check fails. "No error" is never read as "approved".
3. **Unclassifiable falls to the agent.** The classifier has no path from
   "I could not tell" to `pass`.

## The write-surface split

The agent that reviews an update cannot mark that update as reviewed.

| Script | Called by | Can it reach the network? |
| --- | --- | --- |
| `scripts/renovate-gate-verdict.sh` | the agent | No. Writes one local JSON file, never invokes `gh` or `curl` |
| `scripts/renovate-gate-status.sh` | workflow steps only | Yes — but it is **not** in the agent's `--allowedTools` |
| `scripts/renovate-triage-comment.sh` | the agent | Only to create a comment on issue #12 or an open Renovate PR |

The agent records a decision; the workflow performs the action. `close` in a
verdict file means "the workflow should close this PR", never "the agent closed
it". `tests/files.bats` asserts these absences, so the property survives edits to
the workflows.

There is no `issue_comment` trigger anywhere in these workflows. On a public
repository that would take orders from anyone who can type in the comment box.

## Approving, rejecting and giving direction

When the gate blocks a PR you get a comment mentioning you, which the GitHub
Slack app relays. Everything is then one review away:

- **Approve** — clears the gate; queued auto-merge takes it from there. GitHub
  allows an empty body, so this is a single tap.
- **Request changes** — the body decides. Wording that reads as rejection closes
  the PR (which is how Renovate is told to stop proposing that version);
  anything else is treated as direction, answered in a comment, and the PR stays
  blocked. GitHub *requires* a body for this review type, so there is always
  something to read.

Because this repository is public, anyone can submit a review. The first step of
`renovate-review-action.yml` checks the reviewer's collaborator permission and
does nothing at all unless it is `admin` or `write`.

Closing a **digest** PR only ignores that one upstream commit; the next commit on
the tracked branch produces a new PR. To stop tracking a dependency entirely, use
`ignoreDeps` in [`.github/renovate.json5`](../../.github/renovate.json5).

## Setup that lives in the GitHub UI

<!-- The ruleset is deliberately not managed as code: a ruleset definition inside
     the repository could be weakened by the very pull requests it is meant to
     gate. -->

The required status check is configured by hand, once. Without it the gate reports
its verdict and nothing acts on it.

1. **Settings → Rules → Rulesets → New ruleset → New branch ruleset**
2. **Name**: `main-protection`
3. **Enforcement status**: `Active`
4. **Bypass list**: add yourself (Repository admin), so direct pushes to `main`
   keep working
5. **Target branches**: add the default branch (`main`)
6. **Rules**: enable **Require status checks to pass**, then add:
   - `renovate-gate` — the gate itself
   - `Lint`, `Test` — the CI jobs the classifier deliberately does not read
   - `CodeQL`, `GitGuardian Security Checks` — optional, same reasoning
7. Leave **Require branches to be up to date before merging** *off*. Turning it on
   makes Renovate rebase every PR whenever `main` moves, which stalls auto-merge.

To verify: open any pull request and confirm `renovate-gate` appears in its checks
and reports `success` for a non-Renovate PR.

## Rollout order

Enabling automerge before the ruleset exists opens a window in which every PR
merges with no gate at all. The order matters:

1. Land the gate workflow and confirm it reports a status on real PRs
2. Confirm a non-Renovate PR gets an immediate `success`
3. Create the ruleset (above)
4. **Only then** enable `automerge: true` in `.github/renovate.json5`

## Related

- [Externals, SHA-pinning & the single-tarball cache](externals-and-pinning.md) —
  what the digest-pinned entries are and how they refresh
- [Developer toolchain: mise, Brewfile & git](dev-tooling.md) — where the version
  pins Renovate updates actually live
