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
| `home/.chezmoiexternal.toml` | — | フォント・外部 skill・tmux のプラグイン（commit SHA で固定） |
| `home/run_*` | — | lifecycle スクリプト（下記） |
| `install.sh` | — | 新しい Mac のセットアップ |

## lifecycle スクリプト

| スクリプト | 実行する条件 | 内容 |
|---|---|---|
| `run_before_05` | apply のたび | macOS の更新で失われうる Rosetta 2 と Xcode のライセンス同意 |
| `run_before_06` | apply のたび | `~/.config/git/hooks` に書き込みの権限を戻す（下の「秘密情報」） |
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
| `run_after_41` | apply のたび | `~/.config/git/hooks` から書き込みの権限を外す（下の「秘密情報」） |

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
| モデルの役割 | `~/.agents/roles/*.md`（model・effort・道具。`claude -p` に渡す） | `~/.codex/agents/*.toml`（model・model_reasoning_effort） |
| subagent・通知 | 標準機能 | 標準機能 |

- `~/.agents/skills` は `exact_` ディレクトリで、ソースに無い skill は apply で削除する。外部 skill はこの中に
  chezmoi の externals として置く。ハーネス自身が書き込む `.system`（Codex）と、`synced` とその退避の `.trash`（Claude Code）は
  `.chezmoiignore` で削除の対象から外している。
- Codex は `config.toml` と profile（`astra.config.toml`・`agent.config.toml`）に自分でも書き込む（プロジェクトの
  trust・plugin・モデルの案内の表示回数）ので、`modify_` テンプレートで管理するキーだけを上書きし、それ以外は残す。
- hook は、ハーネスの標準機能（設定キー・permission のルール・ダイアログの選択肢）で代替できないときだけ足し、
  スクリプトを `~/.claude/` に置いて `settings.json` の `hooks` で宣言し、理由をここに書く。hook から呼ぶのは
  ハーネス自身の CLI（`claude -p`）までにし、独自のランタイムやサーバーは持たない。
- 今ある hook は `codex-cu-gate.sh`（`Elicitation`）と `tmux-claude-session.sh`（`SessionStart`）の 2 つ。
- `codex-cu-gate.sh` は computer use の許可を判定する。`codex-cu`（Codex の computer use）は `cua.getApp` の
  たびに「Allow Computer Use to use "<App>"?」の elicitation を出し、「常に許可」の記憶を Codex アプリ
  （MCP クライアント）に委ねている。Claude Code にはその記憶がなく、ダイアログを省く手段も hook しかない。
  hook は auto mode と同じ三層（必ず聞くアプリ → 常に許可するアプリ → `claude -p` の分類器がユーザーの依頼に
  照らして判定）で、否・失敗・判断材料の不足はダイアログに戻す。アプリ名は OS の言語の表示名で届くので、
  標準アプリは英語名と日本語名の両方で照合する。permission mode に関わらず効く（hook の入力に
  mode は渡らない）。限界: transcript は非同期に書かれるので、実行予定の js は「結果が未記録の呼び出しが
  1 つだけ」のときに参考として渡すにとどめ、永続 REPL の既存の状態は見えない。subagent の中では user ターンが
  人の依頼ではないので自動承認しない。
- `tmux-claude-session.sh` は、どのペインでどの会話が動いているかを tmux に渡す。Claude Code の設定キーにも
  tmux の機能にも、この対応を渡す標準の手段が無いため、`SessionStart` で session ID と PID を記録する。
  `claude -p` や Bash ツールの子も `TMUX_PANE` を継承するので、Claude Code の制御端末がペインの tty で、
  前景のジョブのときだけ記録する。stdout は Claude Code の文脈に入るので何も出さない。
- skill はどちらのハーネスでも動く書き方にする。もう一方のハーネスのモデルは、その CLI（Claude Code からは
  `codex exec`、Codex からは `claude -p`）で呼ぶ。

## tmux

