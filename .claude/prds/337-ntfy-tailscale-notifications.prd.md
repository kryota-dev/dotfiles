---
slug: 337-ntfy-tailscale-notifications
feature: Replace the ECC desktop-notify Stop hook with a self-hosted ntfy notification system reachable over Tailscale
created_at: 2026-07-26T00:48:42+09:00
grill_session: 967f7b3f-2bd5-438e-b284-feeb13a49ec3
status: finalized
---

# PRD: Self-hosted ntfy notifications over Tailscale (Issue #337)

## Background

Today the only desktop-notification path for Claude Code sessions is the ECC
`stop:desktop-notify` hook (`Stop` event only, local osascript/OSC 9, no history, no
attribution beyond the task summary). Issue #337 asks for three things: broader event
coverage, server-side persistent history, and structured attribution (session / repo /
event type) so history can be filtered after the fact.

This PRD was produced by a 4-perspective council deliberation (reliability/operations,
security, notification UX, repo maintainability), adversarially verified by two
independent reviewers, with every disputed fact re-verified against primary sources. The
following **corrections to Issue #337's stated findings** are binding on implementation:

1. **`brew "ntfy"` does NOT provide a server on macOS.** ntfy's official install docs
   state verbatim: *"Only the ntfy CLI is supported on macOS. ntfy server is currently
   not supported, but you can build and run it for development as well."* The
   homebrew-core formula confirms it — `tags = %w[noserver]` on macOS (Linux gets the
   full build). The installed binary (2.26.0) lists only `publish` and `subscribe` under
   "Client commands"; `ntfy serve --help` returns *"No help topic for 'serve'"*. The
   Issue's claim that "the server binary is already provisioned on this Mac" is false.
   **Resolution (user-decided 2026-07-26): run the official `binwiederhier/ntfy` Docker
   image on this Mac via Docker Desktop**, which is already Brewfile-managed
   (`cask "docker-desktop"`, `home/dot_Brewfile:137`).
2. **The `Notification` hook DOES support matchers.** `hooks.md` states *"Matches on
   notification type. Omit the matcher to run hooks for all notification types."* and
   enumerates the 8 values. (One rendering of the docs also carries a contradictory
   "does not support matchers" line; the matcher-supporting statement plus the documented
   per-matcher config example is authoritative.)
3. **iOS instant delivery from a self-hosted server is possible, but only via ntfy.sh.**
   With `upstream-base-url`, the self-hosted server publishes a `poll_request` to the
   upstream containing **only** the message ID (`X-Poll-ID` header) and the SHA256 of the
   topic URL; ntfy.sh relays it through Firebase → APNs, and the device then fetches the
   real message from the self-hosted server. Message bodies never leave the tailnet.
   Without it, docs say delivery "can take hours". The tailnet currently has 2 iOS and 3
   Android peers, so this is load-bearing. **Approved by user 2026-07-26.**
4. **`cache-duration` defaults to `12h`**, not indefinite; `0` disables the cache
   entirely. 12h is too short for "review history later", so it must be raised explicitly.
5. **This repository is PUBLIC.** The tailnet hostname, MagicDNS suffix, `100.x` address
   and topic name must never be committed; they go through 1Password like every other
   secret in this repo.
6. **`tailscale serve` is available and usable on this machine** (`tailscale serve
   status` responds, MagicDNS suffix and per-node `CertDomains` are provisioned), so the
   server can stay bound to loopback and be published to the tailnet over TLS without any
   certificate management or hard-coded address.
7. **What the outgoing hook actually does**, read from its source
   (`~/.agents/skills/ecc/scripts/hooks/desktop-notify.js`, 250 lines): it consumes only
   `last_assistant_message`, reduces it to the *first non-empty line* truncated to 100
   chars, and emits either an OSC 9 escape written to the parent terminal's tty
   (discovered by walking up to 30 levels of `ps -o ppid=,tty=`, because hook
   subprocesses have no controlling terminal) or, failing that, `osascript`. It never
   reads `session_id` or `cwd`, so the attribution Issue #337 asks for is structurally
   impossible in it — this is the concrete reason for replacement rather than extension.
   Three of its behaviours are deliberately carried forward (AC-020, AC-021); its OSC 9
   path is not (alternative 17).

## User Story

As the maintainer of this dotfiles repo, I want every Claude Code event that deserves my
attention — permission prompts, idle/input-needed, agent completion, turn end, and
failures — delivered to my phone and tablet over the tailnet, tagged with the session,
repo, branch and account it came from, and retained server-side long enough that I can
review what happened while I was away, so that I can leave a session running without
either babysitting the terminal or losing the record of what it did.

