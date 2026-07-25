---
slug: 330-model-tier-codex-permissions
feature: Re-architect pr-workflow, sdd, and multi-review around current model tiers, Codex permissions, and agent composition
created_at: 2026-07-25T20:39:03+09:00
grill_session: session_01YQ9uutMiPknuVfBiaJsBrD
status: finalized
---

# PRD: Model tiers, Codex permissions, and agent composition (Issue #330)

## Background

`pr-workflow`, `sdd`, and `multi-review` orchestrate multi-agent work across Claude and
Codex. Issue #330 identifies four problems: stale model pins on both sides, Codex confined
to a read-only sandbox, mechanical phases running inline on the most expensive model, and
no detection of model/effort mismatch.

This PRD was produced by a 4-perspective council deliberation (architecture/SSOT,
security, cost/model-tier, operations/backward-compat), adversarially verified by two
independent reviewers, with every disputed fact re-verified first-hand. The following
**corrections and confirmations against the Issue's "Current state"** are binding on
implementation:

1. **Live `~/.claude/settings.json` has `"model": "opus[1m]"`** — an *alias* that
   currently resolves to Opus 5 — while the repo pins the literal slug
   `claude-opus-4-8[1m]`. The model drift is real (the Issue's *substance* was right; its
   literal value `claude-opus-5[1m]` was not). The bump is therefore a reconciliation
   *plus* a format decision: pin a literal slug or adopt the alias (AC-013, escalated).
   `effortLevel: "xhigh"` also exists live-only (user-set via `/effort`, persisted to
   settings.json, reverted by the next `chezmoi apply`).
2. **`codex exec` on the installed CLI 0.145.0 has no `--search` flag.** The top-level
   interactive `codex --search` *does* exist, and the `web_search` config key exists in
   the binary. Any "Codex verifies its own claims" adoption must smoke-test the
   non-interactive route before relying on it (AC-007).
3. **The `.orphaned_at` marker for plugin 1.0.6 exists**
   (`~/.claude/plugins/cache/openai-codex/codex/1.0.6/.orphaned_at`), as the Issue said.
   Installed is 1.0.4; the marketplace clone is at v1.0.6. The 1.0.4→1.0.6 diff adds
   `shell: false` to all git command invocations in `scripts/lib/git.mjs` — an unlisted
   shell-injection hardening. Agents/skills markdown is byte-identical.
4. **`codex:codex-rescue` (installed 1.0.4) already defaults to write-capable runs with
   `approval_policy: "never"`, bypasses `--profile` entirely, and does not propagate
   `CODEX_HOME`** — a second, ungoverned permission path that predates this work, and an
   account-isolation leak (invoked from a `cld-r06` session it acts on the personal
   `~/.codex` account).
5. **`cdx` / `cdx-r06` aliases unconditionally use `--profile shared`** — any model bump
   in the shared pin reaches interactive sessions. Option C's "shared unchanged" framing
   and the Issue's recommended model value cannot both hold; the model bump is an
   intentional interactive-facing change and must be declared as such.
6. The plugin setup script (`run_onchange_after_17-setup-claude-plugins.sh.tmpl`) installs
   only when the plugin is absent; it has **no version-reconcile path**, so editing the
   `ref` pin alone never converges the installed version.

## User Story

As the maintainer of this dotfiles repo, I want the three orchestration skills to run
each phase on the cheapest model tier that preserves quality, to use Codex as a
write-capable implementation worker inside a governed sandbox profile, and to be stopped
before implementation whenever the session model does not meet the declared contract — so
that cost, capability, and safety stay aligned without manual vigilance.

## Model/effort contract (the §4 table, frozen here as SSOT input)

This table is the contract `model-fitness-check` (AC-022) enforces. It supersedes Issue
#330 §4 as the authoritative copy; the implementation must embed it in the new skill,
not reference the Issue.

