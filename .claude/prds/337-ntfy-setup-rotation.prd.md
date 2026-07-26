---
slug: 337-ntfy-setup-rotation
feature: Correct ntfy device auth to username/password and make setup + rotation a two-phase-aware command
created_at: 2026-07-26T19:00:21+09:00
grill_session: 8ee99923-4cfa-42ba-b680-1d51dbb3ffce
status: finalized
---

# Background

Self-hosted ntfy notifications (kryota-dev/dotfiles#337) were introduced in #350 and
refined in #357. After #357 the write-only **publisher** token is written into
`~/.config/ntfy/notify-env` (0600 runtime state); the read-only **subscriber** credential
and the **base-url** still live in the `Dotfiles - ntfy` 1Password item.

Three problems now stand:

1. **The device-auth model is wrong (empirically confirmed).** #350/#357 provision a
   read-only **subscriber token** and tell the user to enter it on each phone. In practice
   the ntfy iOS app cannot authenticate to the self-hosted server with a token — only a
   username/password login works. The ntfy phone docs describe the app's auth as mutually
   exclusive: *"If you have a user configured for a server, you cannot add an `Authorization`
   header for that server, as ntfy sets this header automatically. Similarly, if you have a
   custom `Authorization` header, you cannot add a user for that server."* The first-class
   path is **username/password** (app auto-sets Basic Auth); a token only works via the
   manual **custom `Authorization: Bearer` header** path, which did not work on iOS. The
   subscriber user is currently created with a *throwaway* random password that is discarded,
   so no usable device credential ever exists.
2. **Initial setup is manual and order-fragile.** The user must hand-create the 1Password
   item (looking up the tailnet MagicDNS name for `base-url`) before `chezmoi apply`, or the
   validate gate hard-fails. And at first setup **Tailscale is not yet `up` and Docker
   Desktop is not running**, so server-dependent provisioning cannot complete during the
   first apply — it is inherently **two-phase**.
3. **Key rotation is a manual, error-prone multi-command dance** with no single entry point.

Verified primary-source facts driving the design:

- **Device (mobile app) auth = username/password.** Token auth on the app requires the
  manual custom-`Authorization`-header path (empirically non-working on iOS). Basic Auth
  (`curl -u user:pass`) is universally supported (docs.ntfy.sh/config).
- **Publisher (HTTP API / curl) auth with a Bearer token works** — the iOS-app limitation
  does not apply to the local curl publisher, so the publisher token in notify-env stays.
- **ntfy user CLI:** `ntfy user add <u>`, `ntfy user del <u>`, `ntfy user change-pass <u>`,
  `ntfy user list`; `ntfy access <u> <topic> ro` grants read-only. `NTFY_PASSWORD` env sets
  the password non-interactively for **both** `user add` and `user change-pass` (verified in
  the ntfy CLI source `cmd/user.go`: `change-pass` UsageText shows
  `NTFY_PASSWORD=... ntfy user change-pass USERNAME` and `execUserChangePass` reads
  `os.Getenv("NTFY_PASSWORD")`).
- **ntfy token CLI:** `ntfy token add <u>` is additive (max 60/user, does not invalidate
  others); revoke with `ntfy token remove <u> <token>`; only deleting `user.db` invalidates
  everything at once.
- **ntfy `base-url` is optional for core messaging** (docs.ntfy.sh) — required only for
  attachments and email footer links (both unused here); it does not affect the
  `upstream-base-url` iOS relay and is not mandated by `behind-proxy: true`.
- **chezmoi `output` aborts template execution on a non-zero exit** and runs every apply, so
  deriving base-url via `{{ output "tailscale" … }}` would hard-fail `chezmoi apply` when
  Tailscale is down — incompatible with the fail-open contract.
- **`run_onchange` re-fires only on a rendered-hash change** and records exit-0, so an
  existing machine will not re-provision (or restart a downed container) via `chezmoi apply`
  alone — a re-runnable command is required.

# User Story

As the single operator of this repo, I want a fresh machine's ntfy notifications set up (and
a leaked credential rotated, or a downed container brought back) with **one re-runnable
command** that understands the two-phase reality, and I want my phones to actually
authenticate — logging in with a username and password read from 1Password — without the
tailnet name or a publisher token ever landing in the public repo or in 1Password
unnecessarily.

