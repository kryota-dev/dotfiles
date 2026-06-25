# dotfiles

Declarative macOS (Apple Silicon) development environment powered by chezmoi.

[![CI][ci-badge]][ci-url] ![chezmoi][chezmoi-badge] ![shell: zsh][zsh-badge] ![macOS][macos-badge] [![MIT][mit-badge]](LICENSE)

> English | **[日本語](README.ja.md)**

<!-- TODO: add terminal screenshot
<p align="center">
  <img src="docs/screenshot.png" width="720" alt="Terminal screenshot" />
</p>
<p align="center">
  <sub>Ghostty · Starship (Catppuccin Mocha) · Moralerspace Neon</sub>
</p>
-->

## Highlights

- **[chezmoi](https://chezmoi.io/)** — template-driven dotfiles with interactive secret prompts
- **[sheldon](https://sheldon.cli.rs/) + [zsh-defer](https://github.com/romkatv/zsh-defer)** — minimal `.zshrc` core with lazy-loaded modular config
- **[starship](https://starship.rs/)** — Catppuccin Mocha themed two-line prompt
- **[Ghostty](https://ghostty.org/)** — Moralerspace Neon font
- **1Password CLI** — SSH signing, commit verification, secret management
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — skills & agents managed as dotfiles
- **[mise](https://mise.jdx.dev/)** — unified tool/runtime version manager (Node, Python, Ruby, Go, CLI tools)
- **Homebrew** — system packages, GUI apps, and libraries via Brewfile
- **GitHub Actions** — shellcheck, shfmt, Bats tests, zsh startup benchmark

## Getting Started

> Requires **macOS (Apple Silicon)** or **Ubuntu** and **[1Password](https://1password.com/)** (SSH Agent + CLI).

On a fresh machine (no prerequisites needed beyond `curl` and `bash`):

```bash
# Review the script before running: https://github.com/kryota-dev/dotfiles/blob/main/install/install.sh
bash <(curl -fsLS https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install/install.sh)
```

If chezmoi is already installed:

```bash
chezmoi init --apply kryota-dev
```

Lifecycle scripts automatically handle prerequisites, Homebrew packages, fonts, and macOS defaults.

### 1Password Secret Setup

Sensitive files (AWS config) are stored as [1Password Secure Notes](https://developer.1password.com/docs/cli/) and rendered via chezmoi templates at apply time. Before running `chezmoi apply`, ensure:

1. **1Password desktop app** is installed with CLI integration enabled (Settings > Developer > Integrate with 1Password CLI)
2. The following Secure Notes exist in the `kryota.dev` vault:

   | Item Title | Content |
   |-----------|---------|
   | `Dotfiles - AWS Config` | `~/.aws/config` content |

See [1Password secrets onboarding](docs/getting-started/secrets-1password.md) for the full
list of required vault items and how `chezmoi apply` gates on them.

## Documentation

Full documentation lives in [`docs/`](docs/README.md) — English canonical with Japanese
(`*.ja.md`) mirrors. Start at the [docs index](docs/README.md):

- **Getting started:** [installation](docs/getting-started/installation.md) · [verification](docs/getting-started/verification.md) · [1Password secrets](docs/getting-started/secrets-1password.md)
- **Architecture:** [overview](docs/architecture/overview.md) · [chezmoi engine](docs/architecture/chezmoi-engine.md) · [externals & pinning](docs/architecture/externals-and-pinning.md) · [lifecycle scripts](docs/architecture/lifecycle-scripts.md) · [shell environment](docs/architecture/shell-environment.md) · [dev tooling](docs/architecture/dev-tooling.md)
- **AI agents:** [overview](docs/agents/overview.md) · [account isolation](docs/agents/account-isolation.md) · [Claude Code](docs/agents/claude-code.md) · [Codex](docs/agents/codex.md) · [skill provenance](docs/agents/skills-provenance.md)
- **Contributing:** [local dev](docs/contributing/local-dev.md) · [CI & tests](docs/contributing/ci-and-tests.md) · [worktrees & env](docs/contributing/worktrees-and-env.md)
- **Explanation:** [design rationale](docs/explanation/design-rationale.md) · [secrets & isolation](docs/explanation/secrets-and-isolation.md)

## Architecture

### Repository Structure

```
dotfiles/
├── .chezmoiroot              # source root → home/
├── install/                   # bootstrap script
├── home/
│   ├── .chezmoidata.toml     # template data (email, signingkey, name, ghq_user, versions, skills)
│   ├── dot_zshrc.tmpl        # minimal core, sheldon-powered
│   ├── dot_config/
│   │   ├── chezmoi/          # chezmoi behavior config (auto-deployed)
│   │   ├── ghostty/          # terminal config
│   │   ├── mise/             # tool version manager
│   │   ├── sheldon/          # plugin manager
│   │   ├── starship.toml     # prompt theme
│   │   └── zsh/              # deferred shell modules
│   ├── AGENTS.md             # shared AI agent instructions
│   ├── dot_claude/           # Claude Code settings & agents
│   ├── dot_codex/            # Codex settings
│   ├── dot_agents/skills/    # shared AI skills (symlinked)
│   ├── run_once_before_*     # first-time setup
│   ├── run_onchange_after_*  # re-run on content change
│   ├── run_once_after_*      # one-time post-setup
│   └── ...
├── tests/                    # Bats test suite
├── scripts/                  # benchmark utilities
├── Makefile                  # development commands
└── LICENSE
```

### Deep dives

For the zsh startup model, the full lifecycle apply timeline, the chezmoi engine,
externals pinning, and dev tooling, see the [architecture docs](docs/architecture/overview.md):

- [Shell environment](docs/architecture/shell-environment.md) — `.zprofile` → `.zshrc` → sheldon/zsh-defer, modules
- [Lifecycle scripts](docs/architecture/lifecycle-scripts.md) — the numbered `run_once_*` / `run_onchange_*` apply timeline
- [chezmoi engine](docs/architecture/chezmoi-engine.md) · [externals & pinning](docs/architecture/externals-and-pinning.md) · [dev tooling](docs/architecture/dev-tooling.md)

## Claude Code

AI-native development environment — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) settings, custom skills, and agents are managed declaratively as dotfiles via chezmoi. Skills are centralized in `home/dot_agents/skills/` and symlinked to both `~/.claude/skills` and `~/.codex/skills`.

See [`docs/agents/`](docs/agents/overview.md) for the dual-harness × dual-account model,
[account isolation](docs/agents/account-isolation.md), and the
[skill provenance taxonomy](docs/agents/skills-provenance.md).

## Development

| Command | Description |
|---------|-------------|
| `make help` | List available targets (default target) |
| `make lint` | shellcheck + shfmt + zsh syntax |
| `make fmt` | Format shell scripts with shfmt |
| `make test` | Run lint + Bats tests |
| `make benchmark` | Measure zsh startup time |
| `make dump-brewfile` | Export current Homebrew packages |
| `make sync-ghq-completion` | Refresh vendored `_ghq` completion |

> Applying and diffing are done with chezmoi directly: `chezmoi apply -v`, `chezmoi diff`.

**CI pipelines:**
- **CI** (`ci.yml`): Lint (ubuntu) → Test (macos) → Benchmark (macos, main only)
- **Setup Validation** (`setup-validation.yml`): chezmoi apply → mise install → file verification → zsh startup (macos)

See [CI & tests](docs/contributing/ci-and-tests.md) and [local dev](docs/contributing/local-dev.md)
for the bats suite map, the validation matrix, and the full `make` contract.

## License

[MIT](LICENSE)

<!-- badge references -->
[ci-badge]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml
[chezmoi-badge]: https://img.shields.io/badge/managed%20with-chezmoi-blue
[zsh-badge]: https://img.shields.io/badge/shell-zsh-informational
[macos-badge]: https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple
[mit-badge]: https://img.shields.io/badge/license-MIT-green