| Work | Model | Effort | Row type |
|---|---|---|---|
| `pr-workflow` classification/GATE/synthesis; `sdd` Phase 1–3 spec authoring; `multi-review` integration & adjudication | Opus 5 | high (default; not mentioned by the gate) | **floor** (blocking) |
| large tier, PRD deliberation, adversarial verification, cross-cutting design | Opus 5 | xhigh | **floor** (blocking) |
| trivial / small tier only | Sonnet 5 | medium | **cost hint** (non-blocking FYI) |
| Fable-orchestrator sessions (`cldf` family) | Fable 5 | session default | always passes (monotonic rule) |

Capability ordering is monotonic: Fable > Opus > Sonnet > Haiku; generation matters
within a family (Opus 4.8 does **not** satisfy an Opus 5 floor). "Current tier ≥ required
tier" passes silently.

## Acceptance Criteria

### A. Codex permission profile (Option C, refined)

- **AC-001** A new `home/.chezmoitemplates/codex-model-pin.toml` holds the Codex
  model/effort scalars (`personality`, `model`, `model_reasoning_effort`) as the single
  physical pin. `codex-shared-config.toml` becomes `includeTemplate "codex-model-pin.toml"`
  followed by its existing `[features]` table. (Nested include from a `.chezmoitemplates`
  file was verified working via `chezmoi execute-template`.)
- **AC-002** A new `home/.chezmoitemplates/codex-agent-config.toml` composes: the model
  pin, `sandbox_mode = "workspace-write"`, `approval_policy = "never"`, the `[features]`
  table with `multi_agent = true` (parity with `shared` — its omission would be an
  undeclared behavioural difference), and `[sandbox_workspace_write]` with
  `network_access = false`. Scalars are emitted before any table header (TOML composition
  constraint). The profile is self-contained: it must not depend on keys in the unmanaged
  base `~/.codex/config.toml` for its permission posture.
- **AC-003** `home/dot_codex/private_agent.config.toml.tmpl` and
  `home/dot_codex-r06/private_agent.config.toml.tmpl` deploy the agent profile to both
  accounts, mirroring how `shared` is deployed.
- **AC-004** `shared.config.toml` gains no sandbox/approval keys; interactive aliases
  (`cdx`, `cdx-r06`, `hcdx`, `hcdx-r06`) keep `--profile shared` untouched.
- **AC-005** The PR description explicitly states that the model bump in the shared pin
  reaches interactive `cdx` / `cdx-r06` sessions (intentional, per correction 5).

### B. Codex model bump

- **AC-006** `gpt-5.6-terra` + `xhigh` is smoke-tested in isolation via `-c` overrides
  (no SSOT file edits) before being committed to `codex-model-pin.toml`. Pass criteria,
  observed via `codex exec --json` (`session_configured` reports the effective model and
  reasoning effort) and/or `--strict-config`: (a) the CLI accepts the slug without silent
  fallback, (b) `model_reasoning_effort = "xhigh"` remains valid for the 5.6 generation,
  (c) one read-only review run and one `workspace-write` run complete coherently. On
  failure, `gpt-5.5` is kept and the hold-back is recorded in the PR.
- **AC-007** Precisely: the `--search` flag exists top-level but **not** on `codex exec`.
  The non-interactive live-search route (config `web_search` key, or a future exec flag)
  is smoke-tested; "Codex verifies its own claims" is implemented only if a working
  non-interactive route exists, otherwise recorded as intentionally dropped, with the
  parent continuing to supply external facts. Skill docs must not overgeneralize the
  flag's absence.

### C. Codex role widening (skill updates)