## Architecture (frozen here as SSOT input)

```
Claude Code hook (Notification / Stop / StopFailure / SessionEnd)
  -> $HOME/.claude/ntfy-notify.sh   (bash, async, degrades to osascript)
  -> JSON POST https://<magicdns-host>/     [Bearer token]
       ^ tailscale serve (tailnet-only HTTPS, :443)
       -> 127.0.0.1:2586
            -> Docker container `ntfy` (binwiederhier/ntfy, restart: unless-stopped)
                 - cache.db  (SQLite, 168h retention)
                 - user.db   (auth, deny-all + per-topic ACL)
                 - upstream-base-url -> https://ntfy.sh   (iOS poll_request relay only)
Subscribers: ntfy iOS/Android apps on the tailnet, `ntfy subscribe` CLI, poll=1/since= API
```

## Acceptance Criteria

### A. Server runtime (Docker on this Mac)

- **AC-001** A chezmoi-managed Compose file (`home/dot_config/ntfy/compose.yaml.tmpl` →
  `~/.config/ntfy/compose.yaml`) runs the official `binwiederhier/ntfy` image with an
  explicit version tag (not `latest`) and `restart: unless-stopped`.
- **AC-002** The published port is bound to loopback only — `127.0.0.1:2586:80`. Binding
  to `0.0.0.0` or to the tailnet address directly is prohibited; a bats test asserts the
  loopback prefix is present.
- **AC-003** Persistent state lives outside the container in a user-owned state dir
  (`~/.local/state/ntfy/`): `cache.db` (message cache) and `user.db` (auth). Attachments
  are not enabled.
- **AC-004** `home/run_onchange_after_31-setup-ntfy.sh.tmpl` reconciles the container and
  the tailnet publication. It follows the `run_onchange_after_30-register-launchd-agents`
  precedent: embedded `sha256sum` of the Compose file **and** the rendered server config
  so it re-runs on change, and an early `CI` guard.
- **AC-005** When the Docker daemon is unreachable, the setup script prints an actionable
  warning and exits 0 rather than hard-failing. Rationale: Docker Desktop's running state
  is user-controlled and outside chezmoi's convergence model; a hard failure would break
  every unrelated `chezmoi apply`. This is a deliberate, documented exception to the
  lifecycle "hard-fail so chezmoi retries" convention, and is called out in the PR.
- **AC-006** The same script applies `tailscale serve` so the tailnet reaches
  `https://<magicdns-host>/` → `http://127.0.0.1:2586`, idempotently (re-running is a
  no-op). If the CLI requires operator privileges on macOS, the script detects the
  failure, prints the exact one-time `sudo tailscale set --operator=$USER` remedy, and
  exits 0 (see Open Questions 1).
- **AC-007** launchd is **not** used for the server. Docker Desktop's own start-at-login
  plus `restart: unless-stopped` is the supported lifecycle; a second supervisor would
  race it. The repo's launchd conventions (`RunAtLoad` absent, `tests/files.bats`) are
  therefore untouched by this PR.

### B. Server configuration and security posture

- **AC-008** `home/dot_config/ntfy/private_server.yml.tmpl` renders to
  `~/.config/ntfy/server.yml` at mode 0600 and is mounted read-only into the container at
  `/etc/ntfy/server.yml`.
- **AC-009** Auth is on: `auth-file` pointing at `user.db`, `auth-default-access:
  deny-all`, and an ACL granting exactly one user read-write on exactly one topic.
  Defense in depth behind the tailnet boundary — the tailnet is the perimeter, ntfy auth
  is the second layer.
- **AC-010** `behind-proxy: true`, because `tailscale serve` terminates TLS and proxies.
- **AC-011** `cache-file` is set (SQLite, survives restarts) and `cache-duration` is
  raised from the 12h default to **`168h` (7 days)**, sized for AC-021's "review later"
  requirement.
- **AC-012** `upstream-base-url: "https://ntfy.sh"` is set (user-approved). The PR
  description states plainly what is disclosed to ntfy.sh: message ID, SHA256 of the
  topic URL, and notification timing — never message bodies, titles, tags, repo names or
  session IDs. `upstream-access-token` is not used.
- **AC-013** No secret, tailnet hostname, MagicDNS suffix, `100.x` address, or topic name
  appears in any committed file. `base-url`, the topic, and the auth token are read from
  a single new 1Password item at apply time via `onepasswordRead`, following the
  `private_gitleaks-own.toml.tmpl` / `private_claude-secrets.zsh.tmpl` precedent. A bats
  test greps the source tree to assert this.
