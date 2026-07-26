# Secrets & account-isolation design

← [Docs index](../README.md)

🌐 日本語: [secrets-and-isolation.ja.md](secrets-and-isolation.ja.md)

This document explains the cross-cutting design of how secrets and account isolation work together. It covers the _why_ of each mechanism. For the operational how-to (which vault items to create, how to verify the gate), see [secrets-1password.md](../getting-started/secrets-1password.md). For the reference table of per-account env vars and aliases, see [account-isolation.md](../agents/account-isolation.md).

---

## How 1Password secrets reach the filesystem

Secret values live exclusively in the 1Password `kryota.dev` vault. They never appear in any file committed to git. The render path is:

```
1Password vault
    └── op://kryota.dev/<item>/<field>
            │
            │  chezmoi apply
            │  onepasswordRead / op read
            ▼
~/.config/zsh/claude-secrets.zsh    (mode 0600, private_ prefix)
~/.aws/config                        (mode 0600, private_ prefix)
~/.config/git/gitleaks-own.toml     (mode 0600, private_ prefix)
```

`~/.ssh/config` is also a `private_` 0600 file (deployed from `home/private_dot_ssh/config.tmpl`), but it is **not** rendered from 1Password — it uses OS-branching template logic only and contains no `op://` or `onepasswordRead` references.

The source `.tmpl` files contain only `op://` references:

- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - Exa API/credential"` and `onepasswordRead "op://kryota.dev/Dotfiles - Firecrawl API/credential"`
- `home/private_dot_aws/config.tmpl` — a single `onepasswordRead "op://kryota.dev/Dotfiles - AWS Config/notesPlain"` call that renders the entire file from a 1Password Secure Note
- `home/dot_config/git/private_gitleaks-own.toml.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - Redact Patterns/pattern"` injecting the client-identifier regex into the owner-scoped gitleaks config

The `private_` chezmoi prefix is the mechanism that enforces `0600` on the destination file. No additional `chmod` is needed.

The values themselves are single-quoted at render time (the `squote` chezmoi template function): a key containing `$` or a backtick cannot trigger shell expansion or command substitution when the rendered file is sourced by the shell.

### The one write path: ntfy-setup provisioning (#337)

