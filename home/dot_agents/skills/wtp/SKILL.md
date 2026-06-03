---
name: wtp
description: "Comprehensive guide for the `wtp` (Worktree Plus) CLI by satococoa — an enhanced Git worktree manager. Use this whenever the user wants to create, list, remove, or navigate Git worktrees with wtp, mentions `wtp add`/`wtp cd`/`wtp list`/`wtp remove`/`wtp exec`, asks about automatic worktree paths from branch names, post-create hooks (copy/symlink/command) in `.wtp.yml`, branch tracking for worktrees, or shell integration (`wtp shell-init`, `wtp hook`, tab completion, auto-cd). Trigger this even when the user just describes the workflow — e.g. 'spin up a worktree for this feature branch', 'jump to my auth worktree', 'clean up the worktree and its branch' — without naming wtp explicitly, as long as wtp is the available tool."
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# wtp (Worktree Plus)

`wtp` is a Git worktree manager that removes the friction from `git worktree`: it
derives sensible paths from branch names, auto-tracks remote branches, runs
project-specific setup hooks on creation, and provides instant `cd` navigation
between worktrees.

This skill covers the day-to-day commands plus configuration and shell
integration. For the full `.wtp.yml` hook reference (copy/symlink/command hooks,
path resolution rules), read `references/configuration.md`.

## Mental model

- **Worktrees live outside the repo.** By default they go under
  `../worktrees/<branch-name>`, so `feature/auth` → `../worktrees/feature/auth`.
  Slashes in branch names become directories, keeping things organized by type.
- **The main worktree is `@`.** Refer to it as `@` in `wtp cd` / `wtp exec`, or
  omit the name entirely to mean "go home" (like bare `cd`).
- **Hooks run on `wtp add`.** Anything you'd normally do by hand after creating a
  worktree (copy `.env`, symlink caches, install deps) belongs in `.wtp.yml`.

Always confirm the installed version with `wtp --version` if behavior seems off —
this skill is written against **v2.10.x**.

## Creating worktrees — `wtp add`

```bash
wtp add <existing-branch>          # worktree from an existing local/remote branch
wtp add -b <new-branch> [<commit>] # create a new branch + worktree
```

Key behaviors:

- **Auto-tracking**: if `<branch>` isn't local but exists on exactly one remote,
  wtp creates a local tracking branch automatically. No remote → clear error.
- **New branch from a base**: `wtp add -b hotfix/urgent main` branches off `main`.
  The base can be a commit (`abc1234`) or a remote ref (`origin/main`).
- **Run setup after creation**: `--exec "<cmd>"` runs a command inside the new
  worktree *after* hooks finish (supports interactive commands when a TTY exists).
- **Script-friendly**: `--quiet` / `-q` prints only the created absolute path, so
  you can capture it: `dir=$(wtp add -b feature/x --quiet)`.

Examples:

```bash
wtp add feature/auth                      # existing branch (tracks remote if needed)
wtp add -b feature/new-feature            # brand-new branch
wtp add -b hotfix/urgent main             # new branch based on main
wtp add -b feature/test origin/main       # new branch tracking origin/main
wtp add -b feature/x --exec "npm test"    # create, run hooks, then npm test
```

**Multiple remotes** with the same branch name are ambiguous by design. wtp won't
guess — create the local branch yourself, then retry:

```bash
git branch --track feature/shared upstream/feature/shared
wtp add feature/shared
```

## Listing worktrees — `wtp list` (alias `ls`)

```bash
wtp list                 # table: PATH, BRANCH, HEAD; main worktree shown as @ ... *
wtp list --quiet         # paths only (one per line) — good for scripting/piping
wtp list --compact       # minimize column widths for narrow/redirected output
wtp list --max-path-width 80
```

Note: `wtp list` may abbreviate branch names. When you need the **full** branch
name (e.g. to check merge status), pair it with
`git worktree list --porcelain | grep '^branch '`.

## Removing worktrees — `wtp remove` (alias `rm`)

