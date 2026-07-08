# Account Isolation

🌐 日本語: [account-isolation.ja.md](account-isolation.ja.md)

← [Docs index](../README.md)

This page is the reference for how personal and r06 (work) accounts are kept isolated across Claude Code and Codex CLI.
The core principle is: **config shared via symlinks, state isolated via environment variables**.

---

## Environment variable table

The table below lists every per-account directory variable and its value for each account.
These variables are set inline on the agent subprocess — they are never exported into the general shell environment.

| Variable | Personal (default) account | Work (r06) account |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | `~/.claude-r06` |
| `ECC_AGENT_DATA_HOME` | `~/.claude` | `~/.claude-r06` |
| `CLV2_HOMUNCULUS_DIR` | `~/.claude/ecc-homunculus` | `~/.claude-r06/ecc-homunculus` |
| `ECC_MCP_HEALTH_STATE_PATH` | `~/.claude/mcp-health-cache.json` | `~/.claude-r06/mcp-health-cache.json` |
| `GATEGUARD_STATE_DIR` | `~/.claude/.gateguard` | `~/.claude-r06/.gateguard` |
| `CODEX_HOME` | (default — `~/.codex`) | `~/.codex-r06` |

The r06 Claude config directory (`~/.claude-r06`) contains only symlinks pointing back to `~/.claude` for every config artifact (settings, agents, commands, skills). What differs between accounts is entirely in the state that these env vars direct the tools to write.

---

## Alias matrix

These are the user-facing entry points. Each alias corresponds to one cell in the 2 × 2 harness × account matrix.

| Alias | Harness | Account | Effect |
|---|---|---|---|
| `cld` | Claude Code | Personal | Runs `claude` with default-account env set |
| `cld-r06` | Claude Code | Work (r06) | Runs `claude` with r06 env set |
| `hcld` | Claude Code (happy-wrapped) | Personal | Runs `happy claude` with default-account env |
| `hcld-r06` | Claude Code (happy-wrapped) | Work (r06) | Runs `happy claude` with r06 env |
| `claude-config` | Claude Code | Personal | Disables ECC config-protection + gateguard-fact-force gates; for intentional config edits |
| `cldf` | Claude Code | Personal | Runs `claude --model claude-fable-5` with the [Fable 5 orchestrator prompt](#fable-5-orchestrator-cldf-family) — main session runs on Fable 5, delegates execution to Sonnet subagents |
| `cldf-r06` | Claude Code | Work (r06) | `cldf` on the r06 account |
| `hcldf` | Claude Code (happy-wrapped) | Personal | `cldf` through the happy wrapper |
| `hcldf-r06` | Claude Code (happy-wrapped) | Work (r06) | `cldf` on the r06 account through the happy wrapper |
| `cdx` | Codex CLI | Personal | Runs `codex --profile shared` (default `~/.codex`) |
| `cdx-r06` | Codex CLI | Work (r06) | Runs `CODEX_HOME=$HOME/.codex-r06 codex --profile shared` |
| `hcdx` | Codex CLI (happy-wrapped) | Personal | Runs `happy codex --profile shared` |
| `hcdx-r06` | Codex CLI (happy-wrapped) | Work (r06) | Runs `CODEX_HOME=$HOME/.codex-r06 happy codex --profile shared` |

`happy`'s own state (`~/.happy`, i.e. `HAPPY_HOME_DIR` default) is intentionally **shared** across accounts — one phone pairing controls all accounts. Only the inner claude/codex environment is per-account.

---

## Fable 5 orchestrator (`cldf` family)

The `cldf` / `cldf-r06` / `hcldf` / `hcldf-r06` aliases start Claude Code in an **orchestrator configuration**: the main session runs on `claude-fable-5` for overview / planning / synthesis, and task execution is steered into Sonnet subagents. They wrap `_claude_with_home` (same account-isolation environment as `cld` family) with a thin `_claude_fable` helper that:

- pins the main model to the full ID `--model claude-fable-5` (not the `fable` alias, so the delegation prompt's Sonnet-5-era guidance and the main model generation never silently drift apart), and
- appends `home/dot_claude/fable-orchestrator-prompt.md` (deployed to `~/.claude/fable-orchestrator-prompt.md`) as the system prompt when the file is readable. When the file is absent (before `chezmoi apply` or after manual removal) the session still starts, just without the orchestrator prompt.

The prompt file is deliberately kept at `~/.claude/…` and read by both accounts via that absolute path — same "default account dir shared across accounts" precedent as `hooks-fork/`.

`CLAUDE_CODE_SUBAGENT_MODEL` is deliberately **not** set. That environment variable outranks per-invocation `model` params and agent frontmatter, which would collapse the "escalate a hard verification to Fable" escape hatch. The orchestrator prompt steers subagent model choice instead (default `model: sonnet`, upgrade to `fable` only for hard verification, note that `subagent_type: "fork"` always inherits the parent model).

Source: `home/dot_config/zsh/claude.zsh` (`_claude_fable` helper).

---

## `_claude_with_home`: how Claude Code account selection works

The Claude Code aliases all call a single zsh helper function `_claude_with_home`:

```zsh
_claude_with_home() {
  local home_dir="$1"
  shift
  (($#)) || set -- claude
  CLAUDE_CONFIG_DIR="$home_dir" \
    ECC_AGENT_DATA_HOME="$home_dir" \
    CLV2_HOMUNCULUS_DIR="$home_dir/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    "$@"
}
```

Key properties:

- The env vars are **inline-scoped** to the `"$@"` subprocess only. They are not exported into the parent shell.
- `EXA_API_KEY` and `FIRECRAWL_API_KEY` are re-exported scoped to the subprocess so Claude Code's MCP servers can expand the `${EXA_API_KEY}` placeholder from the process environment. The source values come from the `~/.config/zsh/claude-secrets.zsh` file (a 0600 file rendered from 1Password at `chezmoi apply` time, sourced but not exported).
- `cld` passes `"$HOME/.claude"` as `home_dir`; `cld-r06` passes `"$HOME/.claude-r06"`.

Source: `home/dot_config/zsh/claude.zsh`.

---

## Critical: always use the aliases

Running the bare binary name bypasses the account machinery entirely:

| Bare invocation | What is missing |
|---|---|
| `claude` | No `CLAUDE_CONFIG_DIR` — falls back to `~/.claude`; `ECC_AGENT_DATA_HOME` unset |
| `codex` | No `--profile shared` — `$CODEX_HOME/shared.config.toml` not loaded |

The bare `claude` invocation is not an error, but it silently uses the default account dirs and ignores the ECC/CLV2/gateguard state isolation that the aliases provide. For `codex`, the SSOT model, personality, and multi-agent feature configuration are all absent when invoked bare.

---

## See also

- [overview.md](overview.md) — harness × account architecture overview
- [claude-code.md](claude-code.md) — Claude Code hooks, ECC, CLV2 observer
- [codex.md](codex.md) — Codex CLI profile config, hooks
- [secrets-1password.md](../getting-started/secrets-1password.md) — how API keys are rendered from 1Password into 0600 files