- **AC-008** `codex/SKILL.md` is updated as the SSOT for Codex invocation:
  - all `--full-auto` content removed; verified-CLI reference updated without hard-coding
    the version as prose fact where avoidable;
  - the stale model/effort/version restatement (line ~90) replaced by a pointer to the
    SSOT template;
  - a `--profile agent` invocation shape documented for implementation/CI-fix tasks;
    review tasks stay on `--profile shared --sandbox read-only`;
  - `codex exec review --base <branch> / --uncommitted / --commit <sha>` documented as
    the preferred review entry point;
  - an explicit prohibition: `danger-full-access`, `--yolo`,
    `--dangerously-bypass-approvals-and-sandbox` are never used from skills; if a
    situation seems to require them, stop and escalate to the user;
  - a mandatory worktree guard prelude for every `workspace-write` invocation:
    `git rev-parse --path-format=absolute --git-dir --git-common-dir` — abort when the
    two paths are equal (cwd is in the main worktree) **or when rev-parse fails**
    (fail-closed). The naive relative-path comparison was measured to false-negative in
    main-worktree subdirectories and must not be used;
  - an execution-ordering contract: after a `workspace-write` run, the parent reviews
    the full diff **before running any host-side verification commands** (tests, lint,
    build) and before committing — Codex-written tests/Makefile changes execute on the
    host outside the sandbox, so diff review must precede execution, not just the commit;
  - network policy: `network_access` stays false in the profile; call sites opt in via
    `-c sandbox_workspace_write.network_access=true` plus a minimal `network_proxy`
    domain allowlist (docs + registries only; GitHub excluded — the parent supplies
    GitHub-derived context); Codex output produced with network access is treated as
    untrusted input and independently verified by the parent;
  - a residual-risk note: `workspace-write` retains full-disk **read** (e.g. `~/.ssh`,
    auth files); exfiltration via obfuscated diff content is mitigated — not eliminated —
    by the parent diff review and gitleaks, and is accepted as residual risk.
- **AC-009** `multi-review` Phase 2 switches its Codex leg to `codex exec review --base
  <branch>` (read-only), with the current heredoc-embedded-diff shape retained as a
  documented fallback for cases where the base branch is not locally available.
- **AC-010** `pr-workflow` small tier and `sdd` Phase 4 self-contained single-task items
  gain a documented delegation choice between a **Sonnet 5 worker and a Codex worker**
  (`--profile agent`, parent commits) — preserving the Issue's two options, with guidance
  (default Sonnet; Codex when cross-model diversity in implementation is wanted or Claude
  is stuck). The self-contained criterion is operationalized per context: for `sdd`,
  single file + no dependency edges in tasks.md + no shared state with concurrent tasks;
  for `pr-workflow` small tier (no tasks.md), the tier definition itself (few files,
  owned boundary, no contract changes).
- **AC-011** `pr-workflow` Phase 5 gains a documented Codex CI-fix route, connected to
  AC-020: the triage worker's summary diagnosis is the handoff trigger — when the
  diagnosis is clear, the parent passes it plus the failing logs (fetched via `gh`) to
  Codex under `--profile agent`; when unclear, the fix stays with the parent.
- **AC-012** Skill orchestration (`pr-workflow` / `sdd` / `multi-review`) never invokes
  `codex:codex-rescue`; the plugin remains available for ad-hoc manual rescue only. Its
  known gaps (no profile, no `CODEX_HOME` propagation → account-isolation leak from
  `cld-r06`, write-by-default + `approval_policy: never`) are documented in
  `docs/agents/codex.md`.

### D. Claude-side model and effort pins

- **AC-013** `home/dot_claude/settings.json` `model` is updated to the literal slug
  **`claude-opus-5[1m]`** — a reconciliation of real drift (correction 1). Pin format
  DECIDED BY USER (2026-07-25): literal slug over the `opus[1m]` alias, consistent with
  the repo's pinning philosophy and the FACT-marker string assertion (AC-025).
- **AC-014** `effortLevel: "xhigh"` is adopted into `home/dot_claude/settings.json`
  (DECIDED BY USER, 2026-07-25) — declaring the user's standing xhigh preference so
  `chezmoi apply` no longer clears it. Per-session tuning stays available via `/effort`.
- **AC-015** `cc-code-review` and `cc-security-review` agents: `model: inherit` →
  `model: sonnet` + `effort: xhigh`. The behavioural change for standalone use is called
  out in the PR description. `multi-review`'s cost note (line ~581) is inverted: the
  caller raises the model for security-critical / large-tier reviews, with that opt-in
  criterion written into the delegation prompt.
