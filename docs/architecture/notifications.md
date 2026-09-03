# Notifications: self-hosted ntfy over Tailscale

[日本語版](notifications.ja.md)

Claude Code session events are pushed to a ntfy server self-hosted on this Mac and
subscribed from tailnet devices (kryota-dev/dotfiles#337). This replaces the ECC
`stop:desktop-notify` Stop hook (local osascript, no history) with attributable,
persistent, remotely subscribable notifications. The finalized decision record lives
in `.claude/prds/337-ntfy-tailscale.prd.md`.

**Scope boundary**: this page covers the Claude Code `Notification`/`Stop`
hook → ntfy path plus the weekday morning-brief delivery (#361), the weekly
knowledge-distill delivery (#368), and the notification-history dashboard
(#371). One other independent local-only notification path is deliberately
left untouched: the `notify` zsh alias (audible chime, also reused by these
wrappers as their failure alert sound). A second one — `clv2-session-notify.sh`
(SessionStart, instinct-cluster review nudge) — was removed outright in #496
(#473 AC-027) rather than migrated: a session-start nudge is not an action
request, so it had no place in the notification contract this page describes.
`morning-radar.sh` (launchd, weekday
brief) used to notify via local `osascript`; it now renders the brief to a
tailnet HTML page and sends an ntfy notification that links to it —
see [Morning-brief delivery](#morning-brief-delivery-361) below.
`knowledge-distill-radar.sh` (launchd, weekly) sends a plain-text ntfy
notification with no rendered page —
see [Weekly knowledge-distill delivery](#weekly-knowledge-distill-delivery-368)
below. A separate, always-on dashboard lets you browse the cached
`claude-attention`/`claude-done` history and generate on-demand LLM summaries —
see [Notification dashboard](#notification-dashboard-371) below.

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
| `claude-attention` | permission_prompt, idle_prompt, agent_needs_input, weekly knowledge-distill radar (#368), weekly macOS defaults drift (macos-defaults-drift-check, #365) | high (4) | sound/vibrate on |
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
  instincts under every project's
  `$CLV2_HOMUNCULUS_DIR/projects/*/instincts/{personal,inherited}/` (same
  fallback as the skill's own Phase 0, `~/.local/share/ecc-homunculus-default`).
  CLV2 v2.1 moved instinct storage from the global tier
  (`instincts/personal/`) to per-project, so counting there instead matters:
  the global tier is now only a *promotion destination* — `instinct-cli.py`'s
  `promote` copies instincts into it rather than moving them, so summing both
  tiers would double-count already-promoted instincts (#491). The count is
  compared against the skill's own `--min-instincts` default (10). This dry/
  healthy determination is made **independently of claude's own free-text
  response**, so a pipeline that has not accumulated enough material is never
  silently reported as a normal week — the notification always says so
  explicitly (`[縮退] instinct N/10 — ...`).
  Note what this threshold does and does not measure: it is a **cumulative**
  count over all projects and all time, i.e. a "is there enough material to
  cluster at all" gate for the skill's Phase 2, not a weekly-delta signal.
  Before #491 it read a tier that is always empty, so it fired every week and
  the distillation phase never ran; after #491 the real store is far above 10,
  so in practice it will stop firing. "Is the loop still running *this* week"
  is answered by the skill's other Phase 0 diagnostics — observations
  freshness, archive progress, timeout / turn-exhaustion traces — not by this
  threshold.
- **Report**: the skill still runs either way (a dry week still gets the
  skill's own Phase 0/1 degraded diagnostic report) and writes to
  `~/dotfiles/.kryota-dev/knowledge-distill/<YYYY-Www>.md`. The wrapper
  verifies the report file is non-empty before stamping the week done — the
  same-week guard, watchdog, and stamp semantics all mirror morning-radar's
  same-day guard.
- **Permissions**: headless `--allowedTools` is confined to
  `Skill(knowledge-distill)`, read-only Bash prefixes matching the skill's own
  Phase 0/2 diagnostics (`ls`/`cat`/`date`/`jq`/`grep`/`find`/`head`/`tail`/
  `wc`/`ghq list`/the `instinct-cli.py evolve` invocation), the Phase 0.5
  `memory-revalidate.py` invocation (#631 — granted by full path, not by
  widening the entry to a bare `python3` prefix, and read-only in the same
  sense as the diagnostics: it never writes into the auto memory directory),
  and `Edit(~/dotfiles/.kryota-dev/knowledge-distill/**)`. A command absent
  from this list is denied silently, so a phase written into SKILL.md but
  missing here would be indistinguishable from a phase that does not exist
  (the failure #491 was). Proposal application remains manual — neither the
  wrapper nor the skill ever applies its own promotions, and that now includes
  the memory findings Phase 0.5 reports (see
  [auto memory revalidation](../agents/claude-code.md#auto-memory-revalidation)).

  What the allowlist does and does not constrain, per the
  [permission rules](https://code.claude.com/docs/en/permissions#compound-commands):
  a compound command cannot slip past a prefix rule, because "Claude Code is
  aware of shell operators … The recognized command separators are `&&`, `||`,
  `;`, `|`, `|&`, `&`, and newlines. A rule must match each subcommand
  independently" (an unparseable compound, such as a trailing `&&`, isn't split
  and isn't approved — it fails closed). What a rule does *not* constrain is
  everything after the matched prefix: `Bash(<path>:*)` grants "this program,
  any arguments". `memory-revalidate.py` takes `--memory-dir` / `--repo` /
  `--rules` / `--config-dir`, all of which accept arbitrary paths, so the
  headless prompt pins the argument list and says not to add them — a prompt
  injection carried in an instinct or a memory could otherwise widen what the
  weekly run reads without the allowlist objecting.
  `tests/knowledge_distill_radar.bats` asserts the prompt still says so.
- **Budget** (#643): `--max-turns` is
  <!-- FACT:knowledge-distill-max-turns -->80<!-- /FACT --> and the watchdog
  fires at <!-- FACT:knowledge-distill-timeout-seconds -->1200<!-- /FACT -->
  seconds. Both are sized from measurement rather than raised until the symptom
  stopped. Across the three failed runs whose session transcripts survived,
  throughput was 10.3–10.8 seconds per tool call; the two runs that died on
  `--max-turns` reached turn 50 at 523 s and 539 s with the work unfinished; the
  one run that batched its calls (1.93 per turn) got 58 calls done in 597 s and
  was killed by the watchdog instead; and the single success took 589 s of the
  600 s budget — 1.8 % of headroom. So 50 turns and 600 seconds were the same
  wall: 50 serialized turns consume essentially the whole 600 s, which meant the
  watchdog documented as a guard *on top of* `--max-turns` had quietly become
  the primary limit, and which one fired was decided by whether the agent
  happened to batch its calls that week. 80 turns at ~10.5 s is roughly 840 s,
  inside 1200 s, so `--max-turns` is the cost ceiling again. The other half of
  the fix is on the prompt: it still forbids joining commands with `;` or `&&`
  (the allowlist is prefix-matched per command) but now says explicitly that
  this is a rule about the shell, not a limit of one Bash call per turn.
- **Run history** (#643): every attempt appends one JSON object to
  `${XDG_STATE_HOME:-~/.local/state}/knowledge-distill-radar/runs.jsonl`
  (directory 0700, file 0600, trimmed to the most recent 200 records) carrying
  the ISO week, a machine-readable `status`, the exit code, the attempt number,
  the elapsed seconds, and — when an envelope survives — `num_turns` and the
  run's own `subtype`. `num_turns` is the number that had to be excavated from
  session transcripts before the limits above could be sized at all; it is in
  the record from now on. `status` is one of `ok`, `max_turns`, `timeout`,
  `api_error`, `exec_error`, `no_report`, `no_claude`, and `decided_by` names
  which signal chose it. The primary signals are the exit code and claude's
  stderr, both observed directly in the production log across all four failures;
  `--output-format json` is read for enrichment only, because its envelope
  carries no `type` field and a watchdog kill leaves no envelope at all (#526).
  Naming the deciding signal follows the convention #526 settled on for the same
  ambiguity in frontier-harness — an envelope and an exit code do not always
  agree, and collapsing them produces a reason that contradicts its own status.
  The library is `home/dot_claude/job-runlog.sh` → `~/.claude/job-runlog.sh`,
  sourced rather than executed (0644, no `executable_` prefix) and deliberately
  job-agnostic: callers pass their own history file, so morning-radar,
  macos-defaults-drift and #644's staleness reading can reuse it without it
  learning any labels. Only knowledge-distill is wired to it today.
- **Retry** (#643): a failure classified `api_error` is retried once after 60
  seconds; nothing else is. Of the four consecutive failures exactly one was
  transient — 08-07 died on `ENOTFOUND` at 18:12:57, a coalesced fire on wake,
  before the network had come up. Re-running a run that exhausted its budget
  would spend the week's budget twice to die in the same place. Both attempts
  are recorded.
- **Notification**: on success, `claude-attention` receives the `HEADLINE` at
  priority 3 (default), prefixed with `[縮退]` and the instinct count when the
  precheck found a dry pipeline, and with `[復旧]` when the previous recorded
  run had failed. Error paths (claude missing / timeout / non-zero exit / report
  file missing) publish at priority 5, the same convention morning-radar uses
  for errors. Two things are added to the line that a single notification cannot
  be read without (#643): when the same `status` has now failed in two or more
  distinct weeks it is prefixed `[N週連続/status]`, and when the last *success*
  is more than 14 days old the age is appended. The streak is counted in
  scheduled slots rather than records, so a retry writing two records for one
  week is not reported as two weeks. Both individual failures did notify before
  #643 — what nobody could see was that four weeks in a row had gone the same
  way. When the run log itself is unavailable the notification says so rather
  than passing for a normal week; a record that is quietly absent is
  indistinguishable from a week that never ran, the same class of failure as
  #491.

  What this does *not* detect: the staleness reading is only taken while the job
  is running, so it answers "has not succeeded lately", not "has not fired at
  all". A LaunchAgent that never fires needs an outside poller, which #506's
  scheduling work is where that belongs.

Smoke test (publish the current week's report on demand):

```bash
~/.claude/knowledge-distill-radar.sh --force   # one billed run; notifies claude-attention
```

## Notification dashboard (#371)

A lightweight, always-on dashboard lets you browse the cached
`claude-attention`/`claude-done` history from a phone — grouped by the existing
`sid`/`repo`/`account` tags — and generate on-demand LLM summaries. No history
beyond the existing 168h cache, and no new persistence of any kind.

- **Runtime**: a native Deno process
  (`home/dot_config/ntfy-dashboard/server.ts`), **not** containerized. Its
  on-demand summary path shells out to the personal-account `claude` CLI
  (`~/.local/launchers/claude`), which depends on host-only state (mise-managed
  binary resolution, `~/.claude`) that a container would need to duplicate for
  no isolation benefit (unlike the ntfy/brief-page containers, which exist for
  unrelated reasons — see above). Deployed as this repo's first **persistent**
  LaunchAgent (`dev.kryota.ntfy-dashboard`, `RunAtLoad` + `KeepAlive`) — unlike
  `morning-radar`'s one-shot weekday schedule, the dashboard must stay
  reachable at any time. launchd Socket-activation was evaluated and rejected:
  as of writing, none of Deno/Node.js/Bun support consuming a
  `launch_activate_socket` file descriptor without custom native glue
  (confirmed against Apple's XPC documentation and open upstream issues in
  `srvx`/Caddy).
- **Credentials**: the ntfy **subscriber** Basic Auth pair (username/password,
  not the publisher's Bearer token) is provisioned into a 0600 runtime-state
  file (`~/.config/ntfy-dashboard/dashboard-env`, the same shape as
  `notify-env`) by `ntfy_provision_subscriber`/`ntfy_rotate_subscriber` in
  `~/.config/ntfy/lib.sh`. The dashboard process never calls `op read` itself —
  every other `op` call in this system happens during a human-attended
  `chezmoi apply`/`ntfy-setup` run, and an always-on unattended process has no
  tty to unlock 1Password with anyway.
- **Serving**: `Deno.serve` on a loopback port (`[ntfy_dashboard].port` in
  `.chezmoidata.toml`), fronted on the tailnet by `tailscale serve --https` on
  a dedicated port (`[ntfy_dashboard].serve_https`) — the same port-proxy
  pattern as the brief page, on its own port so neither clobbers the ntfy root
  (443) or the brief front (8443). Tailnet-only; never `funnel`. **No
  additional authentication layer** — the tailnet boundary is the sole access
  control, the same posture as the brief page, with one accepted asymmetry:
  the brief page is a side-effect-free static file server, while this
  dashboard's summary action has a billable side effect, mitigated by the rate
  limits below.
- **Summaries**: on demand only (no automatic/scheduled generation). The
  dashboard invokes `claude -p` with an **empty tool allowlist** — pure text
  summarization, no `Bash`/`Read`/`Edit`/etc. — because the summarized
  notification bodies can carry `last_assistant_message` content from other
  sessions, the same residual prompt-injection surface noted above. Calls are
  cached per fetched-window hash (`summary_ttl_seconds`, default 5 minutes) and
  capped per rolling day (`summary_daily_cap`, default 20), with concurrent
  requests for the same window coalesced into a single in-flight call so
  multi-device access cannot trigger duplicate billed calls. A timeout
  (`claude_timeout_seconds`) bounds each call.
- **XSS**: all notification title/body/tag values reach the browser only as
  JSON; the client renders them via DOM `textContent` (never `innerHTML`), so
  no server-side HTML-escaping step can be forgotten.
- **Decision record**: `.claude/prds/371-ntfy-notification-dashboard.prd.md`
  has the full considered-alternatives log (why Deno over Bun, why native over
  Docker, why an always-on process over Socket-activation).

Smoke test:

```bash
BASE="https://$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//'):8444"
curl -sI "$BASE/" | head -1   # expect: HTTP/… 200
tailscale funnel status        # expect: nothing served (tailnet-only)
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
     [secrets-1password](../getting-started/secrets-1password.md). The same
     password is also written to the dashboard's `dashboard-env` runtime-state
     file (#371), so the always-on dashboard process never needs a live `op`
     call of its own.

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
| Dashboard unreachable from the tailnet | `ntfy_assert_dashboard_serve` failed (tailscaled down) — run `ntfy-setup` |
| Dashboard summaries always error | `dashboard-env` stale/missing (e.g. after a subscriber rotation that predates #371) — run `ntfy-setup` to reprovision |

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
