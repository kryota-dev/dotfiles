---
slug: 345-unify-launcher-wrappers
feature: Unify the claude/codex launcher families into non-interactive wrappers with built-in env injection
created_at: 2026-07-26T14:09:18+09:00
grill_session: 8d05fddc-a58c-4aae-999a-9544a8bdb3e2
status: finalized
---

# Background

`cld` / `cld-r06` / `cdx` / `cdx-r06` are interactive-zsh **aliases**, so non-interactive contexts
(hooks, launchd, scripts, Claude's Bash tool) never see them and resolve the bare `claude`/`codex`
binary with no per-account env. That forces duplicated env injection: morning-radar's hand-copied
block ("keep in sync with `_claude_with_home`" — #341 found a real bug in exactly such a copy) and
the codex skill's inline account-selection prelude, repeated 11× (`codex/SKILL.md`).
`secrets-and-isolation.md:150` names this "two places that must stay in sync" as the isolation
model's main maintenance burden.

This PRD consolidates env injection into wrapper commands on PATH so **every** launch — interactive,
hook-spawned, launchd, or Bash-tool — goes through one place. It deliberately takes the **low-risk
path**: claude stays mise-managed (its cold-install, pin-correct `mise which` resolution, the
`mise exec -- claude` provisioning convention, and the native-install self-check symlink all stay
untouched), so the change carries no fresh-machine-bootstrap or bricked-launch risk.

## Verified grounding (re-checked by hand + adversarially, 2026-07-26; see findings-345.md)

- `claude` interactive PATH: mise install dir idx 14 beats `~/.local/bin` idx 40; mise re-prepends
  install dirs every prompt via a `precmd` `hook-env`. `codex` is brew (`/opt/homebrew/bin` idx 41),
  `~/.local/bin` (40) already ahead; no mise involvement.
- `mise which claude` resolves the **pinned** version (2.1.220). `installs/claude/{latest,2,2.1}` all
  exist but track "highest ever installed", **not** the pin (proven: node `latest → 25.8.0` vs pin
  `24.18.0`) — so they are unsafe for pinned resolution; `mise which` is the pin-correct resolver.
- `disable_tools claude` would make `mise which`/`mise exec -- claude` break and leaves the fresh-machine
  cold-install of a disabled tool unverified → **rejected** (see decision log).
- launchd (morning-radar) hard-codes a PATH that excludes `~/.local/bin`. Claude's Bash tool replays an
  interactive shell **snapshot** whose PATH has `~/.local/bin` ahead of homebrew (so the codex wrapper
  wins there today) — but this is a private, untestable-from-repo mechanism (OQ-3).
- `run_once_after_16` (native-self-check symlink) is frozen at native 2.1.185 by a `run_once_`-in-bad-state
  bug; **left as-is** (out of scope) — the low-risk design does not touch the self-check symlink.

# User Story

As the operator of this environment, I want `claude`/`cld`/`codex`/`cdx` (and the `-r06` work-account
variants) to inject the correct per-account isolation env automatically from **any** shell — so the
hand-copied morning-radar env block and the inline codex prelude disappear and cannot drift.

# Acceptance Criteria

- **AC-001**: `claude`, `cld`, `codex`, `cdx`, `cld-r06`, `cdx-r06` are all resolvable and functional
  from a **non-interactive** shell (Claude's Bash tool / a login-shell `-c` invocation), not only
  interactive zsh. (Truly env-scrubbed `env -i` shells are out of scope — no dotfile PATH reaches them.)
- **AC-002**: In interactive zsh, bare `claude`≡`cld` and bare `codex`≡`cdx` resolve to the **same
  wrapper** and produce an **identical environment** (same `CLAUDE_CONFIG_DIR`/`CLV2_HOMUNCULUS_DIR`/
  observer knobs; same `CODEX_HOME` resolution + `--profile shared` injection).
- **AC-003 (isolation invariant)**: `cld-r06`/`cdx-r06` select the work account **unconditionally**.
  For the codex account, **`CLAUDE_CONFIG_DIR` is authoritative when set**: a bare `codex` derives
  `CODEX_HOME` from `CLAUDE_CONFIG_DIR` and **overrides a mismatched inherited `CODEX_HOME`** (closes
  the stray-export cross-account leak); only when `CLAUDE_CONFIG_DIR` is unset does it respect an
  already-set `CODEX_HOME`, else default personal. For claude, bare names fill `CLAUDE_CONFIG_DIR`
  only when unset (a hook-spawned child keeps its parent session's account). Tests prove a `-r06`
  invocation never resolves to the personal account and vice-versa across every
  (`CLAUDE_CONFIG_DIR`,`CODEX_HOME`) input combination, including empty-string (`${VAR+x}` vs `${VAR:-}`).
- **AC-004**: The morning-radar hand-copied env block and the codex prelude (11× in `codex/SKILL.md`)
  are **removed**; morning-radar and the codex skill call the wrappers. The #336 regression guard is
  **relocated, not deleted** — a test asserts the *wrapper* keeps `CLV2_HOMUNCULUS_DIR` outside the
  Claude config dir with the observer knobs. (Env injection is consolidated to the wrapper; the
  observer-enable slug derivation in `run_onchange_after_14` remains a separate mirrored copy — dedup
  is out of scope.)
- **AC-005**: `--profile shared` is injected by the codex wrapper **only when argv carries no
  `--profile`**, detected by a **per-token** scan that recognizes both `--profile` and `--profile=…`,
  stops at a literal `--`, and does not false-match a `--profile` substring inside a prompt argument;
  the injected flag is placed where codex accepts it for the bare, `exec`, and `exec review …` forms
  (verified in design). `codex … --profile agent …` (equals-form included) passes through unchanged.
- **AC-006**: Backward-compat preserved and tested end-to-end: `cldf`/`cldf-r06` still pin
  `--model claude-fable-5` and append the orchestrator prompt file (a test asserts the flag reaches
  the CLI through the wrapper); `claude-config`'s `ECC_DISABLED_HOOKS_EXTRA` prefix still reaches
  `ecc-hook.sh` (the wrapper `exec`s with full env inheritance, never `env -i`). Non-goal: the base
  wrapper injects **no** `--append-system-prompt[-file]` (mutual-exclusivity abort, #331).
- **AC-007**: `make test` (lint + bats) passes with the rewritten `tests/zsh_aliases.bats` (all 8+
  pinned `_claude_with_home`/`_claude_fable`/alias tests updated to the wrapper model) and the
  relocated morning-radar tests in `tests/files.bats`; docs EN/JA mirrors updated and
  `tests/docs_facts.bats` (mirror parity, relative-link resolution, lifecycle-script-documented) passes.

# Considered Alternatives / Rejection Rationale (decision log)

- **[CHOSEN — AC-001/002/003] Low-risk wrappers, claude stays mise-managed.** Wrapper scripts live in a
  dedicated PATH-prepended dir (e.g. `~/.local/…/launchers`); `claude`/`codex` there `exec` the real
  binary — claude via `mise which claude` (pin-correct), codex via `/opt/homebrew/bin/codex` — after
  injecting per-account env. `cld`/`cld-r06`/`cdx`/`cdx-r06` are chezmoi `symlink_` entries dispatching
  on `$0`. Non-interactive contexts are covered by adding the launcher dir first to the launchd/headless
  PATH strings (morning-radar; statusline fallback). The interactive bare-name win over mise (idx 14) is
  a `precmd` hook registered **after** mise's that re-prepends the launcher dir — **contained and
  trivially reversible**, and benign if it ever loses a race (bare `claude` would hit mise's binary, but
  a child in a `cld` session already inherits the account env, so correctness holds). Keeps
  `~/.local/bin/claude` (native self-check symlink) untouched.
- **[REJECTED — the earlier lead] Approach Y′: `disable_tools claude` + wrapper replaces the
  self-check symlink + provisioning switched to the wrapper.** Cleanest "single canonical launcher"
  end-state, but adversarial verify surfaced three unresolved, mostly untestable-from-repo risks:
  (R1) whether `mise install` provisions a `disable_tools`-listed tool on a **fresh** machine is
  unverified — if not, every cold `chezmoi apply` fails at the first claude-touching provisioning step
  (the repo's convention #5 exists because that race is real); (R2) under disable, the pin-correct
  `mise which` breaks and `latest`/`2` track highest-installed not the pin, so the wrapper would need to
  re-parse the pin; (R3) no evidence a wrapper **script** (vs a symlink to a binary) satisfies Claude
  Code's closed-source native-install self-check — if wrong, every claude launch could warn or refuse.
  For a "touches every launch" mechanism these are the wrong risks to take when the low-risk path
  delivers the same user-visible outcome. (User decision, intent gate.)
- **[REJECTED] Remove claude from mise `[tools]` / self-manage the binary.** Disturbs the Renovate pin
  and the install pipeline for no gain over keeping mise-managed.
- **[REJECTED — codex CODEX_HOME] Static `~/.codex` default or unset-only fill-gaps.** Both leak: a
  static default re-points an r06 child at personal; unset-only fill-gaps preserves a *mismatched*
  pre-set `CODEX_HOME` (stray export / nested codex) and silently crosses accounts — the exact shape the
  repo already flags for `codex:codex-rescue` (`codex.md:302`). Chosen: `CLAUDE_CONFIG_DIR`-authoritative
  override (AC-003).
- **[REJECTED] `case "$*" in *--profile*)` detection / tail-append injection.** Substring match
  false-positives on a prompt containing "--profile"; tail-append breaks `codex exec review --base …`
  (options must precede the subcommand); missing the `--profile=` form double-injects → codex hard-errors
  ("cannot be used multiple times"), breaking AC-005's own must-work case. Chosen: per-token parse (AC-005).
- **[REJECTED] Delete the morning-radar #336 sync tests.** They guard a real regression (headless CLV2
  write into a sensitive-file path). Chosen: relocate the assertion to the wrapper (AC-004).

# Out of Scope

- **#344** CLV2 state re-layout (`~/.local/share/claude*/ecc-homunculus`) — separate issue; keep current paths.
- **run_once_after_16 frozen-symlink bug** — pre-existing, not worsened; the low-risk design does not
  touch the self-check symlink. Optional follow-up: convert the `run_once_` gate to `run_onchange_`.
- **Full retirement of the bare-`claude` CLV2 fallback store** — tracked in #344; defensive code stays.
- **codex staying brew-managed**, and the account **secrets** (1Password) mechanism — unchanged.
- **De-duplicating the `run_onchange_after_14` slug derivation** — remains a mirrored copy.

# Open Questions (for /sdd design, none blocking feasibility)

- **OQ-1**: Exact launcher dir + how `cld`/`cld-r06`/`cdx`/`cdx-r06` dispatch on `$0` (must NOT
  `readlink -f "$0"` before dispatch — that would collapse the symlink identity; keep binary-resolution
  and dispatch-identity separate). Zsh `${home_dir:t}` slug logic reimplemented in POSIX for the script.
- **OQ-2**: Exact `--profile` insertion position that codex accepts for bare / `exec` / `exec review`
  forms (verify `codex --profile shared exec …` vs `codex exec --profile shared review …`).
- **OQ-3**: Confirm the launcher dir reaches Claude's Bash tool PATH (snapshot mechanism) before
  deleting the codex prelude; if it can't be guaranteed, keep a minimal prelude as defense.
- **OQ-4**: Whether `mise which claude` resolves the pin reliably in the launchd/headless context
  (mise present via shims); add a fail-loud fallback in the wrapper.

## SECURITY note (grill-me auto escalation — resolved with the user at the intent gate)

Account isolation is the security surface. AC-003 pins the invariant (a `-r06` invocation never
resolves to the personal account and vice-versa) with the `CLAUDE_CONFIG_DIR`-authoritative override
that closes the stray-`CODEX_HOME` leak. The approach choice (low-risk vs Approach Y′) was escalated
and the user selected the low-risk path.
