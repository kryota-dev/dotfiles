# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

macOS向けdotfilesリポジトリ。**chezmoi**でホームディレクトリへの配置を管理する。
chezmoiのsource directoryは`home/`（`.chezmoiroot`で指定）。

## Commands

```bash
# dotfilesを適用
make apply          # chezmoi apply -v

# 差分確認
make diff           # chezmoi diff

# lint（shellcheck + shfmt + zsh syntax check）
make lint

# テスト（lint + bats）
make test

# batsテストのみ
make test-bats      # bats tests/*.bats

# 単一テストファイル
bats tests/files.bats

# shfmt自動修正
make fmt

# zsh起動ベンチマーク
make benchmark

# Brewfile更新
make dump-brewfile

# sheldonプラグイン再ロック
make sheldon-lock
```

## Architecture

### chezmoi source構造（`home/`）

chezmoiの命名規則に従う（`dot_` → `.`、`.tmpl` → テンプレート、`run_once_`/`run_onchange_` → スクリプト、`symlink_` → シンボリックリンク、`private_` → パーミッション制限）。

- **ライフサイクルスクリプト**（番号順に実行）:
  - `run_once_before_00-install-prerequisites.sh.tmpl` — Xcode CLI tools, Homebrew
  - `run_onchange_before_10-brew-bundle.sh.tmpl` — `dot_Brewfile`のハッシュ変更時にbrew bundle
  - `run_onchange_after_20-macos-defaults.sh.tmpl` — macOSシステム設定
  - `run_once_after_30-setup-fonts.sh.tmpl` — フォントインストール
  - `run_once_after_40-setup-sheldon.sh.tmpl` — sheldon lock
  - `run_once_after_90-other-apps.sh.tmpl` — その他アプリ設定

- **zsh設定**: `dot_zshrc.tmpl` → sheldon経由で `dot_config/zsh/*.zsh` をdeferred loadingで読み込み
- **テンプレート変数**: `.chezmoi.toml.tmpl` で `email` と `signingkey` をprompt
- **AIエージェント設定**: `dot_claude/`, `dot_codex/`, `dot_agents/skills/` — Claude/Codexの共有スキルは`dot_agents/skills/`に一元管理し、symlink経由で各ツールに配布

### Lint規約

- shellcheck: `--shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329`
- shfmt: `-i 2 -ci`（インデント2スペース、case indent）
- chezmoiテンプレート行（`{{`を含む行）はlint前に`sed`で除去
- zshファイル（`*.zsh`）は`zsh -n`で構文チェック

### テスト

Bats（Bash Automated Testing System）を使用。`tests/`ディレクトリに配置。
- `files.bats` — chezmoiソースファイルの存在確認
- `shellcheck.bats` — shellcheckパス確認
- `zsh_syntax.bats` — zsh構文チェック

### CI

GitHub Actions（`.github/workflows/ci.yml`）: lint → test → benchmark（mainのみ）

### Git設定

1Password SSH署名によるコミット署名が有効（`dot_gitconfig.tmpl`）。`git commit`時に1Passwordエラーが発生した場合は`notify`コマンドでユーザーに通知すること。