```bash
wtp remove <worktree-name>                    # remove the worktree only
wtp remove --force <name>                      # remove even if the worktree is dirty
wtp remove --with-branch <name>                # also delete the branch (only if merged)
wtp remove --with-branch --force-branch <name> # delete the branch even if unmerged
```

`--with-branch` is the headline feature: it removes the worktree *and* its branch
in one atomic step, so you don't leave orphaned branches behind. The branch is
only deleted if merged unless you add `--force-branch`. The target is the
worktree's **directory name**, not the branch path (see `wtp list` output).

## Navigating — `wtp cd`

`wtp cd` prints the absolute path of a worktree. Two ways to use it:

```bash
cd "$(wtp cd feature/auth)"   # direct: command substitution, works in any shell
cd "$(wtp cd)"                # main worktree (bare cd = "go home")
```

With the shell hook installed (see Shell integration), `wtp cd` changes the
directory directly — no subshell needed:

```bash
wtp cd feature/auth   # jumps there
wtp cd @              # main worktree (explicit)
wtp cd                # main worktree
wtp cd <TAB>          # tab completion of worktree names
```

## Running commands in a worktree — `wtp exec`

```bash
wtp exec <worktree> -- <command> [args...]
```

Runs a command in another worktree without `cd`-ing there. Target resolution is
the same as `wtp cd` (so `@` is the main worktree):

```bash
wtp exec feature/auth -- go test ./...
wtp exec @ -- pwd
```

## Configuration — `.wtp.yml`

```bash
wtp init   # scaffold a .wtp.yml in the repo root with example hooks
```

Minimal shape:

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"   # where worktrees are created, relative to project root
hooks:
  post_create:
    - type: copy
      from: ".env"            # 'from' is relative to the MAIN worktree (gitignored OK)
      to: ".env"              # 'to' is relative to the NEW worktree (defaults to 'from')
    - type: symlink
      from: ".bin"
      to: ".bin"
    - type: command
      command: "npm ci"
```

The three hook types (`copy`, `symlink`, `command`), the exact path-resolution
rules, and `env`/`work_dir` options are detailed in
`references/configuration.md` — read it before editing or generating a `.wtp.yml`,
because the `from`/`to` "main vs new worktree" distinction is the most common
source of mistakes.

## Shell integration

Enables tab completion **and** directory-changing `wtp cd` / auto-cd on
interactive `wtp add`.

- **Installed via Homebrew** (this machine): lazy-loaded. The first `TAB` after
  typing `wtp` evaluates `wtp shell-init <shell>` for the session — no rc edits
  needed. To refresh in the current shell, run `wtp shell-init <shell>` manually.
- **Installed via `go install`**: add one line to your shell rc:

  ```bash
  eval "$(wtp shell-init zsh)"     # zsh  (~/.zshrc)
  eval "$(wtp shell-init bash)"    # bash (~/.bashrc); needs bash-completion v2
  wtp shell-init fish | source     # fish (~/.config/fish/config.fish)
  ```

`shell-init` bundles completion + the cd hook. If you want *only* the cd hook
without completions, use `wtp hook <shell>` instead (`bash`/`zsh`/`fish`
subcommands).

When stdout is not a TTY (command substitution, pipes), `wtp add` keeps plain CLI
behavior and does **not** auto-switch directories — so scripts stay predictable.

## Troubleshooting

wtp aims for actionable errors. Common ones:

- `branch '<x>' not found in local or remote branches` — typo, or the remote
  isn't fetched. Run `git fetch` and retry.
- `branch '<x>' exists in multiple remotes: origin, upstream` — ambiguous;
  create a local tracking branch first (`git branch --track <x> origin/<x>`),
  then `wtp add <x>`.
- `failed to create worktree: exit status 128` — usually the worktree path
  already exists. Check `wtp list`.
- `Cannot remove worktree with uncommitted changes. Use --force to override` —
  commit/stash, or `wtp remove --force <name>` if you mean to discard.

## Related skills

For bulk cleanup of merged worktrees, see the `wtp-cleanup` skill, which detects
worktrees whose branches are already merged into `main` and removes them after
confirmation.
