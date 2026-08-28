---
slug: 526-noninteractive-mode-research
feature: wave-orchestrator と frontier-harness の agent 実行を CLI 非対話モードへ移せるかの調査
created_at: 2026-08-29T00:20:00+09:00
issue: 526
parent: 525
grill_session: n/a (investigation report — not a grill-me output)
status: finalized
---

# CLI の非対話モード・サンドボックス・Remote Control 併用可否の調査

本書は #526 の成果物である。**実装は含まない。** 3 つの CLI（Claude Code / Codex / Antigravity）の
非対話モード・サンドボックス・Remote Control 併用可否を一次ソースで確認し、`wave-orchestrator` と
`frontier-harness` の移行可否と範囲を決める。後続 issue は「候補の列挙」までに留める（issue 化は user 承認を経る）。

> **この文書の位置づけ（`.claude/prds/` の PRD 契約からの意図的な逸脱）**
> `.claude/prds/` は本来 `grill-me` が出力する PRD の置き場で、`grill_session` frontmatter と
> Background / User Story / Acceptance Criteria（`AC-NNN`）/ Considered Alternatives・Rejection Rationale /
> Out of Scope / Open Questions の骨格を契約とする（`grill-me/SKILL.md`）。本書は grill-me の対話成果物ではなく
> **調査報告**なので、`grill_session` は `n/a` とし、Acceptance Criteria は issue #526 の完了条件との対応表として持つ。
> **`/planning --input-prd` の入力としては使わないこと**（AC が実装タスクの受け入れ条件ではなく、調査の網羅性チェックだから）。
> 契約のうち意味のある要素（User Story / Considered Alternatives・Rejection Rationale / Out of Scope / Open Questions）は
> 満たしている。

## Background

`wave-orchestrator` は tmux ペインに**対話セッション**を立て、停止するたびに hook イベントで状態を分類し、
画面を参照して代理応答している。この経路は TUI の描画と外部からのキー送出に依存するため、次の事故を生んだ。

| Issue | 事故 | 性質 |
| --- | --- | --- |
| #472 | TUI が dim（`ESC[2m`）で描くプレースホルダを実入力と誤読し、**誰も入力していない指示**を確定送信しうる | 内容が妥当に見えるので文面から見分けられない |
| #448 | 選択肢を Esc で閉じても hook イベントが 1 件も出ず、`--state` が `ASK_QUESTION` に固着する | 回復手段（`--dismiss`）を別途作って対処 |
| #486 | auto mode の `permission_prompt` は「止まる場合」と「止まらない場合」が両方あり、通知だけでは判別できない | `UNKNOWN` へ倒して fail-closed 化 |

いずれも「**対話 UI を外部から操作する**」ことに由来する。`frontier-harness` は provider adapter が未実装
（#493）で、`runWithRolloutGuard(config, context, executor)` の `executor` を**これから決める**段階にある。
両者が同じ実行基盤を共有できるなら、片方が決め打つ前に揃えて設計する価値がある。

## User Story

orchestrator の運用者として、子 agent の実行を「TUI を外から操作する」形から離せるかどうかを、
**推測ではなく一次ソースと実機挙動**で判断したい。そうすれば、移行する場合も見送る場合も、
その判断を後から根拠ごと辿れる（#472 / #486 のように、事故のたびにガードを足す前に「この経路自体を続けるべきか」を問える）。

## Acceptance Criteria（issue #526 の完了条件との対応）

`AC-NNN` は実装タスクの受け入れ条件ではなく、**調査の網羅性チェック**である。

| ID | 条件（issue #526 より） | 満たした箇所 |
| --- | --- | --- |
| AC-001 | 3 CLI の非対話モードを公式ドキュメントを一次ソースとして網羅的に調査し、機能と制約を裏取りする | §1.1 / §2.1 / §3.1、付録 B |
| AC-002 | 承認・選択肢など対話を要する経路が非対話モードでどう扱われるかを確認し、tmux 経路の「停止の検知と代理応答」の代替可否を判断する | §1.2（実測）／§2.2 / §3.2 / §6 |
| AC-003 | 長時間実行の中断・再開、成果物の受け取り、レビュー指摘への対応が非対話モードで成立するかを確認する | §1.3 / §1.4 / §2.3 / §3.4 |
| AC-004 | 各 CLI のサンドボックス機能を調査し、採否を検討する | §1.5 / §2.4 / §3.3 / §7.2 |
| AC-005 | Remote Control と非対話モードを併用できるかを調査する | §4（実測で併用不可を確認） |
| AC-006 | 移行の可否と範囲を決め、実装対象を後続 issue として分解する（issue 化はしない） | §7 / §8 |
| AC-007 | すべてが一次ソースで裏取りされ、参照先を含む根拠が文書に残る | 各節の［実測］/［原文］表記、付録 A（再現手順）・付録 B（参照一覧） |

## 調査方法

**一次ソースの定義**（本書で根拠として採用したもの）:

1. 各 CLI の公式ドキュメント原文（URL と取得日を付録 B に列挙）
2. 実機にインストールされた CLI の `--help` 出力
3. **実機での挙動検証**（付録 A に再現コマンド）

否定的断定（「○○が無い」「非対話では不可能」）は、ドキュメントに書かれていても**実機の対照実験で確認する**方針を取った。
実際、この方針で 2 件の誤りを回避している（後述 §1.2 の `AskUserQuestion` と §1.5 の `--sandbox` フラグ）。

**検証環境**（2026-08-28 〜 2026-08-29 に実施）:

| 項目 | 値 |
| --- | --- |
| OS | macOS（Darwin 25.5.0, arm64） |
| Claude Code | 2.1.250 |
| Codex CLI | codex-cli 0.150.1 |
| Antigravity CLI | agy 1.1.22 |

以降、**［実測］**の印がある記述は本調査で実際に走らせて確認した挙動、**［原文］**は公式ドキュメントの記述である。

## 1. Claude Code

### 1.1 非対話モードの起動と入出力

`-p` / `--print` で非対話実行になる［原文: cli-usage, headless］。

| 目的 | フラグ | 備考 |
| --- | --- | --- |
| 単発実行 | `-p "<prompt>"` | stdin をパイプすると追加コンテキストになる（10MB 上限） |
| 構造化出力 | `--output-format json` / `stream-json` | `stream-json` は NDJSON。最終行が `result` |
| スキーマ強制 | `--json-schema '<JSON Schema>'` | 結果は `structured_output` に入る |
| **1 プロセス多ターン** | `--input-format stream-json` | stdin に 1 行 1 メッセージ。ターンごとに `result` が出る［実測］ |
| turn 上限 | `--max-turns N` | print mode 限定。`--help` に出ないが実在する［実測］ |
| 予算上限 | `--max-budget-usd` | print mode 限定。subagent の消費も算入［原文］ |
| 起動高速化 | `--bare` | hooks / skills / plugins / MCP / CLAUDE.md を読まない。**認証は `ANTHROPIC_API_KEY` か `apiKeyHelper` のみ**［原文］ |

> ［原文 / cli-usage］"`claude --help` does not list every flag, so a flag's absence from `--help` does not mean it is unavailable."
>
> このためフラグの有無は `--help` ではなく**パース順を使った実測**で判定した（付録 A-1）。`--permission-prompt-tool`
> `--max-turns` `--system-prompt-file` `--append-system-prompt-file` は `--help` に出ないが実在し、`--sandbox` は実在しない。

**skill / slash command は `-p` でも動く**［原文 + 実測］。`/skill-name` をプロンプト文字列に含めると展開される。
実測でも `-p '/eli5 ...'` が該当 skill の `SKILL.md` を読み込む挙動を確認した。子セッションに `pr-workflow` を
走らせる前提が成立する。

`--bg`（background agent）と `-p` は**併用できない**［原文 + `--help`］。両者は別の非対話手段である。

