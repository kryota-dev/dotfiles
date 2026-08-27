---
slug: wave-orchestrator-state-and-send
feature: wave-orchestrator の状態検知と送信経路の是正
created_at: 2026-08-27T11:52:18+09:00
grill_session: cf11345c-cf4e-4d75-96ba-a4d40d0b9602
status: draft
---

# wave-orchestrator の状態検知と送信経路の是正

対象 issue: #440 #441 #442 #443 #444 #445 #447 #448 #449 #450 #471

## Background

`#437`（PR #439）で停止検知を画面テキストから hook payload へ移した直後の実運用（4 セッション
並列 wave）で、10 件の欠陥が露出した。根は 3 つに集約される。

1. **決着イベントの欠落** — `AskUserQuestion` が回答された／キャンセルされたことを示すイベントを
   記録していない。状態の解除信号が存在しないため `ASK` が固着し（#448）、`--select` は確定を
   検証できず（#441）、判定を固定の論理順序に頼らざるを得ず `Stop` が後続の質問を隠す（#447）。
2. **キー送出と TUI 処理の非同期** — `send-keys -l` で本文を流し込むと確定キーを取りこぼし
   （#442）、`Escape` が効かないまま本文がキーとして解釈されて誰も選んでいない回答を確定させる
   （#445）。送信成否を `UserPromptSubmit` だけで見るためキュー経由の配信を常に失敗と報告する
   （#450）。
3. **粒度のカテゴリエラー** — セッション固有の effort を profile 単位のキャッシュファイルに置いた
   ため、並列セッションが互いの値を読み、乖離という事実主張で blocking 停止する（#449）。

加えて配置とドキュメントの齟齬が 2 件（#440 実行ビット、#444 zsh history modifier）。

## User Story

wave-orchestrator の利用者として、並列セッションの停止を取りこぼさず、稼働中を停止と誤認せず、
代理応答が意図しない確定を起こさない状態で監視したい。検知器が判定できないときは、正常と
混同せずそう言ってほしい。

## Acceptance Criteria

### A. 状態判定（#443 #447 #448）

- **AC-001** 未回答判定は `tool_use_id` のペアリング（`PreToolUse` にあり `PostToolUse` ∪
  `PostToolUseFailure` に無い）で行い、イベントの到着順に依存しない。
- **AC-002** `--state` は `ASK_QUESTION` / `ASK_PERMISSION` / `RUNNING` / `IDLE` / `UNKNOWN` を返す。
- **AC-003** 【#447 回帰】ターン内に `Stop` があっても、その後に出た `AskUserQuestion` が未回答なら
  `ASK_QUESTION` を返す。
- **AC-004** 【#448 回帰】回答済みの質問は `ASK_QUESTION` を解除する。
- **AC-005** 【#443 回帰】ターン内の `permission_mode` が一様に `auto` / `bypassPermissions` の
  ときのみ `permission_prompt` を停止扱いしない。混在または非 auto なら `ASK_PERMISSION`
  （誤って停止を見逃す方向へ倒さない）。
- **AC-006** `idle_prompt` は `IDLE` に分類する（「人が答えるべき問い」ではないため）。
- **AC-007** `StopFailure`（API エラーでのターン終了）も `IDLE` の根拠に含める。
- **AC-008** 記録側は `PostToolUse` / `PostToolUseFailure` を `session_id` / `prompt_id` /
  `hook_event_name` / `tool_name` / `tool_use_id` のみに切り詰めて記録し、`tool_input` /
  `tool_response` を書かない。
- **AC-009** `settings.json` に 2 hook が matcher `AskUserQuestion` で配線され、既存 hook を壊さない。
- **AC-031**【追加】SKILL.md の監視の主経路を **`--state` の遷移駆動からイベント追記の
  到着駆動へ**変更する。`--state` は送信前ガード等の補助に位置づける。
  （実運用 4 セッション×30 分で `AskUserQuestion` 停止 5 回・取りこぼしゼロ。#447 の
  サブエージェント委任パターンも検知。#448 コメント）
- **AC-010** 【実機検証】`chezmoi apply` 後、Esc で `AskUserQuestion` を閉じたとき
  `PostToolUseFailure` が記録される。発火しない場合は代替規則へフォールバックし、その事実を
  SKILL.md に記録する。

### B. 送信（#441 #442 #445 #450）

- **AC-011** 本文送出は `tmux load-buffer` + `paste-buffer -p`（bracketed paste）で行い、
  `send-keys -l` を使わない。
