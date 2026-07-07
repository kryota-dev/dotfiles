---
name: pr-workflow
description: |
  タスクから PR マージ手前までの開発ワークフロー全体を orchestrate する skill。
  size tier（trivial/small/standard/large）と operation variant を判定し、tier 別 path で
  ワークツリー作成 → 実装 → CI → review → 指摘対応 を進め、orchestration GATE で進行を整理する。
  トリガー: "pr-workflow", "tier 判定して PR まで orchestrate", "ワークフロー skill で進めて"
  使用場面: 規模の異なるタスクを、tier に応じた最適な深さ（inline〜grill-me+sdd）で PR 化したいとき。
argument-hint: "<task description> [--size=trivial|small|standard|large] [--operation=add-feature|change-feature|fix-defect|refactor|mvp] [--strict]"
user-invocable: true
---

# pr-workflow

タスクの **size tier** と **operation variant** を判定し、tier に応じた path で「ワークツリー作成 → 実装 → CI → review → 指摘対応」を orchestrate する。各既存 skill を束ねる**司令塔**であり、自分は薄く保ち、重い処理は委譲する。

**ワークツリー作業は必須**: pr-workflow は **全 tier で `/wtp` を用いてワークツリーを作成し（Phase 0.5）、以降の全 Phase をそのワークツリー内で実行する**。main worktree を直接汚さない。

**委譲先 skill への呼び出しプロンプト**: `/multi-review` と `/review-resolve-loop` は pr-workflow から呼ぶ際に**オーバーライド指示を委譲プロンプトに含める**（下記 Phase 6・7 参照）。これらの指示は pr-workflow が orchestrator として付加するものであり、skill を standalone で使う場合の挙動には影響しない。

**model-tier（task #28）**: 分類・設計・統合判断は **Opus（Leader）**。機械的実装は **Sonnet 委任**（small tier の general-purpose 起動）、cross-model diversity は **codex**（multi-review）。

**マージは user**: 設計決定（task #21 原案の「merge 自動実行」を上書き）として、本 skill は**絶対に自動マージしない**。GATE 3 は merge-ready の handoff であり、merge は user の明示操作。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<task description>` | - | 実装したいタスク（自由記述。GitHub Issue URL / `#番号` 可） |
| `--size` | 自動判定 | `trivial`/`small`/`standard`/`large`。下記基準の override |
| `--operation` | 自動判定 | `add-feature`/`change-feature`/`fix-defect`/`refactor`/`mvp` |
| `--strict` | off | GATE 2 を auto-proceed から承認待ちに戻す escape hatch（GATE 1・3 は常に user 承認） |

## Phase 0: Classify（分類）

**size tier の判定軸**（text だけで決めず、次を評価。`--size` で override）:

| tier | 目安 |
|------|------|
| `trivial` | 1〜数行、単一ファイル、振る舞い不変、ロールバック容易 |
| `small` | 数ファイル、所有境界内、DB/API/UI 契約変更なし |
| `standard` | 複数ファイル横断 or 新機能、テスト追加要、設計判断あり |
| `large` | 仕様確定が必要 / 外部契約・migration・高ロールバック難度 / 影響広範 |

**round-up default（fail-safe 分類）**: どの tier か迷う・境界上のときは、**必ず上位 tier に切り上げる**。誤分類は over-tiering（コスト増）側に倒し、危険な変更が light path を通過する miss を防ぐ。特に外部契約・migration・security surface（認証/認可/機密情報/外部通信）に触れる可能性があれば `standard` 以上とみなす。

**operation variant**（path の重点を変える。`--operation` で override）:

- `add-feature`: 新規追加。AC 網羅。
- `change-feature`: 既存変更。後方互換を確認。
- `fix-defect`: **再現テスト先行**（RED→GREEN）。
- `refactor`: **public behavior freeze**（外部挙動を変えない検証を重視）。
- `mvp`: **scope gate**（最小で動く範囲に絞り、過剰実装を抑止）。

**mid-flight tier escalation（実装中の再分類）**: 分類は入口の 1 回で固定しない。`trivial`/`small` path の実装中に、**contract（外部 API/DB/UI 契約）・migration・security surface（認証/認可/機密情報/外部通信）への変更**が判明したら、その場で tier を **`standard` 以上へ引き上げ**、対応する重い path（`/sdd` + Phase 6 review 強化）へ切り替える。軽い path のまま危険な変更を通過させない（fail-safe）。escalation したら Phase 6 の `/multi-review` を必ず通す。

## Phase 0.5: Worktree setup（enforced）

