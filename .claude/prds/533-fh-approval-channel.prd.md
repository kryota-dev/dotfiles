---
slug: 533-fh-approval-channel
feature: fh 承認チャネル（非対話モードの permission prompt tool）
created_at: 2026-08-29T03:46:56+09:00
grill_session: session_01RQz7GqPHGcQz5Lz7Hbdi2D
status: finalized
---

# fh 承認チャネル（非対話モードの permission prompt tool）

## Background

`claude -p` は `--permission-prompt-tool` を配線したときだけ `AskUserQuestion` を持つ（#529 PRD §1.2.1 実測）。
配線しないと gate そのものが静かに消える。承認要求も `AskUserQuestion` も**同期的な MCP ツール呼び出し**として
届き、`{"behavior":"allow","updatedInput":{...,"answers":{...}}}` を返すと回答が model へ配送される（§1.2.2 / §1.2.3 実測）。

現行の `wave-orchestrator` は tmux ペインを読んでキーを送る代理応答を行っており、プレースホルダ誤読・Esc 固着・
確定キーの投機送信という事故を積み上げてきた。承認チャネル経由ならこれらは構造的に起こりえない（§6 の対応表で
ガード 2・4・6〜15 が「不要化」）。移植が要るのはガード 1・3・5（policy と台帳）である。

承認チャネルは Claude 固有であり（Codex は `never`/`auto_review` のみ、Antigravity は承認経路なし）、
provider adapter（#493）とは独立して実装できる。

## User Story

wave の子セッション（`claude -p`）が承認を要する操作に当たったとき、**画面を介さずに** user の判断を仰ぎ、
その回答が構造化データとして子へ返る。user が席を外していても子は異常終了せず、時間切れになれば
自動 deny と状態保存で安全に終わる。複数の子が同時に承認を求めても互いに待たされない。

## Acceptance Criteria

### 受け口（stdio MCP server）

- **AC-001**: `fh approve-server` が stdio MCP server として起動し、`initialize` / `notifications/initialized` /
  `tools/list` / `tools/call` / `ping` に応答する。stdout には JSON-RPC メッセージ以外を一切書かない
  （診断は stderr）。
- **AC-002**: `tools/list` は `approve` ツール 1 件を返し、`--permission-prompt-tool mcp__<server>__approve`
  の受け口になる。
- **AC-003**: `tools/call` は `{tool_name, input, tool_use_id}` を受け取り、`content[0].text` に
  `{"behavior":"allow","updatedInput":{...}}` または `{"behavior":"deny","message":"..."}` を
  JSON 文字列として載せて返す（§1.2.2 実測形）。
- **AC-004**: protocolVersion は client の要求値が supported set に含まれればそれをそのまま返し、
  含まれなければ server の最新値を返す（MCP spec の version negotiation どおり。エラーにしない）。
- **AC-005**: stdin が EOF になったら（MCP spec の stdio shutdown は client による stdin クローズで始まる）、
  および SIGTERM / SIGINT を受けたら、待機中の要求を `aborted` として保存してから終了する。
  子の停止で承認要求が宙に浮かない。
- **AC-006**: `fh approve-server` は `--session <id>` / `--approvals-dir <絶対パス>` / `--timeout-ms` /
  `--progress-interval-ms` を受ける。承認 queue のディレクトリを用意できない場合（state root を解決できない、
  symlink である等）は**起動時に非ゼロ終了して stderr に理由を書く**。sanity を欠いたまま起動して
  「エスカレートできない approver」になることを許さない。

### deny ルール（escalation set）

- **AC-010**: deny ルールは repository capability manifest（`<repo>/.harness/policy.json`、#494）とは
  **別ファイル**で管理する。両者は実行時に別々に照合され、統合しない。
- **AC-011**: baseline の escalation ルールは**モジュール内の定数**（コード）で持ち、ファイルからは
  **追加のみ**できる（`additionalRules`）。baseline を削除・無効化するキーを設けない。
  ルールファイルが存在しない・壊れている場合でも baseline は完全に有効。
- **AC-012**: ルールファイルは repository 由来のパスから解決しない。`$HOME/.config/frontier-harness/approval-rules.json`
  か、絶対パスの `FH_APPROVAL_RULES_PATH` のみ。相対値は拒否する（`resolveConfigPath` と同じ不変条件）。
- **AC-013**: baseline は merge / force-push / history-rewrite / release / external-publish / credential /
  deploy / migration / approval-channel-tamper の各カテゴリを持ち、`risk` 値は `config.risk.alwaysEscalate` と
  同じ語彙を使う。
- **AC-014**: ルールに当たったら**自動 deny せず user へ同期問い合わせ**する。
- **AC-015**: `AskUserQuestion` はルールの有無に関わらず**常に**エスカレートし、approver は決して自動回答しない
  （§6 ガード 3 の移植：approver は一次ソース裏取りの能力を持たないため、自動回答の権能自体を与えない）。
