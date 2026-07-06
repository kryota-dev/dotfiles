# Developer toolchain: mise, Brewfile & git

🌐 日本語: [dev-tooling.ja.md](dev-tooling.ja.md)

← [Docs index](../README.md)

This document covers the non-AI developer tooling layer: mise as the version SSOT for runtimes and CLI tools, the Brewfile + `.brewfile-linux-exclude` pattern, git configuration with 1Password SSH commit signing, the global gitleaks pre-commit hook, and the Ghostty terminal setup.

---

## mise: version SSOT

`home/dot_config/mise/config.toml` is deployed verbatim to `~/.config/mise/config.toml` (it is not a `.tmpl` — no machine-specific rendering is needed). It is the single source of truth for all pinned tool versions.

### `[tools]` block

The `[tools]` block in `home/dot_config/mise/config.toml` is the SSOT for every pinned runtime and CLI version. Renovate bumps each pin automatically, and any change re-triggers `run_onchange_after_12-setup-mise` on the next `chezmoi apply`. **Consult that file for the authoritative, current version list.**

The block contains three categories of entries (examples; see `config.toml` for the authoritative, current list):

- **Runtime languages** pinned to exact versions (e.g. `node`, `python`, `ruby`, `go`, `deno`, `rust`).
- **Registry-resolvable CLI tools** using a bare key (e.g. `gh`, `gitleaks`, `shellcheck`, `starship`, `tmux`).
- **npm-backed CLIs** without a mise registry entry, using the `"npm:<pkg>"` key form (e.g. `"npm:agent-browser"`, `"npm:happy"`).

### `[settings]` block

Two non-default settings prevent known fresh-install failures:

```toml
[settings]
python.precompiled_flavor = "install_only"
ruby.compile = false
```