### 1.2 承認と「選択肢で止まる」経路 ★中核

現行 tmux 経路の中核は「子が `AskUserQuestion` で止まる → 画面を見て番号キーを送る」である。
非対話モードでこれがどうなるかが、移行可否を決める。

#### 1.2.1 `AskUserQuestion` の可用性は `--permission-prompt-tool` の有無だけで決まる ［実測］

`system/init` イベントの `tools` 配列に `AskUserQuestion` が現れるかを 2×2 で対照した。

| permission mode | `--permission-prompt-tool` | `AskUserQuestion` |
| --- | --- | --- |
| `default` | なし | **不在** |
| `auto` | なし | **不在** |
| `default` | あり | 在 |
| `auto` | あり | 在 |

つまり **`-p` で prompt tool を配線しないと、子は「user に問う」能力そのものを失う**。
これは #525 が期待した「代理応答が不要になる」ではなく、**gate が静かに消える**という別の失敗である。
「止まらなくなった」と「問えなくなった」は外形が同じで、後者は本リポジトリが最も嫌う沈黙する故障にあたる。

#### 1.2.2 `--permission-prompt-tool` の実測プロトコル ［実測］

MCP stdio server を自作して配線したところ、承認要求は**同期的な MCP ツール呼び出し**として届いた。

受信 payload（`tools/call` の `params`）:

```json
{
  "name": "approve",
  "arguments": {
    "tool_name": "Bash",
    "input": { "command": "touch probe_written.txt", "description": "Create empty file probe_written.txt" },
    "tool_use_id": "toolu_01YZ1wKsDbSnTX43zuov1PTg"
  },
  "_meta": { "claudecode/toolUseId": "toolu_01YZ1wKsDbSnTX43zuov1PTg", "progressToken": 2 }
}
```

返却 payload（`content[0].text` に JSON 文字列として入れる）:

```json
{ "behavior": "allow", "updatedInput": { ... } }
{ "behavior": "deny",  "message": "orchestrator policy: merge is never proxied; escalating to the user" }
```

- `allow` を返すとツールが実行された［実測］。
- `deny` を返すと**ツールは実行されず**、`message` の文言がそのまま model に届き、
  最終 `result` の `permission_denials[]` に `tool_name` / `tool_use_id` / `tool_input` が記録された［実測］。
- **auto-approve 済みの呼び出しは prompt tool に来ない**［実測: `echo` は来ず、`touch` は来た］。
  read-only 相当のコマンドは permission 評価の手前で解決される［原文: agent-sdk/user-input
  "The callback never fires for auto-approved tools."］。

#### 1.2.3 `AskUserQuestion` も同じ経路で往復できる ［実測］

これが本調査で最も重要な確認である。`AskUserQuestion` の呼び出しは prompt tool に**問い・選択肢の構造化 JSON**
として届き、`updatedInput` に `answers` を載せて `allow` を返すと、その回答が model に配送された。

```text
prompt tool が受信:  {"tool_name":"AskUserQuestion",
                      "input":{"questions":[{"question":"Which colour?","header":"Colour",
                               "options":[{"label":"Red",...},{"label":"Blue",...}],"multiSelect":false}]},
                      "tool_use_id":"toolu_01A7qg..."}
prompt tool が返却:  {"behavior":"allow","updatedInput":{...,"answers":{"Which colour?":"Red"}}}
model が受け取った:  Your questions have been answered: "Which colour?"="Red".
最終 result:         "The answer received was: \"Red\""
```

**代理応答は画面参照なしで成立する。** 送信先ペインの取り違え、プレースホルダの誤読、Esc 固着、
確定キーの投機送信といった問題は、この経路には**構造的に存在しない**（画面を読まず、キーを送らず、
「今まさに未回答か」を推定する必要もない ── 呼ばれた時点が未回答であり、返り値が回答である）。

#### 1.2.4 承認を保留できる時間 ［原文］

prompt tool は同期呼び出しなので、**user へのエスカレーション中は子がブロックする**。上限は次のとおり。

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `MCP_TOOL_TIMEOUT` | `100000000` ms（約 28 時間） | MCP ツール実行全体の上限 |
| `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` | stdio は `1800000` ms（30 分） | 応答も progress 通知も無い時間の上限。progress 通知でリセットされる |
| `MCP_TIMEOUT` | `30000` ms | **起動時**に prompt tool の MCP server 接続を待つ上限 |

progress 通知を送るか idle timeout を延ばせば、実運用の「user が寝ている間」も保持できる。
逆に**何もしなければ 30 分でツール呼び出しが中断される**ので、エスカレーション設計はこの 2 つを意識する必要がある。

#### 1.2.5 prompt tool を配線しない場合の各モードの挙動 ［原文］

| 設定 | 承認が要る行為に当たったとき |
| --- | --- |
| `--permission-mode default`（`-p` の既定は Manual）| 承認手段が無い |
| `--permission-mode acceptEdits` | working directory への編集と一般的な FS コマンドのみ自動承認。他は同上 |
| `--permission-mode auto` | 分類器が判断。**3 連続 / 累計 20 回**ブロックで auto mode は一時停止するが、`-p` に prompt tool が無いと *"the action doesn't run and Claude keeps working... Claude Code doesn't stop the run"* ── **黙って実行されないまま継続する** |
| `--permission-mode dontAsk` | `permissions.allow` と read-only コマンド集合以外を拒否。**`AskUserQuestion` は allow ルールがあっても拒否される** |
| `--dangerously-skip-permissions` | ほぼ全通し。ただし *actions no mode auto-approves*（`AskUserQuestion`・`requiresUserInteraction` な MCP ツール・明示 ask ルール・critical path への `rm`）は依然として自動承認されない |

`-p` + auto の「黙って実行されない」は #486 の裏返しである。tmux 経路では「止まったのか動いているのか判らない」だったものが、
非対話では「**止まらないが、やったはずのことをやっていない**」に変わる。prompt tool を配線すればフォールバック先ができる。

### 1.3 長時間実行・中断・再開

- **セッション ID の指定と再開**［実測］: `--session-id <uuid>` で採番し、`-p --resume <uuid>` で**別ディレクトリからでも**
  文脈を保ったまま再開できた（v2.1.223 以降は machine 全体を検索する［原文］）。再開後も `session_id` は同一。
- **1 プロセス多ターン**［実測］: `--input-format stream-json` で 2 ターンを 1 セッション（`session_id` 同一）として処理でき、
  ターンごとに `result` が返った。レビュー指摘への追加指示を「同じプロセスに流し込む」使い方が成立する。
- **シグナル**［原文］: SIGTERM は exit 143 で、進行中のターンは**未完了のまま残る**（resume すると続きから再開）。
  ターンを終わらせたいなら SIGINT か SDK の `interrupt()`。SIGTERM 時は実行中 Bash のプロセスツリーを終了し、
  `SessionEnd` hook のみ実行する。
- **background subagent の待ち**［原文］: `claude -p` は background subagent の完了を待つが、既定で 10 分上限
  （`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`、`0` で無制限）。`multi-review` のように 10 分超の leg を持つ処理では要調整。

### 1.4 成果物の受け取り

`--output-format json` の envelope に `result` / `session_id` / `total_cost_usd` / `permission_denials[]` が入る。
`stream-json` では `system/init`（tools・plugins・`plugin_errors`・`mcp_servers`・`mcp_server_errors`・`capabilities`）、
`assistant` / `user`（`parent_tool_use_id` で subagent を識別）、`system/api_retry`、最終 `result` が流れる［原文］。
成果物そのもの（コード変更・PR）は従来どおりワークツリーと `gh` が真実を持つ。

### 1.5 サンドボックス

