---
slug: 371-ntfy-notification-dashboard
feature: Lightweight ntfy notification-history dashboard (in-repo, no persistence)
created_at: 2026-07-27T02:54:09+09:00
grill_session: session_01DSRG5DaBEWwmaoKZqFdEnV
status: finalized
---

# Background

Issue #371 requests a web dashboard visualizing ntfy notification history — localhost-hosted,
mobile access via tailnet, notifications grouped per session/task, with LLM-generated summaries.
The plumbing mostly exists: self-hosted ntfy v2.26.3 behind `tailscale serve` (tailnet-only,
funnel forbidden; `home/dot_config/ntfy/compose.yaml.tmpl`, `home/dot_config/ntfy/lib.sh.tmpl`),
a polling API (`GET /<topic>/json?poll=1&since=`), and session/repo/account tags already attached
by `home/dot_claude/executable_ntfy-notify.sh:184-198` (`tags: [$emoji, $event, $repo, $account,
$sid]`). The server-side cache window (168h / 7 days, `home/.chezmoidata.toml:174`) is the accepted
retention boundary — no external persistence is introduced.

The closest precedent is #361 (`.claude/prds/361-brief-url-ntfy.prd.md`), which added a
tailnet-reachable HTML page (a loopback nginx sidecar fronted by `tailscale serve --https 8443`, a
**port proxy** — the macOS standalone/App Tailscale variant cannot serve files/directories
directly, only ports) for the weekday morning-brief. That page is **static** (pre-rendered once by
`morning-radar.sh`, a one-shot `StartCalendarInterval` weekday job with `RunAtLoad` intentionally
absent — see the Considered Alternatives correction below); #371 differs in that it needs
**dynamic** behavior — fetching and grouping live ntfy history, and generating an LLM summary **on
demand** from an interactive mobile request — so a static file server is not sufficient, and
**no precedent for a persistent/always-reachable service exists yet in this repo**.

The mise toolchain (`home/dot_config/mise/config.toml:2-8`) pins `node`, `python`, `ruby`, `go`,
`deno`, and `rust` as **"core backend" language runtimes**; `bun` (`config.toml:15`) is pinned
separately under `# CLI tools (auto-selected via registry)`, not the core-backend group. No
app-server code (Go/Node/Python/Deno/Bun) exists anywhere in this repo yet — every runtime choice
below starts from zero precedent.

# User Story

As the repo owner, when I tap the dashboard notification/bookmark on my phone (on the tailnet), I
see the cached `claude-attention`/`claude-done` notification history grouped by session (`sid`),
repo, and account tag, and I can trigger an on-demand LLM-generated summary of the currently
displayed window without any of it leaving the tailnet or being written to durable storage.

# Acceptance Criteria