- **AC-012** 【#445 回帰】`--text` は `ASK_QUESTION` のとき本文を送らずに中止する
  （暗黙に `Escape` を送って状態を変えない）。
- **AC-013**【改訂】`--dismiss` を追加。`Escape` 送出後に**選択肢 UI が実際に閉じたこと**を
  capture で確認してから成功を報告する。閉じなければ非 0 で終了し、本文を送らない。
  （決着イベントは Esc キャンセルで発火する保証がないため、確認は capture に依る）
- **AC-014**【改訂】`--text` の結果は `DELIVERED` / `QUEUED_UNCONFIRMED` / `PENDING_CONFIRM` の
  3 値。**いずれも「送信失敗」と断定しない**。
  - `DELIVERED`: `UserPromptSubmit` が現れた
  - `QUEUED_UNCONFIRMED`: 入力欄が空になったが `UserPromptSubmit` が現れない
    （配信された可能性が高いがターン開始は未確認。**再送しない**）
  - `PENDING_CONFIRM`: 本文が入力欄に残っている（確定キーだけが失われた）
- **AC-015**【改訂】`PENDING_CONFIRM` のとき **`Enter` を 1 回だけ送って再確認する**。
  入力欄をクリアしない（本文は既に届いており、クリアは届いた指示を捨てる）。
- **AC-016**【撤回・改訂】`--select` は**数字キーのみを送り、`Enter` を投機的に送らない**。
  複数問は 1 回の呼び出しで全問を送らず、**1 問ずつ送ってそのつど確定を検証する**。
  確定していなければ `Enter` を 1 回送って再検証する。
  （claude 2.1.221 では数字キーが確定して次問へ進むため、続く `Enter` が次問の既定値を
  確定させる。実測で発生し `✔` が記録された = 安全原則 2 の破れ）
- **AC-017**【改訂】確定の検証は 2 層に分ける。**問い単位**は capture の `☒` / `☐`、
  **呼び出し全体の完了**は決着イベント（`tool_use_id`）。いずれも検証できなければ成功を報告しない。
  問い数や `preview` の有無で安全性を推論しない（単一問でも確定しない例が実測済み）。
- **AC-018**【改訂】画面参照の許容境界を SKILL.md に明記する。
  - **許容（自分の操作の結果）**: 入力欄に本文が残っているか / 選択肢 UI がまだ開いているか /
    どの問いが確定済みか
  - **禁止（セッション状態の判定）**: 停止しているか稼働中か / 何を問うているか
    → hook payload のみを根拠とする（#435 #436 の教訓）
  - 検証不能なら送らずに非 0 で終了する
- **AC-026**【追加】`--key-for` / `--select` は送信前に**選択肢 UI の実在を確認**し、
  確認できなければ送らずに落ちる。（Esc で閉じた後も `--select` が番号を返し、裸の数字キーが
  入力欄へ入る危険。#448 派生危険 1）

### C. 配置とドキュメント（#440 #444）

- **AC-019** `scripts/*.sh` を `executable_` prefix にリネームし、配置後 755 になる。SKILL.md は
  直接実行形のまま動く。
- **AC-020** SKILL.md Phase 2 の tmux target を window ID / pane ID ベースにし、`${SESS}` の
  ブレースが必要な理由を明記する。
- **AC-021** 【機械検査】SKILL.md にブレース無しの `$SESS:` パターンが存在しない。
- **AC-027**【追加】`--self-check` は**自身が直接実行可能か**を試し、結果を報告する。
  （exit 126 を呼び出し側が `|| echo UNKNOWN` で吸収すると全ポーリングが UNKNOWN に落ちる
  沈黙する故障。`bash` 経由の self-check では検出できない。#440 コメント）

### D. model/effort（#449）

- **AC-022** `model-fitness-check` は `${CLAUDE_EFFORT}` を effort の情報源とし、statusline
  snapshot を参照しない。
- **AC-023** `statusline.sh` は `rate_limits_<profile>.json` に `effort` を書かない。quota は維持、
  L2 の TUI 表示は無変更。
- **AC-024** `model-fitness-check` の提示に「すでに要求水準を満たしている（変更不要）」を常に含める。
- **AC-025** 【実機検証】`${CLAUDE_EFFORT}` が実際に展開される。`OFe` が未解決値を `"high"` に
  丸める制約を SKILL.md に明記する。