**CLI フラグは存在しない**［実測: `-p --sandbox` は `error: unknown option '--sandbox'`］。設定 JSON で有効化する
（`--settings` に JSON を直接渡せるので非対話でも制御できる）。例外として `claude remote-control` サーバモードには
`--sandbox` / `--no-sandbox` フラグがある［原文: remote-control］。

実機で境界を確認した（`sandbox.enabled=true`, `failIfUnavailable=true`, `autoAllowBashIfSandboxed=true`,
`allowUnsandboxedCommands=false`, `network.strictAllowlist=true` を `--settings` で渡し、`-p` で実行）［実測］:

| 操作 | 結果 |
| --- | --- |
| cwd 配下への書き込み | 成功 |
| `$HOME` への書き込み | **拒否** |
| `https://example.com` への接続 | **拒否**（`curl: (56) CONNECT tunnel failed, response 403` ＋ `<sandbox_violations> deny network-outbound example.com:443 (host is not on the allow list) </sandbox_violations>`） |
| Write ツールで `$HOME` へ書き込み | **拒否**（sandbox ではなく権限系。`permission_denials[]` に記録） |

**スコープの穴（重要）**［原文 + 実測］:

- サンドボックスが包むのは **Bash のサブプロセスだけ**。Read / Edit / Write は権限システムが担当する。
  つまり `--dangerously-skip-permissions` を併用すると、**ファイル書き込みは OS 強制の外に出る**。
- 既定では sandbox が利用できないとき**警告して素通し**（`failIfUnavailable: true` で hard fail にする）。
- `allowUnsandboxedCommands`（既定 true）は失敗コマンドの sandbox 外リトライを許す。厳格運用では `false`。
- ネットワークは既定でホスト名ベース。TLS を終端しないため、広いドメイン許可は domain fronting の余地を残す［原文 Warning］。
- OS 実装は macOS = Seatbelt、Linux/WSL2 = bubblewrap + socat。WSL1・ネイティブ Windows は非対応。

### 1.6 非対話特有の落とし穴 ［原文］

- **`-p` は workspace trust ダイアログを出さない。** かつ *"Settings files that fail validation are silently ignored
  in this mode (no error dialog is shown)."* ── 壊れた設定が黙って無効化される。
- `--bare` を付けない `-p` は、**信頼していないフォルダでも** そのプロジェクトの `.claude/settings.json` の hooks を実行し、
  `.mcp.json` の server に接続する。
- `AskUserQuestion` は **Agent ツールで起動した subagent では使えない**［原文: agent-sdk/user-input Limitations］。
  親セッションの gate は保てるが、subagent 内部の gate は保てない。

## 2. Codex

### 2.1 非対話モードの起動と既定値

`codex exec`（別名 `codex e`）が非対話モード［原文: non-interactive-mode］。実行時ヘッダで既定値を実測した:

```text
approval: never
sandbox: read-only
```

`codex exec` の `--help` には `-a/--ask-for-approval` が**無い**（対話 `codex` にはある。値は `on-request` / `never`）。
つまり exec は既定で「承認を求めず、失敗はそのまま model に返す」設計である
（［原文］`never`: *"Never ask for user approval Execution failures are immediately returned to the model"`*）。

| 目的 | フラグ |
| --- | --- |
| サンドボックス | `-s/--sandbox read-only\|workspace-write\|danger-full-access` |
| 構造化出力 | `--json`（JSONL: `thread.started` / `turn.started` / `item.*` / `turn.completed` / `error`） |
| 最終メッセージ | `-o/--output-last-message <FILE>` |
| スキーマ強制 | `--output-schema <FILE>` |
| 永続化しない | `--ephemeral` |
| 設定を読まない | `--ignore-user-config` / `--ignore-rules` |
| 作業ディレクトリ | `-C/--cd <DIR>` / `--add-dir <DIR>` |

`codex exec` 自体は 1 プロセスで複数ターンを回す入力形式（Claude の `--input-format stream-json` 相当）を持たない。
ただし `codex queue --thread <UUID|name> --message <TEXT>`（既存セッションへのメッセージ投入）と
`codex exec-server`（experimental）という別経路が CLI に存在する［`--help` で確認］。**本調査では挙動を検証していない**ので、
「多ターンができない」とは断定しない。adapter を常駐プロセス方式で作るなら、この 2 つの検証が前提になる（Open Questions 参照）。

### 2.2 承認モデル ── orchestrator が「回答する」経路は無い

Claude Code の `--permission-prompt-tool` に相当する「**外部プロセスが承認要求を受け取って返す**」チャネルは、
`codex exec` には見当たらなかった。代替は 2 つある［原文: agent-approvals-security］。

1. **`--approve-for-me`**（exec のフラグ）: *"Route approval requests through automatic review using the workspace-write sandbox"*
2. **`approvals_reviewer = "auto_review"`**（config）: 承認要求を**レビュアー agent** に流す。
   評価対象は sandbox escalation・ブロックされたネットワーク要求・`request_permissions`・副作用のある app/MCP ツール呼び出し。
   critical risk は拒否、high risk は十分な user 認可が要る。**prompt-build / review-session / parse の失敗は fail closed**。

いずれも「**人でも orchestrator でもなく、別の agent が判断する**」形であり、`wave-orchestrator` の
「一次ソースで裏取りしてから代理応答する」規律をそのまま載せる先にはならない。
granular approval policy（`sandbox_approval` / `rules` / `mcp_elicitations` / `request_permissions` / `skill_approval`）で
カテゴリ単位に「対話のまま残す／自動拒否する」を選べるが、非対話では「対話のまま残す」＝止まる、である。

### 2.3 中断・再開とフラグの非対称 ［実測］

`codex exec resume --last "<prompt>"` / `codex exec resume <SESSION_ID> "<prompt>"` で文脈が保たれることを確認した。

**ただし `codex exec resume` は `-s/--sandbox` も `-C/--cd` も受け付けない**［実測: `--help` に無く、渡すと usage エラー］。
受け付けるのは `--dangerously-bypass-approvals-and-sandbox`（＝**弱める方向だけ**）である。
サンドボックスを維持したまま再開するには `-c sandbox_mode='"read-only"'` のように config override を使う
（実測でヘッダが `sandbox: read-only` になることを確認）。

> **adapter 設計への含意**: 「初回は `--sandbox` フラグ、再開は `-c sandbox_mode`」という非対称を知らずに書くと、
> 再開時に**サンドボックスが設定既定へ戻る**（＝弱まる）静かな退行を作りうる。

### 2.4 サンドボックス ［実測］

macOS Seatbelt での実効性を確認した。

| モード | cwd 配下への書き込み | `$HOME` への書き込み | ネットワーク |
| --- | --- | --- | --- |
| `read-only` | **拒否**（`zsh:1: operation not permitted: probe.txt`） | 未実施 | 未実施 |
| `workspace-write` | 成功 | **拒否**（`operation not permitted`） | **拒否**（`curl: (6) Could not resolve host`） |

- 書き込み可能ルート内でも `.git` / `.agents` / `.codex` は read-only で保護される［原文］。
- `workspace-write` のネットワークは既定 off（`[sandbox_workspace_write] network_access = true` で開ける）［原文］。
- **非シェル経路（組み込み patch ツール）も sandbox mode で塞がれる**［実測］: `--sandbox read-only` で
  「シェルではなく組み込みの編集機能で書け」と指示すると、tool router が
  `patch rejected: writing is blocked by read-only sandbox; rejected by user approval settings` を返して拒否し、
  ファイルは作られなかった。Claude Code の「サンドボックスは Bash のみ、file tools は権限システム」という
  非対称は Codex には当てはまらない（ただしこの経路の拒否は OS 強制ではなく tool router の policy 判定である）。
- Linux は `bwrap` + `seccomp`。
- **ドキュメントと CLI の drift**［実測］: 公式は `codex sandbox macos [COMMAND]...` の形を示すが、0.150.1 の
  `codex sandbox` はプラットフォーム別サブコマンドを持たず、`--permission-profile <NAME>` を必須とし、
  プロファイルは config の `[permissions]` テーブルに依存する（未定義だと `default_permissions requires a [permissions] table`）。
  サンドボックスの実効性検証は `codex sandbox` ではなく `codex exec --sandbox` で行うのが確実である。

## 3. Antigravity（`agy`）

### 3.1 headless モードの起動と入出力 ［原文: antigravity.google/docs/cli/headless］

`-p` / `--print` / `--prompt` で headless（print）モード。`--output-format text|json|stream-json`、
`--input-format text|stream-json`、`--json-schema`、`--continue` / `--conversation <ID>`、`--print-timeout`（既定 **5m**）。
`stream-json` 入力は 1 プロセス多ターンに対応し、`{"event":"user","message":{"content":"..."}}` を stdin に流す。
JSON envelope は `conversation_id` / `status` / `response` / `error` / `usage` を持ち、`status` は
`SUCCESS` / `ERROR` / `CANCELED` / `INTERRUPTED` / `INVALID` / `WAITING` / `RUNNING`。

### 3.2 承認モデル ── ソフト拒否が exit 0 で返る ★ ［原文 + 実測］

> ［原文］"A tool that requires approval it cannot obtain is soft-denied: the run continues, **exits 0**, and prints a notice
> to `stderr` naming the tool and how to allow it."

実測でも再現した。シェル実行を求めるプロンプトを既定権限で流すと:

```text
exit=0
stdout: {"conversation_id":"...","status":"SUCCESS","response":"","duration_seconds":4.5,"num_turns":1,...}
stderr: jetski: no output produced — a tool required the "unsandboxed" permission that headless mode
        cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json ...
