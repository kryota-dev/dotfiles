# Notifications: self-hosted ntfy over Tailscale

[日本語版](notifications.ja.md)

Claude Code session events are pushed to a ntfy server self-hosted on this Mac and
subscribed from tailnet devices (kryota-dev/dotfiles#337). This replaces the ECC
`stop:desktop-notify` Stop hook (local osascript, no history) with attributable,
persistent, remotely subscribable notifications. The finalized decision record lives
in `.claude/prds/337-ntfy-tailscale.prd.md`.

**Scope boundary**: this page covers only the Claude Code `Notification`/`Stop`
hook → ntfy path. The repo has three other, independent local-only notification
paths that this system deliberately does not touch: `clv2-session-notify.sh`
(SessionStart, instinct-cluster review nudge), `morning-radar.sh` (launchd,
osascript morning brief), and the `notify` zsh alias (audible chime, also reused
by this system's wrapper as its failure alert sound).

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
phones/tablets on the tailnet (read-only token)
```

- **Server runtime**: the Homebrew `ntfy` formula builds macOS binaries with the
  `noserver` tag (`ntfy serve` does not exist), so the server runs as the official
  `binwiederhier/ntfy` Docker image under Docker Desktop. The image tag is pinned in
  `home/dot_config/ntfy/compose.yaml.tmpl` and tracked by Renovate.
- **Network boundary**: the container binds `127.0.0.1` only; tailnet exposure goes
  exclusively through `tailscale serve --bg` (persists across reboots). `tailscale
  funnel` is prohibited — verify with `tailscale funnel status` (expect nothing
  served) whenever in doubt.
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
| `claude-attention` | permission_prompt, idle_prompt, agent_needs_input | high (4) | sound/vibrate on |
| `claude-done` | agent_completed, Stop | default (3) | silent delivery |
| `claude-test` | manual smoke tests | — | mute after testing |

Attribution (repo, branch, account `default`/`r06`, 8-char session id, event type)
travels in titles and tags, never in topic names. Stop bodies are truncated to 200
chars and scrubbed with the client-identifier pattern from
`~/.config/git/gitleaks-own.toml` (best-effort name scrub — **not** a secret/PII
detector; truncation is the primary defense). Accepted residual risk (#337 PRD): a
prompt-injected assistant message could still surface short secret fragments within
the 200-char window — general secret detection is explicitly out of scope.

## Setup runbook (one-time)

1. **1Password item** — create `Dotfiles - ntfy` in the `kryota.dev` vault with a
   real `base-url` (the serve endpoint, `https://<host>.<tailnet>.ts.net`; look it
   up with `tailscale status --json | jq -r .Self.DNSName`) and bootstrap
   placeholders (`tk_REPLACE…`) in the `credential` / `subscriber-token` fields —
   auto-provisioning only issues tokens while those placeholders are in place. See
   [secrets-1password](../getting-started/secrets-1password.md).
2. **Docker Desktop** — enable *Start Docker Desktop when you sign in* (Settings →
   General); the compose `restart: unless-stopped` policy then revives the server
   after every reboot.
3. **Apply** — `chezmoi apply` renders the config, starts the container
   (`run_onchange_after_31-setup-ntfy`), and asserts the `tailscale serve --bg`
   mapping.
4. **Auth is provisioned automatically by step 3**: the apply script creates the
   `publisher`/`subscriber` users (throwaway passwords), grants the per-topic
   ACLs, issues both tokens while the item still holds bootstrap placeholders,
   stores them in the 1Password item, and prints a reminder to run
   `chezmoi apply` once more so the token lands in `~/.config/ntfy/notify-env`
   (file templates re-render on every apply). The commands below are the
   **manual fallback** only for when provisioning printed a skip warning
   (e.g. `op` CLI unavailable):

   ```bash
   cd ~/.config/ntfy
   docker compose exec ntfy ntfy user add publisher     # publisher, write-only
   docker compose exec ntfy ntfy user add subscriber    # devices, read-only
   for t in claude-attention claude-done claude-test; do
     docker compose exec ntfy ntfy access publisher "$t" write-only
     docker compose exec ntfy ntfy access subscriber "$t" read-only
   done
   docker compose exec ntfy ntfy token add --label chezmoi publisher
   docker compose exec ntfy ntfy token add --label devices subscriber
   ```

   In the fallback case, store the two issued tokens in the item's `credential` /
   `subscriber-token` fields, then re-run `chezmoi apply`.
   Note: `ntfy token add` echoes tokens into terminal scrollback — clear it after
   storing the values.
5. **Subscribe devices** — ntfy app (iOS/Android) → *Use another server* with the
   `base-url` endpoint, the subscriber token from 1Password, and the two topics.

## Smoke test

Tokens never go on the command line (`-H` would expose them in `ps` and shell
history — the same rule the wrapper enforces); feed curl a header config via
process substitution instead:

```bash
BASE="$(op read 'op://kryota.dev/Dotfiles - ntfy/base-url')"
ro() { printf 'header = "Authorization: Bearer %s"\n' "$(op read 'op://kryota.dev/Dotfiles - ntfy/subscriber-token')"; }
wo() { printf 'header = "Authorization: Bearer %s"\n' "$(op read 'op://kryota.dev/Dotfiles - ntfy/credential')"; }
# anonymous publish must be denied (401/403)
curl -s -o /dev/null -w '%{http_code}\n' -d test "$BASE/claude-test"
# read-only token must be denied for publish (403)
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
| Local alert sound, no phone notification | Wrapper publish failed — server down. Check `~/Library/Logs/ntfy-notify.log`, then `docker compose -f ~/.config/ntfy/compose.yaml up -d` |
| No notifications right after login | Docker Desktop still starting; the fail-open window is expected. Enable start-at-login (runbook step 2) |
| `chezmoi apply` prints `[ntfy] Docker Desktop is not running` | Intentional warn-and-skip (deviation from lifecycle convention #6): notifications must not block apply. **Recover with the printed `docker compose up -d` command** — re-running `chezmoi apply` alone does NOT retry (the exit-0 run records the `run_onchange` state; the script only re-fires when the compose/server templates change) |
| Phone can't reach the server | Device off the tailnet, or `tailscale serve` mapping lost — re-run `tailscale serve --bg http://127.0.0.1:2586` (also asserted by every re-triggered apply) |
| Old messages missing | `cache-duration` (168h, `[ntfy]` in `.chezmoidata.toml`) elapsed |
| Notifications on the wrong account badge | `CLAUDE_CONFIG_DIR` unset in that session; account falls back to `default` |

## Recovery: user.db (auth) lost or corrupted

Delete `~/Library/Application Support/ntfy/user.db` if corrupted, then re-run
runbook step 4. **Re-issuing tokens invalidates every existing token**: update the
1Password `credential` field, re-run `chezmoi apply`, and re-enter the subscriber
token on every subscribed device.

## Rollback (one step)

Revert the two settings.json changes together — remove `stop:desktop-notify` from
`env.ECC_DISABLED_HOOKS` **and** delete the `notification:ntfy-notify` /
`stop:ntfy-notify` hook entries — then `chezmoi apply`. Doing only one half either
leaves you notification-less or double-notifies. Server teardown (optional):
`docker compose -f ~/.config/ntfy/compose.yaml down` and `tailscale serve --https=443 off`.
