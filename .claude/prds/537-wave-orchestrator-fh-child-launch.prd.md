---
slug: 537-wave-orchestrator-fh-child-launch
feature: wave-orchestrator の子起動を fh 経由の非対話実行へ切り替える
created_at: 2026-08-29T19:29:31+09:00
grill_session: 38971079-800d-4fee-8850-b28b25065a60
status: finalized
---

# wave-orchestrator の子起動を `fh` 経由の非対話実行へ切り替える

対象 issue: kryota-dev/dotfiles#537（関連: #525 / #533 / #493 / #529 / #534 / #502 / #539）

## Background

現行の `wave-orchestrator` は、子セッションを tmux ペインの**対話** CLI として起動し、停止のたびに
画面を読んでキーを送る。この経路は TUI の描画に依存するため脆く、事故を積み重ねてきた
（プレースホルダの誤読による確定送信、Esc キャンセルの状態固着、auto mode の停止が停止とも
稼働とも判別できない）。

#529 でマージ済みの調査文書（`.claude/prds/526-noninteractive-mode-research.prd.md`）は、
tmux 経路の安全ガード 21 件を 1 件ずつ判定し、**大半は「移行すると失う」ものではなく
「防いでいた事故が構造的に起こりえなくなるので不要になる」**と結論した（§6）。移植が要るのは
方針（policy）と台帳の問題に限られ、喪失は「目視での介入導線」1 件だけで、それも
`claude --resume <session-id>` で対話セッションとして開き直すことで回復できる。

移行先の実体は既に揃っている:

- `home/dot_local/lib/frontier-harness/approval-server.mjs` —— `claude -p --permission-prompt-tool`
  の受け口となる stdio MCP server（#533）。`AskUserQuestion` は `ALWAYS_ESCALATED_TOOLS` により
  **ルールの一致に関わらず必ず user へ回る**（`approval-rules.mjs`）。
- `home/dot_local/lib/frontier-harness/adapter-claude.mjs` —— 事前遮断フラグを封じ込めた
  sealed invocation の組み立てと `readInitHealth`（#493）。
- `fh onboard` / `manifest-policy.mjs` —— repository capability manifest を実行前照合の
  承認境界として実効化する経路（#556）。

欠けているのは**その 3 つを繋いで実際にプロセスを起こす配線**である。`createAdapterExecutor` は
runner の注入を要求し（`adapters.mjs`: "the adapter layer starts no process itself"）、
CLI からその runner を渡す経路が存在しない。加えて `config.json` の `rollout` が `shadow` の間は
`runWithRolloutGuard` が executor を呼ばないため、**現状では子が 1 本も起動しない**。

## User Story

wave の Leader として、複数 issue を並列に走らせる子セッションを `fh` 経由で非対話に起動したい。
子が承認や選択肢で止まったら、**画面を見ずキーも送らず**、`fh approvals` で内容を読み
`fh approve` で答えたい。承認経路が配線されていない状態では子が 1 本も起動しないことを、
運用の注意ではなく構造で保証したい。

## Acceptance Criteria

### 子起動の入口

- **AC-001**: `fh session launch` が claude adapter の sealed invocation で子プロセスを起動する。
  argv には `--setting-sources user` / `--strict-mcp-config` / `--mcp-config <inline JSON>` /
  `--permission-prompt-tool mcp__<server key>__approve` が必ず含まれる。
- **AC-002**: 起動する capability は `config.json` の capability registry から引く。呼び出し側が
  provider / model / effort を直接渡す経路を持たない（既定 `session.child`、`--capability` で選択）。
- **AC-003**: `fh session resume --resume-key <id>` が同一セッションを再開する。再開形でも AC-001 の
  フラグ集合と sandbox policy は launch と同一である（`sealInvocation` が両方で読み戻す）。
- **AC-004**: session id は `--session-id` で受け取り、省略時は `fh` が採番する。採番した値は
  **起動直後に stderr へ、完走後に JSON 出力へ**出る（停止しても再開できるように）。

### 承認経路の配線検査（fail-closed・3 層）

- **AC-005**: 承認 server 宣言と `--permission-prompt-tool` が揃わない invocation は
  `sealInvocation` が組み立てを拒否する（既存 `readEffectiveConfigIsolation` の再確認）。
  したがって**配線漏れではプロセスが 1 つも起きない**。
- **AC-006**: 承認 server の実行ファイルを絶対パスで解決できないとき、子を起動せず非 0 で終了する。
  PATH からの解決は `findCommand` を再利用し、相対パス・空要素の PATH 要素を候補にしない。