Phase 0 の分類直後、**tier に関わらず必ず `/wtp` でワークツリーを作成し、以降の全 Phase（実装・commit・PR・CI 監視・review・指摘対応）をそのワークツリー内で実行する**。pr-workflow は main worktree を直接変更しない。

1. **ブランチ名の導出**: operation variant + task から命名する（`add-feature`/`change-feature`→`feat/...`、`fix-defect`→`fix/...`、`refactor`→`refactor/...`、`mvp`→`feat/...`）。GitHub Issue 起点なら `#番号` を含めてよい。
2. **ワークツリー作成**: 新規ブランチは `wtp add -b <branch> main`（既定 base=`main`）、既存ブランチは `wtp add <branch>`。作成後の絶対パスを起点に以降を実行する（`--quiet` で path を捕捉可）。
3. **既存衝突時**: `wtp list` で既存ワークツリー/ブランチを確認。同名があれば再利用するか別名を選ぶ（`failed to create worktree: exit status 128` は path 既存が主因）。
4. **後片付け**: マージは user（GATE 3）。マージ後のワークツリー削除は `/wtp-cleanup`（merged worktree の一括整理）に委ねる。pr-workflow は自動削除しない。

**`/sdd`（standard/large）連携のオーバーライド**: `/sdd` は内部にワークツリー戦略選択を持つが、pr-workflow から呼ぶ際は委譲プロンプトに次を**明記してオーバーライド**する:

> **ワークツリーは pr-workflow が Phase 0.5 で作成済み。この現在のワークツリー内で作業し、新規ワークツリーを作成しないこと（ワークツリー戦略選択のゲートはスキップする）。**

これにより二重作成を防ぐ。→ 承認点インベントリ #2（worktree 戦略選択）は pr-workflow path では発生しない。

## Phase 1-4: tier 別 path

| tier | path |
|------|------|
| `trivial` | inline Edit。**ただし spec/planning の skip は「既に承認済みの計画があるとき」のみ**（global 指示「実装前は `$planning`」を上書きしない。曖昧なら `/planning` を通す）。→ `/commit` → `/create-pr` |
| `small` | **general-purpose サブエージェント（`model: sonnet`）**に inline prompt で委任（named worker は使わない）。prompt に **TDD の RED→GREEN 規律**（テスト先行・最小実装。inline protocol、外部 skill ではない）を含める。→ `/commit` → `/create-pr` |
| `standard` | **軽量 intent gate**（`/sdd` 起動前に intent + scope + 主要 AC を `AskUserQuestion` で 1 回確認。承認 1 回で自律性を最大限維持）→ `/sdd`（完全自律実行）。**`/sdd` は内部で自前に commit + PR 作成まで行う**ため、この path では `/commit`/`/create-pr` を別途呼ばない（二重実行回避）。 |
| `large` | **intent gate（enforced）**: `/sdd` の前に `/grill-me --mode=auto`（自律審議＋最終 PRD を user が 1 回承認）を pr-workflow から auto-invoke する（`--mode=auto` が「対話型だから auto-invoke しない」を解消。auto でも security/data-migration/contract は grill-me が強制 user エスカレート）→ `/sdd`（完全自律実行）。 |

**intent gate（#222・構造化）**: `standard`/`large` は **human intent check なしに実装フェーズ（`/sdd` Phase 4）へ入れない**。large=`/grill-me --mode=auto` の PRD 承認、standard=軽量 intent gate がそれに当たる。**gate を skip する場合は必ず理由を記録**する（decision log / spec / PR の 1 行）。**PRD 生成は non-trivial（standard/large）の default handoff**とする（生成は default、file 永続化は grill-me の memory ポリシーに従い user 承認必須）。

**Plan-PRD pipeline（task #22 / PR10b）連携**: PR10b マージ後は `/grill-me --output-prd` → `/planning --output-plan` → `/sdd --prd --plan` の file handoff を使える。**PR10b 未マージ時はこれらの flag は存在しない**ため、PRD/Plan は手動で渡す。

## GATE 1: Ready for review

Phase 1-4（実装・commit・PR 作成）完了後、**`AskUserQuestion` で「ready for review に移行するか」をユーザーに確認する**。

- trivial/small: `/create-pr` 完了後に確認
- standard/large: `/sdd` 完了（PR 作成済）を検知して pr-workflow 再開後に確認

確認文例:
```
PR #<番号> を ready for review に移行しますか？
移行後も Draft に戻すことは可能です（gh pr convert-to-draft）。
```

- **承認した場合**: `gh pr ready <番号>` を実行 → Phase 5（CI 監視）へ
- **スキップした場合**: Draft のまま Phase 5（CI 監視）へ