### E. 中断と再開（#471）

- **AC-028** 生存確認は `--session-id <uuid>` と `--resume <uuid>` の**両方**を見る。
  （`--resume` で再開したセッションの argv には `--session-id` が無く、ガードが毎回発火して
  代理応答が完全に機能しなくなる。3 セッションで実測）
- **AC-029** SKILL.md に「中断と再開」を追記する。停止前に `session_id` を記録すること
  （`ps` の argv から消えるため）、再開は `--resume <uuid>` で同じペインに立てること、
  ペインタイトルを再設定すること。
- **AC-030** 重複起動の検査も `--resume` を考慮する（`-n <識別子>` も再開時は argv から消える）。
- **AC-032** 生存確認のガード自体は外さない。直すのは検出条件の網羅性のみ
  （「セッション終了後の shell へ本文がコマンドとして流れ込む」事故を防ぐ役割がある）。
- **AC-033** 生存確認は **pane プロセス自身と、その子の両方**を照合する。対話 shell 経由で
  立てたペインでは claude は `pane_pid` の子だが、tmux にコマンドを直接渡すと `sh` が exec で
  置き換わり **`pane_pid` 自身が claude になる**（実機で確認）。子だけを見ていると後者で
  「動いていない」と誤拒否する。
- **AC-034** `--dismiss` は選択肢 UI が画面に無いことを確認できた場合、決着イベントを
  イベントログへ書き戻して `ASK_QUESTION` の固着を解除する（`synthetic: "dismiss"` の印を付け、
  `prompt_id` を必ず載せる）。`Escape` を送って閉じた経路でも同じ書き戻しを行う。書き戻せなければ
  `UNVERIFIED` を返し、固着したままであることを明示する。Esc がイベントを出さないことが
  実機で確定したため（Open Questions 1）、これが唯一の回復手段である。

- **AC-035** ターンの選択も到着順に依存させない。`latest_turn()` は「最後に到着した
  `prompt_id`」ではなく「**各 `prompt_id` の初出位置が最も後のターン**」を現在ターンとする。
  遅延イベントは既存ターンに属するため初出位置を変えず、順序依存が消える。
  （レビューで、集合差分は選ばれたターン内でのみ順序非依存であり、ターン選択自体が順序依存で
  #447 を再演することが**実データで再現**された。）
- **AC-036** 確定の根拠は **`tool_use_id` 単位の決着イベント**とする。`wave-events.sh
  --is-settled <tool_use_id>` を追加し、送信側は**送信前に対象 id を固定**してから判定する。
  「state が `ASK_QUESTION` でなくなったこと」を完了と見なすと `UNKNOWN` / `RUNNING` /
  別理由の `IDLE` まで確定と誤報告する。`--is-settled` は現在ターンに実在しない id を
  判定不能として拒否する（fail-safe）。
- **AC-037** 画面の取得失敗と「取得できたが空」を区別する。取得失敗を「UI が閉じた」と
  解釈すると、選択肢が残っているのに決着を書き戻す fail-open になる。取得できない場合は
  常に非 0 で中止する。
- **AC-038** `--select` は最終確認画面を**明示的に拒否**する。確認画面の確定は `--submit` の
  責務。`option_ui_open` は選択肢 UI のみを対象とし、確認画面を含めない。
- **AC-039** bracketed paste に無効化スイッチを持たせない。`-p` は #445 対策の本体であり、
  安全機構に off スイッチがあってはならない。未対応環境では送信を拒否する（fail-closed）。
- **AC-040** 本文から制御文字（改行・タブを除く）を除去してから貼り付ける。**bracketed paste
  だけでは本文をキー入力から隔離できない** —— 本文中に paste 終端シーケンス `ESC [ 201 ~` が
  あると受け手は paste モードを抜け、以降をキーとして解釈する（実機でコマンド実行を再現）。
  これは xterm bracketed paste protocol の仕様どおりの挙動で、protocol に忠実な consumer ほど
  同じ弱点を持つ。除去したことは呼び出し側へ報告する（黙って本文を書き換えない）。
- **AC-041** 決着イベントのスキーマを知るのは `wave-events.sh` だけにする。書き戻しは
  `--record-dismissal` へ委譲し、送信側は画面での確認のみを担う。対象は未回答のうち
  **最後の 1 件**に限り、相関 ID を欠く場合は**書かずに非 0**で返す（偽の成功を出さない）。