- **AC-014** `home/run_once_after_11-validate-1password.sh.tmpl` gains the new `op://`
  references so a missing item fails loudly at validation time instead of rendering an
  empty config.
- **AC-015** Creating the ntfy user and access token (`ntfy user add` / `ntfy access` /
  `ntfy token add`, executed inside the container) is a documented **one-time manual
  bootstrap**, after which the token is stored by the user in 1Password. It is not
  automated: automating it would require the admin password to round-trip through a
  script, and the operation is genuinely once-per-lifetime.

### C. Hook layer

- **AC-016** A new `home/dot_claude/executable_ntfy-notify.sh` is the single publisher.
  It is shared by both accounts through the absolute `$HOME/.claude/...` path, matching
  the `hooks-fork/` and `clv2-session-notify.sh` precedent, and both accounts see it
  through the existing `dot_claude-r06/symlink_settings.json.tmpl` SSOT symlink.
- **AC-017** Runtime configuration is read from `~/.config/ntfy/notify-env` (0600,
  rendered from 1Password by `home/dot_config/ntfy/private_notify-env.tmpl`) which the
  hook sources directly. It is deliberately **not** routed through
  `private_claude-secrets.zsh.tmpl` / `_claude_with_home`: sourcing it in the hook keeps
  the token out of the Claude Code process environment entirely and makes the hook work
  regardless of how the session was launched.
- **AC-018** Publishing uses ntfy's **JSON publish** (`POST /` with a
  `{topic,title,message,tags,priority}` body) and `Authorization: Bearer`, not the
  `X-Title`/`X-Tags` header form. Rationale: titles and bodies routinely contain Japanese
  text and HTTP header values are ASCII-oriented; a JSON body sidesteps the encoding
  question entirely.
- **AC-019** The hook is wired `async: true` with a short `curl --max-time` bound (≤3s),
  so it can never add perceptible latency to a turn.
- **AC-020** Every failure path (missing env file, unreachable server, non-2xx, timeout,
  Docker Desktop not running) falls back to a local `osascript` desktop notification, so
  behaviour never regresses below what `stop:desktop-notify` does today. The hook exits 0
  in all cases and never blocks a session. The fallback **must reproduce
  `desktop-notify.js`'s AppleScript escaping** — strip backslashes and replace `"` with a
  curly quote before embedding in `display notification "…"` — because AppleScript string
  literals have no backslash-escape syntax, so an unescaped quote in an assistant message
  silently breaks the notification. (`clv2-session-notify.sh` avoids this only because its
  text is a fixed literal; ours is not.) A bats case drives the fallback with a payload
  containing `"` and `\` and asserts a well-formed script and exit 0.
- **AC-021** Every published message carries structured attribution:
  - **title**: `<repo>/<branch> · <account>` — repo and branch derived from the hook's
    `cwd` via `git -C`, account derived from `basename "$CLAUDE_CONFIG_DIR"`
    (`.claude` → `cld`, `.claude-r06` → `r06`);
  - **tags**: machine-filterable facets for the `poll=1&since=` retrieval API —
    event kind, repo, branch, account, and a short session-id prefix, plus one emoji tag
    that drives the icon;
  - **message**: the event's `message` (Notification) or `last_assistant_message`
    (Stop), reduced the way `desktop-notify.js` does it — **take the first non-empty
    line, then truncate to 200 characters** (user-decided 2026-07-26; ECC uses 100).
    Naive head-of-string truncation is explicitly rejected: assistant replies routinely
    open with a Markdown heading or a blank line, which would yield a notification body
    of `##` or nothing. Empty input degrades to a literal, never to an empty body. Full
    transcripts are never published.
  - Non-git `cwd`, detached HEAD, and unset `CLAUDE_CONFIG_DIR` all degrade to a sensible
    literal rather than an empty field or an error.

### D. Event coverage and priority mapping

- **AC-022** A **single topic** carries all events, differentiated by ntfy `priority` and
  tags. Wiring in `home/dot_claude/settings.json`:

  | Hook event | matcher / type | priority | intent |
  |---|---|---|---|
  | `Notification` | `permission_prompt`, `agent_needs_input`, `elicitation_dialog` | 4 (high) | blocked, needs a human now |
  | `Notification` | `idle_prompt` | 4 (high) | waiting on you |
  | `Notification` | `agent_completed` | 3 (default) | agent finished |
  | `Notification` | `auth_success`, `elicitation_complete`, `elicitation_response` | 1 (min) | history only, silent |
  | `Stop` | — | 3 (default) | your turn |
  | `StopFailure` | — | 5 (max) | turn failed |
  | `SessionEnd` | — | 1 (min) | history only, silent |

  This satisfies Issue #337's AC 1 minimum set (permission prompts, idle/input-needed,
  task/agent completion, session stop) with two additions (`StopFailure`, `SessionEnd`).