- **AC-016** `renovate-analyzer`: `model: inherit` → `model: sonnet` + `effort: high`
  (completing the asymmetry fix the Issue omitted).
- **AC-017** The remaining five reviewer agents (`architecture-reviewer`,
  `typescript-reviewer`, `react-reviewer`, `python-reviewer`, `database-reviewer`) get
  `effort: high` floor pins; after this change no finding-generating agent definition
  leaves `effort` unpinned.
- **AC-018** A new curated agent `adversarial-verifier.md` (`model: sonnet`,
  `effort: xhigh`) is added; `pr-workflow` Phase 6 (large tier) runs three instances in
  parallel with distinct refutation framings, replacing the same-context inline round.
  (Rationale: the Agent tool cannot pass `effort` per call; only frontmatter can.)
- **AC-019** `sdd` Explore research is pinned by task shape: verbatim retrieval
  (Phase 1 steering-docs survey) → `model: haiku`; pattern-recognition research
  (Phase 1 architecture analysis, Phase 2 reuse discovery) → `model: sonnet`. The
  cost-optimization note (line ~644) is updated to describe reality. (Deliberate
  refinement of the Issue's uniform-Haiku proposal; see alternative 9.)
- **AC-020** `pr-workflow` Phase 5 CI log triage is delegated: Haiku first-pass
  classification, **sequentially escalating** to Sonnet when the diagnosis is non-obvious
  (a deliberate change from the Issue's "parallel worker" phrasing — triage output is a
  serial gate for the AC-011 handoff, not fan-out work); workers return summary
  diagnoses, never raw logs, to the parent.
- **AC-021** `multi-review` Phase 3 fact-checking is delegated to per-finding Sonnet
  workers (default effort) running in parallel with context7/WebFetch access;
  cross-finding synthesis and adjudication stay with the parent.

### E. model-fitness-check skill

- **AC-022** A new curated skill `model-fitness-check` is the SSOT for the contract
  table above. All three skills call it at their entry point, before any implementation
  phase (`pr-workflow`/`sdd`: top of Phase 0; `multi-review`: before Phase 1 — it has no
  Phase 0), and do not restate the table. Design requirements:
  - row typing as in the table: floor rows block with an `AskUserQuestion` (switch /
    continue anyway with a one-line degradation note / abort) and print literal `/model`
    and `/effort` commands; the trivial-small row is a non-blocking one-line cost hint
    that never stops the workflow;
  - **detection mechanism (specified)**: primary — the session's own system-prompt model
    identity (self-report); secondary — Read of `~/.claude/settings.json` `model` as a
    cross-check (it may lag in-session `/model` changes, so disagreement is surfaced,
    not silently resolved);
  - **normalization rules**: strip the `[1m]` context-window suffix before comparison;
    resolve aliases (`opus`, `sonnet`, `haiku`, `fable`) to their current generation;
    compare by family + generation (Opus 4.8 fails an Opus 5 floor); unknown strings →
    fail-safe (present the check);
  - effort: `effortLevel` in settings.json is readable and is used as the *presented
    default*, but because in-session `/effort` state may diverge, the gate presents and
    asks rather than infers; effort is mentioned only for xhigh rows;
  - if model detection fails entirely, the gate falls back to always presenting the
    check — never silently skipping.
- **AC-023** `docs/agents/skills-provenance.md` / `.ja.md` `FACT:curated-skill-count`
  is bumped (45 → 46) in the same PR.

### F. Plugin version pin

- **AC-024** The installed codex plugin converges on 1.0.6 (the pinned `ref`), adopting
  the `shell: false` hardening. The convergence procedure (`claude plugin marketplace
  update openai-codex && claude plugin update codex@openai-codex` per
  `CLAUDE_CONFIG_DIR`) is recorded, and **verified post-hoc**: the marketplace clone
  remains at v1.0.6 (the CLI is known to ignore refs on some paths), the installed
  version reports 1.0.6, and recovery from the current orphaned-1.0.6 cache state is
  confirmed. The setup script's missing version-reconcile path is documented as a known
  gap (implementing reconciliation is optional in this PR).

### G. Docs, tests, and guardrails

- **AC-025** `docs/agents/claude-code.md` / `.ja.md` model-pin rows gain FACT markers
  backed by a new string-comparison bats assertion (the existing `docs_facts.bats`
  extraction is digit-only and cannot be reused as-is).
- **AC-026** `docs/agents/codex.md` / `.ja.md` document the `agent` profile alongside
  `shared`, the codex-rescue positioning (AC-012), and the unmanaged
  `~/.codex/config.toml` as a known, intentionally-unmanaged drift source. English and
  Japanese mirrors stay in sync in the same PR.
- **AC-027** This repository is never added to `[projects.*] trust_level = "trusted"` in
  any Codex config; the untrusted-by-default property is documented as load-bearing
  (untrusted projects skip project-local `.codex/` layers — the defense against
  malicious PR branches carrying `.codex/` config). *Note: this is a new permanent
  constraint originating from council review, not from Issue #330 — included in the
  user sign-off below.*
- **AC-028** Smoke tests recorded in the PR: (a) `codex exec --profile agent -c
  approval_policy=never` against this untrusted project does not hang on a trust prompt;
  (b) **run in a linked worktree** (where `.git` is a gitdir pointer *file*, not a
  directory): a `workspace-write` run cannot write `.git` / `.agents` / `.codex` —
  main-worktree-only passes are not acceptable evidence; (c) `--add-dir` write scope
  stays within the added directory; (d) `network_proxy` is exercised end-to-end once
  non-interactively (it is an experimental feature gated behind `/experimental`; if it
  does not function under `codex exec`, the network opt-in route is documented as
  parent-mediated only).
- **AC-029** The PR includes a checklist covering every "Current state" row **and**
  every decision row of §3 (Use table) and §5 (delegation table) of Issue #330, each
  marked *updated* / *adopted* / *intentionally held back or skipped* with one line of
  rationale.
- **AC-030** `home/dot_claude/fable-orchestrator-prompt.md` is updated to reflect the
  effort axis: subagent `effort` pins now exist in agent frontmatter, and the Fable
  session's position in the contract table (always passes; delegation defaults
  unchanged). This closes the Issue's "says nothing about effort" row.