Every reference above is read-only — `op read` / `onepasswordRead` pulling a value out of the vault into a `0600` file. The self-hosted ntfy setup (#337) adds this repo's only 1Password **write** path: the shared library `~/.config/ntfy/lib.sh` calls `op item create` (once, only when the `Dotfiles - ntfy` item is absent) and `op item edit` (to store / rotate the read-only `subscriber-password` device-login credential). It runs from `ntfy-setup` on demand and from `run_onchange_after_31-setup-ntfy` at apply time, never during template render. Two properties bound this new surface: the create is **non-destructive** (guarded by `op item get`, so it never overwrites an existing item's fields), and it sits **off the apply-strict path** — macOS-only, and a failure warns and continues rather than aborting apply (the fail-open contract below). The single-field `op item edit field=value` call is the one accepted transient argv exposure for this write (op has no single-field stdin shortcut). See [Notifications](../architecture/notifications.md).

---

## Two strictness levels: apply-strict vs runtime-graceful

The system draws a hard line between apply-time and runtime behavior:

### Apply-strict: `run_once_after_11-validate-1password.sh.tmpl`

This lifecycle script runs once on macOS and aborts `chezmoi apply` with a non-zero exit if any of the <!-- FACT:onepassword-vault-item-count -->4<!-- /FACT --> required 1Password item references is missing or unreachable. The checked references are:

- `op://kryota.dev/Dotfiles - AWS Config/notesPlain`
- `op://kryota.dev/Dotfiles - Exa API/credential`
- `op://kryota.dev/Dotfiles - Firecrawl API/credential`
- `op://kryota.dev/Dotfiles - Redact Patterns/pattern`

The `Dotfiles - ntfy` item (self-hosted notifications, #337) is deliberately outside this gate: it holds only the read-only `subscriber-username`/`subscriber-password` device-login credential, auto-created and filled by `ntfy-setup` after `chezmoi apply` and after Tailscale/Docker are up — a later phase than this validation script. There is no `base-url` field any more; the tailnet MagicDNS name is never stored in 1Password, only derived on demand. See [Notifications](../architecture/notifications.md).

If `op` is not installed, not authenticated, or an item cannot be read, `chezmoi apply` fails fast. Note that `run_once_after_11` is an AFTER-phase script — home has already been mutated by the time it runs. The actual fail-fast paths are: (1) `onepasswordRead` inside `.tmpl` files aborts apply during template render, before those files are written; and (2) `run_once_after_11` acts as a fail-fast gate before the heavier after-phase provisioning (mise, MCP, CLV2, etc.). The intent is that a partially-provisioned machine with missing secrets is worse than a clean abort at either of those points. The script is macOS-only (`{{ if ne .chezmoi.os "darwin" }}` exits early) because CI runs on Ubuntu without a 1Password installation.

### Runtime-graceful: sourcing with a readability guard

The rendered secrets file is sourced by the `claude` wrapper (`~/.local/launchers/claude`), not by `claude.zsh`, only if it exists, is readable, and the caller has not already decided the key:

```bash
if [ -z "${EXA_API_KEY+x}" ] && [ -r "$HOME/.config/zsh/claude-secrets.zsh" ]; then
  . "$HOME/.config/zsh/claude-secrets.zsh"
fi
```

If `chezmoi apply` has not yet been run on the machine, the secrets file is absent and the guard short-circuits cleanly. The MCP servers launch without a key rather than the wrapper erroring out. Because the wrapper runs on every invocation — interactive shell, hook, launchd, or Claude Code's own Bash tool — this sourcing happens once per process, not once per interactive shell session the way a `claude.zsh` source would; the `${VAR:-}` default on export (see below) extends this graceful degradation to the exec'd binary. The `-z "${EXA_API_KEY+x}"` check (unset vs. empty) is what lets a caller opt out of web search by exporting an *empty* `EXA_API_KEY` before invoking the wrapper — `morning-radar` uses exactly this to skip loading the key entirely.

This two-level design — strict at apply time, graceful at runtime — means a freshly cloned machine that hasn't yet provisioned secrets still gets a functional shell, while a machine that has been provisioned but loses 1Password access doesn't have its next `chezmoi apply` silently succeed with empty secrets.

---

## Sourced-not-exported, then re-exported scoped to the subprocess

This is the most consequential secret-handling decision in the repo.

**The pattern:**

1. `private_claude-secrets.zsh.tmpl` is rendered *without* `export` statements — it is plain `KEY='value'` assignment.
2. The `claude` wrapper sources it inside its own short-lived process (not the interactive shell — see [How this composes with the account-isolation env model](#how-this-composes-with-the-account-isolation-env-model)) and then exports the variables (`EXA_API_KEY`, `FIRECRAWL_API_KEY`) just before `exec`ing the real `claude` binary:

```bash
if [ -z "${EXA_API_KEY+x}" ] && [ -r "$HOME/.config/zsh/claude-secrets.zsh" ]; then
  . "$HOME/.config/zsh/claude-secrets.zsh"
fi
# ...
export EXA_API_KEY="${EXA_API_KEY:-}"
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"
exec "$real" "$@"
```

**Why not just `export` in the sourced file?**

An `export` in a file sourced by an interactive shell would leak the variable into every child process for the lifetime of the shell session — every subshell, every external command, every background job. Even sourced inside the wrapper's own process (not the interactive shell), a bare `export` in the secrets file would be redundant with — and less explicit than — the wrapper's own `export` statement, which is the one place that decides exactly which variables reach the exec'd binary.

Because the wrapper process itself is replaced by `exec` rather than spawning a child, the exported variables are scoped to exactly the process that needs them — the real `claude` binary and whatever it spawns (the MCP server) — and never touch the interactive shell that invoked the wrapper in the first place. Claude Code reads `${EXA_API_KEY}` from its process environment when spawning the MCP server; no other process sees it.

The `${VAR:-}` default (empty string when the variable is unset) ensures the export is safe even when the secrets file was never sourced — the MCP servers receive an empty key rather than the wrapper erroring.

---

## How CI excludes secret files before `chezmoi apply`

CI (`setup-validation.yml`) runs `chezmoi apply` on macOS and Ubuntu without access to 1Password. The approach is to physically move secret-bearing template files out of the source tree into `/tmp/chezmoi-excluded/` before apply runs. Each file is guarded by an `if [ -f ]` check so that a missing entry does not abort the step:

```yaml
- name: Exclude CI-incompatible files
  run: |
    for f in \
      home/private_dot_aws/config.tmpl \
      home/dot_config/zsh/private_claude-secrets.zsh.tmpl \
      home/run_once_before_00-install-prerequisites.sh.tmpl \
      home/run_onchange_before_10-brew-bundle.sh.tmpl \
      home/run_once_after_11-validate-1password.sh.tmpl \
      home/dot_config/git/private_gitleaks-own.toml.tmpl; do
      if [ -f "$f" ]; then mv "$f" /tmp/chezmoi-excluded/; fi
    done
    # macOS job also excludes:
    # home/run_once_after_90-other-apps.sh.tmpl
    # home/run_once_after_30-setup-fonts.sh.tmpl  (stale — script removed; tolerated by if guard)
```

Note: `home/private_dot_ssh/config.tmpl` is **not** excluded — it contains no `op://` or `onepasswordRead` references and applies without a 1Password installation.

With those files absent, chezmoi never tries to call `op read` or `onepasswordRead`, so apply succeeds without a 1Password installation. The deployed home directory in CI is missing the secrets files, but that is acceptable — CI validates structural correctness (files exist, tools resolve, zsh starts clean), not runtime secret availability.

When adding a new 1Password-backed template, both the lifecycle script's `ITEMS` array (`run_once_after_11-validate-1password.sh.tmpl`) and the CI exclusion step must be updated together. The two are the only places that enumerate the complete set of required vault items.

---

## How this composes with the account-isolation env model

Account isolation and secret scoping are two overlapping concerns that share the same mechanism: environment variables exported at the wrapper's process boundary, just before it `exec`s the real binary.

The `claude` wrapper (`~/.local/launchers/claude`) does both at once:

```bash
export CLAUDE_CONFIG_DIR                                              # account isolation
export ECC_AGENT_DATA_HOME="$CLAUDE_CONFIG_DIR"                       # account isolation
export CLV2_HOMUNCULUS_DIR="$HOME/.local/share/ecc-homunculus-${homunculus_slug}"  # account isolation, outside the config dir (#336)
export ECC_MCP_HEALTH_STATE_PATH="$CLAUDE_CONFIG_DIR/mcp-health-cache.json"
export GATEGUARD_STATE_DIR="$CLAUDE_CONFIG_DIR/.gateguard"            # account isolation
export EXA_API_KEY="${EXA_API_KEY:-}"                                 # secret scoping
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"                     # secret scoping
exec "$real" "$@"
```

The same single process boundary that isolates ECC state, CLV2 instincts, and gateguard state by account also confines the API keys to that subprocess. Neither concern requires a separate mechanism.

The `codex` wrapper (`~/.local/launchers/codex`) mirrors the pattern for the Codex account env (`CODEX_HOME`), extending it to the Codex CLI. Before #345, the per-account env set was defined in two places that had to be hand-kept in sync — the zsh helper `_claude_with_home` (`claude.zsh`) and the `cdx-r06` alias (`codex.zsh`) — which was the main maintenance burden of the isolation model. #345 removes that duplication: each wrapper is now the single place that defines its harness's env set, and being a real script on PATH rather than a zsh alias, it is reached identically from `cld`/`cld-r06`/`cdx`/`cdx-r06`, a bare `claude`/`codex`, a hook, launchd, or Claude Code's own Bash tool — so there is no second copy left to drift.

The r06 config directory (`~/.claude-r06`) is entirely symlinks pointing back to `~/.claude` — settings, statusline, agents, commands, skills — so config is one SSOT while state trees diverge. Secrets are not per-account in the config-directory sense: both accounts receive the same API keys (the same 1Password items). Account isolation is about state (sessions, governance, caches), not about using different keys per account.

See [account-isolation.md](../agents/account-isolation.md) for the complete env-var and alias reference table.

---

## Secret values never reach git

Three reinforcing layers prevent secrets from being committed:

1. **Template source files contain only references.** The `.tmpl` files hold `op://kryota.dev/...` strings. The rendered values exist only in `~/.config/zsh/` and other destination paths outside the repo.

2. **`private_` prefix enforces `0600`.** The deployed files are permission-restricted; a `git add` on the wrong path would require explicitly including a file outside the tracked tree.

3. **Global gitleaks pre-commit hook.** `~/.gitconfig` sets `core.hooksPath=~/.config/git/hooks`, wiring a gitleaks scan on every commit in every repo. The global `~/.config/git/gitleaks.toml` explicitly allowlists `op://` references and `onepasswordRead` calls so the template source files themselves pass the scan, while actual key values (which would not match the allowlist pattern) would be caught.

The `--no-verify` bypass exists by design (for emergency commits) but CI's server-side posture is the backstop: any committed secret would be caught in CI's gitleaks run even if the pre-commit hook was bypassed locally.
