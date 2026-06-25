# 1Password secrets onboarding

> 🌐 日本語: [secrets-1password.ja.md](secrets-1password.ja.md)

← [Docs index](../README.md)

`chezmoi apply` renders several secret-backed templates directly from 1Password at apply time. This page documents every required vault item, what each is used for, and what breaks when one is missing or renamed.

For the design rationale behind the render-at-apply pattern, see [Secrets & account-isolation design](../explanation/secrets-and-isolation.md).

---

## The hard gate: `run_once_after_11-validate-1password`

On macOS, `chezmoi apply` runs `run_once_after_11-validate-1password.sh.tmpl` immediately after writing all managed files. This script:

1. Verifies `op` (1Password CLI) is installed — exits 1 if absent.
2. Verifies `op account list` succeeds — exits 1 if not authenticated.
3. Calls `op read` for each required item reference — exits 1 on the first missing item.

```
exit 1  →  chezmoi apply fails
         →  subsequent lifecycle scripts do not run
         →  MCP servers, CLV2 observer, mise tools: not set up
```

This is intentional fail-fast behaviour. A missing item is surfaced immediately rather than silently producing a broken environment.

The script is `run_once_`: once it succeeds, chezmoi records its completion and will not re-run it unless the script content changes. If you rename a vault item after a successful apply, add a new item, or move items between vaults, you must force a re-run:

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

**Linux only:** the entire script body is guarded by `{{ if ne .chezmoi.os "darwin" }}` — on Linux it prints "Skipping: not macOS" and exits 0. Linux CI applies without 1Password.

---

## Prerequisites

Before running `chezmoi apply` on macOS:

1. **1Password desktop app** installed and signed in.
2. **CLI integration enabled**: 1Password → Settings → Developer → "Integrate with 1Password CLI".
3. **1Password CLI (`op`)** installed: `brew install --cask 1password-cli`.
4. All four vault items listed below exist in the `kryota.dev` vault.

---

## Required vault items

All items live in the **`kryota.dev`** vault. The exact item titles and field references are load-bearing — renaming either causes `op read` to fail and `chezmoi apply` to exit 1.

### 1. `Dotfiles - AWS Config`

| Attribute | Value |
|-----------|-------|
| Vault | `kryota.dev` |
| Item title | `Dotfiles - AWS Config` |
| Field reference | `notesPlain` |
| op:// URI | `op://kryota.dev/Dotfiles - AWS Config/notesPlain` |
| Rendered to | `~/.aws/config` (`private_dot_aws/config.tmpl`) |
| File mode | `0600` (via `private_` prefix) |

Store the full `~/.aws/config` INI content as the Secure Note body. chezmoi renders it verbatim to `~/.aws/config` at apply time.

### 2. `Dotfiles - Exa API`

| Attribute | Value |
|-----------|-------|
| Vault | `kryota.dev` |
| Item title | `Dotfiles - Exa API` |
| Field reference | `credential` |
| op:// URI | `op://kryota.dev/Dotfiles - Exa API/credential` |
| Rendered to | `~/.config/zsh/claude-secrets.zsh` (`private_claude-secrets.zsh.tmpl`) |
| File mode | `0600` (via `private_` prefix) |

Used by the `exa` user-scope Claude Code MCP server. The rendered file sets `EXA_API_KEY` as a shell variable (not exported); `claude.zsh` re-exports it scoped to the claude subprocess only.

### 3. `Dotfiles - Firecrawl API`

| Attribute | Value |
|-----------|-------|
| Vault | `kryota.dev` |
| Item title | `Dotfiles - Firecrawl API` |
| Field reference | `credential` |
| op:// URI | `op://kryota.dev/Dotfiles - Firecrawl API/credential` |
| Rendered to | `~/.config/zsh/claude-secrets.zsh` (same file as Exa) |
| File mode | `0600` |

Used by the `firecrawl` user-scope Claude Code MCP server. Sets `FIRECRAWL_API_KEY` in the same file.

### 4. `Dotfiles - OpenRouter API`