- **AC-031** `tests/files.bats` gains assertions for the newly deployed files
  (`agent.config.toml` under both `~/.codex` and `~/.codex-r06`), matching the repo's
  norm that deployed artifacts are bats-verified.

## Considered Alternatives / Rejection Rationale

| # | Alternative | Rejected because |
|---|---|---|
| 1 | **Option A** — set model/effort/sandbox flags at each Codex call site inside skills | Creates a fourth copy of the pin; skill behaviour diverges from interactive `cdx`; reproduces exactly the drift pattern Issue #330 documents (AC-001/002 instead centralize the pin in one template) |
| 2 | **Option B** — put permissions into `codex-shared-config.toml` | Would flip interactive `cdx` / `cdx-r06` sessions to `workspace-write`; permission posture and model pin have different risk profiles and must not share one file |
| 3 | Plain Option C as written in the Issue (duplicate model keys in a new agent config) | TOML pitfall: appending scalars after `[features]` would silently nest them; and a second copy of the model pin re-creates drift. Refined into the `codex-model-pin.toml` include shared by both profiles |
| 4 | `network_access = true` as the agent-profile default | Most worker tasks (implementation, CI fix) don't need network; a default-on posture widens the attack surface with no per-call justification. Opt-in forces each call site to articulate why |
| 5 | Consolidating Codex access **into** the `codex:codex-rescue` plugin | Vendor-managed code: cannot inject `--profile`, `CODEX_HOME`, or account isolation; its own defaults (write + never-approve, no profile) are the ungoverned path this PRD closes |
| 6 | Retiring `codex:codex-rescue` entirely | Its ad-hoc rescue value (deliberately thin forwarder) is real and orthogonal to skill orchestration; manual invocations have a human directly in the loop. Restricting skills from calling it + documenting its gaps achieves the governance goal |
| 7 | Pinning the plugin back to 1.0.4 | Chooses the version *without* the `shell: false` shell-injection hardening while simultaneously widening Codex write access — a security regression at the worst moment |
| 8 | chezmoi-managing `~/.codex/config.toml` | The CLI rewrites this file (trust decisions, migration notices); apply would revert user-approved `trust_level` entries; committing it would leak absolute paths of unrelated client projects into a public repo |
| 9 | Uniform `model: haiku` pin for all sdd Explore calls | Reuse-discovery research has an undetectable-false-negative failure mode (the Leader cannot see what Explore missed); only verbatim retrieval is safe at the Haiku tier |
| 10 | A blocking fitness gate for the trivial/small (Sonnet) row | Stopping the lightest path to suggest a *downgrade* maximizes friction exactly where pr-workflow is designed to be autonomous; it is a cost hint, not a quality floor |
| 11 | Copying the contract table into each of the three SKILL.md files | Three copies would drift exactly as the Codex pin did — the Issue's own evidence; single shared skill instead |
| 12 | Adopting `gpt-5.6-sol` for the multi-review diversity leg now | Cross-vendor diversity (GPT vs Claude) already exists; intra-generation diversity adds a second pin + smoke-test surface with unmeasured benefit. Revisit with observational evidence |
| 13 | Advisor tool (API beta) for cheap-worker/expensive-judge pairing | No Claude Code surface exists to declare it; the delegation patterns in section D implement the same shape natively |
| 14 | Letting Codex run `chezmoi apply` (Issue §3 "Do not adopt", made explicit here) | chezmoi's target is `$HOME`, outside any sane workspace root; `~/.agents` and `~/.codex` are themselves sandbox-protected paths — structurally impossible under `workspace-write` and not wanted under any wider mode |
| 15 | Letting Codex run git/`gh` write operations (Issue §3 "Do not adopt") | `.git` stays read-only under `workspace-write`; lifting it would route around the gitleaks hook and 1Password commit signing. The parent commits |

