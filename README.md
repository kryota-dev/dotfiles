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

> Requires **macOS (Apple Silicon)** and **[1Password](https://1password.com/)** (SSH Agent + CLI).

```bash
chezmoi init --apply kryota-dev
```

Lifecycle scripts automatically handle prerequisites, Homebrew packages, fonts, and macOS defaults.

### 1Password Secret Setup

Sensitive files (AWS config, agent skills) are stored as [1Password Secure Notes](https://developer.1password.com/docs/cli/) and rendered via chezmoi templates at apply time. Before running `chezmoi apply`, ensure:

1. **1Password desktop app** is installed with CLI integration enabled (Settings > Developer > Integrate with 1Password CLI)
2. The following Secure Notes exist in the `kryota.dev` vault:

   | Item Title | Content |
   |-----------|---------|
   | `Dotfiles - AWS Config` | `~/.aws/config` content |
   | `Dotfiles - Daily Planning Skill` | Daily planning SKILL.md content |

## Architecture

### Repository Structure

```
dotfiles/
├── .chezmoiroot              # source root → home/
├── home/
│   ├── .chezmoi.toml         # chezmoi config (email, signingkey)
│   ├── dot_zshrc.tmpl        # minimal core, sheldon-powered
│   ├── dot_config/
│   │   ├── ghostty/          # terminal config
│   │   ├── mise/              # tool version manager
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

### Zsh Architecture

`.zshrc` is a minimal core that delegates all plugin and module loading to sheldon with zsh-defer for async initialization:

```
.zprofile                     Homebrew PATH, env vars
    ↓
.zshrc (minimal core)         setopt, PATH, mise, direnv, starship
    ↓
sheldon source                zsh-defer loads everything async
    ├── community plugins     autosuggestions, syntax-highlighting, completions
    └── local modules ──→     aliases, git, docker, claude, ...
```

| Module | Description |
|--------|-------------|
| `aliases.zsh` | General aliases (ll, vi, pn, etc.) |
| `git.zsh` | Git aliases & functions |
| `docker.zsh` | Docker / Compose aliases |
| `claude.zsh` | Claude Code utilities |
| `functions.zsh` | General utilities (yazi, mduch) |
| `completions.zsh` | Completion settings |
| `wtp.zsh` | wtp completions & cd hooks |

### Lifecycle Scripts

chezmoi orchestrates setup through lifecycle scripts — `run_once` scripts execute on first apply, while `run_onchange` scripts re-run when their tracked content changes:

| Phase | Script | Trigger | Description |
|-------|--------|---------|-------------|
| 1 | `00-install-prerequisites` | once (before) | Xcode CLI tools, Homebrew |
| 2 | `10-brew-bundle` | on change | Install packages via Brewfile |
| 2.5 | `11-validate-1password` | once (after) | Validate 1Password CLI |
| 3 | `12-setup-mise` | on change | Install mise-managed tools |
| 4 | `20-macos-defaults` | on change | Finder, Dock, keyboard, etc. |
| 5 | `30-setup-fonts` | once (after) | Moralerspace Neon |
| 6 | `40-setup-sheldon` | once (after) | Lock plugin versions |
| 7 | `90-other-apps` | once (after) | Interactive app downloads |

## Claude Code

AI-native development environment — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) settings, custom skills, and agents are managed declaratively as dotfiles via chezmoi. Skills are centralized in `home/dot_agents/skills/` and symlinked to both `~/.claude/skills` and `~/.codex/skills`.

## Development

| Command | Description |
|---------|-------------|
| `make apply` | Apply dotfiles |
| `make diff` | Preview pending changes |
| `make watch` | Auto-apply on file changes |
| `make test` | Run lint + Bats tests |
| `make lint` | shellcheck + shfmt + zsh syntax |
| `make benchmark` | Measure zsh startup time |
| `make dump-brewfile` | Export current Homebrew packages |

**CI pipeline:** Lint (ubuntu) → Test (macos) → Benchmark (macos, main only)

## License

[MIT](LICENSE)

<!-- badge references -->
[ci-badge]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml
[chezmoi-badge]: https://img.shields.io/badge/managed%20with-chezmoi-blue
[zsh-badge]: https://img.shields.io/badge/shell-zsh-informational
[macos-badge]: https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple
[mit-badge]: https://img.shields.io/badge/license-MIT-green