```

**`status` が `SUCCESS`、exit code が 0、`response` が空文字**である。呼び出し側が exit code と `status` だけを見ると
「成功した」と読む。これは frontier-harness の adapter にとって致命的な誤読源で、
**`response` の非空判定と stderr の走査を必須にしない限り、何もしていない実行を成功として記録する**。

さらに、stream-json 入力に `control_request` / `control_response` を送ると **`ERROR` でセッションが終了し exit 2**［原文］。
つまり **Antigravity には承認要求を外部へ往復させるチャネルが構造的に存在しない**。
取りうるのは「事前に `permissions.allow` へ許可ルールを書く」か「`--dangerously-skip-permissions` で全通し」の二択である。

### 3.3 サンドボックス ── `--sandbox` はファイル書き込みを止めない ★ ［原文 + 実測］

［原文・フラグ表］`--sandbox` = *"Run with terminal sandbox restrictions enabled"*（**terminal** に限定されている）。

実測（`--sandbox --dangerously-skip-permissions`、非 git ディレクトリと git リポジトリの 2 箇所で再現）:

| 操作 | 結果 |
| --- | --- |
| ファイル書き込みツールで `$HOME/.agy-sandbox-outside-probe.txt`（**workspace 外**）を作成 | **成功**（2 回とも。実ファイルの生成を `ls` で確認） |
| `run_command` で `curl` | **失敗**（`sandbox configuration error: deny .git/: non-absolute file path`） |
| `--sandbox` を外して `run_command` | 成功（`pwd` はシェルの cwd を返す） |

すなわちこの版の `--sandbox` は、**守りたい側（ファイル書き込み）を素通しし、壊れて困る側（シェル）を使用不能にする**。
コミュニティ報告（`google-antigravity/antigravity-cli#45`）と同じ結論を、こちらの実測でも独立に得た。

既定権限（`--dangerously-skip-permissions` なし）では workspace 外書き込みはソフト拒否された［実測］。
つまり Antigravity の封じ込めは **OS 強制ではなく権限ポリシー層**にあり、`--dangerously-skip-permissions` は
その唯一の境界を丸ごと外す。**非対話で書き込みを伴う実行に使うなら、外側（コンテナ等）の隔離が必須**である。

### 3.4 中断・再開と workspace 束縛 ［実測］

- `--conversation <ID>` での再開は動作した（`conversation_id` を跨いで文脈保持）。
- `--sandbox` 付きの実行では、agent の「カレントディレクトリ」が起動シェルの cwd ではなく
  `~/.gemini/antigravity-cli/scratch/` に解決された（`run_command` が使えず `pwd` が取れない状況での挙動）。
  ファイル書き込みツールは**絶対パスを要求**する（`./inside.txt` は `path is not absolute` で拒否）。
  orchestrator が「このワークツリーで作業させる」前提を置くなら、workspace 束縛の明示（`--add-dir` / `--project`）と
  実測確認が要る。

## 4. Remote Control と非対話モードの併用

### 4.1 起動形は 3 つ ［原文: remote-control, cli-usage］

| 形 | 性質 |
| --- | --- |
| `claude --remote-control` (`--rc`) | *"Start an **interactive** session with Remote Control enabled"* |
| `claude remote-control` | サーバモード。*"Runs in server mode (no local interactive session)"*。`--spawn same-dir\|worktree\|session`、`--capacity N`（既定 32）、`--sandbox` / `--no-sandbox`、`--continue` / `--session-id` で停止後の復帰 |
| `/remote-control` | 既存の対話セッションから移行 |

### 4.2 `-p` との併用は成立しない ［実測］

`claude -p --remote-control ... "reply ok"` はエラーにならず exit 0 で通る。しかし:

- 4 秒で終了し、**常駐しない**（Remote Control は接続を待ち受ける常駐プロセスが前提）
- `system/init` に Remote Control を示すフィールドが一切現れない
- 出力ストリーム全体を走査しても remote control 関連の痕跡が無い

したがって **`-p` と Remote Control は併用できない**。フラグは受理されるが**無害に効かない**（エラーで教えてくれない点は注意）。
ドキュメント上も `--remote-control` は「対話セッション」と定義されており、実測と整合する。

### 4.3 利用条件 ［原文］

