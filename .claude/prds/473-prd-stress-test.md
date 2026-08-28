# #473 PRD stress-test 結果と sub-issue 分割案

status: 確定 / 実装なし
対象: issue #473 のコメントに投稿された PRD（AC-001〜AC-044 + Considered Alternatives + Out of Scope + Open Questions 4 件）
目的: AC 44 件を sub-issue へ分割する**前**に前提を叩く。分割後に前提が崩れるのを防ぐ。
併読: `.claude/prds/370-existing-layer-gap-analysis.md`

検証方法: 各 AC が名指しする実体（hook / script / env var / パス）をリポジトリと ECC ランタイムで実在確認した。
issue 本文・skill 説明文は根拠に採用していない。

> **追記（2026-08-29）: 本書は執筆時点のスナップショットである。**
> 本文が実在するものとして参照する `hooks-fork/ecc-state-reader.js`（および `ecc-status` /
> `ecc-sessions` / `ecc-work-items`）は、その後 **PR #520（#496）で削除**され、
> `home/.chezmoiremove:126` に削除対象として登録された。「read-only な会話面の
> パターン」という論旨は有効だが、参照先の実体はもう存在しない。
> 本文は当時の判断根拠を保全するため書き換えていない。

---

## 1. 実在確認できた前提（AC はそのままでよい）

| AC | 主張 | 実測 |
|---|---|---|
| AC-009 | `GATEGUARD_BASH_ROUTINE_DISABLED=1` で routine Bash gate だけ無効化 | `gateguard-fact-force.js:138` に実在 |
| AC-011 | 無効状態の Edit/Write fact-forcing wiring を削除 | `ECC_DISABLED_HOOKS` に `pre:edit-write:gateguard-fact-force` が実在し、配線も残存。記述は正確 |
| AC-013 | 7 つの hook を外す | `suggest-compact` / `doc-file-warning` / `quality-gate` / `post-edit-accumulator` / `stop-format-typecheck` / `design-quality-check` / `post-edit-console-warn` すべて実在 |
| AC-015 | `ecc-status`/`ecc-sessions`/`ecc-work-items` reader を外す | `hooks-fork/ecc-state-reader.js` + `zsh/claude.zsh:61-63` として実在 |
| AC-016 | wave-orchestrator を一切変更しない | wave 系 hook は独立エントリで配線され、AC-001 の Notification matcher 変更と配線が分離。実現可能 |
| AC-017 | `ecc-metrics-bridge` / `ecc-context-monitor` を外す | 両方 PostToolUse `*` に実在 |
| AC-026 | `ECC_SESSION_START_CONTEXT=off` で context 注入だけ停止 | `session-start.js:107,199,612` に実在 |

---

## 2. 全体に効く制約: ECC hook ランタイムは改変できない

`home/.chezmoiexternal.toml:161-166` が `.agents/skills/ecc/scripts` を
commit pin の archive external（`refreshPeriod = "168h"`、`include = ["*/scripts/hooks/**", ...]`）として宣言している。
**ECC hook の実体はすべて外部取得物**で、chezmoi source tree に存在せず、refresh で上書きされる。

このリポジトリが ECC hook に対して取れる手段は 3 つだけ:

1. `ECC_DISABLED_HOOKS` / env で挙動を切る
2. `settings.json` から配線を外す
3. `hooks-fork/` に fork を置いて置き換える（既存 4 例）

**「hook の内部挙動を少し変える」という選択肢は存在しない。** これが AC-012 と AC-024 の実装形を規定する（後述）。

---

## 3. 覆った / 修正が必要な AC と、確定した対応

### [MUST] AC-029 / AC-044 — 金曜 18:00 は空きスロットではない

`dev.kryota.knowledge-distill` LaunchAgent が **Weekday 5 / Hour 18** に登録済み。
新 evaluator を同スロットに足すと、同一アカウントで headless `claude -p` が 2 本起動し両方課金される。
PRD には既存 LaunchAgent を停止する AC が無い（AC-043 は macOS drift の休止だけを明示、AC-044 は skill の話のみ）。

**決定: ラベルを改名して入れ替える。** 既存を退役させ、evaluator 用の新ラベルを金曜 18:00 に登録する。
同ラベルのまま実行内容だけ差し替える repoint は採らない（名前と実体を一致させる）。

