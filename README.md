# dotfiles

macOS 開発環境を chezmoi で宣言的に管理するdotfilesリポジトリ。

## Features

- **[chezmoi](https://chezmoi.io/)** によるdotfiles管理（テンプレート・シークレット対応）
- **[sheldon](https://sheldon.cli.rs/)** + **zsh-defer** によるzshプラグイン遅延ロード
- **[starship](https://starship.rs/)** プロンプト
- **[Ghostty](https://ghostty.org/)** ターミナル設定
- **1Password CLI** 連携（SSH signing・シークレット管理）
- **Bats** テスト + **shellcheck** / **shfmt** による品質保証
- **GitHub Actions** CI（lint・test・ベンチマーク）
- **Claude Code** / **Codex** AI設定の統合管理

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install/install.sh)"
```

## Requirements

- macOS (Apple Silicon)
- 1Password（SSH Agent + CLI）

## Structure

```
dotfiles/
├── .chezmoiroot        # chezmoi source root → home/
├── home/               # chezmoi managed dotfiles
│   ├── dot_zshrc.tmpl  # zsh config (~25 lines, sheldon-powered)
│   ├── dot_config/
│   │   ├── ghostty/    # Ghostty terminal config
│   │   ├── sheldon/    # sheldon plugin manager
│   │   ├── starship.toml
│   │   └── zsh/        # zsh modules (8 files)
│   ├── dot_claude/     # Claude Code settings & skills
│   ├── run_once_*      # Auto-setup scripts
│   └── ...
├── tests/              # Bats test suite
├── scripts/            # Benchmark & utility scripts
├── install/            # One-liner bootstrap
└── Makefile            # Development commands
```

## Usage

```bash
# Apply changes
make apply

# Show pending changes
make diff

# Run tests
make test

# Run linter
make lint

# Benchmark zsh startup
make benchmark

# Watch for changes and auto-apply
make watch

# Dump current brew packages
make dump-brewfile
```

## Zsh Architecture

`.zshrc` は ~25行のコアファイルで、sheldon + zsh-defer により8つのモジュールを遅延ロードする:

| Module | Description |
|--------|-------------|
| `aliases.zsh` | 一般エイリアス (ll, vi, pn, etc.) |
| `git.zsh` | Git エイリアス・関数 |
| `docker.zsh` | Docker / Compose エイリアス |
| `claude.zsh` | Claude Code 関連関数 |
| `functions.zsh` | 汎用関数 (yazi, mduch) |
| `brew-helpers.zsh` | Brewfile 管理ヘルパー |
| `completions.zsh` | 補完設定 |
| `wtp.zsh` | wtp 補完・cd フック |

## License

[MIT](LICENSE)