Pro / Max / Team / Enterprise（Team・Enterprise は Owner による有効化が必要）。**API key 認証は非対応**。
`ANTHROPIC_BASE_URL` を `api.anthropic.com` 以外に向けている場合・Bedrock / Google Cloud / Foundry・
enterprise gateway 経由は不可。`DISABLE_TELEMETRY` / `DO_NOT_TRACK` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` /
`DISABLE_GROWTHBOOK` のいずれかが立っていると feature flag 評価が止まり利用できない。

### 4.4 位置づけ

Remote Control は「非対話実行の手段」ではなく「**人が別デバイスから対話する手段**」である。
ただし `claude remote-control --spawn worktree --capacity N` は、
**wave の子セッションを worktree ごとに立てて人が監視する**という現行 tmux 運用の代替になりうる。
これは実行基盤の置き換えではなく**監視面の別軸**として §7 に記録する。

## 5. 3 CLI 能力比較

| 能力 | Claude Code 2.1.250 | Codex 0.150.1 | Antigravity 1.1.22 |
| --- | --- | --- | --- |
| 非対話起動 | `-p` | `codex exec` | `-p` |
| 構造化出力 | `json` / `stream-json` / `--json-schema` | `--json`(JSONL) / `--output-schema` / `-o` | `json` / `stream-json` / `--json-schema` |
| 1 プロセス多ターン | `--input-format stream-json`［実測］ | `exec` には stdin 多ターン入力が無く `exec resume` は別プロセス。別経路として `codex queue --thread` / `exec-server`（experimental）があるが**本調査では未検証** | `--input-format stream-json`［原文］ |
| セッション再開 | `--session-id` / `--resume`［実測］ | `exec resume --last\|<id>`［実測］ | `--continue` / `--conversation`［実測］ |
| **承認を外部へ往復** | **可**（`--permission-prompt-tool`、`AskUserQuestion` も含む）［実測］ | 不可（`auto_review` agent か `never`） | **不可**（`control_request` は ERROR）［原文］ |
| 承認不能時の既定 | prompt tool 無しなら黙って未実行のまま継続［原文］ | 失敗を model に返す［原文］ | ソフト拒否・**exit 0 / status SUCCESS**［実測］ |
| サンドボックスの適用範囲 | **Bash のみ** OS 強制（Seatbelt / bubblewrap）。Read/Edit/Write は権限システム側［実測］ | シェル実行は OS 強制（Seatbelt / bwrap+seccomp）。**組み込み patch ツールも sandbox mode で拒否される**（tool router の policy 判定）［実測］ | **ファイル書き込みは対象外**（`--sandbox` は terminal 限定）［実測］ |
| サンドボックス指定 | 設定 JSON（`--settings` 可） | `-s` フラグ（**resume では不可**、`-c sandbox_mode`）［実測］ | `--sandbox`（実効性に難）［実測］ |
| ネットワーク既定 | 許可ドメイン無し（prompt / strictAllowlist） | `workspace-write` で off | 未確認（`--sandbox` 下で shell 自体が不可） |
| model / effort の pin | `--model` / `--effort` | `-m` / `-c model_reasoning_effort` | `--model` / `--effort` |
| Remote Control 併用 | **不可**［実測］ | 対象外（別機構 `codex remote-control` は experimental） | 対象外 |

## 6. 現行 tmux 経路の安全ガードと、非対話モードでの帰趨 ★★

`wave-orchestrator` のガードは事故から積み上がったものなので、1 件ずつ「非対話でどうなるか」を判定する。
判定は 3 種類 ── **不要化**（防いでいた事故が構造的に起きなくなる）／**要移植**（別の形で実装が要る）／**喪失**（代替が無い）。

| # | ガード | 防いでいる事故 | 非対話（Claude `-p` + prompt tool）での帰趨 |
| --- | --- | --- | --- |
| 1 | マージ・リリース等は無条件エスカレート | gate を経ない無断マージ | **要移植**: approver 側の deny ルール。deny は `permission_denials[]` に残り**監査可能になる**（tmux では記録が残らなかった） |
| 2 | 状態を分類していないペインへ送信しない | 誰も答えていない選択肢の確定 | **不要化**: 送信先という概念が無い。呼ばれた要求にだけ返す |
| 3 | 事実主張に依存する問いは一次ソース裏取りまで自動応答しない | 「既存 flaky です」等の誤った自己診断の追認 | **要移植**: approver の判断ロジックとして実装（人間の規律 → コード化できる） |
| 4 | 検知器の `--self-check`、失敗したら止まる | 検知の沈黙故障 | **不要化**: 検知しない。子が同期的に呼んでくるので「止まったのに気づけない」が起きない |
| 5 | 共有リポジトリの git 操作を子にやらせない | 既定ブランチ更新のロック競合 | **要移植**: deny ルール ＋ 起動プロンプト（現状と同じ） |
| 6 | 状態判定は hook payload のみ、画面テキスト禁止 | #435 / #436 の誤判定 | **不要化**: 画面が無い |
| 7 | 未回答判定を集合の引き算で行う（到着順非依存） | #447（`Stop` 先行評価で停止を IDLE と誤報） | **不要化**: 未回答という状態を推定しない |
| 8 | auto mode の `permission_prompt` は `UNKNOWN` | #486（停止とも稼働とも読めない） | **不要化**（ただし別の失敗に置換）: 承認は prompt tool に来る。prompt tool を配線しないと「黙って未実行のまま継続」に変わる（§1.2.5） |
| 9 | 壊れた JSONL 行があれば `RUNNING`/`IDLE` を降格 | 落ちた行が停止通知だった可能性 | **不要化**: 記録ファイルを介さない |
| 10 | `capture-pane -e` で dim を除外（#472） | 誰も入力していない提案文の確定送信 | **不要化**: 入力欄を読まない |
| 11 | 不可逆操作の語彙で `PENDING_CONFIRM` | 上記の二重化 | **不要化**（#1 の deny ルールが本体になる） |
| 12 | 数字キーのみ送る / 1 問ずつ / Enter を投機送信しない | 次の問いの既定値を確定させる事故 | **不要化**: キー入力が無い。`answers` は問い単位の構造化データ |
| 13 | `--text` は `ASK_QUESTION` 中に送らない、`--dismiss` を明示 | 本文がキー入力として解釈される（#445） | **不要化**: 自由記述は `--input-format stream-json` の別ターンとして送れる［実測］ |
| 14 | 送信前 3 点確認（プロセス生存・未回答・UI 実在） | ペイン取り違え、終了後の shell へ本文が流れる | **不要化**: 呼び出し元プロセスへの戻り値なので取り違えが起きない |
| 15 | 送信結果 3 値（`DELIVERED` / `QUEUED_UNCONFIRMED` / `PENDING_CONFIRM`） | 二重キュー・二重入力 | **不要化**: 戻り値が届いたかは MCP の応答で確定する |
| 16 | 沈黙ストール検知（25 分下限） | イベントを出さない停止 | **一部要移植**: 子プロセスの生死・stream の途絶・`MCP_TOOL_TIMEOUT` / idle timeout の監視に置き換わる |
| 17 | 成果物の検証（報告を検証に代えない） | 「完了しました」の追認 | **要移植**: 非対話でも同じ。むしろ `permission_denials` / `is_error` / exit code が機械可読になる分やりやすい |
| 18 | 停止前に `session_id` を記録（環境が真実を失う） | 再開できなくなる | **要移植**（軽くなる）: `--session-id` を発行側が決められるので、`ps` の argv に依存しない |
| 19 | 識別子をブランチ名から導き 1 つに統一 | 送信先の取り違え | **要移植**（軽くなる）: セッション ID とワークツリーの対応だけで足りる |
| 20 | 重複起動の検査（`-n` / `--resume` 両方） | gate を経ない無断マージの入口 | **要移植**: 起動側が採番するので、自前の台帳で検査できる |
| 21 | 目視での介入導線（tmux にアタッチして人が打つ） | 詰まったときの回復 | **喪失（要代替）**: headless の子には UI が無い。`--session-id` を控えておけば `claude --resume <id>` で対話セッションとして開き直せる［実測: 別ディレクトリからの resume を確認］ |

**この表の要点**: ガード 2・4・6〜15（＝積み上げの大半）は「移行すると失う」ものではなく、
**防いでいた事故が起こりえなくなるので不要になる**。移植が要るのは 1・3・5・16〜20 で、いずれも
**画面や TUI ではなく方針（policy）と台帳の問題**であり、コードで書ける。喪失は 21（目視導線）1 件だけで、
これも `--resume` で回復可能である。

一方で**移行が新たに持ち込む危険**が 3 つある。

| 新規リスク | 内容 | 対処 |
| --- | --- | --- |
| R1 | prompt tool を配線しないと `AskUserQuestion` 自体が消え、**pr-workflow の blocking gate が静かに無効化される**［実測］ | prompt tool の配線を必須にし、`system/init` の tools に `AskUserQuestion` があることを起動時に検査する |
| R2 | `-p` は workspace trust を出さず、**不正な設定ファイルを黙って無視する**［原文］。`--bare` なしでは repo の hooks / MCP が動く | **起動時のフラグで事前に遮断する**（下記） |
| R3 | subagent 内では `AskUserQuestion` が使えない［原文］ | 親セッションに gate を集約する設計を維持する（`pr-workflow` は現状そうなっている） |

**R2 の緩和は事後検査では足りない。** 当初は「起動後に `system/init` の `mcp_server_errors` / `plugin_errors` を
検査して fail する」で足りると考えたが、これは**接続・パースに失敗したものしか捕まえられない**。正常に接続して
応答する（＝エラーを出さない）hook / MCP server は素通りする。さらに `SessionStart` / `Setup` hook は
`system/init` **より前**に走る［原文: headless「Read session metadata」］ので、init を読んだ時点では既に実行済みである。
対話モードの初回 trust ダイアログが「実行**前**の人間の承認」であるのに対し、init 検査は「実行**後**のログ確認」で
性質が異なる。よって R2 の対処は**起動フラグによる事前遮断**とする:

| 手段 | 効果 |
| --- | --- |
| `--setting-sources user`（または `--bare`） | repo の `.claude/settings.json` を読まない ＝ project hooks が走らない |
| `--strict-mcp-config` ＋ `--mcp-config <approver>` | repo の `.mcp.json` を無視し、orchestrator が明示した MCP server だけを接続する（allowlist 方式） |
| 上記が使えない（repo の hooks / skills が必要）場合 | その worktree を**人が一度は明示的に trust した記録**を orchestrator 側に持ち、起動前に照合する |

`system/init` の `mcp_server_errors` / `plugin_errors` 検査は**この事前遮断を前提としたうえでの二次的な健全性確認**
として残す（設定ミスの検出には有効だが、単独では安全境界にならない）。

## 7. Decision

### 7.1 `wave-orchestrator`: **代理応答経路のみ移行する（条件付き移行）**

- **移行する**: 「停止の検知 ＋ 画面参照 ＋ キー送出」を、`claude -p --permission-prompt-tool <MCP tool>` の
  **同期的な承認/回答チャネル**へ置き換える。根拠は §1.2.3 の実測（`AskUserQuestion` の構造化往復）と §6 の対応表
  （ガードの大半が不要化し、移植対象は policy と台帳に限られる）。
- **直前の決定との関係（重要）**: `.claude/prds/wave-orchestrator-hook-based-detection.prd.md`（`status: finalized`,
  2026-08-26）は「**検知**は hook payload、**応答**は payload の options index + 1 を数字キーで送る」と確定し、
  そのとき「SDK へ移行する」案を「**独立した対話型セッションを立て、人が覗いて介入できる**という skill の中核と衝突する」
  という理由で却下している。本書は **検知側の決定（画面テキストではなく hook payload を根拠にする）を維持したまま、
  応答側の決定（数字キー送出）を置き換える**。旧 PRD の却下理由（人が覗ける導線の喪失）は本書でもガード 21 として
  正面から扱い、`--session-id` を控えて `claude --resume <id>` で対話セッションとして開き直せること［実測］、
  および tmux ペインを「窓」として残すことで代替する。**旧 PRD の却下判断を覆すのはこの 1 点であり、
  その理由は §1.2.3 の実測（構造化往復が成立する）と §6（TUI 由来ガードの不要化）にある。**
- **移行しない**: tmux そのもの。**人が覗く窓としての価値は残る**（ガード 21）。実行を headless にしても、
  ペインで子プロセスを走らせて stream をそのまま流せば、可視性は保てる。
  「tmux を捨てる」ことは本調査の目的ではない。
- **前提条件（満たさないなら移行しない）**:
  1. prompt tool の配線を必須化し、起動時に `AskUserQuestion` の存在検査を行うこと（R1）。この検査が無い移行は、
     gate を静かに失う退行になる。
  2. **`--strict-mcp-config` を必須化し、approver 以外の MCP server が子セッションに入らないようにすること。**
     承認チャネルは新しい信頼境界なので、子が任意の MCP server を注入できる状態では承認の迂回・詐称が成立しうる。
  3. **repo 由来の hooks / MCP を事前に遮断すること**（`--setting-sources user` または `--bare`。R2 の表を参照）。
     ワークツリーは issue 由来のブランチを含みうるので、`.claude/settings.json` / `.mcp.json` は信頼境界の外から来る前提で扱う。
  4. **gate を親セッションに集約する設計を維持すること**（R3）。subagent 内では `AskUserQuestion` が使えないため、
     承認を要する判断を subagent へ降ろすと gate が消える。`pr-workflow` は現状この形を満たしている。
- **段階**: `--input-format stream-json` を使えば 1 プロセスで多ターン（＝レビュー指摘対応まで）を回せる［実測］が、
  まずは 1 タスク 1 プロセス ＋ `--session-id` / `--resume` で始めるほうが state が単純になる。

### 7.2 `frontier-harness`: **adapter に「承認チャネルの有無」を capability として持たせる**（#493 への入力）

3 provider の非対話能力は**非対称**であり、`providers.mjs` の「provider 名 → 実行ファイル名」だけでは表現できない。

| provider | 起動方式の推奨 | 承認 | 書き込みを伴う実行 |
| --- | --- | --- | --- |
| `claude` | `-p` ＋ `--permission-prompt-tool` ＋ `--output-format stream-json` ＋ `--strict-mcp-config`（＋ `--setting-sources user`） | **外部往復可** | 可（sandbox は設定 JSON で hard fail 化。**ただし包むのは Bash のみ**。Read/Edit/Write は権限システム側なので `--dangerously-skip-permissions` と併用しない） |
| `codex` | `codex exec --sandbox <mode> --json`、再開は `resume` ＋ `-c sandbox_mode` | 不可（`never` / `auto_review`） | 可（OS 強制サンドボックスが実測で有効） |
| `antigravity` | `-p --output-format json`、**`response` 非空と stderr を必ず検査** | 不可 | **非推奨**（`--sandbox` が書き込みを止めない。外側の隔離が無い限り read-only 用途に限定） |

adapter が満たすべき最小要件（#493 の設計入力）:

1. `runWithRolloutGuard` に渡す `executor` は **provider ごとの起動形・再開形・成功判定を別々に持つ**。
   とくに Antigravity は exit code と `status` だけでは成功を判定できない（§3.2）。
2. **サンドボックス指定はプロセス起動時と再開時で形が違う**（Codex は resume で `-s` を受けない）。
   「初回だけ pin して再開で弱まる」退行を型で塞ぐ。
3. capability registry に `approvalChannel: "external" | "agent-review" | "none"` 相当の軸を持つ。
   `risk.alwaysEscalate` に当たるタスクを `approvalChannel: "none"` の provider へ route してはならない
   （エスカレート先が無いので、ソフト拒否か素通しのどちらかになる）。
4. `rollout: shadow` の間は §1.5 / §2.4 の実測手順を回帰テストとして持つ（サンドボックスが効いていることを
   ドキュメントではなく**挙動**で確認し続ける）。

### 7.3 #492（state schema）へ報告すべき結論

#492 には「adapter の起動方式に依存しない粒度で schema を設計する」よう指示済みだが、
本調査で**起動方式に依存しない形で保持すべき項目**が確定したので、orchestrator 経由で共有する
（本セッションから #492 のセッションへは直接連絡しない）。

1. **セッション識別子は 1 プロセスに 1 つとは限らない。** Claude は `session_id`（呼び出し側で採番可能）、
   Codex は `thread_id` / session id、Antigravity は `conversation_id` を返す。**3 者とも「再開キー」を返す**ので、
   schema には provider 非依存の「resume key」1 本があればよい（provider 固有の意味を持ち込まない）。
2. **成功判定は exit code では表せない。** 少なくとも「終了状態」「成果物の有無」「拒否された操作の一覧」を
   別々に持つ必要がある（Antigravity は exit 0 / `SUCCESS` で何もしていない場合がある）。
3. **拒否・エスカレーションは第一級のイベント**である。Claude は `permission_denials[]` を返し、
   Codex は失敗を model に返し、Antigravity は stderr にしか出さない。schema にこの受け皿が無いと、
   「gate に当たった」という最重要の事実が provider ごとに欠落する。
4. サンドボックスの実効設定（mode / network / writable roots）は**実行ごとの記録項目**にする。
   再開時に弱まりうる（§2.3）ため、「起動時に指定した値」ではなく「その実行で有効だった値」を残す。

### 7.4 据え置く判断

- **Antigravity を実行基盤として採用するか**は、本調査の結論としては「書き込みを伴う実行には使わない」。
  レビューの多様性担当として採用するかは #199 の範囲であり、本書は触れない。
- **Remote Control** は非対話モードの代替にならない（§4.2）。ただし `remote-control --spawn worktree` は
  監視面の選択肢として残す。採否は別途。

## 8. 後続 issue 候補（列挙のみ / issue 化は user 承認後）

| # | 候補 | 依存 |
| --- | --- | --- |
| C1 | 承認 MCP server（permission prompt tool）の実装 ── `allow` / `deny` / `answers` の返却、無条件エスカレート集合の deny ルール、progress 通知による idle timeout 対策、**idle timeout 到達時の安全な fallback（自動 deny ＋ 子セッション状態の保存）**、`--strict-mcp-config` 前提の接続要件 | 本書 |
| C2 | `wave-orchestrator` の子起動を `claude -p --permission-prompt-tool` へ切り替え、起動時に `AskUserQuestion` 存在検査を入れる | C1 |
| C3 | 子起動フラグの固定（`--setting-sources user` / `--strict-mcp-config` の allowlist 方式）＋ 起動時ヘルスチェック（`AskUserQuestion` 存在・`mcp_server_errors` / `plugin_errors`・sandbox 実効性）を子起動シーケンスに追加 | C2 |
| C4 | `scripts/executable_wave-events.sh` / `scripts/executable_send-to-pane.sh` の縮退方針決定（tmux 併用時のみ残す / 撤去する）と、`wave-orchestrator-hook-based-detection.prd.md` への forward pointer 追記 | C2 |
| C5 | `frontier-harness` の provider adapter 実装（#493）に §7.2 の 4 要件を反映 | 本書 |
| C6 | capability registry に承認チャネル軸を追加し、`risk.alwaysEscalate` の route を塞ぐ | C5 |
| C7 | サンドボックス実効性の回帰テスト（Claude / Codex の 4 ケースを bats 化） | C5 |
| C8 | Antigravity adapter の成功判定（`response` 非空 ＋ stderr 走査）と read-only 制限 | C5 |

## Considered Alternatives / Rejection Rationale（決定ログ）

| # | 検討した代替案 | 却下理由 |
| --- | --- | --- |
| 1 | **現状維持**（tmux 対話セッション ＋ 画面参照での代理応答を続ける） | #472（プレースホルダ誤読）・Esc 固着・#486（判別不能）は個別のバグではなく「TUI を外から操作する」構造に由来する。ガードを足しても再発の形が変わるだけである。構造化往復が実測で成立した以上、維持する理由は実装コストだけになる。**ただし §7.1 の前提条件（R1〜R3）を満たせないなら見送るのが正しい** —— その場合は gate を静かに失う退行になる |
| 2 | **全面移行**（tmux を撤去し headless のみにする） | ガード 21（人が覗いて介入する導線）を失う。`--resume` で対話セッションとして開き直せる［実測］とはいえ、詰まった子を即座に覗ける窓の運用価値は高い。実行だけを headless にし、可視化は tmux ペインに残す形を採る |
| 3 | **Claude Agent SDK（TypeScript / Python）へ移行する** | SDK の `canUseTool` は CLI の `--permission-prompt-tool` と同じ能力を提供する［原文］。CLI で必要な能力が揃った以上、`wave-orchestrator` を SDK ホストプロセスとして書き直す変更量に見合わない。将来の選択肢としては残す（`wave-orchestrator-hook-based-detection.prd.md` が同案を却下した理由 ——「人が覗ける導線と衝突する」—— は、代替案 2 と同じ論点で本書でも維持される） |
| 4 | **Codex / Antigravity を wave の実行基盤にする** | 承認要求を外部へ往復させるチャネルが無い（Codex は `auto_review` という別 agent への委譲、Antigravity は `control_request` が ERROR）。「gate は人（または orchestrator）が握る」という要件と両立しない。両者は frontier-harness の worker としては使える（§7.2） |
| 5 | **Remote Control のサーバモード（`--spawn worktree`）を実行基盤にする** | Remote Control は人が別デバイスから**対話する**手段であって、プログラムから駆動する API ではない。`-p` との併用も実測で成立しない（§4.2）。監視面の選択肢としては残す |
| 6 | **Antigravity の `--sandbox` に封じ込めを任せる** | 実測で workspace 外へのファイル書き込みが素通りした（2 回再現）。`--sandbox` は terminal 限定であり、封じ込めは権限ポリシー層にしかない |
| 7 | **承認チャネルを持たず `--permission-mode dontAsk` で完全自動化する** | `dontAsk` は `AskUserQuestion` を allow ルールがあっても拒否する［原文］。R1 と同じ「gate が静かに消える」失敗になる。CI のような使い捨て実行には妥当だが、マージ手前まで走らせる wave の子には使えない |

## Out of Scope

- 本 issue での実装（`wave-orchestrator` / `frontier-harness` のコード変更）
- Antigravity をレビュー多様性担当として採用するかの判断（#199）
- Claude Agent SDK（TypeScript / Python）を採用するかの比較 ── CLI の `--permission-prompt-tool` で
  必要な能力が揃ったため本調査では深掘りしていない（SDK の `canUseTool` は同じ機能をプロセス内で提供する）
- Claude Code 以外の Remote Control 相当機能（`codex remote-control` は experimental のため未検証）

## Open Questions

1. 承認 MCP server を **wave ごとに 1 つ**立てるか、**子セッションごとに 1 つ**立てるか。
   前者は台帳が 1 箇所に集まるが、複数子からの同時要求を捌く設計が要る。
2. `MCP_TOOL_TIMEOUT` の 28 時間と idle 30 分をどう運用するか（progress 通知を送り続けるか、idle を延ばすか）。
3. `--input-format stream-json` の常駐プロセス方式へ進むか、1 タスク 1 プロセス ＋ `--resume` に留めるか。
   前者は起動コストが下がるが、プロセス寿命が state の寿命になる。
4. quota 逼迫時の中断・再開を非対話でどう行うか（SIGTERM でターンが未完了のまま残る挙動を利用する形になる）。
5. Codex の `approvals_reviewer = "auto_review"` を wave の一部として使うか（人の代わりに agent が承認する形を
   本リポジトリの規律に組み込んでよいか）。
6. Codex の `codex queue --thread` と `codex exec-server`（experimental）が常駐プロセス方式の多ターン実行に
   使えるか（本調査では `--help` の存在確認のみで挙動未検証）。使えるなら Codex adapter の形が変わる。

## 付録 A: 再現手順

いずれも 2026-08-28 〜 2026-08-29 に実行した。作業用ディレクトリは scratchpad 配下、
`$HOME` に作られた検証ファイルは実行後に削除済み。

### A-1. `--help` に出ないフラグの実在判定（パース順を利用）

`claude -p` は未知オプションを**最初の 1 件**だけ報告する。判定したいフラグの後ろに確実に存在しない
フラグを置き、エラーがどちらを指すかで実在を判定する。

```sh
probe() { claude -p "$1" "${@:2}" --zzz-not-a-flag "x" 2>&1 | head -2; }
probe --permission-prompt-tool foo   # => unknown option '--zzz-not-a-flag'  → 実在
probe --sandbox                      # => unknown option '--sandbox'          → 非実在
```

### A-2. `AskUserQuestion` の可用性（2×2 対照）

```sh
# $MCP は A-3 の approver を宣言した --mcp-config の JSON 文字列
ask_probe() {  # $1 = permission mode, $2.. = 追加フラグ
  local mode="$1"; shift
  claude -p --setting-sources '' --permission-mode "$mode" "$@" \
    --output-format stream-json --verbose --max-turns 1 --model sonnet "reply ok" \
  | jq -c 'select(.subtype=="init")|{permissionMode,hasAsk:(.tools|index("AskUserQuestion")!=null)}'
}
ask_probe default
ask_probe auto
ask_probe default --mcp-config "$MCP" --strict-mcp-config --permission-prompt-tool mcp__approver__approve
ask_probe auto    --mcp-config "$MCP" --strict-mcp-config --permission-prompt-tool mcp__approver__approve
```

結果: prompt tool 無し → `hasAsk:false`（`default` / `auto` とも）。prompt tool 有り → `hasAsk:true`（同）。

### A-3. permission prompt tool の往復

最小の stdio MCP server（`initialize` / `tools/list` / `tools/call` のみ実装、`tools/call` を
`{"behavior":"allow","updatedInput":{...}}` で返す）を用意し、次を実行する。

```sh
claude -p --mcp-config "$MCP" --strict-mcp-config --setting-sources '' \
  --permission-prompt-tool mcp__approver__approve --permission-mode default \
  --output-format stream-json --verbose --max-turns 6 --model sonnet \
  'Run the shell command: touch probe_written.txt'