AC に明記すべき退役 3 点と**その順序**:

1. 明示的な `launchctl bootout gui/$(id -u)/dev.kryota.knowledge-distill`
2. `run_onchange_after_30-register-launchd-agents.sh.tmpl:23` の `labels=()` 配列から削除
3. `.chezmoiremove` へ plist のエントリを追加

**順序の罠**: `:26-30` のループは配列に載っているものしか bootout しない。
配列から先に消すと、その agent は二度と bootout されずロード済みのまま走り続ける
（`.chezmoiremove` が plist を消しても launchd の登録は残る）。**bootout を配列削除より先に行う。**

AC-044 には「knowledge-distill の週次自動実行を停止し、手動起動のみとする」を明記する。

### [MUST] AC-018 — snapshot に context は存在しない / #446 が先行

- `executable_statusline.sh` が永続化するのは `write_rate_limits_snapshot`（5h/7d の `used_percentage` と `resets_at`）と
  `write_harness_cost`（session cost）の 2 つだけ。`ctx` は 429 行目の**表示にしか使われず永続化されていない**。
- 現在 `context_remaining_pct` を持つのは `ecc-metrics-bridge` だが **AC-017 でそれを消す**。
  AC-017 と AC-018 を素直に実装すると context の供給源が消滅する。
- `rate_limits_<profile>.json` は profile 単位。statusline のコメントは #449 を引いて
  「session 単位の値を profile ファイルに置くと同時実行セッションで互いに壊す」と明記しており、相乗りできない。

**決定: #446 先行、AC-018 はその後続。**
#446 が新設する `session_<sid>.json`（課金起点を billing キー配下に置く方針、user 承認済み）に、
**`context` キーを兄弟として足す**形へ AC-018 を書き換える。#473 側で session snapshot を新設しない。
既存 `rate_limits_<profile>.json` のスキーマは不変に保つ（`model-fitness-check` が consumer）。

> **着手条件（決定済み）**: **#446 の PR merge**。スキーマ確定（PR 提出）では着手しない。
> #446 は現時点で issue コメント 0 件・PR 未作成で、並行セッションが実装中。
> `session_<sid>.json` のスキーマは issue 上に記録されていないため、merge を待つ。
> **#473 の Wave 2 全体が #446 の merge 待ちになることは織り込み済み。**

### [MUST] AC-012 / AC-020 — hook は `AskUserQuestion` を呼べない

`config-protection.js` は `process.exit(2)` による hard block（161-172 行）。
PreToolUse hook が取れるのは「exit 2 で止める（stderr がモデルへ返る）」か「通して advisory を注入する」の 2 つで、
hook から `AskUserQuestion` を発火させる経路は無い。
リポジトリ内の `AskUserQuestion` 前例 8 箇所はすべて SKILL.md の指示文であり、hook 駆動の前例はゼロ。
AC-012 を字義どおり実装すると**保証されたゲートが best-effort の助言に降格する**（AC-020 も同型）。

**決定: hook は現行の hard block を維持し、判断要求は共通 instructions が担う。fork はしない。**
上流 `config-protection.js` の stderr には手を入れない。ブロックを受け取ったモデルが
理由・影響・代替案を提示し、再試行前に `AskUserQuestion` を出すことを**共通 instructions 側で規定**する。
AC-012 の文面をこの形に書き換える。

**fork を採らない理由**: `hooks-fork/` には既に 4 件あるが、AC-015 はそのうち 2 件
（`governance-capture.js` / `post-bash-command-log.js`）を削除する方向であり、
新規 fork を足すのはその流れに逆行する。fork は upstream 追従の保守コストも負う。
この判断により **S8 は起こさず S3 に吸収する**。

### [MUST] AC-001 — dashboard から `claude-done` を外す

`executable_ntfy-notify.sh:141-147` は `agent_completed` と `Stop` を `NTFY_TOPIC_DONE`（`claude-done`）へ送る唯一の producer。
AC-001 で両方を外すと `claude-done` は無人 topic になるが、
`ntfy-dashboard/server.ts:241-242` は `topicAttention` と `topicDone` の**両方を fetch する**設計で、
`dev.kryota.ntfy-dashboard` LaunchAgent も稼働している。PRD には dashboard への言及が無い。

