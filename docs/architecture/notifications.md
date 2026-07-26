# Notifications: self-hosted ntfy over Tailscale

[日本語版](notifications.ja.md)

Claude Code session events are pushed to a ntfy server self-hosted on this Mac and
subscribed from tailnet devices (kryota-dev/dotfiles#337). This replaces the ECC
`stop:desktop-notify` Stop hook (local osascript, no history) with attributable,
persistent, remotely subscribable notifications. The finalized decision record lives
in `.claude/prds/337-ntfy-tailscale.prd.md`.

**Scope boundary**: this page covers the Claude Code `Notification`/`Stop`
hook → ntfy path plus the weekday morning-brief delivery (#361) and the weekly
knowledge-distill delivery (#368). Two other independent local-only
notification paths are deliberately left untouched: `clv2-session-notify.sh`
(SessionStart, instinct-cluster review nudge) and the `notify` zsh alias
(audible chime, also reused by both wrappers as their failure alert sound).
`morning-radar.sh` (launchd, weekday brief) used to notify via local
`osascript`; it now renders the brief to a tailnet HTML page and sends an ntfy
notification that links to it —
see [Morning-brief delivery](#morning-brief-delivery-361) below.
`knowledge-distill-radar.sh` (launchd, weekly) sends a plain-text ntfy
notification with no rendered page —
see [Weekly knowledge-distill delivery](#weekly-knowledge-distill-delivery-368) below.

## Architecture

```
Claude Code hooks (settings.json)
  Notification: permission_prompt | idle_prompt | agent_needs_input | agent_completed
  Stop
        │ stdin JSON (async, fail-open)
        ▼
~/.claude/ntfy-notify.sh ──── enrich (repo/branch/account/session/event)
        │ curl -K, Bearer write-only token, --max-time 3
        ▼
http://127.0.0.1:2586 ── docker: binwiederhier/ntfy (restart: unless-stopped)
        ▲                        └─ state: ~/Library/Application Support/ntfy/
tailscale serve --bg (HTTPS, MagicDNS)          (user.db, cache.db — outside chezmoi)
        ▲
phones/tablets on the tailnet (username/password login)
```

- **Server runtime**: the Homebrew `ntfy` formula builds macOS binaries with the
  `noserver` tag (`ntfy serve` does not exist), so the server runs as the official
  `binwiederhier/ntfy` Docker image under Docker Desktop. The image tag is pinned in
  `home/dot_config/ntfy/compose.yaml.tmpl` and tracked by Renovate.
- **Network boundary**: the container binds `127.0.0.1` only; tailnet exposure goes
  exclusively through `tailscale serve --bg` (persists across reboots). `tailscale
  funnel` is prohibited — verify with `tailscale funnel status` (expect nothing
  served) whenever in doubt.
- **Publisher credential**: the write-only token lives in `~/.config/ntfy/notify-env`
  (0600), runtime state written by the shared `~/.config/ntfy/lib.sh` library
  (sourced by both `run_onchange_after_31-setup-ntfy` and `ntfy-setup`) alongside the
  `user.db`/`cache.db` state — never a chezmoi target, never in 1Password.
- **Subscriber credential**: the read-only `subscriber` ntfy user authenticates with a
  **username + password**, not a token. The ntfy mobile app's own docs describe the
  two auth modes as mutually exclusive — a per-server user login (Basic Auth, set
  automatically by the app) or a custom `Authorization` header (the manual token
  path) — and only the former works in practice on iOS. The username (`subscriber`)
  and a generated password are stored in the `Dotfiles - ntfy` 1Password item.
- **iOS instant push**: `upstream-base-url: https://ntfy.sh` publishes a poll
  request to ntfy.sh for **every incoming message** — regardless of whether any
  iOS device subscribes (topic metadata only, never message bodies) — feeding
  APNs for instant delivery. This is the sole approved metadata egress. The
  device still fetches bodies from this server over the tailnet. If the smoke
  test shows instant push does not work tailnet-only, remove the key to bring
  egress to zero. Record the observed iOS behavior here after the smoke test:
  _observed: (pending first smoke test)_.
- **Topics** (fixed, urgency-based; SSOT in `home/.chezmoidata.toml` `[ntfy]`):

| Topic | Events | Priority | Intended device setting |
|-------|--------|----------|------------------------|
| `claude-attention` | permission_prompt, idle_prompt, agent_needs_input, weekly knowledge-distill radar (#368) | high (4) | sound/vibrate on |
| `claude-done` | agent_completed, Stop | default (3) | silent delivery |
| `claude-brief` | weekday morning brief (morning-radar, #361) | default (3) | mute optional |
| `claude-test` | manual smoke tests | — | mute after testing |

Attribution (repo, branch, account `default`/`r06`, 8-char session id, event type)
travels in titles and tags, never in topic names. Stop bodies are truncated to 200
chars and scrubbed with the client-identifier pattern from
`~/.config/git/gitleaks-own.toml` (best-effort name scrub — **not** a secret/PII
detector; truncation is the primary defense). Accepted residual risk (#337 PRD): a
prompt-injected assistant message could still surface short secret fragments within
the 200-char window — general secret detection is explicitly out of scope.

## Morning-brief delivery (#361)

The weekday `morning-radar.sh` wrapper (launchd `dev.kryota.morning-radar`, #257)
used to announce the brief with a local `osascript` notification that could not
carry the document and never reached mobile. It now renders the brief to a
mobile-readable HTML page and sends an ntfy notification whose **click opens that
page** over the tailnet — **no brief content ever leaves the tailnet**. Two
alternatives were rejected (see the `.claude/prds/361-brief-url-ntfy.prd.md`
decision log): an Artifact/claude.ai page (moves brief content to a third party),
and delivering the brief as an ntfy **message** (the ntfy iOS/Android apps do not
render Markdown — only the web app does — so the brief would show as raw Markdown
on mobile). A browser renders the served HTML page natively.

- **Rendering**: `render_brief_html` writes `~/dotfiles/.kryota-dev/morning-brief/
  <date>.html` with pandoc (`-f markdown-raw_html`, which **escapes any raw HTML**
  in the untrusted brief content — a `<script>` from a GitHub title cannot execute
  on the page — while keeping GFM tables), or a self-contained mobile-readable
  `<pre>` fallback. The headless claude session is **not** granted the `Artifact` tool.
- **Serving**: a loopback **nginx sidecar** (the `brief-page` service in
  `compose.yaml`) serves the brief dir on `ntfy_brief_port`, fronted on the tailnet
  by `tailscale serve --https 8443` — a **port proxy**, because the macOS
  standalone/App Tailscale variant can proxy ports but **cannot serve files or
  directories**. A dedicated HTTPS port keeps it independent of the ntfy root (443).
  Tailnet-only — never `funnel`. `NTFY_BRIEF_BASE_URL` (`https://<magicdns>:8443`)
  is derived at provision time and written to notify-env; the wrapper appends
  `/<date>.html`.
- **Notification**: on success the wrapper publishes to `claude-brief` with the
  `HEADLINE` and the page URL as the ntfy `click`; error paths (claude missing /
  timeout / non-zero exit / brief file missing) publish to `claude-attention` at
  high priority. The publisher token travels via a `curl -K` config file (never
  argv), sourced in a subshell; the env file must be owner-only (0600/0400) or
  delivery fails open (same guard as `ntfy-notify.sh`).
- **Fail-open / degradation**: any publish failure is logged and never aborts the
  run or the same-day stamp (written on brief success, before delivery); if the
  render or the base URL is unavailable, the notification still carries the
  `HEADLINE` (no link).

Existing topics (`claude-attention`/`claude-done`) also now publish with
`markdown: true`, so their bodies render in the ntfy web app.

Smoke test (publish the current brief on demand):

```bash
~/.claude/morning-radar.sh --force   # one billed run; notifies claude-brief with a link
# On a tailnet device, open the notification's link (or):
BASE="https://$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//'):8443"
curl -sI "$BASE/$(date +%F).html" | head -1   # expect: HTTP/… 200
tailscale funnel status                        # expect: nothing served (tailnet-only)
```

## Weekly knowledge-distill delivery (#368)

The `knowledge-distill` skill (`home/dot_agents/skills/knowledge-distill/SKILL.md`)
diagnoses the CLV2 continuous-learning loop weekly and proposes promotions
(evolved skills, curated-skill fixes, memory entries, rules). Cron automation
was explicitly scoped out of the skill pending user approval; approval was
given on 2026-07-26 (weekly cadence), and the `dev.kryota.knowledge-distill`
LaunchAgent (Friday 18:00 local time) now runs it headless, following the
`dev.kryota.morning-radar` pattern (#257) but simpler: no rendered page, no
click URL — just a text summary published to the existing `claude-attention`
topic (no dedicated topic was added).

- **Precheck**: before invoking claude at all, the wrapper counts accumulated
  instincts under `$CLV2_HOMUNCULUS_DIR/instincts/personal/` (same fallback as
  the skill's own Phase 0, `~/.local/share/ecc-homunculus-default`) and
  compares against the skill's own `--min-instincts` default (10). This dry/
  healthy determination is made **independently of claude's own free-text
  response**, so a week with an under-accumulated pipeline is never silently
  reported as a normal week — the notification always says so explicitly
  (`[縮退] instinct N/10 — ...`).
- **Report**: the skill still runs either way (a dry week still gets the
  skill's own Phase 0/1 degraded diagnostic report) and writes to
  `~/dotfiles/.kryota-dev/knowledge-distill/<YYYY-Www>.md`. The wrapper
  verifies the report file is non-empty before stamping the week done — the
  same-week guard, watchdog, and stamp semantics all mirror morning-radar's
  same-day guard.
- **Permissions**: headless `--allowedTools` is confined to
  `Skill(knowledge-distill)`, read-only Bash prefixes matching the skill's own
  Phase 0/2 diagnostics (`ls`/`cat`/`date`/`jq`/`grep`/`find`/`head`/`tail`/
  `wc`/`ghq list`/the `instinct-cli.py evolve` invocation), and
  `Edit(~/dotfiles/.kryota-dev/knowledge-distill/**)`. Proposal application
  remains manual — neither the wrapper nor the skill ever applies its own
  promotions.
- **Notification**: on success, `claude-attention` receives the `HEADLINE` at
  priority 3 (default), prefixed with `[縮退]` and the instinct count when the
  precheck found a dry pipeline. Error paths (claude missing / timeout /
  non-zero exit / report file missing) publish at priority 5, the same
  convention morning-radar uses for errors.

Smoke test (publish the current week's report on demand):

```bash
~/.claude/knowledge-distill-radar.sh --force   # one billed run; notifies claude-attention
```

## Setup runbook (one-time)

`chezmoi apply` must have already deployed the compose file, `~/.config/ntfy/lib.sh`,
and the `ntfy-setup` command before these steps — none of them need to be created by
hand.

1. **Docker Desktop** — enable *Start Docker Desktop when you sign in* (Settings →
   General); the compose `restart: unless-stopped` policy then revives the server
   after every reboot.
2. **Tailscale** — make sure this Mac is `tailscale up` and logged in.
3. **Run `ntfy-setup`** (`~/.local/bin/ntfy-setup`, on PATH) — the single
   re-runnable entry point for the whole lifecycle. It starts the container
   (`docker compose up -d --remove-orphans`), asserts `tailscale serve --bg`, then
   provisions both credentials in one pass:
   - the **publisher** token is written straight into `~/.config/ntfy/notify-env`
     (0600) — the runtime-state file the hook wrapper sources. `op` is not
     required for this half.
   - the **subscriber** user is created (or repaired) with a generated password,
     which is stored in the `Dotfiles - ntfy` 1Password item. This half needs the
     `op` CLI; **the 1Password item is auto-created the first time it is
     absent** (Secure Note, `subscriber-username`/`subscriber-password`) — no
     manual 1Password setup is required. See
     [secrets-1password](../getting-started/secrets-1password.md).

   `chezmoi apply` runs the same provisioning at apply time
   (`run_onchange_after_31-setup-ntfy` sources the same `~/.config/ntfy/lib.sh`),
   but only completes it on a machine where Tailscale is already up and Docker is
   already running. On a **fresh machine neither is true yet**, so the apply-time
   run warns and skips (see Failure modes below) — run `ntfy-setup` once both are
   available to finish setup. This two-phase gap is why `ntfy-setup` exists as a
   separate, re-runnable command rather than relying on `chezmoi apply` alone.

   The commands below are the **manual fallback** only for when `op` is
   unavailable (the subscriber half is then skipped with a warning):

   ```bash
   cd ~/.config/ntfy
   docker compose exec ntfy ntfy user add publisher     # publisher, write-only
   NTFY_PASSWORD='<choose-a-strong-password>' \
     docker compose exec -T -e NTFY_PASSWORD ntfy ntfy user add subscriber   # devices, read-only
   for t in claude-attention claude-done claude-brief claude-test; do
     docker compose exec ntfy ntfy access publisher "$t" write-only
     docker compose exec ntfy ntfy access subscriber "$t" read-only
   done
   docker compose exec ntfy ntfy token add --label chezmoi publisher
   ```

   In the fallback case, write the publisher token into `~/.config/ntfy/notify-env`
   as `NTFY_TOKEN='tk_…'` (keep the file 0600), and store the subscriber
   username/password in the `Dotfiles - ntfy` item's `subscriber-username`/
   `subscriber-password` fields. Note: `ntfy token add` echoes the token into
   terminal scrollback — clear it after storing the value.
4. **Subscribe devices** — ntfy app (iOS/Android) → *Use another server* → the
   server URL (`ntfy-setup` prints it; or derive it yourself with
   `tailscale status --json | jq -r .Self.DNSName`, strip the trailing dot,
   prepend `https://`) → log in with username `subscriber` and the password from
   the `Dotfiles - ntfy` 1Password item → subscribe to the topics
   (`claude-attention`, `claude-done`, and — for the weekday brief —
   `claude-brief`).

## Smoke test

Tokens and passwords never go on the command line (`-H`/`-u` would expose them in
`ps` and shell history — the same rule the wrapper enforces); feed curl a config via
process substitution instead. The server URL is derived on the spot, not stored:

```bash
DNS="$(tailscale status --json | jq -r .Self.DNSName)"
BASE="https://${DNS%.}"
ro() { printf 'user = "subscriber:%s"\n' "$(op read 'op://kryota.dev/Dotfiles - ntfy/subscriber-password')"; }
# The publisher token is not in 1Password — source it from notify-env instead.
wo() { ( . ~/.config/ntfy/notify-env; printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" ); }
# anonymous publish must be denied (401/403)
curl -s -o /dev/null -w '%{http_code}\n' -d test "$BASE/claude-test"
# read-only user/password must be denied for publish (403)
curl -s -o /dev/null -w '%{http_code}\n' -K <(ro) -d test "$BASE/claude-test"
# publisher token succeeds (200); phones should receive it
curl -s -o /dev/null -w '%{http_code}\n' -K <(wo) -d test "$BASE/claude-test"
# history retrieval + filtering examples (verify once, then rely on them)
curl -s -K <(ro) "$BASE/claude-done/json?poll=1&since=24h" | jq 'select(.tags | index("dotfiles"))'
curl -s -K <(ro) "$BASE/claude-attention/json?poll=1&since=all" | jq 'select(.tags | index("permission_prompt"))'
```

Also record whether iOS delivers instantly with the app closed (upstream relay on a
tailnet-only server is unverified upstream — see the PRD).

## Failure modes & troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Local alert sound, no phone notification | Wrapper publish failed — server down. Check `~/Library/Logs/ntfy-notify.log`, then run `ntfy-setup` |
| No notifications right after login | Docker Desktop still starting; the fail-open window is expected. Enable start-at-login (runbook step 1) |
| `chezmoi apply` prints `[ntfy] Docker Desktop is not running` | Intentional warn-and-skip (deviation from lifecycle convention #6): notifications must not block apply. **Recover by running `ntfy-setup` once Docker is running** — re-running `chezmoi apply` alone does NOT retry (the exit-0 run records the `run_onchange` state; the script only re-fires when the compose/server/lib templates change) |
| Phone can't reach the server | Device off the tailnet, or `tailscale serve` mapping lost — run `ntfy-setup` (re-asserts `tailscale serve --bg`; also asserted by every re-triggered apply) |
| Old messages missing | `cache-duration` (168h, `[ntfy]` in `.chezmoidata.toml`) elapsed |
| Notifications on the wrong account badge | `CLAUDE_CONFIG_DIR` unset in that session; account falls back to `default` |

## Recovery: user.db (auth) lost or corrupted, or credential rotation

A **clean install self-heals**: with no prior `run_onchange` state the setup
script runs, finds `~/.config/ntfy/notify-env` absent, and re-provisions the
publisher token and the subscriber user/password into it.

On an **existing machine**, `run_onchange_after_31-setup-ntfy` records exit-0 and
only re-fires when the compose/server/lib templates change, so `chezmoi apply`
alone will not repair a downed container, a lost `user.db`, or rotate a
credential. **`ntfy-setup` is the single recovery command** for all of these:

- **Downed container / lost `tailscale serve` mapping** — `ntfy-setup` restarts
  the container and re-asserts `tailscale serve --bg`.
- **Lost or corrupted `user.db`** — delete it, then run `ntfy-setup`; it
  recreates both users and re-applies the known password/token.
- **Leaked or rotating credential** — `ntfy-setup --rotate publisher|subscriber|all`.
  `ntfy token add` is additive (each user can hold multiple tokens; issuing a new
  one does **not** invalidate existing ones), so publisher rotation reads the
  current token from notify-env first, issues the new one, writes it, then
  revokes the old one (`ntfy token remove`) — only deleting `user.db` invalidates
  every credential at once. Subscriber rotation uses `ntfy user change-pass`
  (preserves the user and its ACLs, no del/re-add gap) and updates the
  `subscriber-password` field in 1Password. **Every subscribed device must
  re-enter the new password after a subscriber rotation.**

## Rollback (one step)

Revert the two settings.json changes together — remove `stop:desktop-notify` from
`env.ECC_DISABLED_HOOKS` **and** delete the `notification:ntfy-notify` /
`stop:ntfy-notify` hook entries — then `chezmoi apply`. Doing only one half either
leaves you notification-less or double-notifies. Server teardown (optional):
`docker compose -f ~/.config/ntfy/compose.yaml down` and `tailscale serve --https=443 off`.