> **分類**: 外向き操作（レビュアーへの通知を伴う）のためユーザー確認を行う。ただし **不可逆ではない**（`gh pr convert-to-draft` でいつでも Draft に戻せる）。

## Phase 5: CI 監視

GATE 1 通過後、**`/monitor-ci` をプライマリ CI 監視ステップとして呼び出す**。

CI 監視を `/review-resolve-loop` に内包させず、**独立したステップとして先行実行する**。CI が落ちている状態でのレビューは無駄になる可能性が高いため、レビュー（Phase 6）の前に CI green を確保する。

**CI fail 時のフロー**（retry budget は pr-workflow 側で管理。最大 3 回）:

1. 失敗 job のログを取得（`gh run view {run_id} --log-failed`）
2. 原因分析 → コード修正 → commit → push
3. 再度 `/monitor-ci` で full pass を確認
4. 3 回 fail → user へエスカレート

CI green → Phase 6 へ。

## Phase 6: AI レビュー（multi-review）

CI green 確認後、`/multi-review` を起動する。

- trivial/small: Phase 1-4 で `/create-pr` 済の PR に対して起動
- standard/large: `/sdd` が作成済の PR に対して起動
- **large tier**: `/multi-review --arch`（diff-scope の盲点検出に `architecture-reviewer` を追加）
- **二重 review の扱い（決定: 併用＝役割分離）**: standard/large では `/sdd` 内蔵 review（=開発中の自己 review）と本 `/multi-review`（=最終 PR への独立 second opinion）を**役割分離で併用**する（置換・skip しない）。

### pr-workflow からの呼び出し時オーバーライド指示

`/multi-review` を pr-workflow から呼ぶ際は、以下を**委譲プロンプトに明記**してオーバーライドする:

> **投稿方法は「サマリーを body に含めて投稿」を自動選択すること。Phase 5 の投稿方法確認（`AskUserQuestion` の 3 択）はスキップし、body サマリー（統合レビュー結果）＋ インラインコメント（MUST/SHOULD/NITS）を `event: "COMMENT"` で即時 submit する。**

これにより `/multi-review` のレビュー結果（body サマリー + インラインコメント）が GitHub PR に投稿された状態で Phase 7 へ進む。

### adversarial 強化（large tier）

`/multi-review` 完了後、**adversarial verify protocol**（独立 reviewer 視点で MUST を反証し、過半が反証→棄却）を inline で 1 ラウンド追加する（外部 skill ではなく手順）。

- **recall sink 化を防ぐ（#224）**: 棄却は **一次ソースで根拠づけられた反証が過半** のときのみ。反証自体が不確実（裏取りできない）なら finding を **棄却せず残し user に届ける**（coverage 優先）。
- **棄却ログ（可監査化）**: 棄却した MUST は、**要約 + 棄却理由（一次ソース根拠）** を統合サマリー/PR の「棄却した指摘」節に必ず記録する。黙って落とさない。

GATE 2（auto-proceed。`--strict` 時のみ user 承認待ち）を経て Phase 7 へ。

## Phase 7: 指摘対応（review-resolve-loop）

`/multi-review` の PR 投稿完了（GATE 2）後、**`/review-resolve-loop` を起動する**。

`/multi-review` が投稿したレビュー（body サマリー + インラインコメント）は `isSelf == true`（自分名義の review）として取り込まれる。これを人間レビュアーからの指摘と合わせて `/review-resolve-loop` が一括処理する。

### pr-workflow からの呼び出し時オーバーライド指示

`/review-resolve-loop` を pr-workflow から呼ぶ際は、以下を**委譲プロンプトに明記**してオーバーライドする:

> **Phase 2-4 の対応方針確認ゲート（`AskUserQuestion`）は、真の人間レビュアー（`isBot == false` かつ `isSelf == false`）が 1 件以上存在するラウンドのみ実行すること。ボット・セルフレビュー（`isSelf == true` の `/multi-review` 投稿分を含む）のみのラウンドは、承認なしで Phase 3 へ直行し自律的にループを継続する。**

これにより `/multi-review` の指摘（セルフ）と人間レビューの指摘を一括処理しつつ、真の人間レビュアーがいる場合のみゲートを通す。

Phase 7 完了後、GATE 3（merge-ready handoff）へ。

## GATE（orchestration の節目）