```

- `echo ...` では prompt tool が呼ばれない（auto-approve される）。`touch ...` では呼ばれる。
- `AskUserQuestion` を使わせるプロンプトに変え、`updatedInput.answers` に `{"<question>":"<label>"}` を
  載せて `allow` を返すと、model 側に `Your questions have been answered: "<question>"="<label>".` が届く。
- `{"behavior":"deny","message":"..."}` を返すと実行されず、`result.permission_denials[]` に記録される。

### A-4. Claude Code のサンドボックス実効性

```sh
SET='{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,
      "allowUnsandboxedCommands":false,"network":{"strictAllowlist":true}}}'
claude -p --setting-sources '' --settings "$SET" --permission-mode acceptEdits \
  --output-format json --max-turns 8 --model sonnet \
  'Run these three shell commands one at a time ... 1) echo IN > ./inside2.txt
   2) echo OUT > "$HOME/.claude-sandbox-probe.txt"  3) curl -sS -m 8 https://example.com'
```

Write ツール版（sandbox ではなく権限系が拒否することの確認）は、同じ設定で
`Use the Write tool (not Bash) to create ~/.claude-writetool-probe.txt` を実行する。

### A-5. Codex のサンドボックス実効性

```sh
codex exec --sandbox read-only --skip-git-repo-check --ephemeral -C "$DIR" \
  'Attempt to create a file named probe.txt ... report whether it was blocked'