# Acceptance Criteria

- **AC-001** Device authentication uses a **subscriber username + password**, not a token.
  The `subscriber` ntfy user is a read-only user (read-only ACL on the topics) provisioned
  with a **known, strong, generated password**; the `Dotfiles - ntfy` 1Password item holds
  `subscriber-username` (value `subscriber`) and `subscriber-password` (concealed). The
  subscriber-token concept is removed.
- **AC-002** The publisher path is unchanged in principle: a write-only token is issued and
  written into `~/.config/ntfy/notify-env` (0600 via `umask 077`, heredoc, no `set -x`,
  never echoed/traced), matching the wrapper-sourced format. Publisher auth is API/Bearer,
  unaffected by the mobile-app limitation.
- **AC-003** `base-url` is fully removed from the 1Password path: (a) the `base-url:` line and
  its `onepasswordRead` call in `private_server.yml.tmpl`; (b) the `Dotfiles - ntfy/base-url`
  entry in the `run_once_after_11` ITEMS array; **and (c) the separate base-url
  format-validation stanza in the same script** (the `op read …/base-url` + `https://*.ts.net`
  check) — leaving (c) in place would hard-fail `chezmoi apply` once the field is gone. The
  tailnet MagicDNS URL is never stored; it is derived on demand for human-facing steps only
  (device login server URL, smoke test) via `tailscale status --json | jq -r .Self.DNSName`
  (trailing dot stripped, `https://` prepended). `onepassword-vault-item-count` FACT → **4**.
- **AC-004** A shared bash library is the SSOT for the whole ntfy lifecycle (bring-up +
  provision + rotate). It is a chezmoi template `home/dot_config/ntfy/lib.sh.tmpl` →
  `~/.config/ntfy/lib.sh` (no secrets, mode 644) that bakes in the `.ntfy.*` constants
  (`port`, `topic_attention`, `topic_done`) via lint-safe assignment-only lines. Both
  `run_onchange_after_31-setup-ntfy` and the `ntfy-setup` command source it; provisioning
  logic is not duplicated. The lib's hash is added to `run_onchange_after_31`'s embedded
  re-trigger hashes so a lib change re-fires the apply-time path.
- **AC-005** The library creates the `Dotfiles - ntfy` 1Password item **only when it is
  absent** (`op item get` fails) — a create-time non-destructive guard — via `op item create`
  as a Secure Note holding `subscriber-username=subscriber` and a `subscriber-password`
  bootstrap placeholder. It never touches an existing item's pre-existing fields, is
  idempotent, and warns-and-continues (fail-open) on any op failure.
- **AC-006** Provisioning issues the publisher token → notify-env, and creates (fresh) or
  repairs (existing) the read-only `subscriber` user with a generated password
  (`NTFY_PASSWORD=… ntfy user add` when absent, else `… ntfy user change-pass`), then writes
  the password into the item's `subscriber-password` field via `op item edit`. The subscriber
  half requires `op`; its absence is a warn-and-continue skip that does not fail the publisher
  half. **Secret hygiene:** the generated password reaches ntfy via the `NTFY_PASSWORD` env
  (never argv); the only argv exposure is the local `op item edit field=value` call — the
  same documented, transient trade-off already accepted for tokens (op offers no stdin path
  for single-field edits); no `set -x`, never echoed.
