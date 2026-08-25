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
| `CLV2_HOMUNCULUS_DIR` | `~/.local/share/ecc-homunculus-default` | `~/.local/share/ecc-homunculus-r06` |
| `ECC_MCP_HEALTH_STATE_PATH` | `~/.claude/mcp-health-cache.json` | `~/.claude-r06/mcp-health-cache.json` |
| `GATEGUARD_STATE_DIR` | `~/.claude/.gateguard` | `~/.claude-r06/.gateguard` |
| `CODEX_HOME` | (default — `~/.codex`) | `~/.codex-r06` |

The r06 Claude config directory (`~/.claude-r06`) contains only symlinks pointing back to `~/.claude` for every config artifact (settings, agents, commands, skills). What differs between accounts is entirely in the state that these env vars direct the tools to write.

`CLV2_HOMUNCULUS_DIR` is the one directory that lives entirely outside `~/.claude` / `~/.claude-r06`, under `~/.local/share/`: Claude Code treats every path under the config dir as a sensitive file requiring interactive Write approval, and the CLV2 analysis session runs headless (`claude --model haiku --print`), so it could never grant that approval and every instinct write failed (issue #336). The other per-account vars (`CLAUDE_CONFIG_DIR`, `ECC_AGENT_DATA_HOME`, `ECC_MCP_HEALTH_STATE_PATH`, `GATEGUARD_STATE_DIR`) stay under the config dir because they are written directly by node/shell code rather than through Claude Code's Write tool, so they never hit that gate.

---

## Launcher command matrix

These are the user-facing entry points. `claude`/`cld` and `codex`/`cdx` all resolve to the same two wrapper *scripts* at `~/.local/launchers/{claude,codex}` — `cld`, `cld-r06`, `cdx`, and `cdx-r06` are symlinks to those scripts, and each wrapper dispatches its account-selection logic on `$0` (the name it was invoked as). Being real files on PATH rather than interactive-zsh-only aliases, they behave identically from any shell — interactive, a hook, launchd, or Claude Code's own Bash tool.

| Command | Harness | Account | Effect |
|---|---|---|---|
| `claude` / `cld` | Claude Code | Personal (fill-gaps) | Runs the mise-managed `claude` binary with the per-account env set; keeps an already-set `CLAUDE_CONFIG_DIR` (so a hook-spawned child stays on its parent session's account), else defaults to `~/.claude` |
| `cld-r06` | Claude Code | Work (r06) | Same wrapper; `CLAUDE_CONFIG_DIR` forced to `~/.claude-r06` unconditionally (override) |
| `claude-config` | Claude Code | Personal | zsh helper: disables ECC config-protection + gateguard-fact-force gates, then calls the `claude` wrapper; for intentional config edits |
| `cldf` | Claude Code | Personal | zsh helper: calls the `claude` wrapper with `--model claude-fable-5` and the [Fable 5 orchestrator prompt](#fable-5-orchestrator-cldf-family) — main session runs on Fable 5, delegates execution to Sonnet subagents |
| `cldf-r06` | Claude Code | Work (r06) | `cldf` on the r06 account |
| `codex` / `cdx` | Codex CLI | Follows `CLAUDE_CONFIG_DIR` (fill-gaps) | Runs the brew-managed `codex` binary with `--profile main` injected unless argv already carries `--profile`; `CODEX_HOME` follows `CLAUDE_CONFIG_DIR` when set (`~/.codex-r06` for a `.claude-r06` dir, else `~/.codex`), otherwise respects an explicit `CODEX_HOME` or defaults to `~/.codex` |
| `cdx-r06` | Codex CLI | Work (r06) | Same wrapper; `CODEX_HOME` forced to `~/.codex-r06` unconditionally (override); `--profile main` still injected |

For the personal account, `claude` and `cld` are literally the same file reached by two names — the wrapper's `$0` dispatch has a branch only for `cld-r06`, not for `cld` — so there is no isolation difference between them; the same holds for `codex`/`cdx`. The short names exist for symmetry with the `-r06` forms and muscle memory, not because the bare name is missing anything (see [Bare invocations are no longer a gap](#bare-invocations-are-no-longer-a-gap)).

---

## Fable 5 orchestrator (`cldf` family)

The `cldf` / `cldf-r06` aliases start Claude Code in an **orchestrator configuration**: the main session runs on `claude-fable-5` for overview / planning / synthesis, and task execution is steered into Sonnet subagents. They wrap the `claude` wrapper (same account-isolation environment as bare `claude`/`cld`) with a thin `_claude_fable` helper that:

- pins the main model to the full ID `--model claude-fable-5` (not the `fable` alias, so the delegation prompt's Sonnet-5-era guidance and the main model generation never silently drift apart), and
- points at `home/dot_claude/fable-orchestrator-prompt.md` (deployed to `~/.claude/fable-orchestrator-prompt.md`) via `--append-system-prompt-file <path>` when the file is readable. The path (not the content) is passed to the CLI, which reads the file at process start — this keeps the prompt body out of argv even as the prompt grows. When the file is absent (before `chezmoi apply` or after manual removal) the session still starts, just without the orchestrator prompt.

The prompt file is deliberately kept at `~/.claude/…` and read by both accounts via that absolute path — same "default account dir shared across accounts" precedent as `hooks-fork/`.

`CLAUDE_CODE_SUBAGENT_MODEL` is deliberately **not** set. That environment variable outranks per-invocation `model` params and agent frontmatter, which would collapse the "escalate a hard verification to Fable" escape hatch. The orchestrator prompt steers subagent model choice instead (default `model: sonnet`, upgrade to `fable` only for hard verification, note that `subagent_type: "fork"` always inherits the parent model).

Source: `home/dot_config/zsh/claude.zsh` (`_claude_fable` helper, which sets `CLAUDE_CONFIG_DIR` explicitly and calls the `claude` wrapper).

---

## The claude wrapper: how Claude Code account selection works

Per-account env injection for Claude Code lives in a single script, `~/.local/launchers/claude` (source: `home/dot_local/launchers/executable_claude`), reached as `claude` / `cld` / `cld-r06` — the latter two are symlinks to it, and the wrapper dispatches on `$0`:

```bash
case "${0##*/}" in
  cld-r06)
    # -r06 name: select the work account unconditionally (override).
    CLAUDE_CONFIG_DIR="$HOME/.claude-r06"
    ;;
  *)
    # claude / cld: fill-gaps only, so an inherited account survives.
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    ;;
esac

# ... derive homunculus_slug from the config-dir basename ...
# ... source claude-secrets.zsh unless the caller already decided EXA_API_KEY ...
# ... resolve the pin-correct mise-managed binary via `mise which claude` ...

export CLAUDE_CONFIG_DIR
export ECC_AGENT_DATA_HOME="$CLAUDE_CONFIG_DIR"
export CLV2_HOMUNCULUS_DIR="$HOME/.local/share/ecc-homunculus-${homunculus_slug}"
export ECC_MCP_HEALTH_STATE_PATH="$CLAUDE_CONFIG_DIR/mcp-health-cache.json"
export GATEGUARD_STATE_DIR="$CLAUDE_CONFIG_DIR/.gateguard"
export EXA_API_KEY="${EXA_API_KEY:-}"
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"

exec "$real" "$@"
```

Key properties:

- The wrapper is a short-lived script process: it exports the env vars into its own process, then `exec`s the real `claude` binary in place — nothing leaks into the interactive shell that launched it, because the wrapper process itself is replaced rather than spawning a child.
- The homunculus slug is derived from the config-dir basename in the same three branches `run_onchange_after_14` uses: `.claude` → `default`, `.claude-*` → the suffix, anything else → strip a leading dot.
- `EXA_API_KEY` and `FIRECRAWL_API_KEY` are sourced by the wrapper itself from `~/.config/zsh/claude-secrets.zsh` (a 0600 file rendered from 1Password at `chezmoi apply` time) — but only when the caller has not already decided the key (even to an empty value), which is what lets `morning-radar` opt out of web search by exporting an empty `EXA_API_KEY`. `claude.zsh` no longer sources this file itself.
- `real` is resolved via `mise which claude` (not via PATH, which would just re-resolve this same wrapper), so the pin-correct mise-managed binary always runs; `CLAUDE_LAUNCHER_BIN` overrides this for tests. If the real binary cannot be resolved, the wrapper fails loudly (exit 127) instead of silently running the wrong binary.

Source: `home/dot_local/launchers/executable_claude`.

---

## Bare invocations are no longer a gap

Before #345, running the bare binary name (`claude`, `codex`) bypassed the account machinery entirely — only the zsh aliases (`cld`, `cdx`, …) injected the per-account env and, for Codex, a managed profile. That gap is closed: `claude` and `codex` on PATH now resolve to the same wrapper scripts as `cld`/`cld-r06` and `cdx`/`cdx-r06`. This works because `~/.local/launchers` is kept ahead of both mise's shim directory and Homebrew's `bin` on PATH — a static prepend in `dot_zshrc.tmpl` plus a `precmd` hook registered *after* `mise activate` (mise re-prepends its own shim dir on every prompt via its own `precmd` hook, so this one must run after it and win) — and launchd's morning-radar script prepends the same directory to its own hard-coded PATH.

Being real files on PATH — not interactive-zsh-only aliases — the wrappers also work from contexts an alias never reached: a hook process, a launchd job, or a command Claude Code's own Bash tool runs. Because there is only one copy of the account-selection logic, the hand-copied env blocks a per-caller alias definition would have needed cannot drift between call sites.

The one remaining distinction is fill-gaps vs. override, not "wrapped vs. bare":

| Invocation | Behavior |
|---|---|
| `claude` / `cld` | Fill-gaps: keeps an already-set `CLAUDE_CONFIG_DIR` (e.g. inherited from a parent `cld-r06` session), else defaults to the personal account |
| `cld-r06` | Override: forces the work account regardless of anything inherited |
| `codex` / `cdx` | Fill-gaps: `CODEX_HOME` follows `CLAUDE_CONFIG_DIR` when set (authoritative — overrides even a mismatched inherited `CODEX_HOME`), else respects an explicit `CODEX_HOME` or defaults to `~/.codex` |
| `cdx-r06` | Override: forces `CODEX_HOME=~/.codex-r06` regardless of anything inherited |

---

## See also

- [overview.md](overview.md) — harness × account architecture overview
- [claude-code.md](claude-code.md) — Claude Code hooks, ECC, CLV2 observer
- [codex.md](codex.md) — Codex CLI profile config, hooks
- [secrets-1password.md](../getting-started/secrets-1password.md) — how API keys are rendered from 1Password into 0600 files