再起動の後に、セッション・ウィンドウ・ペインの並びとレイアウト・各ペインの作業ディレクトリを戻し、
Claude Code の会話を `claude --resume <ID>` で再開する。スクロールバックと、Claude Code 以外のプログラムは
戻さない。resurrect の既定のプロセスの復元は、保存したコマンドラインをそのままシェルに打ち込み、ファイル名
などに含まれる `$(...)` まで実行しうるため、`@resurrect-processes 'false'` で止める。

tmux-resurrect と tmux-continuum は TPM を使わず、chezmoi の externals で `~/.local/share/tmux/plugins/` に
配置し、`~/.tmux.conf` からこの順に読む。master の commit SHA で固定し、Renovate が更新を追跡する。
プラグインは tmux サーバーの中でシェルとして動くため、更新は自動でマージしない。

continuum が 5 分ごとに resurrect で `~/.local/share/tmux/resurrect/` に保存する。ステータス行の描画が契機に
なるので、クライアントが接続している間だけ動く。Ghostty を閉じたときなど、クライアントが切断したときにも
`client-detached` の hook から resurrect で保存する。

Ghostty の最初のウィンドウは、`initial-command` で
`/bin/zsh -lic 'exec tmux new-session -A -s claude-sessions'` を実行する。tmux は mise で入れていて GUI アプリの
PATH に無いため、`.zshrc` の mise を通す対話のログインシェルで起動する。新しいサーバーでは continuum が
最後の保存を復元する。`-A` は、`claude-sessions` が既にあれば attach する指定。保存に同じ名前と位置のペインがあれば、初期の
ペインは復元したペインに置き換わる。2 枚目以降のウィンドウ・タブは普通のシェルを開く。LaunchAgent は使わない。

Claude Code の会話は、SessionStart と resurrect の hook でペインに対応づける。
resurrect の hook は `~/.config/tmux/claude-resume.sh` に置く。

| 契機 | 処理 |
|---|---|
| `SessionStart` | ペインのユーザーオプション `@claude-session-id` と `@claude-pid` に session ID と PID を記録する |
| `post-save-layout` | 記録した PID が生きていて制御端末がペインの tty と一致する行を、`claude_session` として保存ファイルに追記する |
| `pre-restore-all` | 既存のペインに印を付け、すべての印付けが終わったことを記録する |
| `pre-restore-pane-processes` | 印付けが完了していれば、印が無く前景がシェルのペインにだけ `claude --resume <ID>` を送る。ID が UUID の形でない行や、対象のペインが無い行は飛ばす |

復元には次の限界がある。

| 条件 | 限界 |
|---|---|
| 最後の保存より後の変更 | 戻らない。接続中は最大 5 分、切断中の変化は次の接続か切断まで保存されない |
| ほかの tmux サーバーが動いている | continuum は自動の保存も復元もしない（上流の仕様） |
| Claude Code の起動時のオプション | `--model` などは戻らない |
| 保存に無い名前のセッションから始める | 初期のセッションが残る |
| サーバーのペインが 1 つのときに手で復元する（`prefix + C-r`） | そのペインは置き換わる（上流の仕様） |
| ペインの前景で `claude -p` を直接実行する | そのペインの会話の記録を上書きする |

起動直後ではない既存のサーバーに設定を読み込むには、`tmux source-file ~/.tmux.conf` を実行する。
continuum は復元せず、保存だけを始める。

## T3 Code

T3 Code を新しい作業の入口にする。サーバーはデスクトップアプリの内蔵のものだけを使う。常駐サービス
（`t3 service`）を併用すると同じデータを取り合うため、使わない。worktree は T3 Code が作り、
`pr-workflow` はそのまま使う。ターミナルから始める作業は `wtp` を使う。

`home/private_dot_t3/private_userdata/modify_settings.json` は `~/.t3/userdata/settings.json` の次のキーを宣言する。
アプリも書き込むので、管理するキーだけを上書きし、それ以外は残す。

