# Verifying a fresh install

> 🌐 日本語: [verification.ja.md](verification.ja.md)

← [Docs index](../README.md)

This checklist mirrors what `.github/workflows/setup-validation.yml` asserts in CI. Run each step locally after a fresh `chezmoi apply` to confirm the machine converged.

---

## 1. Core files deployed

```bash
for f in \
  ~/.zshrc \
  ~/.zprofile \
  ~/.gitconfig \
  ~/.ssh/config \
  ~/.config/starship.toml \
  ~/.config/sheldon/plugins.toml \
  ~/.config/ghostty/config \
  ~/.config/mise/config.toml; do
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
```

All eight paths must print `OK`. Missing files indicate an incomplete `chezmoi apply`.

## 2. zsh modules deployed

```bash
for mod in aliases git docker claude functions completions wtp ghq; do
  f=~/.config/zsh/${mod}.zsh
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
```

These modules are loaded by sheldon at zsh startup. A missing module causes startup errors or missing aliases.

## 3. mise-managed tools resolve

```bash
eval "$(mise activate bash)"
for tool in node python go; do
  path=$(which "$tool")
  echo "$tool: $path"
  echo "$path" | grep -q ".local/share/mise" || echo "WARNING: $tool not managed by mise"
done
node --version
python3 --version
go version
```

Each binary path must contain `.local/share/mise`. A system-installed tool shadowing the mise version indicates the shims are not active.

## 4. ghq config applied

```bash
ghq_root=$(git config --type path --global --get ghq.root || true)
ghq_user=$(git config --global --get ghq.user || true)
[ "$ghq_root" = "$HOME/ghq" ] && echo "OK: ghq.root" || echo "MISMATCH: ghq.root=$ghq_root"
[ "$ghq_user" = "kryota-dev" ]  && echo "OK: ghq.user" || echo "MISMATCH: ghq.user=$ghq_user"
[ -f ~/.config/zsh/completions/_ghq ] && echo "OK: _ghq completion" || echo "MISSING: _ghq completion"
```

## 5. Clean non-interactive zsh startup

```bash
zsh_stderr=$(zsh -i -c exit 2>&1 >/dev/null) || true
if echo "$zsh_stderr" | grep -qE 'command not found|parse error|not found'; then
  echo "ERROR: zsh startup errors:"
  echo "$zsh_stderr"
else
  echo "OK: zsh starts cleanly"
fi
```

This is the exact check `setup-validation.yml` uses. Any `command not found` or `parse error` in stderr indicates a broken shell module.

## 6. Commit signing wired (macOS)

```bash
git config --global --get gpg.format          # expect: ssh
git config --global --get gpg.ssh.program     # expect: path to 1Password SSH agent binary
git config --global --get commit.gpgsign      # expect: true
```

Then create a throwaway commit to verify 1Password SSH agent signing works end-to-end:

```bash
cd "$(mktemp -d)" && git init && git commit --allow-empty -m "signing test"
```

If a 1Password dialog appears and the commit succeeds, signing is wired correctly.

## 7. Agent launcher aliases load (zsh)

Start a new interactive zsh session (or `exec zsh`) and verify:

```bash
type cld       # should resolve to a function or alias
type cld-r06   # same
type cdx       # Codex default account launcher
type cdx-r06   # Codex r06 account launcher
```

These aliases are defined in `~/.config/zsh/claude.zsh` and loaded by sheldon. If they are missing, check that the zsh module was deployed (step 2) and that sheldon ran successfully.

---

## Troubleshooting quick reference

| Symptom | Likely cause | Remedy |
|---------|-------------|--------|
| `MISSING: ~/.zshrc` | `chezmoi apply` did not complete | Re-run `chezmoi apply -v` and check for errors |
| Tool not under `.local/share/mise` | mise shims not active | Run `mise activate bash` or open a new terminal |
| `command not found` in zsh stderr | Missing dependency or sheldon not locked | Run `sheldon lock` then `exec zsh` |
| `ghq.root` mismatch | `~/.gitconfig` not fully applied | Run `chezmoi apply -v` and check `dot_gitconfig.tmpl` |
| Signing test fails with 1Password error | SSH agent not running or not unlocked | Open 1Password desktop, unlock, retry |
| `cld` / `cdx` aliases missing | `claude.zsh` not loaded by sheldon | Confirm `~/.config/zsh/claude.zsh` exists; run `sheldon lock` |

---

## Relationship to CI

`.github/workflows/setup-validation.yml` runs steps 1–5 on both macOS and Ubuntu after a clean-room `chezmoi apply`. Steps 6 and 7 are macOS-only and require 1Password, so they are excluded from CI. Running this checklist locally gives you the full picture CI cannot cover.