**`python.precompiled_flavor = "install_only"`**: Without this, mise selects the `freethreaded+install_only_stripped` flavor, which omits the `lib/` directory and fails with `"Python installation is missing a 'lib' directory"` on first install (issues #121, #104). The `install_only` flavor ships a complete `lib/`.

**`ruby.compile = false`**: Prevents a source-build deadlock. When ruby is compiled from source, `ruby-build`'s configure probe re-enters the mise shim for the in-progress version and blocks on the install lock (issue #122). Using a precompiled binary avoids this entirely.

### Adding a tool

- **Prefer mise**: Add the tool to `[tools]` with an exact version. Registry-resolvable tools use a bare key; npm-only tools use `"npm:<pkg>"`.
- **Use Brewfile for GUI apps and casks**: Apps that ship as macOS `.app` bundles or App Store apps belong in `dot_Brewfile`, not mise.
- **Bump the pin deliberately**: mise does not use version ranges. Bumping `home/dot_config/mise/config.toml` re-triggers `run_onchange_after_12-setup-mise.sh.tmpl` on the next `chezmoi apply`, which runs `mise install` again.

---

## Brewfile and `.brewfile-linux-exclude`

### `dot_Brewfile`

`home/dot_Brewfile` is a standard Homebrew bundle file: taps, formula, cask, mas (App Store), vscode extension, and go entries. It is **plain text — not a `.tmpl` file**. This is intentional: `make dump-brewfile` runs `brew bundle dump`, which rewrites the file in place. A template would be clobbered or would prevent regeneration.

Constraints:
- Do not add `brew "chezmoi"` to the Brewfile. chezmoi itself is installed via the standalone `curl get.chezmoi.io` bootstrap (PR #22); adding it to the Brewfile would conflict with the mise-managed version.
- Brewfile changes are auto-applied on the next `chezmoi apply` via the embedded sha256 in `run_onchange_before_10-brew-bundle.sh.tmpl`.

### `.brewfile-linux-exclude`

`/.brewfile-linux-exclude` (at the **repo root**, outside the chezmoi source dir `home/`) is a list of `grep -E` patterns. Any Brewfile line matching one of these patterns is excluded on Linux.

This file is the SSOT consumed by two independent consumers:

1. **Lifecycle script** (`run_onchange_before_10-brew-bundle.sh.tmpl`) on Linux:
   ```bash
   grep -E '^(tap |brew )' "$BREWFILE" | grep -v -E -f "$EXCLUDE" > "$TMPFILE"
   brew bundle --no-upgrade --file="$TMPFILE"
   ```
   The script reaches `.brewfile-linux-exclude` via `{{ .chezmoi.sourceDir }}/../.brewfile-linux-exclude` — one level above the `home/` source dir.

2. **CI** (`.github/workflows/setup-validation.yml`) duplicates the identical `grep` pipeline into a temp file before running `brew bundle` on the Ubuntu runner.

When adding a Linux-incompatible Brewfile entry, add a matching pattern to `.brewfile-linux-exclude` rather than branching logic in both places.

---

## git configuration

`home/dot_gitconfig.tmpl` is rendered to `~/.gitconfig`. Identity fields come from chezmoi data (`.chezmoidata.toml`):

```ini
[user]
    name = {{ .name }}
    email = {{ .email }}
    signingkey = {{ .signingkey }}
```

Other notable settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `core.excludesfile` | `~/.gitignore_global` | Global gitignore (macOS/Linux/node patterns + custom) |
| `core.editor` | `nvim` | Default editor |
| `core.hooksPath` | `~/.config/git/hooks` | Global pre-commit hook (see below) |
| `commit.gpgsign` | `true` | Sign every commit |
| `gpg.format` | `ssh` | Use SSH key for signing |
| `init.defaultBranch` | `main` | |
| `extensions.worktreeConfig` | `true` | Per-worktree gitconfig support |
| `ghq.root` | `~/ghq` | ghq clone root |
| `ghq.user` | `{{ .ghq_user }}` | Default GitHub username for `ghq get` |

### 1Password SSH commit signing

The `[gpg "ssh"]` block is **conditionally rendered** by probing for `op-ssh-sign` at apply time:

```
{{- if stat "/Applications/1Password.app/Contents/MacOS/op-ssh-sign" }}
[gpg "ssh"]
    program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
{{- else if stat "/opt/1Password/op-ssh-sign" }}
[gpg "ssh"]
    program = "/opt/1Password/op-ssh-sign"
{{- end }}
```

If neither path exists at apply time, the block is omitted entirely. `commit.gpgsign = true` remains set, so commits will fail to sign on a machine without 1Password installed. The solution is to install 1Password and re-run `chezmoi apply`.

The signing key (`user.signingkey`) is the SSH public key fingerprint stored in `.chezmoidata.toml`. 1Password's `op-ssh-sign` binary intercepts the signing call and retrieves the private key from the 1Password agent.

---

## Global gitleaks pre-commit hook

### Wiring

`dot_gitconfig.tmpl` sets `core.hooksPath = ~/.config/git/hooks`. This replaces `.git/hooks` for every repository on the machine, so the global pre-commit runs for **every commit** regardless of harness (human, Claude Code, or Codex).

`home/dot_config/git/hooks/executable_pre-commit` is deployed as `~/.config/git/hooks/pre-commit` with mode 0755 (`executable_` prefix).

### What the hook does

1. **Resolves gitleaks**: prefers a PATH binary (mise shims), falls back to `mise exec -- gitleaks`, and fails open (skips the scan with a warning) if gitleaks is absent — so commits are never bricked before `mise install` has run.

2. **Selects config**: prefers a repo-local `.gitleaks.toml` (auto-discovered by gitleaks); falls back to `~/.config/git/gitleaks.toml` (the global config). Passing `--config` unconditionally would shadow per-repo allowlists.

3. **Runs the scan**: `gitleaks git --staged --redact --no-banner`. Exits 1 and prints remediation instructions on a finding.

4. **Chains the repo's own pre-commit**: resolves it via `git rev-parse --path-format=absolute --git-common-dir`, then appends `/hooks/pre-commit`. Uses `--git-common-dir` rather than `--git-path hooks/pre-commit` — the latter respects `core.hooksPath` and would resolve back to this global hook, causing an infinite exec loop. An `-ef` self-reference guard provides a second line of defense.

### Global gitleaks config

`home/dot_config/git/private_gitleaks.toml.tmpl` extends the default ruleset and adds two allowlist regexes:

```toml
[extend]
useDefault = true

[allowlist]
regexTarget = "line"
regexes = [
  '''op://\S.*''',
  '''onepasswordRead''',
]
```

`op://` URIs are 1Password references, not secrets. `onepasswordRead` is the chezmoi template function that reads them. Neither embeds a secret value in the source tree.

**No `paths` allowlist is defined.** Because this config is loaded globally via `core.hooksPath`, a `paths` entry would blind the scanner to that path in _every_ repository. Files that should never reach staging (e.g. `.kryota-dev/` planning notes) are excluded via `~/.gitignore_global` instead.

### Client-identifier rule (injected from 1Password)

The config is a chezmoi template (`private_` prefix, rendered with mode 0600) rather than
plain source, because it defines a `client-identifiers` rule whose regex must never appear
in this public repo:

```toml
[[rules]]
id = "client-identifiers"
regex = '''(?i)({{ onepasswordRead "op://kryota.dev/Dotfiles - Redact Patterns/pattern" | trim }})'''
```

At `chezmoi apply` time, the pattern is read from the 1Password item `Dotfiles - Redact
Patterns` (vault `kryota.dev`, field `pattern`), which holds a single `name1|name2|…`
alternation of client/employer identifiers that must not land in a commit. `run_once_after_11-validate-1password.sh.tmpl`
checks that this item exists before apply proceeds. Creating the item itself is a manual,
out-of-band step for the maintainer — its value is never written to this repo.

On a false positive, use the same escape hatch as any other gitleaks finding:
`git commit --no-verify`.

### Caveats

- `git commit --no-verify` bypasses the hook. This is intentional per-harness policy. CI/server-side gitleaks is the backstop.
- A repo that sets its own `core.hooksPath` (e.g. husky) never reaches the global hook at all.
- The hook chains only `pre-commit`. Other hook types (`commit-msg`, `post-commit`, etc.) from `.git/hooks` are not chained; repos relying on those must use a hook manager that also sets `core.hooksPath`.

---

## Ghostty terminal

`home/dot_config/ghostty/config` is deployed verbatim to `~/.config/ghostty/config`. It is not a template.

Key settings:

| Setting | Value |
|---------|-------|
| `font-family` | `Moralerspace Neon` |
| `font-size` | `14` |
| `shell-integration` | `zsh` |
| `term` | `xterm-256color` |
| `copy-on-select` | `clipboard` |
| `cursor-style` | `block` |
| `cursor-style-blink` | `true` |
| `macos-option-as-alt` | `true` |
| `macos-titlebar-style` | `tabs` |

**Font prerequisite**: Ghostty requires the `Moralerspace Neon` font family to be installed. Moralerspace Neon is deployed by the chezmoi engine at apply time via the `["Library/Fonts"]` external in `.chezmoiexternal.toml` (macOS only); the Nerd Font symbols-only cask (`font-symbols-only-nerd-font`) is installed via Brewfile.

---

## Cross-references

- [Lifecycle scripts: ordering & trigger model](lifecycle-scripts.md) — `run_onchange_before_10` (brew bundle) and `run_onchange_after_12` (mise install) are triggered by the hashes of `dot_Brewfile` and `mise/config.toml` respectively
- [zsh startup, prompt & shell modules](shell-environment.md) — `.zshrc` activates mise, direnv, starship, and zoxide
- [CI architecture & test suite](../contributing/ci-and-tests.md) — CI duplicates the `.brewfile-linux-exclude` filter and caches mise installs on `config.toml` hash
- [1Password secrets onboarding](../getting-started/secrets-1password.md) — the 1Password setup that enables SSH commit signing
- [Account isolation: aliases & env](../agents/account-isolation.md) — the gateguard Codex gate that bridges into the AI-agent subsystem