- `defaultRuntimeMode`: `auto`
- `defaultThreadEnvMode`: `worktree`
- `defaultModelSelection`: `instanceId` は `claudeAgent`、`model` は `claude-opus-5-5`
- `branchNamingMode`: `semantic`
- `worktreeCleanup`: `mode` は `custom`。`worktreeOnMerge` だけを有効にし、
  `worktreeKeepWhen` は `uncommitted-changes`（未コミットの変更がある worktree を残す）。

テレメトリは `.zprofile` の `T3CODE_TELEMETRY_ENABLED=false` で止める。遠隔操作は Tailscale HTTPS を使い、
アプリの画面で有効にする。

Claude の Auto では、Claude が人に聞こうとした操作を T3 Code が自動で許可するため、`permissions.ask` が効かない。
リポジトリ・クラウド資源の削除やパッケージの公開なども確認なしで通る。`permissions.deny` は効く。
承認の回数を増やさないため Auto のまま使い、上流の修正を
[#36](https://github.com/kryota-dev/dotfiles/issues/36) で追う。

## モデルの役割分担

設計と判断は Claude。実装者は PR ごとに Claude と GPT から選び、レビューの general は実装と別の系統が担う。
根拠（各モデルの得意・不得意と費用）と役割表は
`home/dot_agents/exact_skills/pr-workflow/references/model-roles.md` にある。

モデルとエフォートは役割ごとに定義ファイルへ宣言し、skill には役割の名前だけを書く。GPT の役割は Codex の custom agent
（`~/.codex/agents/*.toml`）で、Codex からは `spawn_agent`、Claude Code からは `codex exec` に定義の値を渡して起動する
（`codex exec` は agent の定義を選べない）。Claude の役割は `~/.agents/roles/*.md` に置き、どちらのハーネスからも
権限を絞った `claude -p` で起動する。実装の役割（`implementer-claude*`）だけは Bash を持ち、Claude Code の sandbox
（`--settings` で有効にし、ネットワークなし・書き込みは作業ツリーと一時ディレクトリだけで、git の共通ディレクトリへの
書き込みは拒否）の中で動く。Claude Code の subagent にしないのは、親の広い permission を継承させず、
cyber safeguard の fallback を親のセッションから隔離して `modelUsage` で検出するため。`~/.claude/agents` に置くと
Claude Code が自動委譲で subagent として選びうるので、Claude Code が読まない場所に置く。値の正本は定義ファイルで、
役割表との一致と起動の引数は `tests/agent_roles.bats` が検査する。`roles/` と `agents/` は `exact_` にしない
（手元に作った定義を apply で消さないため）。

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

ほかのリポジトリの古い lefthook（2.1.4 以前の `lefthook run`、2.1.0 より前の `lefthook install`）は、グローバルの
`core.hooksPath` のフックを上書きする（lefthook は書き先を `git rev-parse --git-path hooks` で求める）。まず、pre-commit は
リポジトリのフックの子プロセスにだけ `GIT_CONFIG_*` で `core.hooksPath` をリポジトリの hooks に向け、commit の経路での
上書きを書き先ごと外す。commit の外で動く古い `lefthook install` に備えて、さらに次で防ぐ。`run_after_41` が apply のあいだ `~/.config/git/hooks` から
書き込みの権限を外し、`run_before_06` が apply の前に戻す（ディレクトリの `readonly_` は中を更新できない）。
ディレクトリの権限では中身の書き直しを止められないので、pre-commit 自体も `readonly_` にする。
`exact_hooks` が管理外のフックを apply で消す。それでも書き換わったら、pre-commit がリポジトリのフックを呼んだあとに
気付いて元に戻し、警告する。apply が途中で止まって書き込める状態が残っていれば、次の commit で pre-commit が外す。

## 依存の更新

Renovate は minor / patch の更新を週 1 回 1 つの PR にまとめ、CI が通れば自動でマージする。外部 skill・`ax`・
GitHub Actions の更新は手で確認する。CI は `home/dot_config/mise/config.toml` で固定したツールのバージョンで、
Ubuntu 上で `make test` を実行する。