## Out of Scope

- Auditing or changing the three existing `trust_level = "trusted"` entries for
  unrelated projects (separate issue; requires user context this repo lacks).
- chezmoi management of `~/.codex/config.toml` (rejected, alternative 8).
- `gpt-5.6-sol` as a second Codex model (deferred, alternative 12).
- Patching plugin internals (upstream-managed; includes the `spark` slug hardcodes).
- Version-pinning the Codex CLI itself in mise/Brewfile (separate issue candidate;
  today no SSOT exists for the CLI version, which is why prose version claims go stale).
- Full implementation of a plugin version-reconcile path in the setup script (documented
  as a known gap; manual convergence procedure suffices for this PR).
- Any change to GATE semantics, phase structure, or the merge-is-user rule.

## Resolved Decisions (user-approved 2026-07-25)

1. **PRD approved as a whole**, including the security posture: agent profile
   (workspace-write + `approval_policy=never`), network default-off with per-call
   opt-in, worktree guard, codex-rescue excluded from skill orchestration, permanent
   untrusted status for this repo (AC-027), plugin convergence on 1.0.6.
2. **AC-013:** literal slug `claude-opus-5[1m]`.
3. **AC-014:** adopt `effortLevel: "xhigh"` into the repo.
4. **PR packaging: 4-PR split** — PR-1 correctness fixes to `codex/SKILL.md`; PR-2
   Codex profile plumbing + model bump; PR-3 Claude-side pins + new skill/agent + skill
   rewires; PR-4 plugin convergence + docs sweep. Sequenced serially (PR-1 and PR-2
   both touch `codex/SKILL.md`; PR-3 references PR-2's profile).

## Open Questions

1. If the `gpt-5.6-terra` smoke test fails (AC-006), fall back to `gpt-5.5` and report
   the hold-back explicitly in the PR-2 description and at GATE 1 — no silent
   acceptance (safe default; re-escalation happens naturally at the gate).
