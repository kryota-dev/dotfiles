# Claude Code ハーネス

🌐 English (canonical): [claude-code.md](claude-code.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントは、本 dotfiles リポジトリがデプロイする Claude Code ハーネスの設定を説明します。ハーネスは `~/.claude/settings.json`、薄い ECC ランチャー、1 つの chezmoi 管理フックスクリプト、3 行ステータスライン、CLV2 継続学習オブザーバーの配線、および日本語コードレビュー用サブエージェント群で構成されます。2 つ目のアカウント (`~/.claude-r06`) はシンボリックリンクで設定全体をミラーしつつ、ランタイム状態は分離されます。

---

## 目次

- [デプロイ先パス](#デプロイ先パス)
- [settings.json — 主要設定値](#settingsjson--主要設定値)
- [permissions allow/deny サーフェス](#permissions-allowdeny-サーフェス)
- [フックグラフ](#フックグラフ)
  - [SessionStart](#sessionstart)
  - [UserPromptSubmit](#userpromptsubmit)
  - [PreToolUse](#pretooluse)
  - [PostToolUse](#posttooluse)
  - [PostToolUseFailure](#posttoolusefailure)
  - [Notification](#notification)
  - [Stop](#stop)
  - [StopFailure](#stopfailure)
- [ECC ランチャー — ecc-hook.sh](#ecc-ランチャー--ecc-hooksh)
- [フックスクリプト (hooks-fork/)](#フックスクリプト-hooks-fork)
- [ステータスライン](#ステータスライン)
- [CLV2 オブザーバー配線](#clv2-オブザーバー配線)
- [朝次レーダーのスケジュール実行](#朝次レーダーのスケジュール実行)
- [改善候補キュー](#改善候補キュー)
- [レビューサブエージェント](#レビューサブエージェント)
- [r06 ワークアカウント](#r06-ワークアカウント)
- [環境変数リファレンス](#環境変数リファレンス)

---

## デプロイ先パス

| ソースパス | デプロイ先 |
|---|---|
| `home/dot_claude/settings.json` | `~/.claude/settings.json` |
| `home/dot_claude/executable_ecc-hook.sh` | `~/.claude/ecc-hook.sh` (0755) |
| `home/dot_claude/executable_statusline.sh` | `~/.claude/statusline.sh` (0755) |
| `home/dot_claude/executable_morning-radar.sh` | `~/.claude/morning-radar.sh` (0755) |
| `home/dot_claude/executable_wave-session-event.sh` | `~/.claude/wave-session-event.sh` (0755) |
| `home/dot_claude/hooks-fork/prompt-conform-suggest.js` | `~/.claude/hooks-fork/prompt-conform-suggest.js` |
| `home/dot_claude/agents/*.md` | `~/.claude/agents/*.md` |
| `home/dot_claude/fable-orchestrator-prompt.md` | `~/.claude/fable-orchestrator-prompt.md`（`cldf`/`cldf-r06` が `--append-system-prompt-file` で読み込む） |
| `home/dot_claude/symlink_skills.tmpl` | `~/.claude/skills -> ~/.agents/skills` (シンボリックリンク) |
| `home/dot_claude-r06/symlink_*.tmpl` | `~/.claude-r06/{settings.json,CLAUDE.md,statusline.sh,agents,commands,skills}` (シンボリックリンク) |

---

## settings.json — 主要設定値

`home/dot_claude/settings.json` は `~/.claude/settings.json` にデプロイされ、ハーネス全体の単一エントリポイントです。主要なスカラー設定：

| 設定 | 値 | 備考 |
|---|---|---|
| `model` | <!-- FACT:claude-model-pin -->claude-opus-5[1m]<!-- /FACT --> | 1 M コンテキストのピン固定モデル（`home/dot_claude/settings.json` と同期） |
| `effortLevel` | `xhigh` | 永続化される推論 effort。`/effort` でセッション単位に上書き可能 |
| `language` | `Japanese` | 会話出力はすべて日本語 |
| `alwaysThinkingEnabled` | `false` | 拡張思考はタスク単位でオプトイン |
| `cleanupPeriodDays` | `20` | 20 日より古いセッションを自動削除 |
| `agentPushNotifEnabled` | `true` | サブエージェントイベントのプッシュ通知 |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `95` | コンテキスト使用率 95 % で自動コンパクト |
| `MAX_THINKING_TOKENS` | `127999` | 拡張思考トークンの上限 |
| `permissions.defaultMode` | `auto` | リスト外操作のみプロンプト |

`statusLine` フィールドは `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh` を指し、同じ settings.json を両アカウントで共用できます。

2つのプラグインを宣言しています：

| プラグイン | 提供内容 |
|---|---|
| `codex@openai-codex` | Claude Code 内から Codex CLI（OpenAI）へ相談する機能 |
| `claude-code-setup@claude-plugins-official` | Anthropic 公式の read-only コードベース分析ツール。hooks・skills・MCP サーバー・サブエージェントを推奨する |

`enabledPlugins` がプラグインを、`extraKnownMarketplaces` がその入手元となる非公式 marketplace を宣言します
（`openai-codex` → `openai/codex-plugin-cc`、タグ `v1.0.6` に pin）。ただしどちらのキーも、それ自体は
インストールを行いません。CLI は `enabledPlugins` を「*すでにインストール済みの*プラグイン」の有効/無効
スイッチとして扱い、settings.json に宣言があるだけでは marketplace を登録しません
（[anthropics/claude-code#23737](https://github.com/anthropics/claude-code/issues/23737)（duplicate でクローズ）、
[#45323](https://github.com/anthropics/claude-code/issues/45323)（not planned でクローズ）を参照）。
各アカウントのプラグイン実体は `$CLAUDE_CONFIG_DIR/plugins/` にあり、chezmoiignore 対象なので新しいマシンでは空です。

このギャップを埋めるのが `run_onchange_after_17-setup-claude-plugins.sh.tmpl` です。settings.json から
レンダリングした宣言を JSON として埋め込み（＝宣言の単一ソースを保つ）、不足している marketplace の
登録とプラグインのインストールをアカウントごとに実行します。

marketplace は `chezmoi apply` が無人でインストールする実行コードなので、可変な既定ブランチを追ってはいけません。
この pin には落とし穴が 2 つあります。宣言した `ref` は **CLI 引数に含めない限り無視される**ため、スクリプトは
`<repo>#<ref>` を渡します。また ref は `git clone --branch` に届くので、**コミット SHA は使えません** —
ブランチかタグのみです。したがって `openai-codex` はタグで pin しており、このリポジトリが chezmoi external に
用いているコミット pin より弱い保証になります（タグは上流で移動しうる）。現状タグの更新は手動編集で、
Renovate の `github-tags` datasource への接続は別途追跡します。

**settings.json は chezmoi のものであり、CLI のものではありません。** `claude plugin install`・
`claude plugin marketplace add`・対話的な `/plugin` マネージャは、いずれもこのファイルを自前のシリアライザで
書き戻します。その結果トップレベルのキーが並べ替えられ、各 hook の `id`・`description` 注釈が失われます。
機能は壊れません（hook は JSON のキーではなく `command` 内の引数で識別されるため）が、書き戻された
ファイルを `chezmoi add` してはいけません。注釈付きの版に戻すには `chezmoi apply` を実行します。
スクリプト 17 も同じことを自前で行い、終了時にスナップショットを書き戻します。

---

## permissions allow/deny サーフェス

`permissions.allow` リストは一般的な読み取り専用・安全な書き込み操作を事前承認し、Claude Code がプロンプトを表示しないようにします：

- **読み取り**: `ls`, `find`, `tree`, `cat`, `head`, `tail`, `grep`, `rg`, `sort`, `diff`, `echo`, `sed`, `awk`, `jq`
- **ファイルシステム書き込み**: `mkdir`, `cp`, `mv`, `touch`, `chmod`
- **パッケージマネージャー**: `npm`, `pnpm`, `yarn`, `npx`
- **Git**: `status`, `diff`, `log`, `add`, `commit`, `branch`, `checkout`, `switch`, `pull`, `push`, `stash`, `fetch`, `merge`, `tag`, `show`, `cherry-pick`, `remote -v`
- **Docker**: `docker`, `docker-compose`, `docker compose`
- **TypeScript**: `tsc`, `tsx`
- **テスト/リント**: `jest`, `vitest`, `playwright`, `eslint`, `prettier`, `biome`
- **通知**: `osascript -e 'display notification*`
- **GitHub**: `gh search:*`
- **MCP**: `mcp__claude_ai_Google_Calendar__list_events`、context7 ツール

`permissions.deny` リストでブロックされるもの：

- `sudo`、`rm -rf`、`git reset`、`git push --force` / `-f`
- クレデンシャルファイルの読み取り (`.env*`、秘密鍵、PEM ファイル、`*credentials*`、`*secret*`)
- `.env*` と `secrets/` パスへの書き込み
- `env` と `printenv` (シークレットの環境変数ダンプ防止)
- Gmail MCP クレデンシャルファイル
- `mcp__supabase__execute_sql`

---

## フックグラフ

フックは `settings.json` で配線され、ECC ランチャーまたは直接 `node` 呼び出しでディスパッチされます。ECC ディスパッチャー (`run-with-flags.js`) は `ECC_HOOK_PROFILE`（`strict` に設定）と `ECC_DISABLED_HOOKS`（ランチャーがセッション単位の `ECC_DISABLED_HOOKS_EXTRA` をマージ済みの値、#281）でセルフゲーティングします。

**#496 で縮小しました**（#473 の sub-issue）。従来は 37 エントリが同一イベント面に安全防御・品質自動化・観測・監査・通知・学習を重ねていました。19 エントリを除去し 18 エントリになりました。外したもの: Edit ごと・Stop ごとの品質助言（`$code-change-verification` と CI と重複）、判断に結び付かない観測・監査、セッション要約の自動保存と SessionStart の文脈注入、CLV2 の SessionStart 通知。残したもの: 安全境界（コミット検証の迂回禁止・破壊的コマンドの事実確認・開発サーバーの起動・`pre:config-protection`）、CLV2 のツール呼び出しオブザーバー、MCP 失敗時の recovery、ntfy 通知、そして wave-orchestrator のセッションイベント全件。

```mermaid
flowchart TD
    SS[SessionStart] --> SS1[ECC session-start-bootstrap\n文脈注入 off\nCLV2 observer lease 登録]

    UPS[UserPromptSubmit] --> UPS1[prompt-conform-suggest\nmatcherなし]
    UPS --> UPS2[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION]

    PTU[PreToolUse] --> PTU1[config-protection\nWrite Edit MultiEdit]
    PTU --> PTU2[pre-bash-dispatcher\nBash]
    PTU --> PTU3[CLV2 observe.sh pre async]
    PTU --> PTU4[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION\nAskUserQuestion]

    PoTU[PostToolUse] --> PoTU1[CLV2 observe.sh post async]
    PoTU --> PoTU2[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION\nAskUserQuestion]

    PTUF[PostToolUseFailure] --> PTUF1[mcp-health-check\nall tools]
    PTUF --> PTUF2[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION\nAskUserQuestion]

    NTF[Notification] --> NTF1[ntfy-notify async\npermission_prompt idle_prompt\nagent_needs_input agent_completed]
    NTF --> NTF2[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION\npermission_prompt idle_prompt\nagent_needs_input]

    STP[Stop] --> STP1[cost-tracker async]
    STP --> STP2[desktop-notify async\nDISABLED via ECC_DISABLED_HOOKS]
    STP --> STP3[ntfy-notify async]
    STP --> STP4[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION]

    STPF[StopFailure] --> STPF1[wave-session-event async\nopt-in WAVE_ORCHESTRATOR_SESSION]
```

### SessionStart

| フック ID | コマンド | 備考 |
|---|---|---|
| `session:start` | `ecc-hook.sh scripts/hooks/session-start-bootstrap.js` | ライフサイクルのみ。`ECC_SESSION_START_CONTEXT=off` が注入ブロック全て（前回セッション要約・active instinct・learned skill・プロジェクト種別）を抑止する（#496、#473 AC-025）。エントリ自体を残すのは、`session-start.js` が CLV2 オブザーバーの session lease を**注入ゲートより前**で登録するため。エントリごと削除すると、本変更が維持すべき学習エンジンの観測が静かに止まる |

### UserPromptSubmit

| フック ID | Matcher | コマンド | 備考 |
|---|---|---|---|
| `user-prompt-submit:prompt-conform-suggest` | なし | `node hooks-fork/prompt-conform-suggest.js`（タイムアウト 5 秒） | 長くタスク性の強いプロンプトを検知し、`$prompt-conform` の実行提案を `additionalContext` として注入する（task #367）。ECC フォークではなく独立スクリプト — 下記の [フックスクリプト](#フックスクリプト-hooks-fork) とは別に文書化している。`UserPromptSubmit` は[公式 Hooks reference](https://code.claude.com/docs/en/hooks)上 `matcher` 非サポート（silently ignored）のため、このエントリでは省略している。fail-open: 不正な payload・env でチューニングした不正な正規表現・その他の例外はすべて no-output・exit 0 に縮退する。チューニング項目は [Env vars reference](#env-vars-reference) を参照。 |
| `userpromptsubmit:wave-session-event` | なし | `wave-session-event.sh`（async、タイムアウト 10 秒） | hook payload をセッションごとのファイルに追記し、wave-orchestrator の親セッションが TUI を走査せずに子セッションの停止を検知できるようにする（#437）。配線は全セッションに入るが**記録は opt-in**: 環境変数 `WAVE_ORCHESTRATOR_SESSION` が設定されているときのみ記録し（orchestrator が起動する子セッションにのみ export される）、通常セッションは何も記録しない。記録先は `${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events/<session_id>.jsonl`（ディレクトリ 700 / ファイル 600）。fail-open: `jq` が無い、記録先に書けない、`session_id` が UUID として解釈できない、のいずれでも no-op。 |

### PreToolUse

| フック ID | マッチャー | 説明 |
|---|---|---|
| `pre:config-protection` | `Write\|Edit\|MultiEdit` | リンター/フォーマッター設定ファイルへの編集をブロック |
| `pre:bash:dispatcher` | `Bash` | `block-no-verify`、`auto-tmux-dev`、ゲートガードを順番に実行。助言系のサブフック（`tmux-reminder`、`git-push-reminder`、`commit-quality`）は `ECC_DISABLED_HOOKS` で無効化済み（#496、#473 AC-010）。ゲートガードは**破壊的コマンド**の事実確認を維持し、`GATEGUARD_BASH_ROUTINE_DISABLED=1` はセッション最初の非読み取り Bash に対する routine ゲートだけを止める（#473 AC-009） |
| `pre:observe:continuous-learning` | `*` | CLV2 `observe.sh pre` (async)；`tool_start` を `observations.jsonl` に書き込み |
| `pretooluse:wave-session-event` | `AskUserQuestion` | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（async、タイムアウト 10 秒；`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437）。質問が開いたことを記録する；下記の `PostToolUse`/`PostToolUseFailure` 行と `tool_use_id` でペアリングし、後で決着したかを判定する。 |

`GATEGUARD_BASH_EXTRA_DESTRUCTIVE` 正規表現（`env` で設定）は、`pre:bash:dispatcher` が強制する組み込みの破壊的コマンドセットを拡張します：

- `chezmoi destroy/forget/purge`
- `terraform destroy`、`state rm`、`workspace delete`、`force-unlock`、`apply --auto-approve`
- `kubectl delete`、`helm uninstall/delete`
- `docker system prune`、volume/image/container/network prune、`docker rm/rmi --force`
- `brew uninstall/autoremove/untap`、`mas uninstall`、`mise uninstall/implode/prune`
- `gh repo/release/secret/cache/run delete`
- `aws s3 rb/rm`、`aws ec2 terminate-instances`、`aws iam delete-*`、`aws dynamodb delete-table`、`aws rds delete-*`
- `gcloud … delete`
- `supabase db reset`、`supabase projects delete`
- `npm unpublish/publish`、`pnpm purge/store prune`、`yarn unpublish/publish`
- `defaults delete`
- `git filter-repo/branch`

この正規表現は Codex ゲートガードと SSOT を共有します（[codex.ja.md](codex.ja.md#ゲートガード) を参照）。

### PostToolUse

| フック ID | マッチャー | Async | 説明 |
|---|---|---|---|
| `post:observe:continuous-learning` | `*` | Yes | CLV2 `observe.sh post`；`tool_complete` を `observations.jsonl` にキャプチャ |
| `posttooluse:wave-session-event` | `AskUserQuestion` | Yes | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437）。`AskUserQuestion` に回答があったときに発火する。`tool_response` に回答本文が含まれるため、相関フィールド（`session_id`、`prompt_id`、`hook_event_name`、`tool_name`、`tool_use_id`）のみに射影して記録する — 回答本文はディスクに残らない。 |

### PostToolUseFailure

| フック ID | 説明 |
|---|---|
| `post:mcp-health-check` | 失敗した MCP ツール呼び出しを追跡し、不健全なサーバーをマーク、再接続を試みる。Claude Code はこの env var をエクスポートしないため、`CLAUDE_HOOK_EVENT_NAME=PostToolUseFailure` を明示的に設定している。 |
| `posttoolusefailure:wave-session-event` | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437；matcher は `AskUserQuestion`）。通常の tool failure で発火する；上記の `PostToolUse` と `tool_use_id` でペアリングし、質問が決着したことを判定する（#448）。`PostToolUse` と同様、相関フィールドのみを射影して記録する — 回答本文はディスクに残らない。 |

### Notification

| フック ID | マッチャー | Async | 説明 |
|---|---|---|---|
| `notification:ntfy-notify` | `permission_prompt\|idle_prompt\|agent_needs_input\|agent_completed` | Yes | repo/branch/account/session の帰属情報付きで、attention/completion 通知を Tailscale 経由の自己ホスト ntfy サーバーへ publish する（#337; [Notifications](../architecture/notifications.ja.md) 参照）。フェイルオープン: `~/.config/ntfy/notify-env` が無ければサイレント no-op |
| `notification:wave-session-event` | `permission_prompt\|idle_prompt\|agent_needs_input` | Yes | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437）。上記 `notification:ntfy-notify` より matcher が狭く、`agent_completed` を含まない。 |

### Stop

| フック ID | Async | 説明 |
|---|---|---|
| `stop:cost-tracker` | Yes | セッションごとのトークンとコストメトリクスを追跡 |
| `stop:desktop-notify` | Yes | **Disabled**（`env.ECC_DISABLED_HOOKS` により）— `stop:ntfy-notify` に置き換え（#337）。ドキュメント化された 1 ステップロールバック（ここで再有効化 + ntfy エントリを一緒に削除）のため配線は維持 |
| `stop:ntfy-notify` | Yes | セッション停止通知（切り詰め + client-identifier スクラブ済みサマリー）を自己ホスト ntfy サーバーへ publish する（#337） |
| `stop:wave-session-event` | Yes | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437）。ターンが idle/完了したことを記録する。 |

### StopFailure

| フック ID | Async | 説明 |
|---|---|---|
| `stopfailure:wave-session-event` | Yes | 上記 [UserPromptSubmit](#userpromptsubmit) と同じ wave-orchestrator 記録スクリプト（`WAVE_ORCHESTRATOR_SESSION` による opt-in、#437）。API エラーでターンが `Stop` を経ずに終わったときに発火し、orchestrator が子セッションを固着扱いせず idle と判定できるようにする（#447 関連）。 |

---

## ECC ランチャー — ecc-hook.sh

`~/.claude/ecc-hook.sh` は ECC の ~1.5 KB/フックの minified `node -e` ブロブを置き換える小さな bash ランチャーです。

**存在理由。** ECC は通常、各フックコマンドをインラインブロブとして配布します。その大部分は `~/.claude/plugins/…` を走査するプラグインルートフォールバック解決です。本 dotfiles では ECC を chezmoi external（Claude プラグインではない）として管理しているためプラグインルートは固定（`~/.agents/skills/ecc`）であり、このフォールバック走査はデッドウェイトで `settings.json` を読みにくくしていました。このランチャーは `CLAUDE_PLUGIN_ROOT` を 1 回設定し、ECC 自身の `plugin-hook-bootstrap.js` にフックスペックを渡してターゲットスクリプトを解決・ディスパッチします。

**フェイルオープン動作。** `plugin-hook-bootstrap.js` が存在しない場合（`chezmoi apply` が external をフェッチする前の新規マシン）、ランチャーは stdin をそのまま渡して終了コード 0 — ECC 自身の missing-runtime 規約に合わせたサイレント no-op です。

**セッション単位の opt-out — `ECC_DISABLED_HOOKS_EXTRA`。** `settings.json` の `env` ブロックはシェルで export した `ECC_DISABLED_HOOKS` を上書きするため、`ECC_DISABLED_HOOKS=… cld-r06` のような prefix 起動はサイレントに無効でした（#281）。そこでランチャーは、`settings.json` が定義しない変数 `ECC_DISABLED_HOOKS_EXTRA`（シェルの export がそのままフックプロセスへ届く）をディスパッチ前に `ECC_DISABLED_HOOKS` へマージします。`claude-config` エイリアスはこのチャネルを使います。同じ優先順位により `ECC_HOOK_PROFILE` は `settings.json` の値（`strict`）に固定され、シェル側のプロファイル切替はありません。なおこのチャネルはスコープされていません: launcher を経由する任意のフック ID — Bash destructive gate を含む — をこの方法で無効化でき、セッションの shell env を設定できるもの（例: allow 済み direnv の `.envrc`）であれば到達できます。

**settings.json でのコマンドパターン：**

```
# シンプルなフック:
$HOME/.claude/ecc-hook.sh scripts/hooks/session-start-bootstrap.js

# プロファイルゲーティング付きフック:
$HOME/.claude/ecc-hook.sh scripts/hooks/run-with-flags.js <hook-id> <script-path> standard,strict
```

`run-with-flags.js` ラッパーはセルフゲーティングします：`ECC_HOOK_PROFILE` と `ECC_DISABLED_HOOKS` を読み、現在のプロファイルが宣言セットに含まれないか、フック ID が `ECC_DISABLED_HOOKS` に含まれる場合はターゲットスクリプトをスキップします。

---

## フックスクリプト (hooks-fork/)

`home/dot_claude/hooks-fork/` には、`ecc-hook.sh` を経由せず `node <file>` として直接呼び出されるフックスクリプトを置きます（`run-with-flags.js` はプラグインルート外のスクリプトをパストラバーサルガードで拒否するため）。

現在残っているのは [UserPromptSubmit](#userpromptsubmit) フックである `prompt-conform-suggest.js` のみです。これは ECC フォーク**ではありません** — ECC 側の対応実装がなく、ECC ランタイムを `require()` せず、ステートレス（プロンプト本文はディスクにも DB にも書かれない）です。チューニング用の環境変数は[環境変数リファレンス](#環境変数リファレンス)を参照してください。

**ここにあった 3 つの ECC fork は #496（#473 の sub-issue）で削除しました:**

| 削除した fork | 役割 | 削除理由 |
|---|---|---|
| `governance-capture.js` | ECC のガバナンスイベント（秘匿情報・承認要コマンド・機微パス）を `node:sqlite` でアカウントごとの `state.db` へ永続化 | #473 AC-015: キャプチャが判断のループに繋がっておらず、raw コマンド・パス・governance payload を保存された文脈へ広げる唯一の writer だった |
| `post-bash-command-log.js` | 実行した Bash コマンドをアカウントごとの 0600・秘匿情報マスク済み `bash-commands.log` へ追記 | #473 AC-010 / AC-015: 誰も読まない raw コマンド監査 |
| `ecc-state-reader.js` | `ecc-status` / `ecc-sessions` / `ecc-work-items` zsh 関数の背後にある read-only CLI | #473 AC-015: 同じ `state.db` の読み側。writer と 3 つのシェル関数ごと削除 |

配備済みコピーは `home/.chezmoiremove` で回収します（chezmoi source からファイルを消しても、既に配備されたコピーは消えません）。これらが書いたデータ（`state.db`、`bash-commands.log`）は**意図的に残します**: #473 は本変更のスコープを「新規書き込みを止める」に限定しており、蓄積された履歴の削除は別途の明示判断です。

---

## ステータスライン

`~/.claude/statusline.sh` は 3 行のステータスラインをレンダリングします。`settings.json` の `statusLine` キーがこれを指します：

```json
"statusLine": {
  "type": "command",
  "command": "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh"
}
```

### レイアウト

```
L1  <ホスト>  <ディレクトリ>  <ブランチ> [*dirty] [⇡N⇣N]  [worktree]
L2  <モデル>  [effort]  [🧬N]  <ctx○>  [5h%]  [7d%]  <billable-cost>
L3  [battery%]  <network-RTT>  <claude-service-status>
```

- **L1**: ホストアイコン、プロジェクト相対ディレクトリ、dirty/ahead/behind インジケーター付き git ブランチ、worktree 名（worktree 内の場合）
- **L2**: モデル表示名、effort レベル、CLV2 本能クラスター数（🧬N）、残りコンテキストの円（●◕◑◔○）、5 時間・7 日レート制限のパーセンテージとリセット時刻、および請求対象コスト（dim の `incl.` マーカー、またはセッション／日次の金額を JPY で表示。換算レートがキャッシュされていない場合は USD）。金額の意味は [請求デルタコスト](#請求デルタコスト) を参照
- **L3**: バッテリー残量（macOS ラップトップのみ、`pmset` 経由）、ネットワーク RTT ティア（1.1.1.1 への ping）、Claude サービスステータス

### 実装上の制約

**bash 3.2 互換性。** macOS の `/bin/bash` はバージョン 3.2 で `\u` エスケープシーケンスをサポートしません。すべての Nerd Font グリフは `$'...'` リテラル内に生の UTF-8 バイトとしてエンコードされます（例：デスクトップアイコンは `$'\xef\x84\x88'`）。これによりグリフはエディタやフォントの事故を乗り越え、bash 3.2 でも読み取り可能です。

**ノンブロッキング I/O。** すべての外部・ネットワーク操作（ping、curl、`ccusage`、`pmset`）はバックグラウンドサブシェルで実行され、キャッシュディレクトリ（`$XDG_CACHE_HOME/claude-statusline`、mode 700）に書き込まれます。レンダラーはキャッシュから読み取り、各エントリはバックグラウンドでそれぞれの TTL で更新されます（ネットワーク: 15 秒、バッテリー: 60 秒、日次コスト: 5 分、為替レート: 24 時間）。レンダリングは常に瞬時です。

**JPY コスト換算。** 為替レートは `api.frankfurter.dev`（ECB 日次レート）から 24 時間キャッシュで取得されます。レートが利用可能な場合はコストを `¥N,NNN` で表示し、そうでない場合は `$N.NN` にフォールバックします。

### 請求デルタコスト

サブスクリプションでは 5h/7d quota 内の消費は既に支払い済みであり、**quota を消化したウィンドウを超えた消費だけ**が利用クレジットに対して課金されます。生のセッション／日次合計を出すと、決して請求されない金額と実際に請求される金額が同じグリフの下に並んでしまいます。そこで L2 は「実際に支払う額」を表示します：

| stdin の状態 | 表示 | 理由 |
| --- | --- | --- |
| `rate_limits` が無い | `¥N (session)` `¥N (daily)` — 生の合計 | API キー（従量課金）認証、またはサブスクリプションセッションの最初の API 応答前。消化される quota が無いため、合計値が**そのまま**請求額 |
| `rate_limits` があり、両ウィンドウが 100% 未満 | `incl.`（dim） | 請求対象が無い。セグメントを消さずマーカーを置くことで、「無料」であることと「コスト取得が壊れた」ことを区別できる |
| どちらかのウィンドウが 100% | `¥N (session)` `¥N (daily)` — ウィンドウ消化時点からの増分 | 起点を超えた消費だけが請求される |

**起点のライフサイクル。** ウィンドウを消化した瞬間の消費額が起点となり、`$XDG_CACHE_HOME/claude-statusline/session_<session_id>.json`（0600）の `billing` キー配下に保存されます。これは profile 単位ではなく **session 単位**です。profile 単位にすると同一 profile の並列セッションが互いの起点を上書きしてしまうためで、これは profile 単位の rate-limits スナップショットの `effort` で #449 が実測で確立した失敗です。

同じファイルには `context` という兄弟キーも同居します（#499）。`context_window.remaining_percentage` を、`billing` の有無に関わらず**毎レンダ**永続化したものです。起点と違い `context` にはライフサイクルと呼べるものがなく、毎レンダ単純に上書きされます。そのためファイルは `context` のみ（超過なし）、`billing` のみ（harness が `context_window` を省略／不正な値で返したレンダでの超過）、あるいは両方を保持する場合があります。quota ウィンドウが閉じて起点が破棄される際も、`context` の値が残る限りファイルは `billing` を落として書き直されるだけで、どちらのキーも残らない場合にのみファイルごと削除されます。

超過中も `context` は生きたままでなければなりません。「billed」の書き込みは、この描画の context body、または**既にファイルに保存されている値**のいずれかが非空であれば強制されます——今回の描画分だけではありません。これにより、超過の途中で harness が `context_window` の送信をやめても、古いパーセンテージがディスクに残り続けるのではなく能動的に削除されます。どちらの側にも値が無くなれば、この理由による強制書き込みは止まるため、ファイルが無限にチャーンすることはありません。

起点は、消化済みウィンドウのうち**最も遅くリセットされる**方に紐付けます。超過を持続させているのがそのウィンドウだからです。起点が有効なのは、そのウィンドウが同一インスタンス（`resets_at` が不変）であり、かつ依然として消化済みである間だけです。`used_percentage` は同一インスタンス内で単調非減少なので、この 2 条件は「起点以降ずっと超過状態だった」ことの証明になります——壁時計比較が不要で、クロックスキューの影響を受けません。両ウィンドウが消化済みの間に起点はより長生きする方へ引き継がれるため、短い方が超過中にロールオーバーしても起点は失われません。どちらのウィンドウも消化済みでなくなると起点は削除され、表示は `incl.` に戻ります。

**日次の繰越。** `ccusage` の合計は 0 時にリセットされるため、前日の請求残差を繰越額に積んでから新しい日の起点を取り直します。日次の金額は `繰越額 + (当日の合計 − 当日の起点)` です。どちらの増分も 0 でクランプされるので、`ccusage` の後方修正やセッション再開で負の請求額が描画されることはありません。日次側の起点は遅延取得されます——`ccusage` はバックグラウンドで更新されるため、コールドキャッシュ時に 0 で確定させると当日全額が課金として表示されてしまいます。

**通常パスのコスト。** statusline は毎ターン再描画されるため、ウィンドウ判定・session id の解決・「ディスク上に起点があるか」の探索はシェル組み込みだけで行います。超過中は**起点（billing）側**自体の値が、従来どおりのスキップ最適化（値が動いておらずファイルも既にあれば書かない）を今も駆動しますが、#499 でこれを上書きする 2 つのトリガーが加わりました——今回の描画に有効な `context` body があるとき、または前回までの `context` が残っていて削除が必要なとき（前述）です。超過が無いときは、`context_window.remaining_percentage` が存在する限り `context` 兄弟キーは**毎レンダ**書き込まれます——これは `write_harness_cost` / `write_rate_limits_snapshot` が既に毎レンダ払っているのと同じコストを、このファイルにも広げたものです。そのため quota 内（あるいは `rate_limits` が無い）レンダでも、`context` を最新に保つための小さな atomic write が毎ターン 1 回発生するようになりました（以前はゼロでした）。state ファイルの母集団も併せて広がります: `session_<session_id>.json` は従来「実際に quota ウィンドウを超過したセッション」にしか存在しませんでしたが、現在は harness が context 残量を返す**すべてのセッション**に存在します。帰結は 2 つです。ディスク上のファイル数は超過回数ではなく**起動したセッション数**に比例するようになります（下記の 7 日掃除が上限を与えます）。描画パスでは `billing_state_prune` の先頭 glob が常にファイルを見つけるため、その後段の日次スタンプ判定（`date` と `stat`）が「一度も走らない」から「毎レンダ走る」に変わります —— quota を超過しない環境の「追加 fork ゼロ」という性質は失われ、context シグナルと引き換えになりました。終了済みセッションが残したファイルは 1 日 1 回バックグラウンドの `find` で掃除され、この掃除は**自セッションの quota 状態に関わらず**走ります（長期の超過状態にある環境では、そうしないと永久に回収されないため）。なお `find -mtime +N` は 24 時間単位を厳密な `>` で比較するため、実効的な保持期間は最大 N+1 日です。

**既知の制約: 超過中に開始したセッション。** 起点を最初に取る時点では、「このセッションはウィンドウが枯渇する前から走っていた」のか「枯渇した後に開始した」のかを区別する手段がありません。起点はその描画時点の消費額とするため、前者では正しく、後者では初回ターン分の課金が漏れます。代替案（起点を 0 にする）は共通ケースである前者で「超過前の消費全額」を課金として計上してしまうため、この過小報告を意図的なトレードオフとして選んでいます。

**R06 アカウントバッジ。** `CLAUDE_CONFIG_DIR` が `~/.claude-r06` を指す場合、ステータスラインはリバースビデオの `R06` バッジをレンダリングしてアクティブアカウントを視覚的に区別します。

**CLV2 🧬N セグメント。** `clv2_cluster_count()` 関数は `<homunculus>/.review-ready-clusters` にキャッシュされた整数を読み取ります。その writer（`clv2-session-notify.sh`）は #496 で削除されたため（[CLV2 オブザーバー配線](#clv2-オブザーバー配線)参照）、このセグメントはキャッシュが最後に受け取った値のまま変化しません。レンダラーの除去はステータスライン側の変更に属します。以下の優先順位は、将来 writer が復活したときに両者が乖離しないようそのまま残しています：

1. `$CLV2_HOMUNCULUS_DIR`（設定されており絶対パスの場合）
2. `$XDG_DATA_HOME/ecc-homunculus`（`XDG_DATA_HOME` が絶対パスの場合のみ）
3. `$HOME/.local/share/ecc-homunculus`（フォールバック）

非絶対パスの `XDG_DATA_HOME` は無視されます（そのまま使用されません）。プロデューサーとコンシューマーがこの優先順位で一致している必要があります；不一致はセグメントが古いデータやゼロを読み取る原因になります。

---

## CLV2 オブザーバー配線

CLV2 (continuous-learning v2) はツール呼び出しを観察し、繰り返しパターンを「本能 (instinct)」にクラスタリングし、`/evolve` でスキルを提案する ECC スキルです。

### SessionStart のライフサイクル

`clv2-session-notify.sh` はかつてセッションごとに 1 回実行され、レビュー待ち instinct クラスター数を再計算し、7 日スロットルのデスクトップ通知を発火していました。#496（#473 AC-027）で削除しました: セッション開始の通知は行動要求ではなく、そのセッションでほとんど誰も動かない数値のために Python の `evolve` パスが毎セッション走っていたためです。

`SessionStart` に残るのは `session:start` で、オブザーバーの session lease を登録します。文脈注入は無効（`ECC_SESSION_START_CONTEXT=off`、#473 AC-025）ですが、エントリ自体は残す必要があります — `session-start.js` は lease を**注入ゲートより前**に書き込むため、エントリごと削除するとループが依存する観測まで止まります。

ステータスラインは今も `<homunculus>/.review-ready-clusters` から 🧬N セグメントを描画しますが、このキャッシュには writer がいません。したがってセグメントは最後に書かれた値で凍結します。レンダラーの除去はステータスライン側の変更に属するため、ここでは行いません。

### ツール呼び出しごとのオブザーバー

CLV2 の `observe.sh` スクリプトは `PreToolUse` と `PostToolUse` の両方に async フックとして配線されています：

- `pre:observe:continuous-learning` — `tool_start` イベントを `observations.jsonl` にキャプチャ
- `post:observe:continuous-learning` — `tool_complete` イベントをキャプチャ；Haiku オブザーバープロセスにシグナル

スクリプトは ECC の `observe-runner.js` を経由せず直接呼び出されます（ECC プラグインルートに `skills/` ツリーがないため、runner が `observe.sh` を見つけられない）。スクリプトは `$0` から独自の `SKILL_ROOT` を解決します。両フックは async なのでツールごとのレイテンシを追加しません。

**オブザーバーの有効化。** オブザーバーは各アカウントのランタイム `<homunculus>/config.json` で有効化する必要があります。これは `run_onchange_after_14-enable-clv2-observer.sh.tmpl` によって実行され、ライフサイクルスクリプトのコンテンツハッシュが変わる各 `chezmoi apply` 後に `jq` マージで `observer.enabled=true` を書き込みます。CLV2 スキル自身の `config.json` を編集すると chezmoi external の 168 時間更新で上書きされます。

---

## 朝次レーダーのスケジュール実行

kryota-dev/dotfiles#257: launchd LaunchAgent が平日朝に `/morning-brief` を headless 実行し、結果を macOS 通知でハンドオフします。検知 + 通知のみで、下流 skill（issue-fleet / renovate-sweep / review-fleet）の auto-dispatch は行いません。

| 構成要素 | パス | 役割 |
|---|---|---|
| LaunchAgent plist | `home/Library/LaunchAgents/dev.kryota.morning-radar.plist.tmpl` → `~/Library/LaunchAgents/` | 平日（月〜金）9:00 ローカル時刻に発火（この Mac は JST 前提） |
| wrapper | `~/.claude/morning-radar.sh` | personal アカウントで `claude -p "/morning-brief …"` を実行し、brief 保存と通知を行う |
| 登録 | `run_onchange_after_30-register-launchd-agents.sh.tmpl` | plist 変更時に `launchctl bootout → bootstrap`。CI ではスキップ（[ライフサイクルスクリプト](../architecture/lifecycle-scripts.ja.md)） |

- **スケジュール挙動。** スリープ中に跨いだ発火は復帰時に 1 回へ coalesce され、電源オフの日はスキップされます。`~/.local/state/morning-radar/` の日付マーカーで課金実行を 1 日 1 回に制限し、手動再実行は `~/.claude/morning-radar.sh --force` で行います。
- **縮退モード。** claude.ai の Gmail/Calendar コネクタは headless で OAuth を完了できないため、brief は取得失敗を明記して GitHub + ローカルコンテキストへ縮退します（morning-brief SKILL.md に記載の挙動）。
- **権限とコスト。** wrapper は明示的な `--allowedTools` allowlist（read-only の `gh`/`git` とファイル読み取り、`Write` は brief 出力先のみ）を渡し、`--dangerously-skip-permissions` は使いません。モデルは `sonnet` に固定、`--max-turns` でターン上限、600 秒の watchdog が課金バックストップです。平日 5 回/週の費用は #257 で事前承認済みです。
- **出力契約。** brief は `~/dotfiles/.kryota-dev/morning-brief/<YYYY-MM-DD>.md` に保存され、最終応答は `HEADLINE:` の 1 行のみ。wrapper がそれを ntfy 通知に載せ、click で tailnet 上に serve された brief ページを開きます（tailnet-only、#361 — [notifications](../architecture/notifications.ja.md#朝ブリーフの配信-361) 参照）。

---

## 改善候補キュー

Issue kryota-dev/dotfiles#501（#473 のサブ issue）: ECC 継続的改善ループは、候補を通知で押し付けるのではなく、ローカルの所有者専用キューに保持します。候補は複数を同時に保持し、1 件に絞られるのは**提示の場面だけ**です。

| 構成要素 | パス | 役割 |
|---|---|---|
| ランチャー | `home/dot_local/bin/executable_agent-improvement` → `~/.local/bin/agent-improvement` | mise pin の node で CLI モジュールを exec する |
| CLI モジュール | `home/dot_local/lib/agent-improvement/{paths,schema,store,view,cli}.mjs` | パス解決と所有者専用書き込み、境界検証、保存、導出ビュー、サブコマンド dispatch |
| 状態 | `${XDG_STATE_HOME:-~/.local/state}/agent-improvement/queue.json` | ディレクトリ 0700 / ファイル 0600。`.chezmoiignore` で除外し、public リポジトリへ取り込まれないようにする |
| シェル面 | `home/dot_config/zsh/claude.zsh` の `improvement-status` / `improvement-next` / `improvement-resolve` | フラグを透過させるため alias ではなく zsh 関数 |
| 会話面 | curated skill `improvement-status` | `agent-improvement status` の出力をセッション内に整形表示する |

**サブコマンド**: `status [--history]` と `next` は厳密に読み取り専用で、書き込むのは `resolve` と `upsert` だけです。

- **表示は評価しない。** `status` と `next` は state ディレクトリを作らず、キューファイルにも触れず、週次 evaluator を起動しません。失効と延期期限は読み取り時の導出ビューとして計算し、書き戻しません。つまり「表示したせいで状態が変わる」経路が存在しません。
- **順位は保存せず導出する。** 候補は evaluator が順位付けに使った 5 指標（頻度・影響・根拠の強さ・実装コスト/リスク・期待効果）を記録し、順位は固定の重み付けから毎回再計算します。同点は根拠の新しい順 → id 昇順で解決します。順位を保存すると、要約元の指標と乖離しうるためです。
- **回答は三択固定。** `resolve <id> --decision=adopt|defer|reject` が判断面のすべてです。採用には成功指標・変更前の基準値・再評価日・効果不十分時の調整/revert 条件が必須です。延期の既定は 7 日です。
- **失効と終端状態。** 新しい根拠が 28 日無い active 候補は失効として表示します。`rejected` と `promoted` は終端で、後から `upsert` されても復活せず skip として報告されます。
- **Issue 化は payload を捨てる。** 採用に `--issue-url` を添えると、候補は id・タイトル・作成日時・Issue URL だけになります。GitHub Issue を唯一の正本とし、キュー側に二重の正本を残さないためです。
- **provenance のみを持つ。** 候補が持つ account 情報は `evidence_accounts`（根拠がどのアカウント由来か）だけです。どのアカウントに影響する変更かは、採用後の planning で判断します。

このキューを埋める週次 evaluator（#506）と、読み取って提示する完了時の経路（#507）は別の変更です。キューは単体で動作します（`agent-improvement upsert` に候補を流し込めば、採用・延期・見送り・Issue 化の一巡をどちらも無しに検証できます）。

---

## レビューサブエージェント

<!-- FACT:claude-agent-count -->13<!-- /FACT --> 個のサブエージェント定義ファイルが `home/dot_claude/agents/` に存在し、`~/.claude/agents/` にデプロイされます。すべてのシステムプロンプトは日本語のレビュー出力を誘導するために日本語で書かれています。

すべてのエージェントは frontmatter で `model` と `effort` の両方をピン固定しており、呼び出し元セッションのモデルを継承しません（standalone 起動でもピン固定された tier で動作します）。これらの値の SSOT は frontmatter であり、下表は説明用です。

| エージェント | 用途 | Tier |
|---|---|---|
| `cc-code-review.md` | 汎用コードレビュー ([MUST]/[SHOULD]/[NITS]/[GOOD] 形式) | sonnet / xhigh |
| `cc-security-review.md` | OWASP フォーカスのセキュリティレビュー | sonnet / xhigh |
| `adversarial-verifier.md` | レビュー指摘を独立視点で反証（large tier の反証ラウンド） | sonnet / xhigh |
| `architecture-reviewer.md` | リポジトリ全体の集約視点 — 単一 diff では見えない重複・設計 drift | sonnet / high |
| `typescript-reviewer.md` | TypeScript 特化レビュー | sonnet / high |
| `python-reviewer.md` | Python 特化レビュー | sonnet / high |
| `react-reviewer.md` | React/フロントエンドレビュー | sonnet / high |
| `database-reviewer.md` | データベーススキーマとクエリレビュー | sonnet / high |
| `performance-reviewer.md` | パフォーマンスレビュー（N+1・hot path・メモリ・キャッシュ） | sonnet / high |
| `test-reviewer.md` | テストのカバレッジ・独立性・信頼性レビュー | sonnet / high |
| `ux-reviewer.md` | UI/UX・アクセシビリティレビュー | sonnet / high |
| `renovate-analyzer.md` | Renovate 依存関係更新分析 | sonnet / high |
| `fact-check-worker.md` | 1 件の指摘を一次ソースで裏取り（read-only、書き込み・実行なし） | sonnet / high |

`multi-review` スキルは検出されたファイルタイプに基づいて言語/ドメインレビュアーを、変更の特性に基づいて横断観点（performance/test/ux）レビュアーを動的にスポーンします。`architecture-reviewer` は `--arch` または pr-workflow の large tier のときのみ、`adversarial-verifier` と `fact-check-worker` は PR 単位ではなく指摘単位でスポーンされます。

---

## r06 ワークアカウント

`home/dot_claude-r06/` は `~/.claude-r06/` に 6 つのシンボリックリンクをデプロイします：

| シンボリックリンク先 | 指す先 |
|---|---|
| `settings.json` | `~/.claude/settings.json` |
| `CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `statusline.sh` | `~/.claude/statusline.sh` |
| `agents/` | `~/.claude/agents/` |
| `commands/` | `~/.claude/commands/` |
| `skills` | `~/.claude/skills`（→ `~/.agents/skills`） |

設定は 1 つの SSOT；ランタイム状態は `claude` ラッパー（`~/.local/launchers/claude`、`claude`/`cld`/`cld-r06` としてアクセス）が設定する環境変数で分離されます：

| 環境変数 | `claude` / `cld` の値 | `cld-r06` の値 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | `~/.claude-r06` |
| `ECC_AGENT_DATA_HOME` | `~/.claude` | `~/.claude-r06` |
| `CLV2_HOMUNCULUS_DIR` | `~/.local/share/ecc-homunculus-default` | `~/.local/share/ecc-homunculus-r06` |
| `GATEGUARD_STATE_DIR` | `~/.claude/.gateguard` | `~/.claude-r06/.gateguard` |

セッション、ガバナンス `state.db`、本能、bash コマンドログ、キャッシュは各ランタイムコードがこれらの環境変数からパスを解決するため自然に分離されます。

`CLV2_HOMUNCULUS_DIR` だけは意図的に config dir の**外**に置き、アカウントをパスのサフィックスで表現しています。Claude Code は config dir 配下の全パスを sensitive file として扱い、書き込み前に対話承認を要求します。一方 CLV2 の分析パスは headless（`claude --model haiku --print`）で承認者がいないため、この変数が `<account>/ecc-homunculus` を指していた間は本能の書き込みが一度も成功しませんでした。observer は承認交渉で turn を使い切り "Reached max turns" で終了し、本能の生成数はゼロのままでした（#336）。他の 3 変数が config dir 配下のままなのは、それらを書くコード（node フック、シェルスクリプト）が Claude Code の Write ツールを経由せず直接書き込むため、sensitive-file ゲートの対象にならないからです。

`claude` は `cld` と同じラッパースクリプトに解決されるため（`~/.local/launchers/claude` は PATH 上で mise のシムより前に維持されています — [アカウント分離](account-isolation.ja.md#ベア呼び出しはもはやギャップではない) を参照）、素の `claude` 呼び出しも `cld`/`cld-r06` と同一の per-account 環境注入を経由するようになりました。別のフォールバックへ落ちることはありません。ラッパーの fill-gaps ルール（`CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`）により `claude` と `cld` は同一に振る舞います：どちらもすでに設定済みの `CLAUDE_CONFIG_DIR` を維持し（フック起動の子プロセスが親セッションのアカウントに留まるため）、それ以外は個人アカウントにデフォルトします。異なるのは `cld-r06` のみで、`CLAUDE_CONFIG_DIR=$HOME/.claude-r06` を無条件に強制します。

---

## 環境変数リファレンス

| 変数 | 設定場所 | 効果 |
|---|---|---|
| `ECC_HOOK_PROFILE` | `settings.json env` | `strict` = strict プロファイルでゲーティングされるすべてのフックを実行。固定値：settings.json env がシェルの export を上書きするため、セッション単位のプロファイル切替はない（#281） |
| `ECC_DISABLED_HOOKS` | `settings.json env` | スキップするフック ID のカンマ区切りリスト。#496 以降は、ECC ランタイム内部にあり `settings.json` から配線を外せないサブフックだけを列挙する: `pre:bash:tmux-reminder`、`pre:bash:git-push-reminder`、`pre:bash:commit-quality`（#473 AC-010）と `stop:desktop-notify`（#337 のロールバック配線）。対応するエントリが存在しないフック ID は削除した — 何もゲートしていないのに有効な安全判断のように読めるため |
| `ECC_DISABLED_HOOKS_EXTRA` | シェル（`claude-config` エイリアス、prefix 起動） | セッション単位の追加 opt-out：settings.json env が基底変数を上書きするため、`ecc-hook.sh` がこれを `ECC_DISABLED_HOOKS` へカンマ結合でマージする（#281） |
| `ECC_SESSION_START_CONTEXT` | `settings.json env` | `off` = SessionStart の文脈（前回セッション要約・active instinct・learned skill・プロジェクト種別）を一切注入しない。#473 AC-025。必要時は `--continue`/`--resume` と `$session-summary` で賄う |
| `GATEGUARD_BASH_ROUTINE_DISABLED` | `settings.json env` | `1` = セッション最初の非読み取り Bash に対するゲートガードの routine ゲートをスキップする。破壊的コマンドの事実確認は別の実行経路であり有効なまま（#473 AC-008 / AC-009） |
| `GATEGUARD_BASH_EXTRA_DESTRUCTIVE` | `settings.json env` | 追加の破壊的コマンドパターンの正規表現；Codex ゲートと SSOT 共有 |
| `PROMPT_CONFORM_SUGGEST_MIN_LENGTH` | 既定未設定（運用者がチューニング可能） | `prompt-conform-suggest.js` がプロンプトをさらに検査する前に要求する文字数閾値（既定 150）を上書きする。非負整数のみ有効、それ以外は既定値へフォールバック |
| `PROMPT_CONFORM_SUGGEST_TASK_REGEX` | 既定未設定（運用者がチューニング可能） | `prompt-conform-suggest.js` が使う命令形タスク動詞の正規表現（既定は JP/EN のタスク文面）を上書きする。不正な正規表現は組み込み既定へフォールバック |
| `PROMPT_CONFORM_SUGGEST_KEYWORD_REGEX` | 既定未設定（運用者がチューニング可能） | `prompt-conform-suggest.js` が使う skill/プロンプト作成系キーワードの正規表現を上書きする。不正な正規表現は組み込み既定へフォールバック |
| `CLAUDE_PLUGIN_ROOT` | `ecc-hook.sh` | `~/.agents/skills/ecc` に固定；ECC のプラグインフォールバック走査をスキップ |
| `CLAUDE_CONFIG_DIR` | claude ラッパー | Claude Code が使用する `~/.claude*` ディレクトリを選択 |
| `ECC_AGENT_DATA_HOME` | claude ラッパー | ECC（とフック fork）が状態を書き込む場所 |
| `CLV2_HOMUNCULUS_DIR` | claude ラッパー | CLV2 本能/クラスターの homunculus データディレクトリ。`~/.local/share/ecc-homunculus-<アカウント slug>` に置き、config dir の外に出すことで headless な本能書き込みが sensitive-file ゲートに阻まれないようにしている（#336） |
| `ECC_OBSERVER_TIMEOUT_SECONDS` | claude ラッパー | 既定 300。CLV2 observer の watchdog を引き上げ、Haiku 分析が 120s で SIGTERM されるのを防ぐ（#256）。`:-` 形式のため明示 override が優先 |
| `OBSERVER_ACTIVE_HOURS_START` / `OBSERVER_ACTIVE_HOURS_END` | claude ラッパー | 両方の既定を `0` にして CLV2 session-guardian の時刻ゲート（upstream 既定 800-2300）を無効化する。この環境ではセッションが深夜帯に及ぶため、時刻ゲートが分析サイクルを丸ごと skip していた。guardian の cooldown ゲートと idle ゲートは引き続きサイクルを抑制する（#336） |
| `ECC_OBSERVER_MAX_TURNS` | claude ラッパー | 既定 100（upstream の上限値）。自動スケールの下限 20 では Read → 重複チェック → Write の途中で打ち切られていた。サイクルの実際の上限は turn 数ではなく上記の watchdog が決める（#336） |

---

## 関連ドキュメント

- [アカウント分離](account-isolation.ja.md) — 2 アカウントモデルの仕組み
- [スキルプロベナンス](skills-provenance.ja.md) — ECC/Anthropic external スキルフェッチとプロベナンス分類
- [Codex ハーネス](codex.ja.md) — Codex CLI の対応ドキュメント
- [アーキテクチャ概要](../architecture/overview.ja.md) — リポジトリ全体の構造