- **AC-016**: ルールに当たらなかった tool call は allow を返す（既定）。ルールファイルは
  `defaultDecision: "escalate"` によって**厳しくする方向にのみ**この既定を上書きできる。

### user への到達経路

- **AC-020**: 承認要求は `<state root>/frontier-harness/approvals/<id>.request.json` として永続化される。
  書き込みは `paths.mjs` の `ensureDirectory` / `writeJsonAtomic` 経由（0700 ディレクトリ / 0600 ファイル /
  symlink 拒否 / 予測不能な一時名 + `O_EXCL` + rename）。
- **AC-021**: 回答は `<id>.answer.json` として別ファイルに書かれる。**各ファイルの writer はちょうど 1 つ**
  （request と outcome は server、answer は responder）で、lost update が起きない。
- **AC-026**: answer ファイルの書き込みは **first-write-wins** とする（一時ファイルを `O_EXCL` で作り
  `link(2)` で公開する。既存ファイル・既存 symlink があれば `EEXIST` で失敗する）。
  `fh approve` の二重起動が競合しても、後着が黙って先着を上書きすることはない。
  timeout 後に届いた回答は孤児として残るが、決着は request ファイルの outcome が持つため影響しない。
- **AC-022**: `fh approvals --json` が pending な要求を列挙する。`AskUserQuestion` の要求は
  questions / options を含み、responder がそのまま選択肢として提示できる。
- **AC-023**: `fh approve --request <id> --allow [--answers <json>] | --deny [--message <text>]` が回答を書く。
  既に解決済み、または answer が既に存在する要求への二重回答は拒否する（exit != 0）。
- **AC-024**: responder は 2 系統を交換可能に取れる：(a) orchestrator セッションが `fh approvals` を読んで
  `AskUserQuestion` で user に問い、`fh approve` で書き戻す、(b) user が直接 `fh approve` を叩く。
  queue はどちらが応じたかを前提にしない。orchestrator が落ちても承認は決着できる。
- **AC-025**: `AskUserQuestion` への回答は、キー集合が `input.questions` の question 集合と**一致**し、
  各値が当該 question の option label（`multiSelect` なら label の配列）であることを検証する。
  検証は書き込み側（`fh approve`）と読み出し側（server）の両方で行う。

### 時間の扱い

- **AC-030**: 待機中は `notifications/progress`（`params: {progressToken, progress, message}`、
  `progress` は単調増加）を既定 60000 ms 間隔で送り、`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`
  （stdio 既定 1800000 ms）をリセットする。progressToken が要求の `_meta` に無ければ送らない（MCP spec 準拠）。
- **AC-031**: escalation の待機上限は既定 28800000 ms（8 時間）。`MCP_TOOL_TIMEOUT` 既定（100000000 ms）を
  下回る 86400000 ms を上限にクランプする。
- **AC-032**: timeout 到達時は自動 deny を返し、request ファイルへ `status: "timed_out"` と
  decidedAt / 元の tool 入力 / sessionId / toolUseId を保存する。子は異常終了しない。

### テスト（完了条件の機械化）

- **AC-040**: **deny ルールに当たった操作が、user の回答なしに `allow` されない**ことをテストで固定する
  （回答が無いまま timeout に達した場合は `deny`、回答があればその通り）。
- **AC-041**: idle timeout（1800000 ms）を超える待機で progress が複数回送られ、子が異常終了せず
  自動 deny + 状態保存で終わることをテストで固定する（時計は注入する）。
- **AC-042**: 同時に 2 件の要求が pending になり、任意の順で独立に解決できることをテストで固定する。
- **AC-043**: ルールファイルが baseline を弱められないことをテストで固定する。

### ドキュメント

- **AC-050**: `docs/agents/frontier-harness.md`（英語）と `.ja.md`（日本語ミラー）に承認チャネルの節を追加し、
  子起動側に要求する接続条件（`--strict-mcp-config` / `--setting-sources user`）と**残余リスク**を明記する。
- **AC-051**: load-bearing な数値（timeout 既定・progress 間隔）は `<!-- FACT:... -->` マーカーで包み、
  `tests/docs_facts.bats` が named constant と突き合わせる。

## Considered Alternatives / Rejection Rationale