- **AC-007** `ntfy-setup` (deployed `~/.local/bin/ntfy-setup`, on PATH; source
  `home/dot_local/bin/executable_ntfy-setup`) is idempotent and re-runnable and performs the
  **full lib flow**: start the container (`docker compose up -d --remove-orphans`), assert
  `tailscale serve --bg`, then provision/repair both credentials. It fails **clearly** (prints
  the missing prerequisite and exits non-zero) only when a prerequisite it cannot fix itself
  is absent — Docker Desktop daemon not running, or Tailscale not `up`/logged-in. Distinct
  non-zero exit codes distinguish "prerequisite unmet" from "operation error". Non-darwin: the
  binary is `.chezmoiignore`d (mirroring the existing `.config/ntfy` exclusion).
- **AC-008** `ntfy-setup --rotate publisher|subscriber|all` rotates:
  - *publisher* — **read the current token from notify-env first**, issue a new token, write
    notify-env, then `ntfy token remove` the previously-read old token (correct order so the
    genuinely-old, possibly-leaked token is the one revoked).
  - *subscriber* — `NTFY_PASSWORD=<new> ntfy user change-pass subscriber` (preserves the user
    and its ACLs; no del/re-add gap), then update the 1Password `subscriber-password`.
  When real (non-placeholder) credentials already exist and no `--rotate` flag is given, it
  prompts via `/dev/tty` ("credentials already exist — rotate? [y/N]"); if `/dev/tty` cannot
  be opened (non-interactive), it defaults to **N (skip)**, consistent with fail-open.
  Subscriber rotation prints a reminder that every device must re-enter the new password.
- **AC-009** `install/install.sh` stays thin (still just bootstraps chezmoi) and does **not**
  attempt ntfy provisioning at bootstrap; it prints a closing note that ntfy notifications
  need Tailscale `up` + Docker running, after which the user runs `ntfy-setup`.
- **AC-010** `run_onchange_after_31-setup-ntfy` stays fail-open (exit 0) on any missing
  docker/tailscale/op and delegates the whole flow to `lib.sh`; a clean install self-heals,
  and the documented recovery/repair path for existing machines (downed container, throwaway
  subscriber password, credential rotation) is the single `ntfy-setup` command.
- **AC-011** Docs (EN + JA mirrors: `notifications`, `secrets-1password`, `lifecycle-scripts`,
  `secrets-and-isolation`, `ci-and-tests`) are updated: **device subscription uses a
  username/password login (from 1Password), not a token**; setup runbook centered on
  `ntfy-setup`; rotation via `ntfy-setup --rotate`; honest recovery semantics; on-demand
  base-url derivation. The inaccurate "Re-issuing tokens invalidates every existing token"
  sentence is corrected. Stale rationale that ties the CI exclusion of `server.yml` to
  `onepasswordRead`/1Password (its own header comment, `ci-and-tests`, and the relevant
  bats-test comments) is reworded to "no longer op-backed but kept excluded". The
  pre-existing drift in `secrets-1password.md` (its "CI exclusions" list omits
  `private_server.yml.tmpl` and states a stale count) is reconciled to the actual value and
  given a machine-checkable FACT marker.
- **AC-012** FACT markers are synced (`onepassword-vault-item-count` → 4;
  `ci-both-exclusion-count` stays 7) and bats tests updated to pin the new behavior —
  including the two `files.bats` ntfy tests that currently assert the *opposite* ("1password
  ITEMS covers the ntfy item fields" asserting base-url present + `onepasswordRead …/base-url`
  in server.yml; and the "CI excludes the ntfy onepasswordRead template" wording). `make test`
  (lint + all bats) passes.
- **AC-013** Backward compatible / self-migrating: the library never overwrites the existing
  item, so an existing machine's now-unused fields (`base-url`, `credential`,
  `subscriber-token`) are left untouched and harmless; `private_server.yml.tmpl` re-renders
  without base-url and the container restart picks it up; the deployed `notify-env` is
  unchanged. Running `ntfy-setup` on an existing machine **repairs** the subscriber user
  (which had a throwaway password) to a known password via `change-pass` and records
  `subscriber-username` + `subscriber-password` in 1Password. No destructive data migration.
- **AC-014** No tailnet MagicDNS name or client/employer identifier literal appears in the
  repo; commits, PR body, and docs are in English with no AI credit/signature.

