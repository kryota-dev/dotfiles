---
slug: 337-ntfy-tailscale
feature: Self-hosted ntfy notification system over Tailscale (replaces ECC desktop-notify)
created_at: 2026-07-26T13:01:43+09:00
grill_session: 8ee99923-4cfa-42ba-b680-1d51dbb3ffce
status: finalized
---

# PRD: Self-hosted ntfy notification system over Tailscale

## Background

Claude Code sessions currently notify only via the ECC `stop:desktop-notify` Stop hook
(osascript, local-only, no history). GitHub Issue #337 requests replacing it with a
notification system backed by a ntfy server self-hosted on the primary Mac, reached via
Tailscale so tailnet devices (phone, tablet) can subscribe. Goals: richer notification
timing (official hook events beyond Stop), persistent reviewable history (ntfy
server-side cache), and structured attribution (session, repo, branch, account, event
type) so history can be filtered.

Primary-source facts constraining the design (verified against docs.ntfy.sh,
code.claude.com/docs/en/hooks.md, tailscale.com/kb, and this machine during
deliberation):

- **The Homebrew `ntfy` formula builds macOS binaries with the `noserver` Go build tag:
  `ntfy serve` does not exist in the Brewfile-provisioned binary** (verified via
  `brew cat ntfy` and `ntfy --help` on this machine). ntfy server on macOS is
  officially unsupported. The Brewfile does, however, already provision
  `cask "docker-desktop"`, and ntfy publishes an official Docker image.
- Message history requires `cache-file` (SQLite); default is in-memory 12h only.
  `auth-file` must be set for auth to exist at all; `auth-default-access: deny-all` is
  the documented recommendation for private instances.
- `tailscale serve --bg` persists across reboots and tailscaled restarts (Tailscale KB
  1242); without `--bg` the mapping dies with the terminal session.
- iOS instant push requires `upstream-base-url` forwarding poll requests through
  ntfy.sh/APNs; the device then fetches the message body from our server directly, so
  tailnet reachability from the phone is required either way. Whether this works on a
  Tailscale-only server is not documented (unverified). Android connects directly and
  works regardless.
- Claude Code `Notification` hook supports matcher-based routing across 8 types
  (`permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`,
  `elicitation_complete`, `elicitation_response`, `agent_needs_input`,
  `agent_completed`); `Stop` provides `last_assistant_message` on stdin; handlers can
  be `command` (payload reshaping possible) or `http` (no reshaping, env-var headers
  only). The documented Notification stdin schema guarantees only the common fields
  (`session_id`, `cwd`, `hook_event_name`, ...) — no message body field is documented
  for Notification events.
- CI handles `onepasswordRead` templates by physically excluding them: the
  `Exclude CI-incompatible files` step in `.github/workflows/setup-validation.yml`
  `mv`s a hardcoded file list out of the source tree before `chezmoi apply`, in both
  the macOS and Ubuntu jobs. There is no `.chezmoiignore`/template-guard precedent.

## User Story

As the owner of this dotfiles setup running long autonomous Claude Code sessions, I want
permission prompts, input-needed events, completions, and session stops pushed to my
tailnet devices with session/repo/event attribution and a persistent, filterable
server-side history, so that I can react promptly while away from the Mac and audit
"what asked for what, when" after the fact.

## Design decisions (council-adjudicated, revised after adversarial review)

- **D1 Runtime**: ntfy server runs as a Docker container using the official ntfy image
  with a **pinned version tag** (Renovate-trackable via the docker-compose manager),
  defined in a chezmoi-managed compose file (`home/dot_config/ntfy/compose.yaml.tmpl`)
  with `restart: unless-stopped`. Docker Desktop is already Brewfile-provisioned; its
  start-at-login setting is a documented runbook prerequisite. No launchd plist. The
  original council pick (launchd + Homebrew binary) was invalidated by the verified
  `noserver` build tag.
- **D2 Reachability**: the container publishes its port as `127.0.0.1:<port>:80`
  (loopback-only at the host). Tailnet exposure exclusively via `tailscale serve --bg`
  (HTTPS on the ts.net MagicDNS name; TLS terminated by tailscaled). `tailscale
  funnel` is prohibited; a funnel-absence check command is documented.
