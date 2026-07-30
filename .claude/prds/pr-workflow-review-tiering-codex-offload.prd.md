---
slug: pr-workflow-review-tiering-codex-offload
feature: pr-workflow / multi-review のレビュー tier ルーティング + Codex コスト分散・観測性・resume
created_at: 2026-07-30T13:56:30+09:00
grill_session: 50224f1b-9d21-40cc-9255-55eead272ab9
status: draft
---

# Background

`pr-workflow` は size tier（trivial/small/standard/large）を判定して PR まで orchestrate する司令塔で、レビューは `multi-review` に委譲する。現状 2 つの課題がある。

1. **レビューエージェントの過剰起動**: `multi-review` の spawn ロジックは tier をほぼ見ない。常設 3 ツール（cc-code-review / cc-security-review / codex）は tier 問わず常に起動し、言語 specialist（typescript/react/python/database）と横断 specialist（test/ux/performance）はファイル拡張子・変更特性のマッチで起動する（tier 無関係）。tier を見るのは `architecture-reviewer`（`--arch`/large のみ）だけ。結果、`.tsx` + テスト + CSS を含む小さな PR でも cc-code + cc-security + codex + typescript + react + ux + test = **7 エージェント**が起動しうる。大規模タスクでは妥当だが、小タスクでは過剰。

2. **Claude 偏重のコスト構造**: 常設のうち Codex は 1 本のみ。cc-code-review / cc-security-review / 全 specialist / adversarial-verifier はすべて Claude（sonnet〜xhigh）。Claude 予算に負荷が集中している。GPT/Codex の得意領域を明確化し Codex にコストを分散したい。

加えて、Codex がレビュー負荷の大半を担う設計に移すと、Codex 側に 2 つの運用課題が顕在化する。

3. **Codex 実行ログがリアルタイムに見えない**: Claude subagent は Claude Code CLI 上にライブでログが流れるが、Codex は `-o RESULT_FILE` + `>/tmp/codex-run.log` へ退避する設計で、実行中の様子を追いにくい。

4. **再レビューが cold-start**: 修正後の再レビューで、reviewer が前ラウンドの文脈（自分の指摘・棄却判断）を引き継げない。`multi-review` は誤指摘の再提起を「棄却台帳」の注入で抑えているが、これは session 継続があれば構造的に不要になる。

**能力面の前提確認（grill で確定）**: Codex は `--cd <dir> --sandbox read-only` + rubric を heredoc 注入すれば、Claude specialist subagent と**機能的に等価**に振る舞える（agent 定義の本文は移植可能な prompt テキストで、Claude 固有機構ではない）。よって「Claude でなければできない仕事」はほぼ存在せず、モデル配分の判断軸は capability ではなく **モデル多様性・並列現実性・コスト**である。

# User Story

開発者として、pr-workflow でタスクを PR 化する際に、

- **小さなタスクでは最小限のレビューエージェントだけが起動**し、大規模タスクでは現状の網羅的レビューが維持されてほしい（tier に応じた深さ）。
- **レビュー負荷の大半が Codex(GPT) に分散**され、Claude は「深い推論・専門・反証」に集中してほしい。ただし**バグ見落としを増やさない**（モデル多様性を失わない）。
- Codex レビューの**進捗をリアルタイムに覗け**、修正後の**再レビューは reviewer の文脈を引き継いだ resume** で回ってほしい。

# Acceptance Criteria

## tier-aware roster（Part 1: 起動制御）

- **AC-001**: `multi-review` は tier を認識する。`--tier=trivial|small|standard|large` フラグで受け取り、tier ごとに「許可するレビュー層」を決める（tier が spawn 数の主レバー）。
- **AC-002**: `--tier` 未指定の standalone 起動時は、diff（変更行数・ファイル数・変更特性）から tier を自動推定する。境界では **fail-safe に上位 tier へ切り上げる**。推定基準は `pr-workflow` 既存の tier 判定軸を SSOT として流用し、新しい閾値を発明しない。
- **AC-003**: tier → roster の対応は以下とする。

  | tier | Claude | Codex |
  |---|---|---|
  | trivial | —（なし） | generalist |
  | small | generalist (cc-code) | generalist |
  | standard | security | generalist + specialists |
  | large | security + architecture + adversarial | generalist + specialists |

- **AC-004**: trivial も `multi-review` を skip せず、Codex generalist 1 本は走らせる（誤分類時の最小安全網）。
- **AC-005**: マッチ 0 件（非対象言語のみの変更）では specialist を spawn しない現行挙動を維持する。specialist の検出方法（拡張子/特性マッチ）は現状のまま、実行先だけ変わる（下記 AC-011）。