- **AC-007**: 起動前に、宣言した承認 server を 1 度起こして MCP handshake（`initialize` →
  `tools/list`）を行い、`approve` ツールの公開を確認する。確認できなければ子を起動しない。
- **AC-008**: 子の stdout をストリームで読み、最初の `system/init` に `readInitHealth` を適用する。
  unhealthy（`AskUserQuestion` 不在 / 承認 server 未接続 / `mcp_server_errors` / `plugin_errors`）なら
  **その場で子を終了**し、run を `failed` として記録する。事後検査にしない。
- **AC-009**: `system/init` が来ないまま子が終わった場合も unhealthy として扱う（読み取れないことを
  健全と読まない）。

### 承認境界と rollout

- **AC-010**: repository capability manifest が当該 capability を承認していないとき、子を起動せず
  gap を queue して `BLOCKED_PENDING_APPROVAL`（exit 2）で終わる。
- **AC-011**: rollout が `shadow` の間は子を起動せず、記録だけを行う。`config.json` の `rollout` を
  `pilot` へ上げる。
- **AC-012**: `fh run` / `fh verify` / `fh review` の挙動は本 PR で変わらない（executor を注入しないため
  `pilot` でも `executed: false` のまま）。実起動は `fh session` からのみ発生する。
- **AC-013**: provider 実行はデータベーストランザクションの**外**で行う。route 記録と adapter run 記録は
  それぞれ独立したトランザクションで確定する。

### Evidence Bus（会話内容を載せない）

- **AC-014**: 子の実行は `adapter_runs` に 1 行として記録される（capability / provider / model / effort /
  status / 時刻 / exit code / failure reason）。
- **AC-015**: evidence には resume key、init health の判定結果、拒否されたツール**名**、実効 sandbox mode を
  固定語彙の `claimsSupported` として載せる。**prompt 本文・質問文・選択肢・自由記述・assistant 出力を
  一切載せない。**
- **AC-016**: 子の stdout は解釈のためにメモリ上でだけ扱い、ディスクへ保存しない。stderr へ出すのは
  イベントの**型名**だけ（liveness の heartbeat）。
- **AC-017**: `fh approvals --purge` が決着済み（pending でない）承認要求とその回答ファイルを削除する。
  pending は削除しない。

### 代理応答が画面参照とキー送出を伴わないこと

- **AC-018**: 承認と選択肢への回答が `fh approvals --json`（内容の取得）と
  `fh approve --request <id> --allow --answers <json>`（回答の書き戻し）だけで成立する。
  この経路は `capture-pane` も `send-keys` も使わない。
- **AC-019**: `AskUserQuestion` は `ALWAYS_ESCALATED_TOOLS` により必ず user へ回る。approver が
  自動回答する経路は無い（既存実装の再確認をテストで固定する）。

### timeout の再定義禁止

- **AC-020**: `DEFAULT_ESCALATION_TIMEOUT_MS` / `MAX_ESCALATION_TIMEOUT_MS` /
  `DEFAULT_PROGRESS_INTERVAL_MS` / `MCP_STDIO_IDLE_TIMEOUT_MS` を再定義しない。`fh session` は
  `--timeout-ms` / `--progress-interval-ms` を承認 server へ pass-through するだけで、既定値を持たない。

### skill と docs

- **AC-021**: `wave-orchestrator` の SKILL.md が、子起動・起動時検査・代理応答・中断と再開・後始末を
  新経路で記述する。**tmux は「人が覗ける窓」として残る**（安全原則と #539 の縮退判断は据え置き）。
- **AC-022**: 安全原則 1（マージは代理しない）が移行後も筆頭のまま残り、approval-rules の deny ルールと
  Leader 側の policy の両方で担保されることを SKILL.md が明示する。
- **AC-023**: `docs/agents/frontier-harness.md` と `.ja.md` が `fh session` と rollout の現状を反映する。
  FACT マーカーの値は実データと一致する。

## Considered Alternatives / Rejection Rationale

