# 構成

## 原則

- **環境を宣言するだけにする。** このリポジトリが持つのは設定と、それを配置するスクリプトだけ。独自のランタイム・
  サーバー・状態ストア・CLI は持たない。
- **標準機能を優先する。** Claude Code・Codex・chezmoi・Renovate が持つ機能は自作しない。
- **macOS だけを対象にする。**

## ディレクトリ

| パス | 配置先 | 内容 |
|---|---|---|
| `home/` | `~` | chezmoi のソースのルート（`.chezmoiroot`） |
| `home/.chezmoidata.toml` | — | 個人の値と、外部のものの pin |
| `home/.chezmoiexternal.toml` | — | フォントと外部 skill（commit SHA で固定） |
| `home/run_*` | — | lifecycle スクリプト（下記） |
| `install.sh` | — | 新しい Mac のセットアップ |

## lifecycle スクリプト

| スクリプト | 実行する条件 | 内容 |
|---|---|---|
| `run_before_05` | apply のたび | macOS の更新で失われうる Rosetta 2 と Xcode のライセンス同意 |
| `run_onchange_before_10` | Brewfile の変更 | `brew bundle`（1 項目の失敗で apply を止めない） |
| `run_onchange_after_12` | mise の設定の変更 | `mise install` |
| `run_onchange_after_13` | スクリプトの変更 | Claude Code の MCP サーバーの登録 |
| `run_onchange_after_14` | Codex の computer use プラグインの変更 | その MCP サーバーを Claude Code に `codex-cu` として登録 |
| `run_onchange_after_17` | settings.json の変更 | 宣言した Claude Code の plugin のインストール |
| `run_onchange_after_18` | mise の設定の変更 | agent-browser が使うブラウザの取得 |
| `run_onchange_after_20` | スクリプトの変更 | macOS の `defaults` とファイアウォール |
| `run_onchange_after_21` | スクリプトの変更 | `duti` で既定のアプリ |
| `run_onchange_after_22` | LaunchAgent の変更 | キーの割り当ての LaunchAgent を読み込み直す |
| `run_onchange_after_40` | sheldon の設定の変更 | `sheldon lock` |

## キーボード

Caps Lock と Control の入れ替えだけは、`~/Library/LaunchAgents` に置いた LaunchAgent がログインのたびに
`hidutil` で設定する。システム設定の修飾キーはキーボードごとにしか設定できず、`hidutil` の割り当ては再起動で
消えるため。OS に付属するコマンドを呼ぶだけで、独自のランタイムは持たない。

## シェル

`.zprofile` で Homebrew・環境変数・MCP の API キー（1Password から描画した 0600 のファイル）を読み込む。
`.zshrc` で mise・direnv・starship・zoxide を有効にし、sheldon がプラグインと `~/.config/zsh/*.zsh` を
zsh-defer で遅延読み込みする。

## コーディングエージェント

Claude Code と Codex で、形式が許す範囲で設定を共有する。

| | Claude Code | Codex |
|---|---|---|
| ルール | `~/.claude/CLAUDE.md` が `~/AGENTS.md` を読み込む | `~/.codex/AGENTS.md` → `~/AGENTS.md` |
| skill | `~/.claude/skills` → `~/.agents/skills` | `~/.agents/skills` をそのまま読む |
| 設定 | `~/.claude/settings.json`（ファイルごと管理） | `~/.codex/config.toml`（modify テンプレート） |
| 危険なコマンド | `permissions.ask` / `deny` | `~/.codex/rules/dotfiles.rules` |
| MCP サーバー | `run_onchange_after_13` で登録 | `config.toml` に宣言 |
| 記憶・subagent・通知 | 標準機能 | 標準機能 |

- `~/.agents/skills` は `exact_` ディレクトリで、ソースに無い skill は apply で削除する。外部 skill はこの中に
  chezmoi の externals として置く。ハーネス自身が書き込む `.system`（Codex）と `synced`（Claude Code）は
  `.chezmoiignore` で削除の対象から外している。
- Codex は `config.toml` に自分でも書き込む（プロジェクトの trust・plugin）ので、`modify_` テンプレートで
  管理するキーだけを上書きし、それ以外は残す。
- どちらのハーネスでも hook は使わない。
- skill はどちらのハーネスでも動く書き方にする。`multi-review` は、もう一方のハーネスの CLI
  （Claude Code からは `codex exec`、Codex からは `claude -p`）を別モデルのレビュアーとして使う。

## 秘密情報

秘密情報の値は 1Password にだけ置く。テンプレートは `onepasswordRead` で読み、`private_` 属性（0600）で配置する。
vault 名・自宅のホスト名のように、秘密ではないが公開したくない値もリポジトリに書かない。vault 名は
`.chezmoi.toml.tmpl` の `promptStringOnce` で初回に入力させて手元の設定に残し、ホスト名は 1Password から描画する。
グローバルの gitleaks の pre-commit hook がすべてのコミットを検査し、自分のリポジトリではクライアント・勤務先の
固有名（パターンは 1Password にある）も検出する。

## 依存の更新

Renovate は minor / patch の更新を週 1 回 1 つの PR にまとめ、CI が通れば自動でマージする。外部 skill・`ax`・
GitHub Actions の更新は手で確認する。CI は `home/dot_config/mise/config.toml` で固定したツールのバージョンで、
Ubuntu 上で `make test` を実行する。