## モデル配分（Part 1: コスト分散）

- **AC-006**: 多様性フロアを守る。**non-trivial な review（small/standard/large）では常に Claude≥1 + Codex≥1** を保証する。trivial のみ単一モデル（Codex）を許容する。
- **AC-007**: generalist（汎用レビュー）は Codex 単独とする（規模に対しコストが爆発する層を offload）。例外は small で、diff が小さくコストが低いため Claude generalist (cc-code) を安価なフロア anchor として併走させる。standard 以上では security が anchor 役を担い、generalist は完全に Codex へ移す。
- **AC-008**: security は Claude が担う（高ステークス・深い推論、standard 以上のフロア anchor）。architecture は Claude が担う（whole-repo の深い推論、large のみ）。
- **AC-009**: 言語/横断 specialist は全て Codex で実行する（増殖層を offload）。
- **AC-010**: adversarial verify（large）は cross-model とする。**generator と逆のモデル族**が反証する（Codex 由来の MUST は Claude が、Claude-security 由来の MUST は Codex が反証）。**各 MUST × 2 並列**、**2 本とも一次ソースで反証したときのみ棄却**、総 spawn 上限は **8**（旧 12 から引き下げ）。反証が不確実なら finding を残す（recall 優先）現行方針は維持。

## rubric SSOT / Codex 実行（Part 1 実装基盤）

- **AC-011**: specialist の rubric（観点定義）の SSOT は **agent `.md` 本文**とする。Codex 経路は当該 `.md` を Read し frontmatter を剥がして heredoc に注入する。rubric を複製しない（drift ゼロ）。Claude specialist subagent 定義は latent に保持する（将来 Claude で走らせる逃げ道 = 多様性フロアの保険）。
- **AC-012**: agent `.md` 本文の Claude 固有文言（「CLAUDE.md が自動ロードされる」・Read/Glob/Grep 前提等）を harness 中立に整える（Codex 注入時に破綻しない）。
- **AC-013**: Codex effort は leg 別にキャリブレーションする。standard/large generalist と adversarial は `xhigh`、specialist と small/trivial generalist は `high`、agent profile（実装/CI 修正）は現行 `xhigh` 維持。
- **AC-014**: `home/.chezmoitemplates/codex-model-pin.toml` は **変更しない**。デフォルト `xhigh` を fail-safe として据え置き、leg 別の引き下げ（`high`）は `multi-review` の `-c model_reasoning_effort=` 上書きが持つ。model は `gpt-5.6-terra` 単一のまま（model 段の差別化はしない）。
- **AC-015**: Codex の同時実行数に上限を設け、超過分はバッチで順次消化する（全 specialist を消化しつつ、未検証の shared account 並列競合を構造回避）。上限で待機中の leg は観測ビュー上 `queued` と分かる。

## Codex 観測性（Part 2）

- **AC-016**: 各 Codex leg は `codex exec --json` でイベントを per-leg の `STREAM_<leg>.jsonl` へストリームし、`-o RESULT_<leg>.txt` に最終結果を書く。**親 Claude は RESULT のみ読み、JSONL は読まない**（親コンテキストを汚さない）。
- **AC-017**: ライブ観測ビューは **tmux best-effort、コア（JSONL + `-o` + session-id 捕捉）は tmux 非依存**とする。`$TMUX` で挙動を出し分ける。
  - `$TMUX` セット（親が tmux 内）: 同セッションに専用ウィンドウ `codex-review-<PR>` を自動作成し、`Ctrl-b w` 等での切替を案内する。
  - `$TMUX` 未セット + tmux 在: detached セッションを作り、**親エージェントが「別ターミナルで `tmux attach -t codex-review-<PR>`」を提示**する（現端末では attach 不可＝Claude TUI と衝突する旨も添える）。
  - tmux 非在: JSONL ファイルのみ残し、`tail -f <STREAM_leg>.jsonl` のパスを提示する。
  - **セッション lifecycle は multi-review（作成者）が所有し自己完結する**: create は `tmux kill-session ... 2>/dev/null` → `new-session`（idempotent。accumulation を (owner,repo,PR) ごと最大 1 に bound）、round 終了（Phase 5 投稿後）に自分のセッションを teardown する（**client が attach 中なら残置**して観測画面を消さない）。caller（pr-workflow）の teardown に依存しないため **standalone 多用でも溜まらない**。観測（tmux）と resume（`sessions.json`）は独立で、teardown しても resume は壊れない（round 2 は fresh に作り直す）。