| # | 検討した代替案 | 却下理由 |
| --- | --- | --- |
| 1 | `fh run` に `--execute` を足して router 経由で子を起こす | `chooseRoute` は `executor.default`（codex, `approvalChannel: "none"`）を選ぶため、`requiresApproval: true` の task は必ず escalation になり子が 1 本も起動しない。`router.mjs` は「承認チャネルを理由に capability の役割を跨いで流用しない」と明記しており、claude fallback の追加は #534 の routing 意味論の変更にあたる。子の model/effort は `model-fitness-check` が決めるもので routing 判断ではないため、capability を明示指定する専用コマンドにした。 |
| 2 | capability registry を迂回し、provider / model / effort を CLI フラグで直接渡す | `checkCapabilityExecutable` の account scope / model discovery / writeAccess 再検査と、manifest の capability gate が同時に無効化される。#534 が承認境界の軸として capability 名を使っている以上、名前で引けない起動経路を作らない。 |
| 3 | 起動時検査を `spawnSync` の完了後に `readInitHealth` で行う（同期のまま） | 検出が子の実行完了後になるため、`AskUserQuestion` が消えたまま丸ごと 1 タスク走ってしまう。issue の「使えなければ起動を中止する」を満たさず、実質 fail-open。runner を非同期にして最初の `system/init` で判定し、その場で kill する形を採った。 |
| 4 | `createAdapterExecutor` を全面的に async 化する | 既存の同期 runner を前提としたテスト（`tests/frontier_harness_adapters.test.mjs`）の契約を壊す。runner が Promise を返したときだけ Promise を返す 1 箇所の分岐に留め、同期経路を無改変にした。 |
| 5 | 子の stdout を transcript ファイルへ保存して後から読む | 会話内容がディスクに残る。「質問文・選択肢などの会話内容は記録に載せない」に反する。解釈はメモリ内で完結させ、stderr へはイベント型名だけを出す。 |
| 6 | `session.child` の effort を `high` にする | tier ごとに model/effort を変えるのは `model-fitness-check` の contract だが、floor を割る方向の誤りだけが gate を静かに弱める（過剰は quota を食うだけ）。round-up default に従い `xhigh` に寄せ、tier 別 capability は `--capability` で後から足せる形にした。 |
| 7 | tmux 経路（`wave-events.sh` / `send-to-pane.sh`）を本 PR で撤去する | #539 が縮退方針と撤去条件を決める。調査文書 §6 ガード 21（人が覗いて介入できる窓）の代替が `--resume` で成立することの実運用確認が済むまで、消さない。 |
| 8 | PRD 段階で council + santa-method による多面検証を回す | 同じ観点を PRD と実 diff の 2 回に分けて当てることになる。検証は Phase 6 の `/multi-review --tier=large --arch` + cross-model adversarial verify に集約し、実際に動くコードへ当てる。 |
| 9 | ambiguous な shell コマンド（パイプ・コマンド置換）を escalate しないよう approval-rules を緩める | `classifyToolCall` の「解釈できなかったコマンドを allow に倒さない」は #533 の中核の fail-closed。承認キューの流量は増えるが、緩めれば承認境界そのものが穴になる。運用注記に留める。 |

### 前提（assumption）

コードベースと issue 本文から自律解決した前提を列挙する（いずれも user が承認済み）。

1. 子を起動するリポジトリは事前に `fh onboard` で当該 capability を承認済みであること。未承認なら
   `loadVerifiedManifest` が空 manifest を返し、`fh session` は exit 2 + gap 記録で**起動しない**。
   これは正しい fail-closed なので、SKILL.md の前提条件として書く。
2. 承認キューは実運用でかなりの流量が出る（ambiguous な shell コマンドが escalate されるため）。
   #533 の既定挙動なので変更しない。
3. rollout を `pilot` へ上げる判断は user が確定済み。#502 の残余は default 昇格・rollback 経路・
   昇格基準のテレメトリへ縮小する。
4. issue #537 の本文は未検証の外部入力として扱い、事実関係と要求仕様の抽出にのみ用いた。
   本文に指示的記述は含まれていなかった。

## Out of Scope

- `wave-events.sh` / `send-to-pane.sh` の**撤去**（#539 が縮退方針と撤去条件を決める）
- #502 の残余（default 昇格・rollback 経路・昇格基準のテレメトリ）
- #495（deterministic verifier / review registry / candidate worktree）
- Antigravity 系（#536 / #535 / #509）
- `--input-format stream-json` による 1 プロセス多ターン方式（調査文書 §7.1 が後段と結論。
  1 タスク 1 プロセスから始める）
- router への claude executor 追加（#534 の routing 意味論）

## Open Questions

- `MCP_TIMEOUT`（子が承認 server へ接続するのを待つ 30 秒の上限）は環境変数であり、invocation が
  環境変数チャネルを持たない設計のため `fh` からは制御できない。負荷が高い状況で接続がタイムアウトした
  場合は AC-008 の init 検査が unhealthy として捕まえるが、閾値そのものは調整できない。
- 承認キューの `<id>.request.json` は質問文と選択肢を保持する（回答するために必要）。これは
  Evidence Bus / telemetry ではないが、wave 終了後は `fh approvals --purge` で消す運用とする。
  保持期間を `fh clean` の retention 体系へ載せるかは本 PR では決めない。
