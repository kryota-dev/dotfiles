# `.wtp.yml` Configuration Reference

`wtp` reads project-specific settings from `.wtp.yml` in the repository root.
Scaffold one with `wtp init`. This file controls where worktrees are created and
what runs automatically after each `wtp add`.

## Table of contents

- [Top-level structure](#top-level-structure)
- [defaults](#defaults)
- [Hooks overview](#hooks-overview)
- [copy hook](#copy-hook)
- [symlink hook](#symlink-hook)
- [command hook](#command-hook)
- [Path resolution: main vs new worktree](#path-resolution-main-vs-new-worktree)
- [Full example](#full-example)

## Top-level structure

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"
hooks:
  post_create:
    - { ... }
```

## defaults

| Key        | Meaning                                                      | Default          |
| ---------- | ----------------------------------------------------------- | ---------------- |
| `base_dir` | Base directory for new worktrees, relative to project root. | `"../worktrees"` |

A branch named `feature/auth` with the default `base_dir` is created at
`../worktrees/feature/auth`. Slashes are preserved as nested directories.

## Hooks overview

`hooks.post_create` is a list of steps executed in order **after** the worktree
is created and **before** any `wtp add --exec` command runs. Each step has a
`type` of `copy`, `symlink`, or `command`. Hooks are the way to get a worktree to
a ready-to-code state without manual steps.

## copy hook

Copies a file or directory into the new worktree. Designed for bootstrapping with
files that live in the main worktree but are **gitignored** (so a fresh worktree
wouldn't otherwise have them) — e.g. `.env`, `.claude`, `.cursor/`.

```yaml
- type: copy
  from: ".env"   # relative to the MAIN worktree; gitignored files allowed
  to: ".env"     # relative to the NEW worktree; defaults to `from` if omitted
```

- `from`: always resolved relative to the **main** worktree.
- `to`: resolved relative to the **new** worktree. If omitted, defaults to the
  same value as `from` (relative paths only). An absolute `from` **requires** an
  explicit `to`.
- Works for both files and directories (`from: ".cursor/"`).

This behavior is identical regardless of which worktree you run `wtp add` from.

## symlink hook

Creates a symlink in the new worktree pointing at a path in the main worktree.
Use this to **share** large or mutable directories instead of copying them —
e.g. `.bin`, `.cache`, `node_modules`.

```yaml
- type: symlink
  from: ".bin"   # relative to the MAIN worktree (or absolute)
  to: ".bin"     # relative to the NEW worktree (or absolute)
```

Copy vs symlink: copy when each worktree needs its own independent file; symlink
when worktrees should share a single underlying directory.

## command hook

Runs a shell command inside the new worktree.

```yaml
- type: command
  command: "npm install"
  env:                       # optional: extra environment variables
    NODE_ENV: "development"
  work_dir: "."              # optional: working directory, relative to the new worktree
```

- `command`: the shell command to execute.
- `env`: optional map of environment variables for that command.
- `work_dir`: optional working directory (relative to the new worktree). Defaults
  to the worktree root.

Prefer explicit, single-step commands (`npm ci`, then `npm run db:setup`) over
one big script, so a failure points clearly at the step that broke. A task runner
target (`make bootstrap`) is fine too.

## Path resolution: main vs new worktree

This is the single most common source of confusion, so internalize it:

| Hook field             | Resolved relative to     |
| ---------------------- | ------------------------ |
| `copy.from`            | **Main** worktree        |
| `copy.to`              | **New** worktree         |
| `symlink.from`         | **Main** worktree        |
| `symlink.to`           | **New** worktree         |
| `command.work_dir`     | **New** worktree         |

Mnemonic: you're pulling assets **from** the main worktree **to** the brand-new
one. `from` looks back at the source of truth; `to` lands in the worktree you just
created.

## Full example

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"

hooks:
  post_create:
    # Copy gitignored local config from the main worktree
    - type: copy
      from: ".env"
      to: ".env"
    - type: copy
      from: ".claude"        # `to` omitted → defaults to ".claude"

    # Share a directory instead of duplicating it
    - type: symlink
      from: ".bin"
      to: ".bin"

    # Install dependencies and set up the database
    - type: command
      command: "npm install"
      env:
        NODE_ENV: "development"
    - type: command
      command: "make db:setup"
      work_dir: "."
```