- **AC-018**: JSONL を簡潔な 1 行に整形するヘルパー `codex-stream-fmt`（curated script）を用意し、生 JSONL をそのまま見せない（**ただし jq 不在時は簡潔整形を諦め、leg タグ付きで生 JSONL への degrade を許容する** = 可用性優先のフォールバック。整形が主機能で、フォールバックは jq 非在という限定条件でのみ発生）。セッション名は `#` を避け `codex-review-<owner>__<repo>__<PR>`（例 `codex-review-kryota-dev__dotfiles__412`）とする。

## Codex resume 再レビュー（Part 3）

- **AC-019**: round 1（初回レビュー）で各 Codex leg の session id を `--json` イベントから捕捉し、`<scratch>/codex-review/<owner>__<repo>__<PR>/sessions.json`（非コミット。区切りは `__` で cross-repo のハイフン曖昧衝突を回避）に `{leg → session_id}` を記録する。所有者は `multi-review`。
- **AC-020**: round 2+（修正後の再レビュー）は、open な指摘を持つ Codex leg を `codex exec resume <session_id> <prompt>` で継続する。resume により棄却台帳の注入は Codex leg で不要になる（session 継続が再提起を構造的に防ぐ）。
- **AC-021**: resume プロンプトに「修正で新たに混入した問題も差分を走査せよ」を明示する（anchoring 緩和）。session id 欠落・期限切れ・resume 失敗時は fresh レビューにフォールバックする。
- **AC-022**: 再レビュー対象は「前ラウンドで open 指摘を持つ leg」を resume。clean だった leg は原則スキップし、修正 diff がその leg のドメイン（拡張子/特性）に触れた場合のみ fresh で追加 spawn する。Claude 側は resume を追加せず現状維持（round ごと fresh spawn + 棄却台帳）。

## 回帰防止

- **AC-023**: `--tier` 未指定・`--arch` 未指定の standalone `multi-review` は、AC-002 の自動推定を除き従来と互換に動く（既存呼び出し元を壊さない）。
- **AC-024**: Claude leg の model/effort 契約（§4 contract / agent `.md` frontmatter）は据え置き、Codex leg（codex-model-pin + `-c` 上書き）とは独立で競合しない。

# Considered Alternatives / Rejection Rationale

- **[起動制御レバー] 総数ハードキャップ N のみ** → 却下。「大規模は現状が妥当・小規模が過剰」という問題認識に対しては tier 駆動が最も素直。ハードキャップだけでは「どれを落とすか」の優先度定義が別途要り、small でも常設 3 が必ず埋まる問題が残る。tier 駆動を主レバーに採用（AC-001）。
- **[standalone tier] 未指定は standard 固定 / フル roster 維持** → 却下。standalone で小さな PR を見るとき過剰が残る。diff 自動推定（fail-safe 切り上げ）を採用（AC-002）。
- **[軽量 tier roster] trivial=code1 / small=code+security（Claude 主体のまま specialist だけ外す）** → 却下。Codex へのコスト分散が進まない。trivial=codex1 / small=code+codex を採用（AC-003）。security を軽量 tier から外す安全性は `pr-workflow` の mid-flight tier escalation（security surface 検知で standard 昇格）が担保する。
- **[specialist を Claude 維持] curated Claude specialist のペルソナ資産を失う懸念** → 却下（grill 中に撤回）。agent `.md` はほぼ全て移植可能な rubric テキストで Claude 固有機構ではないと一次ソース（typescript-reviewer.md 全文）で確認。specialist は Codex 実行に移し、rubric SSOT は agent `.md` に残す（AC-009 / AC-011）。
- **[モデル配分] コスト最優先で単一モデル許容（small/standard を Codex 単独）** → 却下。レビューは見落としたら無意味な工程で、多様性フロアを崩すと offload の代償が読みにくい。多様性フロア維持を採用（AC-006）。
- **[generalist 配分] 両族併走（standard で Claude generalist も残す）** → 却下。generalist は広く高コストで、規模が大きいほどコストが爆発する。standard 以上は generalist を Codex 単独にし、Claude フロアは security が担う（AC-007）。small だけはコストが小さいため Claude generalist を anchor に残す。
- **[adversarial] ×3・上限 12 のまま維持** → 却下。旧 ×3 は generator と反証が同族（Claude）ゆえの自己強化バイアスを回数で補うものだった。cross-model 化で独立性が構造的に上がるため ×2・上限 8 へ引き下げ、2 票ガードで誤棄却を抑える（AC-010）。コスト削減と厳密性維持を両立。
- **[Codex effort] 全 leg フラット xhigh を維持** → 却下。Codex 負荷増で xhigh 一律は Codex 側コストが膨らむ。leg 別キャリブレーション（specialist=high 等）を採用（AC-013）。ただし generalist は「最後の広い網」ゆえ xhigh 維持（high に落とすと primary 検出が痩せる）。
- **[Codex model 段] specialist を安い GPT モデルに、generalist/adversarial を terra に分ける** → 却下（KISS）。effort 段で calibration は十分効いており、第二モデル導入の保守コストが利得を上回りやすい。model は terra 単一（AC-014）。
- **[Codex 並列] 上限なしで全同時 spawn** → 却下。shared account の並列競合が未検証。上限 + バッチ順次で構造回避（AC-015）。
- **[観測性] 親が BashOutput をポーリングしてナレーション** → 却下。親コンテキストを消費し offload の趣旨に逆行。`--json` + tmux best-effort（親は RESULT のみ読む）を採用（AC-016/AC-017）。
- **[観測性 tmux] 常時 tmux 前提** → 却下。親を tmux 外で起動する運用が多い。コアを tmux 非依存にし、`$TMUX` 判定で degrade。tmux 外では attach コマンドを提示（AC-017）。
- **[resume] 既定 fresh・resume は明示時のみ** → 却下。再提起問題（棄却台帳）が残り効率も落ちる。既定 resume + 新規混入走査 + 失敗時 fresh フォールバックを採用（AC-020/AC-021）。
- **[trivial] multi-review 丸ごと skip** → 却下。誤分類時にレビュー無しで通る。Codex 1 本を最小安全網として残す（AC-004）。