**決定: dashboard の対象 topic を絞る AC を追加する。** topic を残して空を許容する案は採らない。

### [SHOULD] AC-024 — 挿入点は `ecc-hook.sh`

AC-024 は「retained safety/warning/recovery が実際に発火した時だけ」event counter を記録するよう求める。
対象（`block-no-verify`、Bash destructive fact-forcing、MCP recovery）はすべて external な ECC hook で、内部を計測できない。

**決定: `home/dot_claude/executable_ecc-hook.sh` の `exec` を外し、ラッパー 1 箇所で観測する。**
このラッパーはリポジトリ所有で、settings.json 上の **21 個の hook すべてが通る入口**
（SessionStart 1 / PreCompact 1 / PreToolUse 6 / PostToolUse 7 / PostToolUseFailure 1 / Stop 5）。
現在は `:47` の `exec node "$bootstrap" node "$@"` がシェルを node で置換するため終了コードを観測できない。
`exec` を外せば pinned な runtime に触れずに発火を数えられる。

個々の hook 側で記録する案は、対象が upstream ファイルで fork が必要になるため採らない（AC-012 と同じ理由）。

**コスト**: hook 1 回につきプロセスが 1 段増える。PostToolUse の `*` matcher は tool call のたびに走るため
回数が多い。したがって S4b の受け入れ条件に
**「hook 1 回あたりのオーバーヘッドを実測し、許容できなければ revert する」**を必ず入れる。
なお S4b は S1 の後なので、計測時点では 21 個のうち相当数が既に外れている（計測はその状態で行う）。

### [SHOULD] AC-026 / AC-028 — 学習ループの消費側だけが消える

`Active instincts:` の注入元は ECC `session-start.js:459`。AC-026 の `ECC_SESSION_START_CONTEXT=off` がこれを止める一方、
AC-028 は observer（生産側）を維持する。結果として instinct は週次 evaluator の cluster 計算のためだけに書かれ続ける
（cluster は instinct 本文から計算されるので死蔵ではないが、日常セッションでの behavioral payoff は消える）。
token 削減という PRD の主題と整合する**正当なトレードオフ**だが、明示的な選択として書かれていない。

**推奨**: Considered Alternatives に「SessionStart の instinct 注入だけ残す」案と却下理由を追記する。

### [NITS] AC-003 — 既存 radar の失敗通知には重複抑止が無い

`notify_error` は失敗のたびに priority 5 を送る。`$STATE_DIR/last-run` は成功時にしかスタンプしないため、
「初回失敗は一度だけ、成功回復まで重複しない」という状態機械は新規実装になる。
AC-004 が「未確認の incident を次の interactive セッションが読む」ことを要求するので、
incident 状態は agent から読める場所（= AC-035 の queue と同じストア）に置く。

### [NITS] AC-021 — sentinel は自前の状態を持つ

既存 `detectLoop` は `bridge.recent_tools` を入力とするが、その bridge は AC-017 で消える。
「最小の PostToolUse sentinel」は自前の ring buffer を持つ必要があり、"最小" の見積もりを上振れさせる。

### [情報] 5 つの新規 state writer は 1 モジュールに集約する

匿名 event counter・hash 化 scope・週次 rollup・session snapshot 読み・loop ring buffer が
それぞれ書き込み先を持つ。PRD は 5 つの独立 AC として書いているが、
**1 つの state モジュール / 1 ディレクトリに集約すべき**（YAGNI と保守性）。

---

## 4. Open Questions への回答

### Q1: evaluator の model / turn・time guard / token budget

**現状では実測ベースで決められない。** 既存 radar の実測値（`sonnet` pin / `--max-turns 50` / timeout 600s / watchdog）が
出発点になるが、gap analysis §3.1 のとおり radar は縮退経路しか通っておらず、
**Phase 2/3 を通った正常 run のコスト分布が存在しない**。

**回答**: 計測パス（S0）を直して正常 run を数回通してから決める。それまでは radar の現行値を暫定値として据え置く。
AC-033 の「正常 run の実測後に調整する」方針は正しいが、その正常 run が現状は発生していない。

### Q2: candidate queue の JSON schema / aggregator の field 定義