- **AC-023** The ECC hook is retired by appending `stop:desktop-notify` to
  `env.ECC_DISABLED_HOOKS` in `home/dot_claude/settings.json` — the established
  disable-an-ECC-hook mechanism (#280/#281). The ECC external itself is not modified.

### E. Tests, lint, docs

- **AC-024** `tests/files.bats` gains assertions covering: the new source files exist;
  the Compose port mapping is loopback-bound (AC-002); the rendered server config
  contains `auth-default-access: deny-all`, a non-default `cache-duration`, and
  `behind-proxy: true`; `settings.json` wires the expected hook ids with `async: true`;
  `ECC_DISABLED_HOOKS` contains `stop:desktop-notify`; the setup script embeds both
  content hashes and guards `CI`.
- **AC-025** A behavioural bats test drives `ntfy-notify.sh` with a synthetic hook JSON
  payload and no env file present, asserting it exits 0 and does not attempt a network
  call — the no-op/fallback contract of AC-020.
- **AC-026** A repo-hygiene bats test greps the chezmoi source tree for the tailnet
  hostname pattern, `100.x` addresses, and bearer-token shapes, asserting none are
  committed (AC-013).
- **AC-027** `make lint` passes: shellcheck + shfmt on the new `.sh`, and the templated
  files survive the `{{`-line stripping used by the lint pipeline.
- **AC-028** `docs/architecture/` gains a notification-layer section (English canonical +
  `.ja.md` mirror, updated in the same PR) covering the Docker/tailscale-serve topology,
  the event→priority table, the failure/fallback behaviour, the one-time bootstrap
  procedure, and the phone-app subscription steps. Load-bearing numbers get `<!-- FACT -->`
  markers per the repo's docs-freshness convention where a machine check is meaningful.

## Considered Alternatives / Rejection Rationale

| # | Alternative | Rejected because |
|---|---|---|
| 1 | Run `ntfy serve` natively from the Brewfile binary (Issue #337's stated plan) | Impossible: upstream does not support the macOS server and homebrew-core builds `-tags noserver`. This is the correction that reopened the whole deployment question |
| 2 | Build a macOS server binary from source with the mise-managed Go 1.26.5 | Upstream explicitly scopes a macOS server build to "development"; embedding the web UI drags in a node/pnpm asset build; carrying an unofficial build recipe in dotfiles is a standing maintenance debt with no upstream support contract (**user-considered and declined 2026-07-26**) |
| 3 | Run the server on the Linux homelab instead | Officially supported and always-on, which would also survive Mac sleep — but the user has twice chosen to keep the server on this Mac; deployment target is the user's call (**user-considered and declined 2026-07-26**) |
| 4 | launchd LaunchAgent supervising the container | Docker Desktop already supervises via `restart: unless-stopped`; a second supervisor races it and adds a plist whose safety conventions (`RunAtLoad` absent) were written for a *billed Claude run*, not a daemon |
| 5 | Bind ntfy to the `100.x` tailnet address directly, no `tailscale serve` | Plain HTTP; hard-codes an address that would land in a public repo or force another 1Password round-trip; loses the free per-node TLS cert that the phone apps want |
| 6 | Tailscale **Funnel** instead of Serve | Funnel publishes to the public internet — the opposite of the Issue's "reachable via Tailscale but not exposed beyond the tailnet" constraint |
| 7 | `type: "http"` hooks posting the raw payload straight to ntfy | Claude Code's hook JSON is not ntfy's publish JSON; there is no reshaping step, so title/tags/priority/truncation and the osascript fallback would all be impossible. `command` + a script is the only shape that satisfies AC-018/020/021 |
| 8 | Header-based publish (`X-Title` / `X-Tags` / `X-Priority`) | Header values are ASCII-oriented and this workflow's titles and bodies are frequently Japanese |
| 9 | One topic per event type (8 topics) | 8 subscriptions to manage on every device, 8 ACL entries, and no benefit: ntfy's per-priority notification channels already give per-device sound/DND control, and the retrieval API filters on tags. Priority 1 delivers the "record it but stay silent" case a separate topic was meant to provide |
| 10 | Two topics (`attention` vs `activity`) | Same reasoning as 9 with half the overhead — the closest runner-up. Kept as the documented escape hatch: the topic is a config value, so splitting later is a config change, not a redesign |
| 11 | Publishing the full `last_assistant_message` | Full assistant output — including code fragments and anything sensitive the turn touched — would sit in the SQLite cache for the retention window and on every subscribed device (**user-considered and declined 2026-07-26**) |
| 12 | Event/attribution only, no message body | Safest, but a notification you cannot act on without walking back to the Mac defeats the purpose (**user-considered and declined 2026-07-26**) |
| 13 | No `upstream-base-url` (fully closed, zero third-party contact) | iOS delivery would degrade to "up to hours" per upstream docs, and 2 of the 5 mobile tailnet peers are iOS — the away-from-desk case the Issue exists to solve (**user-considered and declined 2026-07-26**) |
| 14 | Route the token through `private_claude-secrets.zsh.tmpl` + `_claude_with_home` | Would place a publish token in the environment of every Claude Code process and its children; sourcing a 0600 file inside the hook is both tighter and independent of how the session was launched |
| 15 | Relying on Claude Code's built-in `agentPushNotifEnabled` | Already enabled and orthogonal: it delivers to the Claude mobile app with no server-side history, no repo/branch/account attribution, and no tag-filterable retrieval — none of Issue #337's three goals |
| 16 | Keep ECC `stop:desktop-notify` running alongside the new hook | Duplicate notification for every turn end; the Issue asks for a replacement |
| 17 | Porting `desktop-notify.js`'s OSC 9 path (write the escape to the parent tty so clicking focuses the Claude Code tab) into the fallback | `hooks.md` states hooks have had no controlling terminal since v2.1.139 and directs implementations to return `terminalSequence` instead; ECC's `ps`-walk is a workaround around that. The click-to-focus benefit is also moot here — the primary channel is a phone on the tailnet, and the local path is only a degraded fallback. `osascript` alone keeps the fallback small enough to be fully test-covered |

## Out of Scope

- Wiring `SubagentStop` and `TaskCompleted` (high volume / payload shape unverified;
  additive later, once the base channel has proven signal-to-noise).
- Automating phone-app subscription setup (manual, documented in AC-028).
- Automating the one-time ntfy user/token bootstrap (AC-015).
- repo-radar / morning-brief publishing into this channel (#257 follow-up).
- Replacing or retiring the `notify` zsh alias (`aliases.zsh.tmpl`).
- ntfy Web Push, attachments, e-mail publishing, phone calls.
- Moving the server to the Linux homelab (alternative 3).
- Any change to Docker Desktop's own start-at-login setting (a GUI preference, outside
  chezmoi's reach; called out in the docs instead).

## Resolved Decisions (user-approved 2026-07-26)

1. **PRD approved as a whole**, including the security posture: loopback-only bind,
   `tailscale serve` as the sole tailnet ingress, `auth-default-access: deny-all` plus a
   per-topic ACL, all identifiers and the token routed through 1Password, and a 7-day
   server-side message cache holding truncated assistant text.
2. **Server runtime: the official Docker image on this Mac via Docker Desktop** — chosen
   after the native-macOS-server premise was disproved. Native source build (alt. 2) and
   relocation to the Linux homelab (alt. 3) were both presented with their tradeoffs and
   declined.
3. **`upstream-base-url: "https://ntfy.sh"` is adopted** for iOS instant delivery,
   accepting the disclosure of message ID, topic-URL hash, and timing to ntfy.sh.
4. **Notification bodies carry a truncated summary** (not attribution-only, not full
   text).
5. **ECC's hook is retired by flag, not by edit** (AC-023), and the settings.json block
   stays wired with a `description` explaining why it is off — matching the
   `pre:edit-write:gateguard-fact-force` (#280) and `post:bash:command-log-audit`
   precedents.

## Open Questions

1. Whether `tailscale serve` requires `sudo tailscale set --operator=$USER` on this
   macOS build. Resolved at implementation time by attempting it; AC-006 already
   specifies the fail-soft-with-remedy behaviour either way, so this cannot block.
2. ntfy's accepted character set for arbitrary tag strings (a `key:value` shape vs
   `key-value`). Verified against a live publish during implementation; AC-021 specifies
   the facets, not the separator.
3. Default ntfy visitor rate limits vs. burst hook traffic (a fast multi-agent session
   can emit many `Notification` events in a minute). Measured during smoke testing; if
   hit, the fix is a `visitor-request-limit-*` bump in server.yml, not a design change.
4. Behaviour when Docker Desktop is not running: notifications fall back to local
   osascript (AC-020) and **no history is recorded for that period**. Accepted; the
   alternative is a supervisor that force-starts Docker Desktop, which is rejected as
   too invasive.
