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
| `run_onchange_after_20` | スクリプトの変更 | macOS の `defaults`・ファイアウォール・GUI アプリの PATH |
| `run_onchange_after_21` | スクリプトの変更 | `duti` で既定のアプリ |
| `run_onchange_after_22` | LaunchAgent の変更 | キーの割り当ての LaunchAgent を読み込み直す |
| `run_after_31` | apply のたび | Obsidian の vault をそろえる（下記） |
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
| 記憶 | Obsidian の vault（`autoMemoryEnabled: false`） | Obsidian の vault（`features.memories = false`） |
| subagent の役割 | `~/.claude/agents/*.md`（model・effort） | `~/.codex/agents/*.toml`（model・model_reasoning_effort） |
| subagent・通知 | 標準機能 | 標準機能 |

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
- skill はどちらのハーネスでも動く書き方にする。もう一方のハーネスのモデルは、その CLI（Claude Code からは
  `codex exec`、Codex からは `claude -p`）で呼ぶ。

## モデルの役割分担

設計と判断は Claude、実装は GPT に任せる。レビューの general は実装と別の系統の
Claude が担う。根拠（各モデルの得意・不得意と費用）と役割表は
`home/dot_agents/exact_skills/pr-workflow/references/model-roles.md` にある。

モデルとエフォートは、役割ごとに各ハーネスの標準の subagent 定義に宣言し、skill には役割の名前だけを書く。
Claude Code 2.1.291 は subagent の effort を定義の frontmatter でしか受け付けず、`codex exec` は Codex の
agent の定義を選べず、`claude -p --setting-sources ""` は `~/.claude/agents` を読まない。そのため、もう一方の
ハーネスから呼ぶときは、定義ファイルの model と effort の行を `sed` で読んで CLI の引数に渡す。Claude の役割は、
Claude Code が親のときも subagent ではなく `claude -p` で走らせる。親の広い permission を継承させず、cyber safeguard の
fallback を親のセッションから隔離して検出するため。値の正本は定義
ファイルで、役割表との一致は `tests/agent_roles.bats` が検査する。`agents/` は `exact_` にしない（`/agents` で
手元に作った定義を apply で消さないため）。

## 作業記憶（Obsidian の vault）

Claude Code と Codex の作業記憶は `~/vaults/` の Obsidian の vault に置く（手順は `vault` skill、設計は
`.claude/prds/obsidian-vault.prd.md`）。記憶の置き場所を 1 つにするため、両ハーネスの標準の memory は止めている。
エージェントが学んだ振る舞いのルールは vault に提案として書き、ユーザーが PR で `home/AGENTS.md` に反映する。vault は git-remote-gcrypt で暗号化し、Google Drive の同期フォルダの
ディレクトリへ push する。vault の中身はこのリポジトリに置かない。

新しい Mac でも覚えておく手順を残さないため、`run_after_31` が apply のたびに足りないものだけを作る。
1Password の項目「Dotfiles - Vault」とドキュメント「Dotfiles - Vault GPG key」から GPG 鍵を入れ、
pinentry-mac が読むキーチェーンの項目（service `GnuPG`・account は keygrip）を作り、Drive のバックアップから
手元に無い vault を clone し、別名の symlink を作り、Obsidian の vault の一覧に登録する。1Password や Drive に
まだサインインしていなければ何もせず、apply を止めない。Obsidian Git が gcrypt と gpg を見つけられるよう、
`run_onchange_after_20` が `launchctl config user path` で GUI アプリの PATH に Homebrew を入れる。

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
