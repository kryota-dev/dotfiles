# chezmoi engine: data, templates & name decoding

🌐 日本語: [chezmoi-engine.ja.md](chezmoi-engine.ja.md)

← [Docs index](../README.md)

The chezmoi engine is the meta-layer that every other subsystem depends on. It defines how the source tree maps to `$HOME`, what template variables are available, and how to share config fragments across multiple deployment targets. This doc covers name decoding, the template-variable inventory, OS branching, `includeTemplate`, and the two chezmoi config files.

---

## Source → `$HOME` name decoding

The chezmoi source root is `home/` (set by `.chezmoiroot`). All paths below are relative to `home/`.

| Source prefix / suffix | Effect on destination | Example |
|------------------------|-----------------------|---------|
| `dot_` | Replaced by `.` | `dot_zshrc` → `~/.zshrc` |
| `dot_config/` | Prefix expands recursively | `dot_config/zsh/foo.zsh` → `~/.config/zsh/foo.zsh` |
| `private_` | Destination created at mode `0600` | `private_dot_aws/config` → `~/.aws/config` (0600) |
| `executable_` | Destination created at mode `0755` | `dot_claude/executable_statusline.sh` → `~/.claude/statusline.sh` (0755) |
| `symlink_` | Creates a symlink; file content is the link target | `symlink_skills.tmpl` → rendered path is the symlink target |
| `.tmpl` suffix | File is rendered as a Go template; suffix stripped from destination name | `dot_gitconfig.tmpl` → `~/.gitconfig` |
| `run_once_` prefix | Script executes exactly once (keyed by script content SHA256) | `run_once_after_11-validate-1password.sh.tmpl` |
| `run_onchange_` prefix | Script re-executes whenever its content hash or a watched input hash changes | `run_onchange_before_10-brew-bundle.sh.tmpl` |

Prefixes and suffixes combine. Example: `home/dot_config/chezmoi/private_chezmoi.toml` decodes to `~/.config/chezmoi/chezmoi.toml` at mode `0600`.

---

## Template-variable inventory

All `.tmpl` files have access to two variable namespaces: the static data loaded from `.chezmoidata.toml`, and the chezmoi built-ins under `.chezmoi.*`.

### Static data: `home/.chezmoidata.toml`

This file is auto-loaded by chezmoi (any file named `.chezmoidata.*` in the source tree is merged into the template data dict). No per-machine configuration is required.

| Variable | Type | Value / purpose |
|----------|------|-----------------|
| `.email` | string | Commit author and git config email |
| `.name` | string | Commit author name (`kryota-dev`) |
| `.signingkey` | string | Path to SSH public key used for git commit signing (`~/.ssh/ssh-key.pub`) |
| `.ghq_user` | string | Default `ghq` user namespace (`kryota-dev`) |
| `.versions.moralerspace_font` | string | Moralerspace font release version; used in the external archive URL (Renovate-bumped) |
| `.skills.anthropic_commit` | string | SHA of the `anthropics/skills` commit to fetch; Renovate bumps this |
| `.ecc.version` | string | ECC release version — the **Renovate** tracking anchor for the `github-tags` customManager. Not referenced by any chezmoi template (chezmoi consumes `.ecc.commit`); bumped together with `.ecc.commit` on each ECC release |
| `.ecc.commit` | string | Immutable commit SHA of the pinned ECC release; used in all ECC external URLs |
| `.ecc.skills` | string array | The <!-- FACT:ecc-skill-count -->126<!-- /FACT -->-entry list of adopted ECC skill names; ranged over in `.chezmoiexternal.toml` to generate one external entry per skill |

Reference top-level keys bare: `{{ .name }}`, `{{ .email }}`. Reference nested tables with dots: `{{ .ecc.commit }}`, `{{ .versions.moralerspace_font }}`.

### chezmoi built-ins

| Variable | Type | Common use |
|----------|------|------------|
| `.chezmoi.os` | string | `"darwin"` on macOS, `"linux"` on Linux; the OS branching key |
| `.chezmoi.homeDir` | string | Absolute path to `$HOME`; used in hook paths and config files |

---

## OS branching

The canonical OS branch idiom is:

```
{{ if eq .chezmoi.os "darwin" }}
# macOS-only block
{{ else if eq .chezmoi.os "linux" }}
# Linux block
{{ end }}
```

The negated exclude form is also used:

```
{{ if ne .chezmoi.os "darwin" }}
# non-macOS block (e.g. ignore Library/ on Linux)
{{ end }}
```

This guard appears in:

- `.chezmoiignore` — ignores `Library/` when not on Darwin.
- `.chezmoiexternal.toml` — wraps the Moralerspace font entry (macOS only).
- Most `run_*` lifecycle scripts — guards macOS-specific commands.

macOS is the primary target. Linux support exists to keep CI green; some features (fonts, macOS defaults) are simply absent on Linux.

---

## Shared templates: `includeTemplate`

Files under `home/.chezmoitemplates/` are **not** deployed directly. They are named fragments included by other `.tmpl` files via:

```
{{ includeTemplate "<fragment-name>" . }}
```

The trailing `.` passes the current data context (all template variables) to the fragment. Resolution searches `.chezmoitemplates/` first, then the source directory.

| Fragment | Included by | Purpose |
|----------|-------------|---------|
| `coding-standards.md` | `AGENTS.md.tmpl` | House coding standards (Japanese), authored once. Embedded into `~/AGENTS.md`; `~/.claude/CLAUDE.md` picks it up transitively via its `@~/AGENTS.md` import (a Claude Code file reference, not a chezmoi `includeTemplate`) |
| `codex-hooks.json` | `dot_codex/hooks.json.tmpl`, `dot_codex-r06/hooks.json.tmpl` | Actual Codex `PreToolUse` hook body; references `{{ .chezmoi.homeDir }}` |
| `codex-shared-config.toml` | `dot_codex/private_shared.config.toml.tmpl`, `dot_codex-r06/private_shared.config.toml.tmpl` | Shared Codex profile config; personality, model, reasoning effort, `multi_agent` flag |

The `dot_codex/` and `dot_codex-r06/` directories are structurally identical thin wrappers around `includeTemplate` calls. The real config bodies live in `.chezmoitemplates/` so the two accounts cannot drift.

---

## The two chezmoi config files

Two TOML files under `home/` both relate to chezmoi, but serve different purposes.

### `home/.chezmoidata.toml` — template DATA

Auto-loaded. Contains **values that `.tmpl` files read**. This is where you put email, key paths, version pins, and any other variable a template needs. It is never deployed to `$HOME`; it only exists in the source tree to feed the template engine.

### `home/dot_config/chezmoi/private_chezmoi.toml` — chezmoi BEHAVIOR config

Deploys to `~/.config/chezmoi/chezmoi.toml` at mode `0600` (due to `private_` prefix). Contains **chezmoi's own settings**, not template data. Currently:

```toml
[diff]
  exclude = ["scripts"]
```

The `exclude = ["scripts"]` setting means `chezmoi diff` hides `run_*` lifecycle script changes by default. A script edit can apply silently in diff output unless you pass `--exclude=` to override the filter. This is intentional — lifecycle script diffs are often noisy and the content hash (`run_once_`/`run_onchange_`) is the meaningful signal.

Confusing these two files is easy because both are TOML files associated with chezmoi. The rule: data for templates → `.chezmoidata.toml`; chezmoi's own behaviour → `dot_config/chezmoi/private_chezmoi.toml`.

---

## `.chezmoiignore` and `.chezmoiremove`

### `.chezmoiignore`

Glob patterns of **destination** paths chezmoi will neither create nor manage. It does not delete existing files matching these patterns — it simply ignores them. The file is itself a template, so patterns can be OS-conditional.

Use cases in this repo:
- Harness runtime state: `~/.claude/history.jsonl`, `~/.codex/sessions/`, ECC databases, etc.
- AWS CLI and SSO caches.
- `Library/` on non-Darwin (Linux).

Patterns are destination-path globs (i.e., relative to `$HOME`), not source globs.

### `.chezmoiremove`

Destination paths chezmoi **actively deletes** on every `chezmoi apply`. This is the mechanism for retiring a file that was previously deployed.

Deleting a file from the chezmoi source tree does **not** remove an already-deployed copy from `$HOME`. If you want to remove a deployed file, you must:

1. `git rm` the source file (or remove it from an external list), **and**
2. Add the destination path to `.chezmoiremove`.

Current entries: four orphaned `sdd-*` agent files and three `agent-browser` specialized skills (`electron`, `slack`, `dogfood`) whose deployed copies are force-removed because the CLI now serves them at runtime.

---

## Lint interaction

Template files (`.tmpl`) contain Go template directives mixed with shell or TOML syntax. The lint pipeline strips lines containing `{{` with `sed '/{{/d'` before running shellcheck, shfmt, and `zsh -n`. This means:

- A shell statement on the same line as a `{{ … }}` directive will be lost during linting.
- A backslash line-continuation (`\`) on a line that immediately follows a stripped template line will break the surviving shell statement.

Keep template directives on their own lines. See [contributing/local-dev.md](../contributing/local-dev.md) for the full lint pipeline.