codex exec --sandbox workspace-write --skip-git-repo-check --ephemeral -C "$DIR" \
  'Run exactly these three shell commands ... 1) echo WROTE > ./inside.txt
   2) echo WROTE > "$HOME/.codex-sandbox-outside-probe.txt"  3) curl ... https://example.com'
```

非シェル経路（組み込み patch ツール）も同じ sandbox mode で塞がれることの確認:

```sh
codex exec --sandbox read-only --skip-git-repo-check --ephemeral -C "$DIR" \
  'Use your built-in file editing capability (apply_patch or the equivalent non-shell tool), NOT a shell command,
   to create a file named patched.txt containing the single word PATCHED. Then report whether it was blocked and
   quote the exact error.'
# => patch rejected: writing is blocked by read-only sandbox; rejected by user approval settings
```

### A-6. Codex の再開とサンドボックス pin

```sh
codex exec resume --last --skip-git-repo-check -c sandbox_mode='"read-only"' '<prompt>'
```

`codex exec resume --help` に `-s/--sandbox` と `-C/--cd` は無い（`--dangerously-bypass-approvals-and-sandbox` はある）。

### A-7. Antigravity のソフト拒否とサンドボックス

```sh
# ソフト拒否（既定権限）: exit 0 / status SUCCESS / response 空 / stderr に notice
agy -p 'Run the shell command: echo hello-agy-probe ...' --output-format json --print-timeout 3m

