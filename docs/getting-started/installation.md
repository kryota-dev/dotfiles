# Installation & bootstrap

> 🌐 日本語: [installation.ja.md](installation.ja.md)

← [Docs index](../README.md)

This doc covers the two entry points for bootstrapping these dotfiles, what each does under the hood, and how to verify idempotency on re-runs.

The root `README.md` shows the happy-path one-liner. This page explains edge cases: missing Xcode CLI tools, non-Debian Linux, network retries, and what happens after chezmoi downloads and applies.

---

## Prerequisites

| Platform | Required before bootstrap |
|----------|--------------------------|
| macOS (Apple Silicon) | `curl`, `bash` (both present in macOS by default) |
| Ubuntu / Debian | `curl`, `bash`, `sudo` |
| Other Linux | Not supported — the script exits with an error |

**1Password** (desktop app with CLI integration enabled, plus CLI `op` in PATH) is needed before `chezmoi apply` can render secret-backed templates. On a truly fresh machine, `install.sh` downloads and applies dotfiles; the 1Password gate (`run_once_after_11`) validates secrets only after that. See [1Password secrets onboarding](secrets-1password.md) for the required vault items.

---

## Entry point A — fresh machine (recommended)

```bash
# Review the script first: https://github.com/kryota-dev/dotfiles/blob/main/install/install.sh
bash <(curl -fsLS https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install/install.sh)
```

`install.sh` is intentionally short. Its logic:

### 1. OS detection

The script branches on `uname`:

```
Darwin   → macOS path
Linux    → Linux path (apt-get required)
anything else → exit 1 (unsupported)
```

### 2. macOS: Xcode CLI tools

```bash
if ! xcode-select -p &>/dev/null; then
  xcode-select --install
  echo "Please re-run this script after installation completes."
  exit 0
fi
```

If the Xcode CLI tools are absent, the script triggers the graphical installer dialog and **exits 0** — a clean exit, not an error. The script does NOT block waiting for the dialog; you must re-run the bootstrap command after the tools finish installing. On machines where tools are already present, this check is a no-op.

### 3. Linux: apt-get prerequisites

```bash
sudo apt-get update
sudo apt-get install -y build-essential curl file git
```

`sudo` and `apt-get` must both be available. If either is absent the script exits 1 immediately. No support for yum, dnf, pacman, or any other package manager.

### 4. chezmoi download — 3x retry with backoff

```bash
for attempt in 1 2 3; do
  if installer=$(curl -fsLS https://get.chezmoi.io) && [ -n "$installer" ]; then
    break
  elif [ "$attempt" -lt 3 ]; then
    sleep $((attempt * 5))   # 5s, then 10s
  else
    exit 1
  fi
done
```

The installer shell script is downloaded from `get.chezmoi.io`. If the download fails (network error, empty body), the script retries up to 3 times with a growing delay: 5 seconds before attempt 2, 10 seconds before attempt 3. On persistent failure it exits 1.

### 5. chezmoi init --apply

```bash
sh -c "$installer" -- init --apply kryota-dev
```

The `get.chezmoi.io` installer places the `chezmoi` binary in `~/.local/bin/` (or wherever the installer decides), then immediately runs:

```
chezmoi init --apply kryota-dev
```

This clones `github.com/kryota-dev/dotfiles` into the chezmoi source directory, reads `.chezmoiroot` (`home/`), and triggers the full apply including lifecycle scripts.

---

## Entry point B — chezmoi already installed

```bash
chezmoi init --apply kryota-dev
```

Use this if chezmoi is already on your PATH (e.g., from a previous install or installed via mise/brew). The outcome is identical to entry point A from step 5 onwards.

---

## What happens after `chezmoi init --apply`

chezmoi applies in a fixed two-phase order. The numbered lifecycle scripts run as part of apply:

```
BEFORE phase (runs before any files are written)
  00-install-prerequisites   run_once    Xcode CLI tools + Homebrew / Linuxbrew
  10-brew-bundle             run_onchange  brew bundle --no-upgrade

chezmoi writes all managed files to $HOME

AFTER phase (runs after files are written)
  11-validate-1password      run_once    1Password gate (macOS only) — exits 1 if any item missing
  12-setup-mise              run_onchange  mise install (3-attempt retry)
  13-setup-mcp               run_onchange  Register Claude Code MCP servers
  14-enable-clv2-observer    run_onchange  Enable CLV2 continuous-learning observer
  16-migrate-claude-binary   run_once    Symlink ~/.local/bin/claude → mise install
  18-setup-agent-browser     run_onchange  Download Chromium for agent-browser
  20-macos-defaults          run_onchange  macOS system preferences (macOS only)
  40-setup-sheldon           run_onchange  sheldon lock
  50-set-login-shell         run_once    chsh -s zsh (Linux only)
  90-other-apps              run_once    Interactive optional app downloads (macOS only)
```

Note: fonts (Moralerspace Neon) are **not** deployed by a lifecycle script. They are fetched directly by the chezmoi engine at apply time via the `["Library/Fonts"]` external declared in `home/.chezmoiexternal.toml` (macOS only). The Nerd Font symbols-only cask is installed via the Brewfile.

See [Lifecycle scripts: ordering & trigger model](../architecture/lifecycle-scripts.md) for the full semantics.

---

## Idempotency and safe re-runs

Running `chezmoi apply -v` (or re-running the bootstrap) is safe:

- `run_once_` scripts track the SHA256 of their rendered content. They do not re-run unless the script body changes.
- `run_onchange_` scripts embed a hash of the file they track (e.g., `dot_Brewfile`, `mise/config.toml`). They re-run only when that hash changes.
- File writes are idempotent by design — chezmoi writes a file only when its content differs.

**Exception:** if `run_once_after_11-validate-1password` already completed on a prior run, chezmoi will not re-run it even if you add a new vault item. To force a re-run, remove its recorded state:

```bash
chezmoi state delete-bucket --bucket=scriptState
```

Then re-run `chezmoi apply`.

---

## Applying changes from the source tree

Once bootstrapped, apply updates with:

```bash
chezmoi apply -v        # apply and show changed files
chezmoi diff            # preview what would change without applying
```

There is intentionally no `make apply` target. See [Local development & the make contract](../contributing/local-dev.md).

---

## Next steps

1. Complete the [1Password secrets onboarding](secrets-1password.md) — required before `chezmoi apply` can render secret-backed templates.
2. Run the [verification checklist](verification.md) to confirm the machine converged.