# Out of Scope

- Claude subagent 側への resume 導入（Claude は harness の継続機構で足りるとの判断。今回は Codex 専用の非対称対応）。
- `codex-model-pin.toml` 本体の変更（据え置きが結論。差別化は呼び出し側の `-c` 上書きに閉じる）。
- 第二 GPT モデルの導入（model 段の差別化）。
- Codex resume 失敗時の自動再開・cross-account resume（同一 Claude セッション/アカウント内の resume のみ対象）。
- macOS で新規ターミナルを自動起動して attach する挙動（端末エミュレータ依存で脆いためコマンド提示に留める。将来の任意拡張）。
- pr-workflow のレビュー round をいつ・何回回すかの再設計（本 PRD は「再レビューが起きたら resume を使う」まで。多段レビューのトリガ設計は別途）。

# Open Questions

## 検証済み（2026-07-30, codex-cli 0.145.0 で smoke test 実施）

- **OQ-001 → 解決**: `codex exec resume <thread_id> <prompt>` をラッパー経由（グローバル位置に `--profile shared` 注入）で実行し **exit=0・エラー無し**。round1 で記憶させたトークンを resume 後に正しく回答＝**session 文脈を継承**。同一 `thread_id` が継続。→ **ラッパー改修は不要**。resume は `--json` / `-o` も併用可。
- **OQ-002 → 解決**: session/thread id は `--json` ストリーム最初のイベント **`{"type":"thread.started","thread_id":"<UUID>"}`** の `thread_id` に載る。これを resume の SESSION_ID に使う（UUID）。実装では round1 の JSONL 先頭を grep して捕捉する。
- **OQ-003 → 解決（範囲限定）**: read-only の `codex exec` を **3 本同時起動**して全 exit=0・約 10 秒で完了、独立 `thread_id`、**レート制限/429/競合エラー無し**。→ **同時 3 本は実証上安全**（AC-015 の上限の床として妥当）。ただし検証は極小プロンプト×3 本のみ。重いレビュー leg での高並列（5〜7 本）や持続負荷は未検証のため、上限は保守的に設定し実測で調整する。

## 副次的な検証所見

- Codex は `~/AGENTS.md` を自動ロードする（`~/AGENTS.mdを読み込みました` を観測）。**rubric 注入 + project 文脈が Codex でも効く裏付け**（AC-011 の前提を支持）。
- Codex は skill descriptions を context へ読み込む情報イベント（"Skill descriptions were shortened to fit the 2% skills context budget"）を出す。失敗ではないが **Codex 側 input トークンを消費**する（round1 で input ~19.6k tokens）。Codex 負荷増でこの固定オーバーヘッドが効くため、**未使用 skill/plugin の整理**が Codex コスト最適化の任意の後続論点になりうる。

## 未解決

- **OQ-004**: `codex-stream-fmt` と tmux review-window ヘルパーの配置場所（curated script の置き場と provenance 分類）。
- **OQ-005**: session-id 状態ファイルの TTL / クリーンアップ契機（PR マージ後・worktree cleanup 連動）。
