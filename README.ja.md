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

> **macOS (Apple Silicon)** または **Ubuntu** と **[1Password](https://1password.com/)** (SSH Agent + CLI) が必要です。

新規マシンの場合（`curl` と `bash` 以外の前提条件は不要）：

```bash
# 実行前にスクリプトの内容を確認: https://github.com/kryota-dev/dotfiles/blob/main/install/install.sh
bash <(curl -fsLS https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install/install.sh)
```

chezmoi がインストール済みの場合：

```bash
chezmoi init --apply kryota-dev
```

ライフサイクルスクリプトが前提条件のインストール、Homebrew パッケージ、macOS 設定を自動的に処理します（フォントは chezmoi external でデプロイされます）。

1Password の必須 vault item と `chezmoi apply` のゲートについては
[1Password シークレットの初期設定](docs/getting-started/secrets-1password.ja.md) を参照してください。

## ドキュメント

詳細なドキュメントは [`docs/`](docs/README.ja.md) にあります（英語が正、日本語 `*.ja.md` はミラー）。
[ドキュメント目次](docs/README.ja.md) から辿れます:

- **はじめに:** [インストール](docs/getting-started/installation.ja.md) · [検証](docs/getting-started/verification.ja.md) · [1Password シークレット](docs/getting-started/secrets-1password.ja.md)
- **アーキテクチャ:** [概要](docs/architecture/overview.ja.md) · [chezmoi エンジン](docs/architecture/chezmoi-engine.ja.md) · [externals & pinning](docs/architecture/externals-and-pinning.ja.md) · [ライフサイクルスクリプト](docs/architecture/lifecycle-scripts.ja.md) · [シェル環境](docs/architecture/shell-environment.ja.md) · [開発ツール](docs/architecture/dev-tooling.ja.md)
- **AI エージェント:** [概要](docs/agents/overview.ja.md) · [アカウント分離](docs/agents/account-isolation.ja.md) · [Claude Code](docs/agents/claude-code.ja.md) · [Codex](docs/agents/codex.ja.md) · [skill provenance](docs/agents/skills-provenance.ja.md)
- **コントリビュート:** [ローカル開発](docs/contributing/local-dev.ja.md) · [CI & テスト](docs/contributing/ci-and-tests.ja.md) · [worktree & 環境](docs/contributing/worktrees-and-env.ja.md)
- **解説:** [設計判断](docs/explanation/design-rationale.ja.md) · [シークレットと分離](docs/explanation/secrets-and-isolation.ja.md)

## アーキテクチャ

### リポジトリ構成

```
dotfiles/
├── .chezmoiroot              # ソースルート → home/
├── install/                   # ブートストラップスクリプト
├── home/
│   ├── .chezmoidata.toml     # テンプレートデータ（email、signingkey、name、ghq_user、versions、skills）
│   ├── dot_zshrc.tmpl        # 最小コア、sheldon 駆動
│   ├── dot_config/
│   │   ├── chezmoi/          # chezmoi 挙動設定（自動 deploy）
│   │   ├── ghostty/          # ターミナル設定
│   │   ├── mise/             # ツールバージョンマネージャー
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

### 詳細

zsh の起動モデル、ライフサイクルの適用タイムライン、chezmoi エンジン、externals の pinning、
開発ツールについては [アーキテクチャドキュメント](docs/architecture/overview.ja.md) を参照してください:

- [シェル環境](docs/architecture/shell-environment.ja.md) — `.zprofile` → `.zshrc` → sheldon/zsh-defer、モジュール
- [ライフサイクルスクリプト](docs/architecture/lifecycle-scripts.ja.md) — 番号順の `run_once_*` / `run_onchange_*` 適用タイムライン
- [chezmoi エンジン](docs/architecture/chezmoi-engine.ja.md) · [externals & pinning](docs/architecture/externals-and-pinning.ja.md) · [開発ツール](docs/architecture/dev-tooling.ja.md)

## Claude Code

AI ネイティブ開発環境 — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) と [Codex](https://openai.com/index/introducing-codex/) の設定、カスタムスキル、エージェントを chezmoi 経由で dotfiles として宣言的に管理します。スキルは `home/dot_agents/skills/` に一元管理し、`~/.claude/skills` と `~/.codex/skills` にシンボリックリンクで配布します。

[`docs/agents/`](docs/agents/overview.ja.md) で dual-harness × dual-account モデル、
[アカウント分離](docs/agents/account-isolation.ja.md)、[skill provenance 分類](docs/agents/skills-provenance.ja.md) を解説しています。

## 開発

| コマンド | 説明 |
|---------|------|
| `make help` | 利用可能なターゲットを一覧表示（デフォルトターゲット） |
| `make lint` | shellcheck + shfmt + zsh 構文チェック |
| `make fmt` | shfmt でシェルスクリプトを整形 |
| `make test` | lint + Bats テストを実行 |
| `make benchmark` | zsh 起動時間を計測 |
| `make dump-brewfile` | 現在の Homebrew パッケージをエクスポート |
| `make sync-ghq-completion` | vendoring した `_ghq` 補完を更新 |

> 適用と差分確認は chezmoi を直接実行します: `chezmoi apply -v` / `chezmoi diff`。

**CI パイプライン:**
- **CI** (`ci.yml`): Lint + Test (`make lint` / `make test-bats`) + ghq 補完同期 — すべて ubuntu-latest
- **Setup Validation** (`setup-validation.yml`): macOS と Ubuntu/Linuxbrew でのエンドツーエンド `chezmoi apply`
- **Benchmark** (`benchmark.yml`): 週次 cron + 手動 dispatch (macOS)

bats スイートのマップ、検証マトリクス、`make` コントラクト全体は
[CI & テスト](docs/contributing/ci-and-tests.ja.md) と [ローカル開発](docs/contributing/local-dev.ja.md) を参照してください。

## ライセンス

[MIT](LICENSE)

<!-- badge references -->
[ci-badge]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/kryota-dev/dotfiles/actions/workflows/ci.yml
[chezmoi-badge]: https://img.shields.io/badge/managed%20with-chezmoi-blue
[zsh-badge]: https://img.shields.io/badge/shell-zsh-informational
[macos-badge]: https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple
[mit-badge]: https://img.shields.io/badge/license-MIT-green