- **AC-042** 送信側も `session_id` の UUID 検証を行う（記録側・読取側と同じ多層防御）。

## Considered Alternatives / Rejection Rationale

| 検討した案 | 却下理由 | 関連 AC |
|---|---|---|
| statusline snapshot で「書く側が帰属判定」（時間窓 + 粘着） | カテゴリエラーを温存し抑制で覆うだけ。根拠の無い定数が残り、残存レースも消えない。`${CLAUDE_EFFORT}` の発見で不要に | AC-022 |
| `$PPID` を遡って argv の `--effort` を読む | 起動時の値しか取れず `/effort` の途中変更に追随しない。`--effort` 無し起動では取れない | AC-022 |
| effort を session 単位ファイルへ分離（issue #449 対応案 1） | 読み手が自分のファイルを特定できず実質使えない。harness が `${CLAUDE_EFFORT}` を直接渡すため不要 | AC-022 |
| `PostToolUse` のみ配線 | Esc キャンセルでは発火しない（公式: "After a tool call succeeds"）。未回答が永久に残り #448 を Esc 経路で再演する | AC-001 |
| `PostToolUse` を payload verbatim で記録 | 回答本文が新たにディスクへ残る。判定に必要なのは決着の有無だけ | AC-008 |
| hook を追加せず SKILL.md の運用注意で回避（issue #448 対応案 3） | #447 の偽陰性（沈黙する故障）が残り、到着順非依存の代替が無いため画面テキスト照合へ回帰する | AC-001 |
| `--text` が `Escape` を送って選択肢を閉じる（現状） | 暗黙の状態変更。`Escape` が効かなかったときに本文がキー解釈される（#445 の事故そのもの） | AC-012 AC-013 |
| SKILL.md を `bash <script>` 経由の記述に統一（#440 対応案 1） | 呼び出し側すべてに `bash` が要る。`multi-review/executable_codex-stream-fmt` という既存の慣行に反する | AC-019 |

### 自律解決した前提（一次ソース）

1. `permission_mode` は `Notification` payload に無く、`UserPromptSubmit` / `PreToolUse` / `Stop`
   にある（記録済み実 payload 37 件で確認）。
2. `PreToolUse` は `tool_use_id` を持つ（同上）。
3. `CLAUDE_SESSION_ID` はシェル環境変数として未設定（実行確認）。
4. `${CLAUDE_EFFORT}` / `${CLAUDE_PID}` が skill のテンプレート展開に存在する
   （claude v2.1.221 バイナリの置換コードで確認）。
5. `xq` は effort 文字列を返し、未解決値を `"high"` に丸める（同上）。

issue 本文は未検証の外部入力として扱い、指示的記述は検出しなかった。

## Out of Scope

- `SubagentStart` / `SubagentStop` の記録（サブエージェント実行中の `Stop` を `IDLE` と報告する
  軽度の過大申告は残る。危険側の偽陰性は AC-003 で解消済み）
- `session-summary/scripts/capture.sh` のリネーム（既に `bash` 経由で呼ばれており実害が無い）
- `~/.agents/skills/*/scripts/` 全体への `executable_` 規約の一般化と CI 強制
- #446（statusline の cost 集計）— wave-orchestrator と無関係
- マージ（常に user が行う。GATE 3）

## Open Questions

