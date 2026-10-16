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
| 設定 | `~/.claude/settings.json`（ファイルごと管理） | `~/.codex/config.toml` と profile（modify テンプレート） |
| 危険なコマンド | `permissions.ask` / `deny` | `~/.codex/rules/dotfiles.rules` |
| MCP サーバー | `run_onchange_after_13` で登録 | `config.toml` に宣言 |
| 記憶・subagent・通知 | 標準機能 | 標準機能 |

- `~/.agents/skills` は `exact_` ディレクトリで、ソースに無い skill は apply で削除する。外部 skill はこの中に
  chezmoi の externals として置く。ハーネス自身が書き込む `.system`（Codex）と `synced`（Claude Code）は
  `.chezmoiignore` で削除の対象から外している。
- Codex は `config.toml` と profile（`astra.config.toml`・`agent.config.toml`）に自分でも書き込む（プロジェクトの
  trust・plugin・モデルの案内の表示回数）ので、`modify_` テンプレートで管理するキーだけを上書きし、それ以外は残す。
- hook は、ハーネスの標準機能（設定キー・permission のルール・ダイアログの選択肢）で代替できないときだけ足し、
  スクリプトを `~/.claude/` に置いて `settings.json` の `hooks` で宣言し、理由をここに書く。hook から呼ぶのは
  ハーネス自身の CLI（`claude -p`）までにし、独自のランタイムやサーバーは持たない。
- 今ある hook は `codex-cu-gate.sh`（`Elicitation`）だけ。`codex-cu`（Codex の computer use）は `cua.getApp` の
  たびに「Allow Computer Use to use "<App>"?」の elicitation を出し、「常に許可」の記憶を Codex アプリ
  （MCP クライアント）に委ねている。Claude Code にはその記憶がなく、ダイアログを省く手段も hook しかない。
  hook は auto mode と同じ三層（必ず聞くアプリ → 常に許可するアプリ → `claude -p` の分類器がユーザーの依頼に
  照らして判定）で、否・失敗・判断材料の不足はダイアログに戻す。アプリ名は OS の言語の表示名で届くので、
  標準アプリは英語名と日本語名の両方で照合する。permission mode に関わらず効く（hook の入力に
  mode は渡らない）。限界: transcript は非同期に書かれるので、実行予定の js は「結果が未記録の呼び出しが
  1 つだけ」のときに参考として渡すにとどめ、永続 REPL の既存の状態は見えない。subagent の中では user ターンが
  人の依頼ではないので自動承認しない。
- メール・カレンダーは Spark Desktop 同梱の Spark CLI（`spark`）を MCP（`spark mcp`）で使う。Claude Code は
  公式 plugin（`readdle/spark-claude-plugin`。MCP と recipe の skill を含む）を `settings.json` の inline
  marketplace で commit SHA に固定し、Codex は `config.toml` に MCP を宣言する。`spark` は Spark Desktop の
  IPC ソケットにつなぐので、Codex の sandbox の中のシェルからは届かない（sandbox の外で起動する MCP なら届く）。
  そのため、skill だけの公式 Codex plugin は使わない。受信したメールの本文は信頼できない入力なので、書き込み系の
  `draft` / `event` / `comment` / `action` / `contact-action` は、MCP でもシェルでも毎回確認する（Claude Code は
  `permissions.ask`、Codex は `default_tools_approval_mode = "writes"` と rules）。アプリの中の設定は宣言できないので、
  新しいマシンでは手で行う: Spark Desktop の Settings → AI Agents → Setup CLI（`/usr/local/bin/spark` を作る）と、
  アカウントごとの access level（Off / Read / Triage / Send）。`spark` は起動中の Spark Desktop に問い合わせるので、
  使う間は Spark Desktop を開いておく。
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
