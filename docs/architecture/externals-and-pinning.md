# Externals, SHA-pinning & the single-tarball cache

🌐 日本語: [externals-and-pinning.ja.md](externals-and-pinning.ja.md)

← [Docs index](../README.md)

`home/.chezmoiexternal.toml` declares every external resource chezmoi fetches at apply time: Anthropic skill archives, the ECC hook runtime, <!-- FACT:ecc-skill-count -->126<!-- /FACT --> ECC skills (generated from a single list), the `aside` slash command, and the Moralerspace font. This document explains the caching model, the `range`-driven fan-out, SHA pinning, refresh windows, and the `chezmoiignore`/`chezmoiremove` lifecycle for retiring deployed files.

---

## What is declared

| Category | Source repo | Entry type | Count |
|----------|-------------|------------|-------|
| Anthropic skills | `anthropics/skills` | `archive` | 17 |
| ECC hook runtime (`scripts/hooks` + `scripts/lib`) | `affaan-m/ECC` | `archive` | 1 |
| ECC adopted skills | `affaan-m/ECC` | `archive` (range-generated) | = length of `[ecc].skills` (asserted by `tests/docs_facts.bats`) |
| `aside` slash command | `affaan-m/ECC` | `file` | 1 |
| Moralerspace font (macOS only) | `yuru7/moralerspace` | `archive` | 1 |

Total declared entries: the static entries (17 + 1 + 1 + 1 = 20) plus the `range`-generated ECC skill entries (= length of `[ecc].skills`), so the total tracks the array automatically. Total actual HTTP downloads at a cold apply: 4 (one per unique tarball URL — see caching below).

---

## Single-tarball URL caching

chezmoi caches external archives keyed by the SHA256 of the URL string. Any two entries with **identical URLs** cause exactly one download; the cached bytes are reused for every entry sharing that URL.

This repo exploits that property deliberately:

- All 17 Anthropic skill entries share `https://github.com/anthropics/skills/archive/{{ .skills.anthropic_commit }}.tar.gz`. One download, 17 extractions from the cache.
- The 1 ECC hook-runtime entry and all ECC skill entries share `https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz`. One download, 1 + len([ecc].skills) extractions.

Adding more entries from the same repo is therefore essentially free in network terms — only the `include` glob and `stripComponents` value differ per entry.

---

## Archive entry anatomy

A typical Anthropic skill entry:

```toml
[".agents/skills/algorithmic-art"]
    type = "archive"
    url = "https://github.com/anthropics/skills/archive/{{ .skills.anthropic_commit }}.tar.gz"
    stripComponents = 3
    include = ["*/skills/algorithmic-art/**"]
    refreshPeriod = "168h"
```

| Field | Meaning |
|-------|---------|
| Section key | Destination path relative to `$HOME` |
| `type = "archive"` | Fetch a tarball; extract matching paths |
| `url` | Templated with a commit SHA from `.chezmoidata.toml` |
| `stripComponents` | Leading path components to strip from tarball entries before writing |
| `include` | Glob matched against **tarball-internal** paths to select what to extract |
| `refreshPeriod` | How long chezmoi serves the cached copy before re-checking upstream |

`stripComponents = 3` drops the `<repo>-<commit>/skills/<name>/` prefix so the skill's files land directly at `~/.agents/skills/<name>/`.

The single `file` entry (`aside.md`) fetches a raw URL with no extraction:

```toml
[".claude/commands/aside.md"]
    type = "file"
    url = "https://raw.githubusercontent.com/affaan-m/ECC/{{ .ecc.commit }}/commands/aside.md"
    refreshPeriod = "168h"
```

---

## The `range .ecc.skills` fan-out

Writing a near-identical TOML block for each ECC skill by hand would be error-prone. Instead, `.chezmoiexternal.toml` is itself a Go template. The entire ECC skills section is a single `range` loop:

```
{{ range $skill := .ecc.skills -}}
[".agents/skills/{{ $skill }}"]
    type = "archive"
    url = "https://github.com/affaan-m/ECC/archive/{{ $.ecc.commit }}.tar.gz"
    stripComponents = 3
    include = ["*/skills/{{ $skill }}/**"]
    refreshPeriod = "168h"

{{ end -}}
```

Key points:

- `.ecc.skills` is the array in `home/.chezmoidata.toml` `[ecc]` table; its length is the authoritative ECC skill count.
- Inside the `range` block, `.` is rebound to the current element (the skill name string). To reach other top-level data — specifically the commit SHA — you must use **`$`** (the root context): `{{ $.ecc.commit }}`, not `{{ .ecc.commit }}`.
- **To add or remove an ECC skill**, edit only the `[ecc].skills` array in `home/.chezmoidata.toml`. The range block generates the external entry automatically. Never hand-write per-skill entries in `.chezmoiexternal.toml`.