- **D2' iOS instant push**: **enabled** (user-approved at the gate, overriding the
  security-lens default): server config sets `upstream-base-url: https://ntfy.sh`,
  accepting that poll requests (topic metadata, never message bodies) leave the
  tailnet. Actual iOS instant delivery on a Tailscale-only server is unverified
  upstream; the smoke test records the observed behavior in the notifications doc.
  If it proves non-functional, iOS degrades to app-open fetch with no further change.
- **D3 Event scope (v1)**: `Notification` hook matchers `permission_prompt`,
  `idle_prompt`, `agent_needs_input` (attention class) and `agent_completed`
  (completion class), plus the `Stop` event (completion class). `SubagentStop`,
  `TaskCompleted`, `SessionEnd`, `auth_success`, and the three elicitation matchers
  (`elicitation_dialog`, `elicitation_complete`, `elicitation_response`) are deferred
  (noise control; opt-in later). Whether `agent_completed` and `Stop` double-fire for
  the same completion is verified during implementation and matchers tuned if needed.
  Known limitation: Notification-event stdin documents no message body, so
  attention-class notifications carry attribution + event type only (best-effort body
  if the payload turns out to include one).
- **D4 Handler**: a single repo-owned shell wrapper (`command` hook type, async) that
  reads hook stdin JSON, enriches it (repo, branch from `cwd` via git; account from
  `CLAUDE_CONFIG_DIR`; short session id; event type), applies truncation/scrubbing
  (D7'), and publishes JSON to ntfy via curl. The token is read at runtime from a 0600
  chezmoi-deployed env file and passed via **`curl --config` (`-K`) with the
  `Authorization` header written in the curl config file — never `-H` with shell
  expansion (argv-visible), never logged; no `set -x`**. `curl --max-time` short, no
  retries, fail-open. No debounce/rate limiting in v1 (accepted: async hooks +
  max-time bound the blast radius; revisit if high-frequency sessions prove noisy).
- **D5 Topics**: two fixed topics — `claude-attention` (actionable: permission/input
  events, high priority) and `claude-done` (completions, default/low priority) — plus
  `claude-test` for smoke tests. Attribution lives in tags/title (repo, branch,
  account, event, short session id), not in topic names. ACL: publisher user
  write-only on all three; subscriber user read-only.
- **D6 Auth bootstrap**: one-time manual issuance (`ntfy user add`, `ntfy access`,
  `ntfy token add` — executed inside the container via `docker compose exec`)
  following a documented runbook; **both** tokens (publisher write-only, subscriber
  read-only) stored in 1Password (`kryota.dev` vault). chezmoi deploys the publisher
  token into the 0600 env file via `onepasswordRead`;
  `run_once_after_11-validate-1password` ITEMS extended. The subscriber token is
  entered on devices manually from 1Password (runbook). `auth.db` recovery = re-run
  the runbook; the runbook states that re-issuance invalidates existing device tokens
  and lists what must be re-entered where.
- **D7 History retention**: `cache-duration` = **168h (7 days)** (user-confirmed at
  the approval gate), value SSOT in `.chezmoidata.toml`.
- **D7' Content scrubbing**: truncation (default 200 chars) is the **primary** defense
  for `last_assistant_message`-derived bodies. As a secondary, best-effort layer the
  wrapper scrubs client identifiers using the regex embedded in the chezmoi-deployed
  `~/.config/git/gitleaks-own.toml` (extracted with a fixed-format-assuming `sed`;
  extraction failure ⇒ fall back to truncation-only). This layer is explicitly **not**
  a secret/PII detector — the pattern is a client/employer name list — and the PRD
  makes no stronger claim. Strength user-confirmed at the approval gate: truncated
  (200 chars) + client-identifier scrub.
- **D8 Migration/fallback**: `stop:desktop-notify` disabled by appending to
  `env.ECC_DISABLED_HOOKS` in `home/dot_claude/settings.json` (existing SSOT). No dual
  notification channel; on publish failure the wrapper logs and plays a content-free
  local alert sound (silent-drop prevention). Known accepted window: settings.json
  (files phase) activates the new hooks before `run_onchange_after_31` (after phase)
  has started the server on a fresh apply — fail-open covers it. Rollback = remove
  the env entry **and** the new hook entries together (documented as one step) to
  avoid double notification.
- **D9 Placement**: compose file + server config `home/dot_config/ntfy/*.tmpl`;
  secrets env `home/dot_config/ntfy/private_*-env.tmpl` (0600, **added to the CI
  exclude list in `.github/workflows/setup-validation.yml`, both jobs**); assertion
  script `home/run_onchange_after_31-setup-ntfy.sh.tmpl` (embedded-hash, CI guard,
  darwin-only; asserts `docker compose up -d` and the `tailscale serve --bg` mapping;
  warns instead of hard-failing when Docker Desktop is not running — documented
  deviation from the launchctl exit-1 convention so a closed Docker Desktop never
  blocks `chezmoi apply`); wrapper under `home/dot_claude/`; runtime state
  (`auth.db`, `cache.db`) bind-mounted from `~/Library/Application Support/ntfy/`
  (0700/0600), outside the chezmoi target tree. Non-darwin machines: full no-op via
  OS guards and `.chezmoiignore`.

## Acceptance Criteria

Integration-level criteria (verified once via a documented manual smoke-test runbook;
CI cannot start services or reach the network):

- AC-001: Events `permission_prompt`, `idle_prompt`, `agent_needs_input`,
  `agent_completed` (Notification hook) and `Stop` are published to the self-hosted
  ntfy server; each notification carries repo, branch, account (default/r06), short
  session id, and event type in title/tags. Verified by the documented smoke test.
- AC-002: History is persisted via `cache-file` with `cache-duration` set from a single
  SSOT value in `.chezmoidata.toml`; docs include `poll=1&since=` query examples
  filtering by session/repo/type, each verified once manually before documenting.
- AC-003: The container port is published on `127.0.0.1` only; tailnet exposure is via
  `tailscale serve --bg` (HTTPS); `tailscale funnel` is prohibited and a
  funnel-absence verification command is documented.
- AC-014: `upstream-base-url` is set to `https://ntfy.sh` in the server config; the
  smoke test records whether iOS instant delivery works on the tailnet-only setup.
- AC-004: Auth is enabled (`auth-file`, `auth-default-access: deny-all`); publishing
  uses a write-only token, subscribing a read-only token; the smoke-test runbook
  includes anonymous-access denial **and** a read-only-token publish attempt being
  rejected.

Machine-verifiable criteria (bats/CI):

- AC-005: The publisher token comes from a new 1Password item via `onepasswordRead`
  into a 0600 file; validate-1password ITEMS and the `onepassword-vault-item-count`
  FACT marker are updated; the new template is added to the CI exclude list in
  `.github/workflows/setup-validation.yml` (both jobs); gitleaks stays clean.
- AC-006: The wrapper is fail-open: on unreachable server it exits within its curl
  timeout, logs the failure, plays a content-free local alert, and never blocks the
  session. The token never appears in argv/stdout/stderr/logs: the header travels via
  `curl -K`, and bats asserts the wrapper contains no `-H`-with-expansion pattern.
- AC-007: Published bodies never contain raw `last_assistant_message`: truncation
  (default 200 chars) always applies; the client-identifier scrub layer's TOML regex
  extraction is a separable function unit-tested in bats against a fixture TOML,
  with extraction failure falling back to truncation-only.
- AC-008: `stop:desktop-notify` is appended to `env.ECC_DISABLED_HOOKS` in
  `home/dot_claude/settings.json`; the existing bats jq assertion is updated; the new
  Notification/Stop hook entries follow the existing settings.json hook structure
  (id/async/timeout).
- AC-009: The compose file pins an exact ntfy image version (no `latest`), sets
  `restart: unless-stopped`, and publishes only `127.0.0.1:<port>:80`; bats asserts
  all three. The assertion script carries the embedded-hash and CI-guard strings
  (bats-checked, morning-radar assertions untouched); Renovate tracks the image tag.
- AC-010: `auth.db`/`cache.db` live outside the chezmoi target tree with 0700 dir
  permissions; bats asserts no runtime-state paths exist inside the chezmoi source.
- AC-011: CI (macOS + Ubuntu) completes `chezmoi apply` + bats with no service start
  and no network access; non-darwin machines are a full no-op.
- AC-012: `make lint` and `make test` pass; new bats coverage exists for the wrapper
  (mocked stdin/curl: payload construction, enrichment, truncation/scrub fallback,
  fail-open, token hygiene, missing-env-file no-op).
- AC-013: Docs: a notifications architecture page (EN + JA mirror), lifecycle-scripts
  table update, mobile (iOS/Android) subscription runbook incl. token entry from
  1Password, and troubleshooting (Docker Desktop not running, boot/login race,
  meaning of the local fallback alert, cache expiry, funnel check).

## Considered Alternatives / Rejection Rationale

- **launchd + Homebrew `ntfy` binary** (original council pick, D1): invalidated —
  the macOS formula builds with the `noserver` tag; `ntfy serve` does not exist in
  the installed binary (verified on this machine). Kept here as the decision-log
  record of why a unanimous council pick was reversed.
- **Source build via go (mise-managed) + launchd** (rejected, D1): adds a Go
  toolchain dependency (absent today) and per-upgrade build maintenance for a
  configuration that upstream does not support on macOS anyway; Docker Desktop is
  already provisioned and the official image is the supported artifact.
- **Direct bind to the Tailscale 100.x IP** (rejected, D2): races the tailscale0
  interface at boot, plain HTTP end-to-end, per-IP templating churn. `tailscale
  serve --bg` decouples ntfy's lifecycle from network state and provides managed TLS,
  which the ntfy mobile apps prefer.
- **`http` hook handler type** (rejected, D4): cannot reshape the payload (no
  repo/branch/account enrichment, no scrubbing), requires the token as a long-lived
  env var (`allowedEnvVars`), and embeds untestable logic in settings.json.
- **Per-repo/per-session/per-account topics** (rejected, D5): unbounded topic growth
  breaks deny-all ACL management and mobile subscription UX; urgency-based topics map
  directly to per-topic sound/mute on devices, and tags cover attribution.
- **Automated token provisioning script** (rejected, D6): a rare one-time operation;
  automation would route freshly minted secrets through scripts/temp files. Manual
  runbook + 1Password matches the existing audited secrets path; ops' self-healing
  concern is addressed by the recovery runbook and the idempotent assertion script.
- **Full dual-channel fallback (auto-revert to ECC desktop-notify)** (rejected, D8):
  would resurrect the rich local channel this issue retires; a content-free local
  alert covers the "Mac awake but server down" gap without content-leak risk.
- **JS wrapper in `hooks-fork/`** (rejected, D4/D9): `hooks-fork/` precedent is for
  forking ECC-runtime JS hooks; this is a standalone curl/jq one-shot, which the
  repo's shell toolchain (shellcheck/shfmt/bats) already covers end-to-end.
- **Staged migration (run both channels for a while)** (rejected, D8): the switch is
  a single settings.json edit with a documented one-step rollback; parallel channels
  add duplicate notifications for marginal safety.

## Out of Scope

- `tailscale funnel` / any public-internet exposure (explicitly prohibited; the
  user-approved `upstream-base-url` metadata egress in D2' is the sole exception).
- SubagentStop / TaskCompleted / SessionEnd / auth_success / elicitation event
  coverage (future opt-in; elicitation = 3 individual matcher values, no wildcard).
- General secret/PII detection in published bodies (truncation + client-identifier
  scrub only; see D7').
- Automated token rotation; ntfy uptime monitoring beyond the local alert; log
  aggregation dashboards; publish debounce/rate limiting.
- Tailnet ACL / device-sharing review (assumption documented: the tailnet contains
  only the owner's personal devices).
- ntfy servers on other machines / HA; per-repo topic provisioning; custom history UI.

## Open Questions

Resolved at the user approval gate (2026-07-26): iOS instant push **enabled** (D2');
`cache-duration` **168h**; body strength **200-char truncation + client-identifier
scrub** (D7').

Resolved during implementation (verification tasks, not user decisions):

1. `agent_completed` vs `Stop` double-fire behavior for the same completion.
2. Exact Authorization header format for token publish (verify against
   docs.ntfy.sh/publish before wiring the curl config file).
3. Whether Notification-event stdin carries any usable message body beyond the
   documented common fields.
4. Docker Desktop start-at-login + `restart: unless-stopped` behavior across reboot
   (smoke-tested once, documented in the runbook).
5. Actual iOS instant delivery through the upstream relay on the Tailscale-only
   setup (smoke test; outcome recorded in the notifications doc).