# --sandbox でも workspace 外への書き込みが通る
agy -p 'Use your file-writing tool to create $HOME/.agy-sandbox-outside-probe.txt containing ESCAPED ...' \
  --sandbox --dangerously-skip-permissions --output-format json --print-timeout 5m
```

### A-8. Remote Control と `-p`

```sh
claude -p --remote-control --setting-sources '' --output-format stream-json --verbose \
  --max-turns 1 --model sonnet "reply ok" | jq -c 'select(.subtype=="init")'
```

exit 0・4 秒で終了・`init` に Remote Control を示すフィールド無し・ストリーム全体にも痕跡無し。

### A-9. セッション再開（Claude）

```sh
U=$(uuidgen | tr 'A-Z' 'a-z')
claude -p --session-id "$U" --output-format json --max-turns 1 --model sonnet "Remember the word: banana. Reply OK."
OTHER=$(mktemp -d) && cd "$OTHER"
claude -p --resume "$U" --output-format json --max-turns 1 --model sonnet "What word?"   # => banana
```

## 付録 B: 参照した一次ソース

すべて 2026-08-28 〜 2026-08-29 に取得。

### Claude Code（`code.claude.com/docs/en/`）

| ページ | 本書での用途 |
| --- | --- |
| `cli-usage`（CLI reference） | フラグ・サブコマンドの正典。`--help` が全フラグを列挙しない旨の明記 |
| `headless`（Run Claude Code programmatically） | `-p` の基本・出力形式・`--bare`・SIGTERM/SIGINT・background task の扱い |
| `permission-modes` | モード表・*actions no mode auto-approves*・auto mode のフォールバック・`dontAsk` の `AskUserQuestion` 拒否 |
| `sandboxing` | Bash サンドボックスの範囲・設定・protected paths・network isolation・limitations |
| `settings-reference` | `sandbox.*` キーの一覧 |
| `env-vars` | `MCP_TOOL_TIMEOUT` / `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` / `MCP_TIMEOUT` ほか |
| `remote-control` | 3 つの起動形・server mode のフラグ・利用条件 |
| `agent-sdk/user-input` | `canUseTool` と `AskUserQuestion` の questions/answers 形式・subagent 制限 |

### Codex

| ページ | 本書での用途 |
| --- | --- |
| `developers.openai.com/codex/non-interactive-mode` | `codex exec` の基本・既定 read-only・JSONL・resume・`--output-schema` |
| `developers.openai.com/codex/agent-approvals-security` | sandbox と approval の 2 層・`--ask-for-approval never`・`auto_review`・protected paths・OS 実装 |
| `developers.openai.com/codex/developer-commands` | `codex exec` / `codex sandbox` のフラグ一覧 |

### Antigravity

| ページ | 本書での用途 |
| --- | --- |
| `antigravity.google/docs/cli/headless` | headless の全仕様。soft-deny の明記・`control_request` の拒否・`--sandbox` の定義（terminal 限定）・`--print-timeout` |

### CLI 自身の出力

`claude --help` / `claude agents --help`（2.1.250）、`codex --help` / `codex exec --help` /
`codex exec resume --help` / `codex sandbox --help` / `codex queue --help` / `codex exec-server --help`（0.150.1）、
`agy --help`（1.1.22）。

### 本リポジトリ

`home/dot_agents/skills/wave-orchestrator/SKILL.md`、同 `scripts/executable_wave-events.sh`、
同 `scripts/executable_send-to-pane.sh`（chezmoi source の実名。deploy 後は `executable_` 接頭辞が外れる）、
`home/dot_local/lib/frontier-harness/{cli,rollout,router,config,doctor,readiness,providers,task,paths,state-root,state-store}.mjs`
（§7.3 の報告項目は `state-store.mjs` の schema に接続する）、
`.claude/prds/wave-orchestrator-hook-based-detection.prd.md`、`.claude/prds/frontier-harness-pr-workflow.prd.md`、
`home/dot_agents/skills/grill-me/SKILL.md`（`.claude/prds/` の PRD 契約）。