| Gate | タイミング | 役割 | default |
|------|-----------|------|---------|
| GATE 1 | Phase 1-4 完了後（PR 作成直後） | **外向き操作の確認**（ready for review 移行） | **user 承認待ち**（外向き操作。不可逆ではない） |
| GATE 2 | Phase 6 `/multi-review` 完了後 | 進行チェックポイント | **auto-proceed**（`--strict` 時のみ user 承認待ち） |
| GATE 3 | Phase 7 `/review-resolve-loop` 完了後 | **merge-ready handoff** | **user 承認待ち**（merge は常に user） |

## 承認点インベントリと集約方針

pr-workflow は GATE を追加する一方で委譲先の確認を必要最小限に抑え、**意味ある決定点のみ** にユーザー承認を集約する。

### 承認点インベントリ（standard / large path）

| # | 承認点 | 発生元 | 役割 | 扱い |
|---|--------|--------|------|------|
| 1 | intent / 設計承認（large=`/grill-me --mode=auto` の PRD 承認 / standard=軽量 intent gate） | pr-workflow Phase 1-4（#222） | **不可逆前の意味ある決定** | **残す** |
| 2 | worktree 戦略の選択 | `/sdd` Phase 0-4 | 進行チェックポイント（setup） | **発生しない**（Phase 0.5 で `/wtp` により作成済み。`/sdd` へはオーバーライドで新規作成を抑止） |
| 3 | GATE 1（ready for review?） | pr-workflow GATE | **外向き操作の確認** | **常に user 承認**（外向きだが不可逆ではない） |
| 4 | GATE 2（multi-review 完了後） | pr-workflow GATE | 進行チェックポイント | **auto-proceed**（`--strict` 時のみ承認待ち） |
| 5 | 人間レビュアーへの返信内容承認 | `/review-resolve-loop` Phase 4-1b | **不可逆・外向きの最終確認** | **残す** |
| 6 | GATE 3（Phase 7 完了後 = merge-ready handoff） | pr-workflow GATE | **不可逆操作の最終確認** | **残す**（merge は常に user） |

> `/multi-review` の投稿方法 3 択は、pr-workflow からの委譲プロンプトでオーバーライドするため承認点として発生しない。`/review-resolve-loop` の対応方針一括承認は、真の人間レビュアーがいるラウンドのみ発生する（Phase 7 オーバーライド指示）。`standard`/`large` では commit + PR 作成を `/sdd` が自律実行するため、それらの確認はこの path では発生しない。

### GATE と委譲先確認の役割分担

| 種別 | 定義 | 例 | 既定の扱い |
|------|------|----|-----------|
| **外向き操作の確認** | 外部への通知・公開を伴う操作の直前 | GATE 1（ready for review） | user 承認を経る（不可逆ではないが外向き） |
| **進行チェックポイント** | 進行の節目。危険がなければ自動で進む | GATE 2 | auto-proceed |
| **不可逆操作の最終確認** | 取り消せない / 外向き高影響操作の直前 | intent/設計承認, 人間返信, GATE 3 | user 承認を必ず経る |

## Failure mode / recovery（主要）

| 局面 | 対処 |
|------|------|
| Phase 0.5 ワークツリー作成失敗 | `wtp list` で既存衝突を確認 → 別ブランチ名で再試行。remote 曖昧/未 fetch は `git fetch` 後に retry。解決不能 → user |
| Phase 4 実装失敗 | RED→GREEN 規律で再試行、3 回 retry → user |
| Phase 5 CI fail | ログ取得 → 原因分析 → 修正 → retry（pr-workflow が budget 管理、最大 3 回）。3 回 fail → user |
| Phase 5 commit 失敗（1Password） | `osascript` で通知音付き push 通知 → 中断 |
| Phase 6 multi-review CRITICAL | Phase 7 の `/review-resolve-loop` で autonomous 修正 |
| Phase 6 adversarial で重大反証（large） | 内部 Fix cycle、収束不能 → **user エスカレート**（対話 skill を自動起動しない） |
| Phase 7 merge conflict | 解消（general-purpose 委任可）、解決不能 → user |
| GATE 3 で user reject | pr-workflow 停止（merge しない） |

## 注意

- 本 skill は orchestrator。重い処理は各 skill に委譲し、分類・GATE・統合判断に専念する。
- **ワークツリー作業は必須**（Phase 0.5）。全 tier で `/wtp` を使い、main worktree を直接汚さない。standard/large の `/sdd` には新規ワークツリー作成を抑止するオーバーライドを渡す。
- **マージは user**（GATE 3 を通しても自動マージしない）。
- **CI first**: CI green を確認してからレビューを実施する（Phase 5 → Phase 6 の順）。CI が落ちている状態でのレビューは無駄になる可能性が高い。