# Considered Alternatives / Rejection Rationale

- **Device auth via read-only token (status quo of #350/#357)** — *Rejected / corrected.*
  Empirically the ntfy iOS app cannot log in with a token; per the phone docs the token path
  is the manual custom-`Authorization`-header route, which did not work on iOS. Username/
  password (Basic Auth) is the app's first-class, working path. (AC-001)
- **Subscriber password rotation via `ntfy user del` + `ntfy user add`** — *Rejected* in
  favor of `ntfy user change-pass`: the CLI source confirms `change-pass` honors
  `NTFY_PASSWORD` non-interactively, so it is scriptable **and** preserves the user's ACLs
  with no window where the user does not exist — del+add would need a fragile ACL re-grant
  step and a brief existence gap. (AC-008)
- **Derive base-url via chezmoi `{{ output "tailscale" … }}`** — *Rejected.* `output` aborts
  `chezmoi apply` on a non-zero exit and runs every apply, so a Tailscale-down machine would
  hard-fail apply, violating fail-open. (AC-003)
- **Store/derive base-url at all (1Password or runtime state)** — *Rejected.* base-url is
  optional for our use; dropping it is simpler and removes the only op dependency from
  server.yml. (AC-003)
- **`ntfy-setup` that only *checks* preconditions (does not start the container)** —
  *Rejected.* Because `run_onchange` won't re-fire, a check-only command cannot restart a
  downed container after a reboot, breaking the "one re-runnable command" promise; the command
  runs the full bring-up + provision flow via the shared lib. (AC-007, AC-010)
- **`ntfy-setup` as a pure zsh function / a `~/.config/zsh/*.zsh` glob-source shim** —
  *Rejected.* A bash lib sourced by both the apply script and a real on-PATH executable keeps
  provisioning DRY and works from any shell/hook; and this repo has no zsh glob-source
  mechanism — the real precedent is on-PATH executables under `~/.local/`
  (`home/dot_local/launchers/…`, #358 launcher unification). (AC-004, AC-007)
- **Auto-rotate via credential expiry + a scheduled job** — *Rejected.* Over-engineering for
  a single-user fail-open path; expiry adds a silent-break failure mode. (AC-008)
- **Assumption (auto-resolved, from the user's explicit direction):** the 1Password item is
  auto-created when absent, the entry point is `ntfy-setup`, and it is run interactively after
  Tailscale/Docker are up.

# Out of Scope

- Auto-deleting the now-unused `base-url` / `credential` / `subscriber-token` fields from an
  existing item (optional, manual; harmless if left).
- Auto-configuring subscriber devices (inherently manual username/password re-entry).
- Scheduled/automatic credential expiry or rotation.
- Attachments, email notifications, or Web Push (would require reintroducing base-url).
- Changing the `notify-env` format or the hook wrapper (`~/.claude/ntfy-notify.sh`).
- The publisher API-auth model (stays a Bearer token).
- Removing `private_server.yml.tmpl` from the CI exclude list (it no longer calls
  `onepasswordRead`, but stays excluded to minimize churn; `ci-both-exclusion-count` stays 7).

# Open Questions

- **Q1 (security surface — user-confirmed):** the library runs `op item create` to
  auto-create the `Dotfiles - ntfy` item when absent, and `op item edit` to store the
  subscriber password — automated writes to the 1Password vault, and the stored
  `subscriber-password` is a real login secret (scoped read-only via ACL), a stronger secret
  than the former read-only token. Accepted because it is the only credential the iOS app
  accepts. Confirmed mechanism: create **only when absent** (never overwrite other fields),
  Secure Note, `subscriber-username` + `subscriber-password` placeholder, fail-open on error.
- **Q2:** iOS instant-push remains pending the first real smoke test; dropping base-url does
  not affect the `upstream-base-url` relay per docs, but the smoke test should confirm
  end-to-end iOS delivery once device username/password login is in place. (Verification, not
  a design blocker.)
