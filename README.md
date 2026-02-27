# dotfiles

Declarative macOS (Apple Silicon) development environment powered by chezmoi.

[![CI][ci-badge]][ci-url] ![chezmoi][chezmoi-badge] ![shell: zsh][zsh-badge] ![macOS][macos-badge] [![MIT][mit-badge]](LICENSE)

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
- **1Password CLI** — SSH signing, commit verification
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — skills & agents managed as dotfiles
- **Homebrew** — declarative package management via Brewfile
- **GitHub Actions** — shellcheck, shfmt, Bats tests, zsh startup benchmark

## Getting Started

> Requires **macOS (Apple Silicon)** and **[1Password](https://1password.com/)** (SSH Agent + CLI).

```bash
chezmoi init --apply kryota-dev
```

On first run, chezmoi will prompt for your Git email and SSH signing key path.
Lifecycle scripts automatically handle prerequisites, Homebrew packages, fonts, and macOS defaults.

## Architecture

### Repository Structure

```
dotfiles/
├── .chezmoiroot              # source root → home/
├── home/
│   ├── .chezmoi.toml.tmpl    # interactive config prompts
│   ├── dot_zshrc.tmpl        # minimal core, sheldon-powered
│   ├── dot_config/
│   │   ├── ghostty/          # terminal config
│   │   ├── sheldon/          # plugin manager
│   │   ├── starship.toml     # prompt theme
│   │   └── zsh/              # deferred shell modules
│   ├── dot_claude/           # AI skills & agents
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
.zprofile                     Homebrew PATH, rbenv, env vars
    ↓
.zshrc (minimal core)         setopt, PATH, direnv, starship
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
| `brew-helpers.zsh` | Brewfile management helpers |
| `completions.zsh` | Completion settings |
| `wtp.zsh` | wtp completions & cd hooks |

### Lifecycle Scripts

chezmoi orchestrates setup through lifecycle scripts — `run_once` scripts execute on first apply, while `run_onchange` scripts re-run when their tracked content changes:

| Phase | Script | Trigger | Description |
|-------|--------|---------|-------------|
| 1 | `00-install-prerequisites` | once (before) | Xcode CLI tools, Homebrew |
| 2 | `01-install-1password-cli` | once (before) | 1Password CLI |
| 3 | `10-brew-bundle` | on change | Install packages via Brewfile |
| 4 | `20-macos-defaults` | on change | Finder, Dock, keyboard, etc. |
| 5 | `30-setup-fonts` | once (after) | Moralerspace Neon |
| 6 | `40-setup-sheldon` | once (after) | Lock plugin versions |
| 7 | `90-other-apps` | once (after) | Interactive app downloads |

## Claude Code

AI-native development environment — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) settings, custom skills, and agents are managed declaratively as dotfiles via chezmoi. See `home/dot_claude/` for details.

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