---

## ECC hook runtime vs ECC skills: `stripComponents` difference

The ECC hook runtime entry uses `stripComponents = 2`, not 3:

```toml
[".agents/skills/ecc/scripts"]
    type = "archive"
    url = "https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz"
    stripComponents = 2
    include = ["*/scripts/hooks/**", "*/scripts/lib/**"]
    refreshPeriod = "168h"
```

`stripComponents = 2` drops `<repo>-<commit>/scripts/` → the `hooks/` and `lib/` subdirectories land at `~/.agents/skills/ecc/scripts/hooks/` and `~/.agents/skills/ecc/scripts/lib/`.

`stripComponents = 3` (used by all skill entries) drops one more level (`<repo>-<commit>/skills/<name>/`) so files land directly at `~/.agents/skills/<name>/`.

Getting this wrong places files at the wrong depth and they will not be found by skill discovery.

---

## SHA pinning and `refreshPeriod`

Every external URL interpolates an **immutable commit SHA**, never a branch name or tag:

```toml
url = "https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz"
```

The SHA is defined in `home/.chezmoidata.toml` under `[ecc].commit`; Renovate bumps it on every new ECC release (see the Renovate bump model section). The current value is intentionally not repeated here — it is the SSOT in `.chezmoidata.toml` and changes frequently. Example shape:

```toml
[ecc]
  commit = "<commit-sha>"   # current value: home/.chezmoidata.toml [ecc].commit
```

A moved tag cannot change the fetched bytes. The `refreshPeriod` controls how long chezmoi serves its local cache before re-downloading:

| Resource | `refreshPeriod` |
|----------|----------------|
| Anthropic skills | `168h` (7 days) |
| ECC hook runtime | `168h` (7 days) |
| ECC skills | `168h` (7 days) |
| `aside` command | `168h` (7 days) |
| Moralerspace font | `672h` (28 days) |

Within the period chezmoi serves the cached copy without a network request. After the period expires, the next `chezmoi apply` re-downloads (but fetches the same bytes if the SHA has not changed).

---

## Renovate bump model

`renovate.json5` includes a `customManager` regex that matches the `version` and `commit` fields in `.chezmoidata.toml` and bumps them together as a single PR when a new ECC release tag appears.

Critical policy: **ECC is never auto-merged.** A `packageRule` in `renovate.json5` sets `"automerge": false` for `affaan-m/ECC`. Every ECC bump must be reviewed manually because the ECC tarball contains executable hook scripts that run inside the agent harness.

The same pin-in-data / bump-via-Renovate pattern applies to `anthropics/skills` (`.skills.anthropic_commit`) and the Moralerspace font (`.versions.moralerspace_font`).

---

## `.chezmoiignore` vs `.chezmoiremove`

These two files govern what chezmoi does with paths it does **not** own in the source tree.

### `.chezmoiignore` — leave unmanaged

Destination-path globs that chezmoi will neither create, update, nor delete. Used for runtime state that must not enter the source tree: session histories, SQLite databases, auth tokens, local overrides.

The file is itself a template, so patterns can be OS-conditional. Example from `.chezmoiignore`:

```
{{ if ne .chezmoi.os "darwin" }}
Library/
{{ end }}
```

### `.chezmoiremove` — actively delete

Destination paths chezmoi **deletes on every apply**. Required when retiring a previously deployed file.

Removing a file from the chezmoi source tree (via `git rm`) does **not** remove an already-deployed copy from `$HOME`. The deployed copy becomes orphaned. To clean it up you need both steps:

1. Remove from source: `git rm home/path/to/file` (or remove the name from `.ecc.skills`).
2. Add the `$HOME`-relative destination path to `home/.chezmoiremove`.

Current `.chezmoiremove` entries:

```
# Orphaned SDD agents
.claude/agents/sdd-designer.md
.claude/agents/sdd-worker.md
.claude/agents/sdd-work-reviewer.md
.claude/agents/sdd-design-reviewer.md

# agent-browser specialized skills (now CLI-served at runtime)
.agents/skills/electron
.agents/skills/slack
.agents/skills/dogfood
```

The `agent-browser` specialized skills are a concrete example of the pattern: they were previously vendored as static files, then replaced by a CLI that serves version-matched copies at runtime. The static copies were removed from source **and** their destination paths were added to `.chezmoiremove` to ensure clean removal on the next `chezmoi apply`.