| Attribute | Value |
|-----------|-------|
| Vault | `kryota.dev` |
| Item title | `Dotfiles - OpenRouter API` |
| Field reference | `credential` |
| op:// URI | `op://kryota.dev/Dotfiles - OpenRouter API/credential` |
| Rendered to | `~/.config/zsh/dmux-secrets.zsh` (`private_dmux-secrets.zsh.tmpl`) |
| File mode | `0600` |

Used by dmux's AI features (smart branch slugs, AI commit messages, pane-state analysis, `aiMerge`). Sets `OPENROUTER_API_KEY`.

---

## What breaks when an item is missing or renamed

| Missing item | Immediate failure | Downstream impact |
|-------------|-------------------|-------------------|
| `Dotfiles - AWS Config` | `chezmoi apply` exits 1 at the validation gate | `~/.aws/config` not written; AWS CLI unusable |
| `Dotfiles - Exa API` | `chezmoi apply` exits 1 at the validation gate | `claude-secrets.zsh` not rendered; exa MCP server starts but fails to authenticate |
| `Dotfiles - Firecrawl API` | `chezmoi apply` exits 1 at the validation gate | `claude-secrets.zsh` not rendered; firecrawl MCP server starts but fails to authenticate |
| `Dotfiles - OpenRouter API` | `chezmoi apply` exits 1 at the validation gate | `dmux-secrets.zsh` not rendered; dmux AI features unavailable |

Because the gate checks all four items before any succeeds, a single missing item blocks the entire after-phase of lifecycle scripts.

---

## How the values are rendered

The templates use chezmoi's `onepasswordRead` function:

```
# private_dot_aws/config.tmpl
{{- onepasswordRead "op://kryota.dev/Dotfiles - AWS Config/notesPlain" }}

# private_claude-secrets.zsh.tmpl
EXA_API_KEY={{ onepasswordRead "op://kryota.dev/Dotfiles - Exa API/credential" | squote }}
FIRECRAWL_API_KEY={{ onepasswordRead "op://kryota.dev/Dotfiles - Firecrawl API/credential" | squote }}

# private_dmux-secrets.zsh.tmpl
OPENROUTER_API_KEY={{ onepasswordRead "op://kryota.dev/Dotfiles - OpenRouter API/credential" | squote }}
```

Key points:
- Values are rendered at `chezmoi apply` time only — never stored in the repo.
- The `private_` chezmoi prefix ensures all rendered files are written with mode `0600`.
- API keys are wrapped in `squote` (single-quote), so a key containing `$` or backticks cannot trigger shell expansion when the file is sourced.
- The rendered `.zsh` files use unset variables (no `export`) so the values do not leak into every child process of the interactive shell. The launcher functions in `claude.zsh` and `dmux.zsh` re-export them scoped to their subprocess.

---

## CI exclusions

`setup-validation.yml` excludes all 1Password-dependent files before running `chezmoi apply` in CI. The following 6 files are moved to `/tmp/chezmoi-excluded/` in **both** jobs (macOS and Ubuntu):

```
home/private_dot_aws/config.tmpl
home/dot_config/zsh/private_claude-secrets.zsh.tmpl
home/dot_config/zsh/private_dmux-secrets.zsh.tmpl
home/run_once_before_00-install-prerequisites.sh.tmpl
home/run_onchange_before_10-brew-bundle.sh.tmpl
home/run_once_after_11-validate-1password.sh.tmpl
```

The **macOS job** additionally excludes `home/run_once_after_90-other-apps.sh.tmpl` (and a stale reference to `home/run_once_after_30-setup-fonts.sh.tmpl` that no longer exists — tolerated by an `if [ -f ]` guard).

CI therefore never touches 1Password and the rendered secret files are never present in CI runners.

---

## Further reading

- [Secrets & account-isolation design](../explanation/secrets-and-isolation.md) — why secrets are sourced-not-exported, the 0600 render pattern, and how this composes with account isolation.
- [Installation & bootstrap](installation.md) — the full apply sequence and when the validation gate runs.
