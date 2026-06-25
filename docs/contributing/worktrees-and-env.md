# Worktrees and Environment

🌐 日本語: [worktrees-and-env.ja.md](worktrees-and-env.ja.md)

← [Docs index](../README.md)

This document covers the worktree automation (`wtp` + `.wtp.yml`), the `direnv`-based environment loading (`.envrc` / `.env`), and the project-scoped MCP server (`.mcp.json`).

---

## Worktree automation with wtp

[wtp](https://github.com/kryota-dev/wtp) (Worktree Plus) manages git worktrees with post-create hooks. The repo's `.wtp.yml` configures where worktrees are created and what happens after creation.

### `.wtp.yml`

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees/dotfiles"

hooks:
  post_create:
    - type: symlink
      from: ".env"
      to: ".env"

    - type: symlink
      from: ".spec-workflow"
      to: ".spec-workflow"

    - type: command
      command: "direnv allow"
```

Key points:

- **`base_dir`** is relative to the main checkout. A new worktree created with `wtp add` lands at `../worktrees/dotfiles/<branch-name>`, a sibling of the main repo directory.
- **Post-create hook 1**: symlinks `.env` from the main checkout into the new worktree. This means the worktree inherits `OP_ACCOUNT` (and any future variables) without manual copying.
- **Post-create hook 2**: symlinks `.spec-workflow` from the main checkout. Both `.env` and `.spec-workflow` are gitignored; the symlinks share state between the main checkout and all worktrees.
- **Post-create hook 3**: runs `direnv allow` so the `.envrc` in the new worktree activates immediately on first `cd`.

**Prerequisite**: `.env` and `.spec-workflow` must exist in the main checkout before `wtp add` is run. The `.spec-workflow` directory is created by the spec-workflow MCP server on first use. `.env` must be bootstrapped from `.env.template` (see below).

---

## direnv and `.env`

The repo uses [direnv](https://direnv.net/) to load per-project environment variables. The entire `.envrc` is one line:

```sh
dotenv
```

This tells direnv to load `.env` into the shell whenever you `cd` into the repo (or a worktree). After the first `direnv allow` — which the wtp post-create hook runs automatically for new worktrees — the variables in `.env` are exported into the shell.

### `.env.template`

The committed template shows the required variables:

```sh
OP_ACCOUNT=my.1password.com
```

`OP_ACCOUNT` selects the 1Password account that `op` and chezmoi's `onepasswordRead` use during `chezmoi apply`. `my.1password.com` is the correct value for individual accounts on 1Password.com; adjust if your account is on a different domain.

### Bootstrapping `.env`

`.env` is gitignored. Create it from the template before your first `chezmoi apply`:

```bash
cp .env.template .env
# edit .env if your OP_ACCOUNT domain differs
direnv allow
```

After `direnv allow`, `OP_ACCOUNT` is available in your shell whenever you are inside the repo directory. New worktrees created with `wtp add` inherit the same `.env` via the symlink hook and run `direnv allow` automatically.

### Sandbox read gotcha

In some environments (notably Claude Code's agent sandbox), `.env` and `.envrc` may be permission-blocked for Read or Bash tool calls. To inspect these files without hitting permission errors, use `git show`:

```bash
git show HEAD:.env.template   # view the committed template
git show HEAD:.envrc           # view the envrc (single line: dotenv)
```

`.env` itself is gitignored and cannot be read via `git show`; read the working-copy file directly if you have filesystem access, or infer its contents from `.env.template`.

---

## Project-scoped MCP server

`.mcp.json` declares the MCP server that is active when Claude Code or Codex works in this repo:

```json
{
  "mcpServers": {
    "spec-workflow": {
      "command": "npx",
      "args": ["-y", "@pimzino/spec-workflow-mcp@latest", "."]
    }
  }
}
```

`spec-workflow` provides the spec-driven development workflow tooling (`/spec-workflow`, `/approvals`, etc.). It is project-scoped — it only activates when the agent's working directory is this repo.

Note: `context7` and `deepwiki` were previously declared in `.mcp.json` and have since been moved to user scope (installed via `run_onchange_after_13-setup-mcp.sh.tmpl`). The project `.mcp.json` keeps only the project-specific `spec-workflow` server.

The `.spec-workflow/` directory created by the MCP server is gitignored. The wtp symlink hook shares it across worktrees so spec state is accessible regardless of which worktree you are working in.

---

## Cross-references

- Makefile targets and lint: [local-dev.md](local-dev.md)
- CI and tests: [ci-and-tests.md](ci-and-tests.md)
- 1Password secrets and `onepasswordRead`: [../getting-started/secrets-1password.md](../getting-started/secrets-1password.md)
- chezmoi apply and source structure: [../architecture/chezmoi-engine.md](../architecture/chezmoi-engine.md)
