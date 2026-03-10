# dotfiles

chezmoi による宣言的な macOS (Apple Silicon) 開発環境。

[![CI][ci-badge]][ci-url] ![chezmoi][chezmoi-badge] ![shell: zsh][zsh-badge] ![macOS][macos-badge] [![MIT][mit-badge]](LICENSE)

> **[English](README.md)** | 日本語

<!-- TODO: add terminal screenshot
<p align="center">
  <img src="docs/screenshot.png" width="720" alt="ターミナルスクリーンショット" />
</p>
<p align="center">
  <sub>Ghostty · Starship (Catppuccin Mocha) · Moralerspace Neon</sub>
</p>
-->

## 特徴

- **[chezmoi](https://chezmoi.io/)** — テンプレート駆動の dotfiles 管理、対話式シークレットプロンプト
- **[sheldon](https://sheldon.cli.rs/) + [zsh-defer](https://github.com/romkatv/zsh-defer)** — 最小限の `.zshrc` コアと遅延読み込みによるモジュール構成
- **[starship](https://starship.rs/)** — Catppuccin Mocha テーマの2行プロンプト
- **[Ghostty](https://ghostty.org/)** — Moralerspace Neon フォント
- **1Password CLI** — SSH 署名、コミット検証
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — スキルとエージェントを dotfiles として管理
- **[mise](https://mise.jdx.dev/)** — 統合ツール/ランタイムバージョンマネージャー (Node, Python, Ruby, Go, CLI ツール)
- **Homebrew** — システムパッケージ、GUI アプリ、ライブラリの管理
- **GitHub Actions** — shellcheck、shfmt、Bats テスト、zsh 起動ベンチマーク

## はじめに

> **macOS (Apple Silicon)** と **[1Password](https://1password.com/)** (SSH Agent + CLI) が必要です。

```bash
chezmoi init --apply kryota-dev
```

ライフサイクルスクリプトが前提条件のインストール、Homebrew パッケージ、フォント、macOS 設定を自動的に処理します。

## アーキテクチャ

### リポジトリ構成

```
dotfiles/
├── .chezmoiroot              # ソースルート → home/
├── home/
│   ├── .chezmoi.toml         # chezmoi 設定（email、signingkey）
│   ├── dot_zshrc.tmpl        # 最小コア、sheldon 駆動
│   ├── dot_config/
│   │   ├── ghostty/          # ターミナル設定
│   │   ├── mise/              # ツールバージョンマネージャー
│   │   ├── sheldon/          # プラグインマネージャー
│   │   ├── starship.toml     # プロンプトテーマ
│   │   └── zsh/              # 遅延読み込みシェルモジュール
│   ├── AGENTS.md             # 共有 AI エージェント指示
│   ├── dot_claude/           # Claude Code 設定 & エージェント
│   ├── dot_codex/            # Codex 設定
│   ├── dot_agents/skills/    # 共有 AI スキル (シンボリックリンク)
│   ├── run_once_before_*     # 初回セットアップ
│   ├── run_onchange_after_*  # 内容変更時に再実行
│   ├── run_once_after_*      # 1回限りのセットアップ後処理
│   └── ...
├── tests/                    # Bats テストスイート
├── scripts/                  # ベンチマークユーティリティ
├── Makefile                  # 開発コマンド
└── LICENSE
```

### Zsh アーキテクチャ

`.zshrc` は最小限のコアで、すべてのプラグインとモジュールの読み込みを sheldon に委譲し、zsh-defer で非同期初期化を行います：

```
.zprofile                     Homebrew PATH、環境変数
    ↓
.zshrc (最小コア)              setopt、PATH、mise、direnv、starship
    ↓
sheldon source                zsh-defer がすべてを非同期に読み込み
    ├── コミュニティプラグイン   autosuggestions、syntax-highlighting、completions
    └── ローカルモジュール ──→  aliases、git、docker、claude、...
```

| モジュール | 説明 |
|-----------|------|
| `aliases.zsh` | 汎用エイリアス (ll, vi, pn 等) |
| `git.zsh` | Git エイリアス & 関数 |
| `docker.zsh` | Docker / Compose エイリアス |
| `claude.zsh` | Claude Code ユーティリティ |
| `functions.zsh` | 汎用ユーティリティ (yazi, mduch) |
| `completions.zsh` | 補完設定 |
| `wtp.zsh` | wtp 補完 & cd フック |

### ライフサイクルスクリプト

chezmoi はライフサイクルスクリプトによってセットアップを統制します — `run_once` スクリプトは初回適用時に実行され、`run_onchange` スクリプトは追跡対象の内容が変更されたときに再実行されます：

| フェーズ | スクリプト | トリガー | 説明 |
|---------|-----------|---------|------|
| 1 | `00-install-prerequisites` | once (before) | Xcode CLI ツール、Homebrew |
| 2 | `10-brew-bundle` | on change | Brewfile によるパッケージインストール |
| 2.5 | `11-validate-1password` | once (after) | 1Password CLI の検証 |
| 3 | `12-setup-mise` | on change | mise 管理ツールのインストール |
| 4 | `20-macos-defaults` | on change | Finder、Dock、キーボード等 |
| 5 | `30-setup-fonts` | once (after) | Moralerspace Neon |
| 6 | `40-setup-sheldon` | once (after) | プラグインバージョンのロック |
| 7 | `90-other-apps` | once (after) | 対話式アプリダウンロード |

## Claude Code

AI ネイティブ開発環境 — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) と [Codex](https://openai.com/index/introducing-codex/) の設定、カスタムスキル、エージェントを chezmoi 経由で dotfiles として宣言的に管理します。スキルは `home/dot_agents/skills/` に一元管理し、`~/.claude/skills` と `~/.codex/skills` にシンボリックリンクで配布します。

## 開発

| コマンド | 説明 |
|---------|------|
| `make apply` | dotfiles を適用 |
| `make diff` | 保留中の変更をプレビュー |
| `make watch` | ファイル変更時に自動適用 |
| `make test` | lint + Bats テストを実行 |
| `make lint` | shellcheck + shfmt + zsh 構文チェック |
| `make benchmark` | zsh 起動時間を計測 |
| `make dump-brewfile` | 現在の Homebrew パッケージをエクスポート |

**CI パイプライン:** Lint (ubuntu) → Test (macos) → Benchmark (macos, main のみ)

## ライセンス

[MIT](LICENSE)

<!-- badge references -->
[ci-badge]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml
[chezmoi-badge]: https://img.shields.io/badge/managed%20with-chezmoi-blue
[zsh-badge]: https://img.shields.io/badge/shell-zsh-informational
[macos-badge]: https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple
[mit-badge]: https://img.shields.io/badge/license-MIT-green