**回答（設計指針として確定）**:
- 置き場所は AC-035 のとおり `${XDG_STATE_HOME:-~/.local/state}/agent-improvement/`。
  同階層の `wave-orchestrator` / `agent-workflow` が 0700 の先例（`knowledge-distill-radar` / `morning-radar` は 0755 なので手本にしない）。
- 会話面は `ecc-state-reader.js` + zsh 関数の既存パターンを踏襲し、
  `status | next | resolve` の 3 サブコマンドを持つ **1 つの read-mostly CLI** にまとめる
  （AC-037/038/039 が 3 実装に分かれるのを避ける）。`resolve` だけが書き込む。
  - **amendment（#501 実装時）**: 実際には `upsert` を加えた 4 サブコマンドになった。`upsert` は候補投入の口で `resolve` と並ぶ書き込み経路。S5 が S6（evaluator）に依存せず単体検証できることを完了条件にしているため、evaluator 抜きで候補を入れる手段が要る。
- incident 状態（AC-003/004）も同じディレクトリに置く。

### Q3: evaluator incident の topic/tag

**回答（実コードから確定）**: `claude-attention` を再利用し tag で識別する。
`knowledge-distill-radar.sh` が同じ判断を既に下しており、
「single topic (claude-attention), reused per intent-gate decision」と根拠をコメントに残した上で
`tags: ["microscope","knowledge-distill"]` を使っている。
新 topic は `.chezmoidata.toml` / ntfy サーバ設定 / dashboard の 3 箇所に波及するため、tag 識別が最小コスト。
priority 5（incident）と priority 3（通常結果）の使い分けも踏襲できる。

### Q4: `~/.claude*/session-data/` の削除・保持期間短縮

**回答（決定済み）**: **配線停止のみ行い、既存データは温存する。**
#473 のスコープを「新規書き込みを止める」に限定し、削除は別 issue の明示判断に送る。
同じ扱いを governance SQLite（AC-015）と既存 observations にも適用する。

---

## 5. sub-issue 分割案

tier は `pr-workflow/SKILL.md:44-47` の定義に従い、境界上は上位へ切り上げる（round-up default）。

### S0 は #473 の外

**S0: knowledge-distill の instinct 計測パス不整合** → **独立 issue**（#473 の sub-issue にしない）
tier: **small**（`radar.sh:154` と `SKILL.md:45,95` の 2 箇所、`instinct-cli.py` へ委譲する形が最小、`knowledge_distill_radar.bats` あり）
実測: 3 つの homunculus すべてで `instincts/personal` = 0 件。実蓄積は `projects/*/instincts/**` に
fallback 1 件 / 個人 1400 件 / 第2アカウント 2105 件。
**S6 の必要性を実測するための前提**であり、Q1 の回答もこれに依存する。

### #473 の sub-issue

| # | sub-issue | 含む AC | tier | 依存 |
|---|---|---|---|---|
| **S1** | ECC hook の縮小（削除のみ） | 008-011, 013-015, 017, 025, 027 + 016(不変ガード) | **standard** | なし |
| **S2** | 通知契約の再定義 | 001, 002, 042 + dashboard topic 絞り込み（新 AC） | **standard** | なし |
| **S3** | 共通 instructions の判断原則 | 005, 006, 007, 012 | **small** | なし |
| **S4a** | statusline に context キーを追加 | 018 の supply 側 | **small** | **#446 の merge** |
| **S4b** | signal 収集 hook + state モジュール | 018 の consume 側, 019-024 | **standard** | S1, S4a |
| **S5** | candidate queue + read-mostly CLI | 030, 034-037, 039-041 | **standard** | なし |
| **S6** | scheduled evaluator と launchd 入替 | 029, 031-033, 043, 044 | **large** | S0(判断材料), S1, S5 |
| **S7** | end-of-task 連携と incident 提示 | 003, 004, 038 | **standard** | S3, S5 |

**S8 は起こさない。** AC-012 は instructions のみで実装するため S3 に吸収した（S3 は small のまま）。

### tier 判定の根拠

- **S1 = standard**: `settings.json` 単一ファイルへの大規模編集だが、外す対象に安全周辺
  （raw audit / governance capture）が含まれ、`claude_permissions.bats` / `files.bats` の更新を伴う。
  round-up 規則（security surface に触れる可能性があれば standard 以上）を適用。
  **分割しない理由**: すべて「配線を外す」同種操作で同一ファイルを触る。分けると同一ファイルへの PR が
  5 本並び、コンフリクトのほうが高くつく。