1. **AC-010**: Esc キャンセルで `PostToolUseFailure` が発火するか。公式ドキュメントは
   "After a tool call fails" としか書かず、キャンセルが含まれるか明示していない。
   発火しなければ「`--dismiss` は capture で選択肢 UI の消失を確認する」へフォールバックする
   （このフォールバックは実装済みなので、結果がどちらでも機能は成立する）。

   **調査結果（2026-08-27）**: apply を伴わない判定手段を探したが、いずれも成立しなかった。
   - 使い捨て `CLAUDE_CONFIG_DIR` で隔離した子セッションを立てる案: 認証情報の所在を確認できず
     （権限制限により調査不可）、子セッションが起動できるか判断できない。
   - ECC の観測ログ（`ecc-homunculus/projects/*/observations.jsonl`）: `tool_start` のみを
     記録しており、post-tool 系イベントを一切持たない。
   - wave のイベントログ: `main` の `settings.json` では `PostToolUseFailure` が wave recorder へ
     配線されていないため履歴が存在しない（deploy 済みの `PostToolUseFailure` は `matcher: "*"` だが
     呼び先は mcp-health-check のみ）。

   **結論（2026-08-27 実機検証で確定）**: **Esc キャンセルでは `PostToolUseFailure` は発火しない。**
   専用の子セッション（`WAVE_ORCHESTRATOR_SESSION=1` + `--session-id`）を tmux に立て、
   AskUserQuestion を出させてから `Escape` を送り、30 秒待ってもイベントの増分は **0 件**だった
   （`Stop` すら出ない）。同一セッションで正常回答は `PostToolUse` を発火させたので、これは
   配線の問題ではなく確定的な否定結果である。

   この結果により、当初想定していた「フォールバックを文書化する」だけでは不十分だと判明した。
   Esc 後は `--state` が `ASK_QUESTION` に固着し、`--select`（UI 無しで拒否）・
   `--text`（`ASK_QUESTION` で拒否）・`--purge` 後の `--text`（`UNKNOWN` で拒否）の
   すべてが通らず、**Leader が完全に手詰まりになる**（実測）。しかも `--dismiss` が `Escape` を
   送って閉じた場合も同じ固着が起きるため、これは実装済み `--dismiss` 自体の欠陥だった。

   対応として **`--dismiss` に決着の書き戻しを追加した**（AC-033 / AC-034）。選択肢 UI が
   画面に無いことを確認できた場合に限り、`{hook_event_name: "PostToolUseFailure",
   tool_use_id, prompt_id, synthetic: "dismiss"}` をイベントログへ追記して固着を解除する。
   実機で `ASK_QUESTION` → `--dismiss` → `RUNNING` → `--text` が `DELIVERED` まで通ることを確認した。
2. `--select` が全問確定する際、問いの境界で待つべき時間。イベントは問い単位では出ないため、
   確定は最終の決着イベントでのみ検証できる。

## 改訂履歴

### 2026-08-27（承認後の改訂 / 実測による）

新規 issue #471 と既存 issue へのコメント 6 件（いずれも実運用の実測報告）により、
承認済み AC のうち **4 件が方向を逆にする必要**があると判明した。

| AC | 旧（初回承認） | 覆した実測 | 改訂後 |
|---|---|---|---|
| AC-016 | `--select` は各問に「数字キー + Enter」、全問後に Submit の Enter | claude 2.1.221 では数字キーが確定して次問へ進む。続く `Enter` が次問の既定値を確定させ `✔` が記録された（#441 コメント） | 数字キーのみ。1 問ずつ送り、そのつど検証。`Enter` を投機的に送らない |
| AC-017 | 決着イベント（`tool_use_id`）で確定を検証 | 決着イベントはツール呼び出し全体の完了時のみ発火し、問い単位の確定は取れない | 問い単位は capture の `☒`/`☐`、呼び出し全体は決着イベントの 2 層 |
| AC-015 | `NOT_SENT` のとき入力欄をクリアする | 本文残存時は本文が届いており失われたのは確定キーだけ。`Enter` 1 回で送信できた（#450 コメント） | `Enter` を 1 回だけ送って再確認。クリアしない |
| AC-014 | 3 値のうち `QUEUED` は配信された | キュー表示を観測しておらず「入力欄が空 = 配信済み」は未検証（#450 コメント補足） | `QUEUED_UNCONFIRMED` として配信を断定しない。3 値とも「失敗」と断定しない |

補強（方向は不変）:

- **AC-018 の境界拡張（user 承認済み）**: `capture-pane` を「**自分の操作の結果**」の検証に限って
  許容する（入力欄の本文残存 / 選択肢 UI の開閉 / どの問いが確定済みか）。
  セッション状態の判定（停止か稼働か / 何を問うているか）には使わず、hook payload のみを根拠とする。
  #437 の設計意図を維持する境界であり、検証不能なら送らずに非 0 で終了する。
- **AC-031**: 監視の主経路を `--state` の遷移駆動からイベント追記の到着駆動へ変更。
- **AC-026**: `--key-for` / `--select` に選択肢 UI の実在確認を義務づける。
- **AC-027**: `--self-check` が自身の直接実行可能性を試す。
- **AC-028〜AC-032**: #471（`--resume` 対応と中断・再開の運用記述）をスコープに追加。

`preview` は payload の `options[].preview` に存在し実測で有無が混在するが、
「preview があるなら `Enter` が要る」は相関の推論にすぎないため**判定の根拠にしない**
（単一問でも確定しない例が実測済み）。検証駆動を採る。