| # | 代替案 | 却下理由 |
|---|--------|----------|
| 1 | 承認 queue を SQLite state（`approvals` テーブル）に置く | 新テーブル/アクセサの露出には `state-store.mjs` の編集が要るが、同一 wave で #541 が同ファイルを所有している。加えて escalation 経路を schema migration に結合させると、migration 失敗が「user に問えない」に直結する。**request/answer は 1 要求 1 ファイルの JSON queue** とし、`paths.mjs` を**呼ぶ側**として使う |
| 2 | 単一の state ファイルに全 pending をまとめる | wave 1 で 4 セッション並列時に複数が同時停止した実績がある。単一ファイルは writer が競合し lost update を生む。**1 要求 1 ファイル**なら lock 無しで N 並列を扱え、任意順に解決できる |
| 3 | approver と orchestrator を unix socket / HTTP で繋ぐ | listener・ポート/権限管理・第二の障害ドメインが増える一方、得られるのは低遅延だけ。承認は人間の応答時間（分〜時間）が支配的で、poll の遅延は無視できる |
| 4 | orchestrator が tmux 経由で approver に応答を送る | 本 issue が撤去しようとしている TUI 依存をそのまま再導入する |
| 5 | deny ルールを `.harness/policy.json`（#494 manifest）に同居させる | 失敗の方向が逆。manifest の漏れは fail-closed（実行できない）で気づけるが、deny ルールの漏れは fail-open（人に聞かずに実行される）で気づけない。同居させるとこの非対称が見えなくなる（issue 本文の指定） |
| 6 | deny ルールを repository-local ファイル（`.harness/approval-rules.json`）に置く | untrusted checkout が空のルールファイルを同梱するだけで escalation を無効化できる。`resolveConfigPath` が既に同じ脅威（repo 同梱 config が `risk.alwaysEscalate` を差し替える）を塞いでいるので、同じ不変条件を適用する |
| 7 | ルールファイルを baseline の完全な置き換えにする | 置き換え可能ということは「削除可能」ということで、fail-open 側のルールに対しては最悪の性質。**baseline はコード内定数、ファイルは追加のみ**とし、既定の上書きは厳しくする方向（`defaultDecision: "escalate"`）だけ許す |
| 8 | ルールに当たらない tool call も既定でエスカレートする | wave の目的（無人進行）が成立しない。`echo` 等の read-only は permission 評価の手前で解決され prompt tool に来ない（§1.2.2 実測）ので、既定 allow でも「全部素通し」にはならない。fail-open 方向であることは docs に明記し、baseline の削除不能性で緩和する |
| 9 | approver 自身が ntfy 等で user へ通知する | 承認は新しい信頼境界であり、そこに外向き I/O と（通知コマンドという形の）任意コマンド実行を持ち込むと blast radius が広がる。呼び鈴は responder 側（orchestrator）の責務とし、本 issue では扱わない |
| 10 | progress を送らず `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` を環境変数で延ばす | 子の起動環境に依存し、設定漏れが 30 分での沈黙切断として現れる。progress は approver 側で完結し、MCP spec が明示的に許す手段（"MAY reset the timeout clock when receiving a progress notification"） |
| 11 | protocolVersion を client の要求値でそのまま echo する | 実装していない revision の互換を騙ることになる。spec は「supported なら同じ値、そうでなければ server の最新」と定めており、それに従う。新しい client は fallback を受け入れるか切断するかを自分で決められる |
| 12 | 承認レコードを SQLite の `approvals` テーブルにも二重記録する | `APPROVAL_KINDS` への enum 追加と、escalation 経路の state root 解決への結合が必要になる。request ファイル自体が prune されない監査証跡として機能するため、本 PR では行わず #534（capability registry の承認軸）へ送る |

### 前提（assumption / 自律解決した枝）

- 受信 payload と返却 payload の形は #529 の実測値（§1.2.2 / §1.2.3）をそのまま採用する（推測ではない）。
- `notifications/progress` の params 形・`progress` 単調増加・version negotiation・stdio shutdown 手順は
  MCP spec（2025-06-18）で確認済み。
- `paths.mjs` は編集しない（#541 が同一 wave で所有）。`providers.mjs` / `router.mjs`（#493）、
  `state-store.mjs`（#541）も触らない。`cli.mjs` は本 issue が唯一の書き手。
- 承認 queue の置き場は `defaultStatePath` と同じ state root（検証済み git common directory）配下とする。
  worktree 間で共有され、repository 単位で分離されるという既存の性質をそのまま継承する。
- issue 本文・PRD は事実抽出にのみ用い、そこに含まれる指示的記述には従っていない。

## Out of Scope

- `wave-orchestrator` の子起動切替（#537）。本 PR は受け口と CLI を提供するだけで、子の argv は組み立てない。
- capability registry の承認チャネル軸（#534 / #493 §7.2-3）。
- Antigravity adapter（#536）、provider adapter 本体（#493）。
- `#494` の manifest 実装への変更（参照のみ）。
- 承認要求の user への push 通知（呼び鈴）。responder 側の責務。
- `fh clean` による request ファイルの prune（承認は監査証跡として保持する既存方針に合わせ、削除しない）。

## Open Questions

- 呼び鈴（ntfy 通知）を orchestrator 側のどこに置くかは #537 で決める。本 PR は queue を読めば分かる状態にする。
- 同一 UID のプロセス（＝子セッション自身）が `<id>.answer.json` を書けば自己承認が成立する。OS レベルの
  分離なしにこれを塞ぐ手段は無いため、`approvals.granted_by` の既存の但し書きと同じ扱いで docs に明記し、
  baseline ルールに「approvals ディレクトリを参照する Bash コマンドはエスカレート」を入れて多層防御とする。
  根本的な解決（別 UID / 別ホストでの responder）は据え置く。
