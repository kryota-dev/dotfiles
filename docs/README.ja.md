# docs/ — リファレンス目次

> 🌐 English (canonical): [README.md](README.md)

このリポジトリ（`kryota-dev/dotfiles`）は、chezmoi で管理された macOS ファーストの dotfiles セットです。`curl | bash` 一行のブートストラップで開発者 + AI エージェントの作業環境全体を構築します。chezmoi のソースツリーは `home/` 配下にあり、chezmoi の命名規則に従って `$HOME` へデプロイされます。`chezmoi apply` 実行時、番号順に並んだライフサイクルスクリプトが Homebrew パッケージのインストール、1Password シークレットの検証、mise 管理ツールチェーンのセットアップ、Claude Code MCP サーバーの登録、zsh プラグインセットのロックなどを行います。

**この docs/ ツリーは、必要に応じて参照する深いリファレンスです。** リポジトリルートの `README.md` はハッピーパスのクイックスタートを扱います。このルーターはすべての詳細ドキュメントへのリンクと「どこに何があるか」の説明を提供します。

---

## 目次

### はじめに

| ドキュメント | 説明 |
|-------------|------|
| [インストールとブートストラップ](getting-started/installation.ja.md) | 2 つのエントリポイント（`curl\|bash` vs `chezmoi init --apply`）、OS 別前提条件、chezmoi ダウンロードのリトライループ、冪等性 |
| [インストールの確認](getting-started/verification.ja.md) | `setup-validation.yml` のアサートを再現する実行可能な収束チェックリスト |
| [1Password シークレットのオンボーディング](getting-started/secrets-1password.ja.md) | 必要な Vault アイテム、フィールド名、`run_once_after_11` のハードゲート |

### アーキテクチャ

| ドキュメント | 説明 |
|-------------|------|
| [アーキテクチャ概要](architecture/overview.ja.md) | ブートストラップ → chezmoi エンジン → ライフサイクル → zsh/ツール → AI エージェント層 → CI をまたぐサブシステムマップとデータフロー図 |
| [chezmoi エンジン: データ・テンプレート・名前デコード](architecture/chezmoi-engine.ja.md) | 名前デコード表、テンプレート変数インベントリ、OS 分岐イディオム、`includeTemplate`、2 つの chezmoi 設定ファイル |
| [Externals・SHA ピン・シングルアーカイブキャッシュ](architecture/externals-and-pinning.ja.md) | 147 個の external エントリが少数のキャッシュダウンロードに集約される仕組み、`range .ecc.skills` ファンアウト、更新ウィンドウと Renovate バンプ |
| [ライフサイクルスクリプト: 順序とトリガーモデル](architecture/lifecycle-scripts.ja.md) | before/after 二フェーズモデル、完全な適用タイムライン（00→90）、`run_once` vs `run_onchange` のセマンティクス、埋め込みハッシュのトリック |
| [zsh 起動・プロンプト・シェルモジュール](architecture/shell-environment.ja.md) | `.zprofile` → `.zshrc` → sheldon 遅延ローディング、新しい `.zsh` モジュールの追加方法 |
| [開発ツールチェーン: mise・Brewfile・git](architecture/dev-tooling.ja.md) | mise バージョンピン、`Brewfile` + `.brewfile-linux-exclude`、git 1Password 署名、グローバル gitleaks フック |

### エージェント

| ドキュメント | 説明 |
|-------------|------|
| [AI エージェント層の概要](agents/overview.ja.md) | デュアルハーネス（Claude Code + Codex）× デュアルアカウント（default + r06）マトリクス、共有ルールと SSOT スキル層 |
| [アカウント分離: エイリアス・env・tmux ソケット](agents/account-isolation.ja.md) | アカウント別 env 変数表、完全なエイリアスマトリクス、`_claude_with_home` |
| [Claude Code ハーネス設定](agents/claude-code.ja.md) | `settings.json`、ECC フックフォーク、CLV2 オブザーバーの配線、3 行ステータスライン、日本語レビューサブエージェント |
| [Codex CLI ハーネス設定](agents/codex.ja.md) | デュアル `CODEX_HOME` アカウント、`hooks.json`、`shared.config.toml` SSOT、gateguard |
| [スキルライブラリと出自分類](agents/skills-provenance.ja.md) | 5 分類（curated/external/system/evolved/unmanaged）とスキル追加手順 |

### コントリビュート

| ドキュメント | 説明 |
|-------------|------|
| [ローカル開発と make の契約](contributing/local-dev.ja.md) | 全 `make` ターゲット表、lint パイプラインの内部構造、`{{` 行ストリッピングの注意点 |
| [CI アーキテクチャとテストスイート](contributing/ci-and-tests.ja.md) | `ci.yml` vs `setup-validation.yml`、bats スイートマップ、Brewfile フィルター、既知の問題 |
| [Worktree（wtp）と direnv/MCP 環境](contributing/worktrees-and-env.ja.md) | `.wtp.yml` の post-create フック、direnv `.env` ブートストラップ、spec-workflow MCP サーバー |

### 解説

| ドキュメント | 説明 |
|-------------|------|
| [なぜこの設計なのか](explanation/design-rationale.ja.md) | 重要な設計判断: シングルアーカイブキャッシュ、タグでなく SHA ピン、config 共有/state 分離、sourced-not-exported シークレット、`make apply` なし |
| [シークレットとアカウント分離の設計](explanation/secrets-and-isolation.ja.md) | `op://` 参照が apply 時に `0600` ファイルとしてレンダリングされる仕組み、runtime-graceful vs apply-strict、アカウント分離との合成 |

---

## どこに何があるか

| サーフェス | 記載すること | 記載しないこと |
|-----------|-------------|---------------|
| ルート `README.md` / `README.ja.md` | ランディングページ、ハッピーパスのクイックスタート、リポジトリ構造、開発コマンド表、CI サマリー | 深い前提条件の詳細、トラブルシューティング、アーキテクチャの説明 |
| リポジトリルートの `CLAUDE.md` / `AGENTS.md` | 必須スキルルール、言語ポリシー、スキル出自ポリシー、docs/ への一行ポインター | メカニクス（lint フラグ、ライフサイクル順序、アカウント env 表）— それらは docs/ に記載 |
| デプロイ済み `home/AGENTS.md.tmpl`、`home/dot_claude/CLAUDE.md` | **リポジトリなしで動く**自己完結したエージェント指示 | docs/ へのポインター — デプロイ済みファイルは自己完結でなければならない |
| 各スキル `SKILL.md`（スキルディレクトリ内） | スキルの権威的リファレンス（目的・使い方・例） | 分類や「スキルの追加方法」— それは `docs/agents/skills-provenance.md` に記載 |
| `docs/`（このツリー） | リポジトリ内で作業する人間と AI エージェント向けの深いリファレンス・ハウツー・解説 | README を複製するクイックスタート、リポジトリなしで動く必要があるコンテンツ |

---

## 言語ポリシー

英語ドキュメント（`foo.md`）が正典です。日本語ミラー（`foo.ja.md`）は英語版と並んで配置されます。各英語ドキュメントは先頭付近で日本語ミラーへリンクし、各日本語ドキュメントは英語正典へリンクします。これはリポジトリ既存の `README.md` / `README.ja.md` 慣例に倣っています。

[docs/README.md →](README.md)