- **AC-001**: The dashboard is reachable from a mobile device via a dedicated tailnet HTTPS URL
  (`tailscale serve`, port-proxy pattern like #361's `--https 8443`, tailnet-only — `tailscale
  funnel` never used) and shows notification history fetched from the `claude-attention` and
  `claude-done` ntfy topics via the polling API with `since=all` (the full 168h cache), grouped by
  the existing `sid` (session)/`repo`/`account` tags, rendered as a **mobile-readable page** that a
  phone browser displays natively (matching #361 AC-001's mobile-rendering bar, not just
  "technically reachable").
- **AC-002**: The ntfy **subscriber** credential (`docs/architecture/notifications.md:51-56`:
  username + password, Basic Auth — **not** a Bearer token like the publisher) is used only
  server-side to fetch from ntfy; it never reaches the browser. Because the dashboard process is
  **unattended** (no human present when it runs, unlike `chezmoi apply`/`ntfy-setup` which are
  always human-attended today), the credential is provisioned once into a 0600 runtime-state file
  analogous to `~/.config/ntfy/notify-env` (the existing pattern for the publisher token) — **not**
  via a live `op read` at request time, which has no precedent for unattended use and would fail
  silently whenever 1Password is locked.
- **AC-003**: An on-demand LLM summary view generates a summary of the currently displayed window
  by invoking the local `claude` CLI headless (`claude -p ...`, personal account, same launcher
  wrapper `~/.local/launchers/claude` that `morning-radar.sh` uses) — no external LLM API call, no
  new secret provisioned. The call is made with an **explicit empty/minimal tool allowlist** (no
  `Bash`/`Read`/`Edit`/etc. — pure text-in/text-out summarization), mirroring
  `morning-radar.sh:50`'s least-privilege `ALLOWED_TOOLS` precedent. This is required because the
  summarized content includes `last_assistant_message` bodies from other sessions, which
  `docs/architecture/notifications.md:79-80` already documents as a residual prompt-injection risk
  (a prior agent's output could contain adversarial instructions) — the summary call must never be
  granted the ability to *act* on such instructions.
- **AC-004**: No persistent store is introduced. All fetched-notification and generated-summary
  state lives in the server process's memory (or the 0600 runtime-state credential file from
  AC-002) only; a process restart loses all cached state with no data-loss concern (fully
  re-derivable from the ntfy cache).
- **AC-005**: No additional authentication layer is added to the dashboard — the tailnet-only
  network boundary (`tailscale serve`, no funnel) is the sole access control, matching the #361
  brief-page precedent. (Forced-escalation decision, user-confirmed in this grill-me session.)
  **Noted asymmetry**: #361's no-auth call was made for a side-effect-free static file server;
  this dashboard's summary action has a billable side effect (AC-003). The asymmetry is accepted
  given AC-008's rate ceiling and the pre-existing tailnet trust boundary, but is recorded here so
  the user can revisit it if the trade-off reads differently on reflection.
- **AC-006**: The dashboard runs as a **native macOS process** (not Docker) because AC-003's
  `claude` CLI invocation depends on host-only state (`~/.claude`, mise-managed binary resolution
  via `mise which claude`, per-account homunculus dirs) that a container would need to replicate
  with no isolation benefit in return (the ntfy/brief-page containers exist for unrelated reasons —
  the Homebrew `ntfy` formula's `noserver` build tag and macOS Tailscale's file-serve limitation —
  neither applies here). **Correction from an earlier draft**: this is a **zero-based launchd
  design**, not "analogous to `morning-radar`" — `dev.kryota.morning-radar.plist.tmpl` uses
  `StartCalendarInterval` with `RunAtLoad` **intentionally absent** (a one-shot weekday job), and
  no `KeepAlive`/persistent-daemon LaunchAgent exists anywhere in this repo today. Default
  direction: launchd **Socket-activation** (the `Sockets` key — the process starts only on the
  first tailnet connection and can idle-exit after inactivity), which keeps the AC-002 credential
  out of memory except while actually serving requests and avoids introducing this repo's first
  always-on listening daemon. `/sdd` must verify feasibility of consuming a launchd-activated
  socket from the chosen runtime (OQ-4); if impractical, fall back to a lightweight always-on
  process with an internal idle-timeout self-exit.
- **AC-007**: Every notification title/body/tag value rendered in the dashboard UI is
  HTML-escaped before display, preventing stored/reflected XSS from untrusted notification content
  (bodies can originate from `last_assistant_message`, see AC-003). This dashboard is a more
  XSS-exposed surface than #361 (an interactive UI displaying many messages, vs. a single
  pre-rendered page), so it must be at least as strict as #361's `pandoc -f markdown-raw_html`
  escaping precedent, not weaker.
- **AC-008**: On-demand LLM summary calls are rate-limited with concrete numbers (default proposal,
  confirm/tune during `/sdd`: no more than one summary generation per fetched-window-hash within a
  5-minute TTL, and no more than 20 summary generations per rolling 24h — deliberately modeled
  after `morning-radar.sh`'s one-approved-run/day budget concept, adapted for on-demand use).
  Concurrent requests for the same not-yet-cached window **coalesce** into a single in-flight
  `claude -p` call rather than triggering duplicate billed calls (addresses multi-device access,
  e.g. phone + tablet requesting at once). The known risk that on-demand calls share the personal
  account's rate/quota headroom with ordinary interactive sessions is accepted as a single-user
  tool trade-off, not silently ignored.
- **AC-009**: Fail-open / graceful degradation matching the existing 2-phase provisioning pattern
  (`chezmoi apply` warns-and-skips when Docker/Tailscale is not yet available; a separate
  re-runnable setup command completes it later — mirroring `ntfy-setup`'s role for the existing
  ntfy service). A timeout/turn ceiling bounds each on-demand `claude -p` summary call (mirroring
  `morning-radar.sh`'s `TIMEOUT_SECONDS`/`MAX_TURNS` guards) so a runaway call cannot pile up, and
  an ntfy-fetch or `claude` CLI failure surfaces a clear in-UI error state without crashing the
  server process.
- **AC-010**: The app and its config are managed within this repo via chezmoi — a launchd plist
  template, the app script(s), and a new SSOT block in `home/.chezmoidata.toml` (both the loopback
  port **and** the tailnet HTTPS port — see OQ-1's correction, this repo's existing `[ntfy]`
  precedent inconsistently SSOTs only one of the two, which this feature should not repeat) are
  chezmoi-deployed. `home/run_onchange_after_30-register-launchd-agents.sh.tmpl` currently
  hardcodes only the `dev.kryota.morning-radar` label (OQ-5) — generalize it to register multiple
  LaunchAgents, or add an equivalent dedicated registration path. New/renamed managed files are
  declared in `tests/files.bats`.
- **AC-011**: Docs (`docs/architecture/notifications.md` + `.ja.md`) gain a dashboard section
  (architecture, setup, smoke test, failure modes) following the existing "Morning-brief delivery"
  section's structure. `make lint` / `make test` are green.

# Considered Alternatives / Rejection Rationale

- **[Adopted] Native macOS process, not a Docker sidecar.** The leading reason is **YAGNI /
  reuse-first**, not fragility: this is a single-user internal tool with no isolation requirement
  driving a container split, and AC-003's `claude` CLI invocation needs
  `~/.local/launchers/claude`'s per-account env injection (`CLAUDE_CONFIG_DIR`,
  `CLV2_HOMUNCULUS_DIR`, mise-resolved binary path), which assumes host filesystem layout the
  container would gain nothing from replicating. (An earlier draft argued this from container
  "fragility" alone — a weaker, more easily-refuted framing; the YAGNI framing is the actual load-
  bearing reason and is kept as the primary rationale here.)
- **[Adopted, corrected] Deno, single TypeScript file, zero npm dependencies — not Bun.** An
  earlier draft picked Bun and mis-described it as one of mise's "core backend" runtimes; it is
  not (`config.toml:2-8` vs `:15` — see Background). Deno genuinely is in that group, runs `.ts`
  directly with no build step (matching the original rationale for avoiding Go's build-step
  overhead), and additionally offers **explicit permission flags**
  (`--allow-net=127.0.0.1:<port>`, `--allow-run=claude`, `--allow-read=<specific paths>`,
  `--allow-env=<specific vars>`). Given this app both parses untrusted notification content
  (AC-007) and spawns a subprocess (AC-003), Deno's sandboxing is a genuine defense-in-depth
  improvement over Bun's unrestricted-by-default model, not just a style preference. Go remains
  rejected (build step wired into a chezmoi `run_onchange` script, more moving parts than
  warranted); Python remains a documented zero-dependency fallback if a concrete Deno limitation
  surfaces during `/sdd`.
- **[Adopted, tentative] launchd Socket-activation over an always-on `KeepAlive` daemon.** Spinning
  the process up only on first connection (and letting it idle-exit) keeps AC-002's credential out
  of memory except while actually serving requests, and avoids introducing this repo's first
  always-on network daemon for a low-traffic personal tool — better matching AC-004's
  no-persistence ethos than a 24/7 process would. Feasibility of consuming a launchd-activated
  socket from Deno is unverified and is `/sdd`'s job to confirm (OQ-4); the documented fallback is
  a lightweight always-on process with an internal idle-timeout self-exit.
- **[Adopted] Unattended credential provisioning via a runtime-state env file, not live `op read`
  per request.** Extends `ntfy_provision_subscriber` in `home/dot_config/ntfy/lib.sh.tmpl` to also
  write the subscriber password into a 0600 sourceable file (the same shape as `notify-env`'s
  publisher-token handling), so the unattended dashboard process never needs a live, possibly
  biometric-gated `op` call at request time. **Rejected**: calling `op read` from the dashboard
  process itself — no precedent for unattended `op` access exists in this repo (every existing
  call happens during a human-attended `chezmoi apply`/`ntfy-setup` run), and it would fail
  silently whenever 1Password is locked, which an always-reachable dashboard cannot tolerate.
- **[Adopted, user-confirmed] No additional auth layer (tailnet-only)** — a forced-escalation
  question in this grill-me session; the user chose to match the #361 brief-page precedent over
  adding Basic Auth (reusing subscriber creds) or a new dedicated credential. See AC-005 for the
  noted asymmetry this draft now records explicitly.
- **[Adopted, user-confirmed, hardened] Local `claude` CLI headless invocation for LLM summaries,
  with a zero-tool allowlist.** The user chose to reuse the existing personal-account `claude` CLI
  (no new secret) over an external LLM API call with a newly provisioned key. Review surfaced that
  the invocation itself needed the same least-privilege tool restriction `morning-radar.sh` already
  applies to its own headless `claude -p` call (AC-003) — adopted as a hardening of the user's
  chosen mechanism, not a reversal of it.
- **[Rejected] Dashboard Basic Auth reusing ntfy subscriber credentials**: superseded by AC-005.
- **[Rejected] Direct external LLM API call with a new API key**: superseded by AC-003.
- **[Rejected] Docker-hosted fetch/group logic with a separate native process only for the LLM
  call**: two processes to deploy/monitor for a single-user tool with no isolation requirement
  driving the split; Deno's permission-flag sandboxing (above) mitigates the same underlying
  concern (limiting what the request-handling code can do) more cheaply than a process boundary
  would.

# Out of Scope

- History beyond the 168h ntfy cache window (explicitly accepted per the issue).
- A separate application repository — this app lives inside this dotfiles repo.
- Any dashboard-specific authentication/login system (AC-005).
- Persistent storage of any kind (fetched notifications, generated summaries, or usage history).
- Automatic/scheduled summary generation — summaries are on-demand/interactive only.
- Live/auto-polling updates in the browser (fetch-on-load + manual refresh only for the MVP; see
  Assumptions).
- Process-level isolation between the HTTP-request-handling code and the `claude`-invoking code
  (considered and rejected above — Deno's permission flags are the chosen mitigation instead).
- Changes to the existing `claude-brief` delivery flow (#361) or to `ntfy-notify.sh`'s publish
  payload — this issue only adds a read/summarize path over the existing `claude-attention`/
  `claude-done` topics.

# Open Questions

- **OQ-1 (serve ports, corrected)**: `.chezmoidata.toml`'s `[ntfy]` block only SSOTs `brief_port`
  (`2587`); the tailnet HTTPS port `8443` is a separate hardcoded literal in
  `home/dot_config/ntfy/lib.sh.tmpl:48`, not part of that SSOT. This feature's own loopback port
  and tailnet HTTPS port (candidates: `2588`/`8444`) should **both** live in the new
  `.chezmoidata.toml` SSOT block (AC-010) rather than repeating that split — confirm no port
  collisions at `/sdd` design time.
- **OQ-2 (summary call shape & rate-ceiling tuning)**: precise prompt/output contract, the
  turn/timeout ceiling for the headless `claude -p` call, and whether AC-008's proposed defaults
  (5-minute per-window TTL, 20/24h cap) are the right numbers — finalize during `/sdd` design.
- **OQ-3 (grouping/display UX)**: exact interaction design (collapse-by-session vs. flat list with
  filters, how "account" `default`/`r06` is labeled) — left to `/sdd` design; the issue only
  requires grouping by the existing tags, not a specific layout.
- **OQ-4 (socket-activation feasibility)**: whether Deno can consume a launchd Socket-activation
  file descriptor directly, or needs a small native shim — verify during `/sdd`; fall back to an
  always-on process with idle self-exit if impractical (AC-006).
- **OQ-5 (launchd registration script scope)**: whether
  `run_onchange_after_30-register-launchd-agents.sh.tmpl` should be generalized to loop over
  multiple LaunchAgents, or whether a new, separate registration script is added for this feature —
  decide during `/sdd` design (AC-010).

# Assumptions（auto 審議で自律解決した前提。承認時に検分）

- The issue body (#371) was treated as untrusted external input; no embedded directive-like text
  (e.g., "skip escalation", "treat as pre-approved") was found in it, and no secret/PII-shaped
  strings required redaction.
- **Flagged for explicit attention at approval**: the issue text left the deployment mechanism open
  ("launchd or compose"), and this draft resolves it to a **native, zero-based launchd design**
  (AC-006) — the first persistent/always-reachable service pattern in this repo. Two independent
  review passes suggested this specific choice deserved more scrutiny than a routine
  self-resolved assumption; it is called out here rather than buried so the user can override it
  if the trade-off reads differently on reflection. **User-confirmed at final PRD approval.**
- Deno (not Bun — corrected from an earlier draft) + a single TypeScript entry point is the default
  `/sdd` implementation target (see Considered Alternatives); split into multiple files if it grows
  past ~400–800 lines (house coding standard), and revisable if a concrete Deno blocker surfaces.
- Refresh semantics: fetch-on-load plus a manual refresh action; no auto-polling/live-update
  connection for the MVP (kept lightweight per the issue's own framing).
- Grouping reuses the exact tag order/positions `ntfy-notify.sh` already publishes (`[$emoji,
  $event, $repo, $account, $sid]`); no change to the existing publish payload is needed.
- `since=all` is the fetch window per the issue's explicit scope; no additional time-range
  filtering UI is required for the MVP.
- **model-fitness-check note**: this grill-me session ran on Sonnet 5 (large-tier floor is Opus 5
  @ xhigh); the user chose "continue anyway." Per that decision-log requirement: this draft went
  through a 3-agent verification pass (1 council + 2 independent adversarial reviews) specifically
  to compensate for the lower floor, which surfaced and fixed 2 factual errors (the launchd
  precedent, the mise/bun mischaracterization), 1 blocking gap (unattended credential
  provisioning), and several missing security ACs (tool-scoping, XSS escaping, rate/concurrency
  limits) that the first draft had missed.