- **S2 = standard**: `ntfy-notify.sh` の event map、`settings.json` の matcher、`ntfy-dashboard/server.ts` の
  topic 絞り込みの 3 ファイル横断 + `ntfy_notify.bats` / `ntfy_dashboard.bats` の 2 本。
- **S3 = small**: `home/AGENTS.md.tmpl`（harness 非依存）と `home/dot_claude/CLAUDE.md`（Claude 固有）の
  テキストのみ。契約変更もコードもない。AC-012 の判断要求もここに載る（fork しないため）。
- **S4a = small**: statusline への 1 キー追加。**#446 の PR merge まで着手しない。**
- **S4b = standard**: 新規 hook 3 種（resource warning / loop sentinel / scope collector）+ 集約 state モジュール。
  `ecc-hook.sh` の `exec` 除去（AC-024）もここ。設計判断を含む新機能。
  受け入れ条件に **hook 1 回あたりのオーバーヘッド実測と、許容不可なら revert** を含める。
- **S5 = standard**: 新規 CLI + schema + state + zsh 関数 + bats。evaluator 無しでも手動投入でテストできるため
  S6 と独立に進められる。
- **S6 = large**: launchd の改名入替は退役順序を誤ると**ロード済み agent が残り続けるロールバック困難な状態**を作る。
  加えて evaluator wrapper 本体と AC-043 の drift 休止を含む。round-up 規則（高ロールバック難度）を適用。
- **S7 = standard**: instructions と incident 状態の読み取りを通常フローへ接続する。S3 と S5 の両方が要る。

### 依存順序（wave 化）

```
Wave 1（並行可）: S0(独立issue) | S1 | S2 | S3 | S5
Wave 2（並行可）: S4a(#446 merge 後) | S7(S3+S5 後)
Wave 3          : S4b(S1+S4a 後) → S6(S0+S1+S5 後)
```

- **外部依存は #446 の 1 本だけ**（S4a）。S4a を Wave 1 に入れないのはこのため。
  Wave 2 以降が #446 の merge 待ちになることは織り込み済み。
- S6 が最後なのは、S5 の queue schema と S1 の signal 削除が確定してからでないと
  evaluator の入出力が決まらないため。
- S0 は #473 の外だが、**S6 の着手前に完了していること**が望ましい（Q1 の実測が S6 の AC-033 に必要）。

### 評価入力の秘匿化契約（S6 に効く・決定済み）

evaluator へ渡すのは `instinct-cli.py evolve` の **cluster サマリのみ**
（trigger / instinct ID / avg confidence / domain / scope）。
instinct 本文は Haiku 生成の自由文で `project_name` を含みうるため渡さない。
`observations.jsonl` は `.input` に Bash コマンド全文とファイルパスを保持するため渡さない（AC-015/032 と整合）。

---

## 6. 決着済みの判断

| 論点 | 決定 |
|---|---|
| AC-012 の実装形 | **instructions のみ。fork しない。** S8 は起こさず S3 に吸収 |
| AC-024 の挿入点 | **`ecc-hook.sh` の `exec` を外してラッパー 1 箇所で観測。** S4b の受け入れ条件にオーバーヘッド実測と revert 条件を入れる |
| S4a の着手条件 | **#446 の PR merge**（スキーマ確定では着手しない） |
| S0 の扱い | **#473 の sub-issue にせず独立 issue** |
| AC-029/044 | **ラベル改名による入替**（repoint は採らない）。退役は bootout → 配列削除 → `.chezmoiremove` の順 |
| AC-018 | **#446 の `session_<sid>.json` に `context` キーを兄弟として追加**。既存 `rate_limits_<profile>.json` は不変 |
| AC-001 | **dashboard から `claude-done` を外す**（空 topic を残さない） |
| evaluator 入力 | **cluster サマリのみ**。instinct 本文と `observations.jsonl` は渡さない |
| 既存蓄積データ | **配線停止のみ・温存**。削除は別 issue の明示判断 |

分割案は §5 で確定。起票へ進める状態。
