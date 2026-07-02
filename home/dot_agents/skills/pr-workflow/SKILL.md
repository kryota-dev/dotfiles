---
name: pr-workflow
description: |
  タスクから PR マージ手前までの開発ワークフロー全体を orchestrate する skill。
  size tier（trivial/small/standard/large）と operation variant を判定し、tier 別 path で
  実装 → review → PR 対応 → CI を進め、orchestration GATE で進行を整理する。
  トリガー: "pr-workflow", "tier 判定して PR まで orchestrate", "ワークフロー skill で進めて"
  使用場面: 規模の異なるタスクを、tier に応じた最適な深さ（inline〜grill-me+sdd）で PR 化したいとき。
argument-hint: "<task description> [--size=trivial|small|standard|large] [--operation=add-feature|change-feature|fix-defect|refactor|mvp] [--strict]"
user-invocable: true
---

# pr-workflow

タスクの **size tier** と **operation variant** を判定し、tier に応じた path で「実装 → review → PR 対応 → CI」を orchestrate する。各既存 skill を束ねる**司令塔**であり、自分は薄く保ち、重い処理は委譲する。

**委譲先 skill の対話性は尊重する**: `/commit` `/create-pr` `/multi-review` `/sdd` は各々が独自に user 確認を持つ。pr-workflow はそれらを**置換・抑止しない**。下記 GATE は pr-workflow が**追加で**挟む orchestration の節目であり、委譲先の承認回数を減らすものではない（承認連投の体感は減るが、各 skill の確認は残る）。

**model-tier（task #28）**: 分類・設計・統合判断は **Opus（Leader）**。機械的実装は **Sonnet 委任**（small tier の general-purpose 起動）、cross-model diversity は **codex**（multi-review）。

**マージは user**: 設計決定（task #21 原案の「merge 自動実行」を上書き）として、本 skill は**絶対に自動マージしない**。GATE 3 は merge-ready の handoff であり、merge は user の明示操作。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<task description>` | - | 実装したいタスク（自由記述。GitHub Issue URL / `#番号` 可） |
| `--size` | 自動判定 | `trivial`/`small`/`standard`/`large`。下記基準の override |
| `--operation` | 自動判定 | `add-feature`/`change-feature`/`fix-defect`/`refactor`/`mvp` |
| `--strict` | off | orchestration GATE を全段 user 承認待ちにする（tier=large は自動 on） |

## Phase 0: Classify（分類）

**size tier の判定軸**（text だけで決めず、次を評価。`--size` で override）:

| tier | 目安 |
|------|------|
| `trivial` | 1〜数行、単一ファイル、振る舞い不変、ロールバック容易 |
| `small` | 数ファイル、所有境界内、DB/API/UI 契約変更なし |
| `standard` | 複数ファイル横断 or 新機能、テスト追加要、設計判断あり |
| `large` | 仕様確定が必要 / 外部契約・migration・高ロールバック難度 / 影響広範 |

**operation variant**（path の重点を変える。`--operation` で override）:

- `add-feature`: 新規追加。AC 網羅。
- `change-feature`: 既存変更。後方互換を確認。
- `fix-defect`: **再現テスト先行**（RED→GREEN）。
- `refactor`: **public behavior freeze**（外部挙動を変えない検証を重視）。
- `mvp`: **scope gate**（最小で動く範囲に絞り、過剰実装を抑止）。

**tier=large は auto-strict**（`--strict` を自動付与）。

## Phase 1-4: tier 別 path

| tier | path |
|------|------|
| `trivial` | inline Edit。**ただし spec/planning の skip は「既に承認済みの計画があるとき」のみ**（global 指示「実装前は `$planning`」を上書きしない。曖昧なら `/planning` を通す）。→ `/commit` → `/create-pr` |
| `small` | **general-purpose サブエージェント（`model: sonnet`）**に inline prompt で委任（named worker は使わない）。prompt に **TDD の RED→GREEN 規律**（テスト先行・最小実装。inline protocol、外部 skill ではない）を含める。→ `/commit` → `/create-pr` |
| `standard` | `/sdd`（完全自律実行）。**`/sdd` は内部で自前に commit + PR 作成まで行う**ため、この path では `/commit`/`/create-pr` を別途呼ばない（二重実行回避）。 |
| `large` | （任意で）先に `/grill-me` で設計を詰める → `/sdd`（完全自律実行）。**`/grill-me` は対話型のため、pr-workflow から自動 invoke せず user が事前に実行する**前提。 |

**Plan-PRD pipeline（task #22 / PR10b）連携**: PR10b マージ後は `/grill-me --output-prd` → `/planning --output-plan` → `/sdd --prd --plan` の file handoff を使える。**PR10b 未マージ時はこれらの flag は存在しない**ため、PRD/Plan は手動で渡す。

## Phase 5: review

- **PR が存在する状態で** `/multi-review`（cc-code-review + cc-security-review + codex 並列）を起動する。trivial/small は Phase 1-4 で `/create-pr` 済、standard/large は `/sdd` が PR 作成済。
- **aggregate-view review（#223, large tier）**: **`large` tier では `/multi-review --arch`** を使い、diff-scope の盲点（既存抽象との重複・不要な結合・意図した設計からの drift）を集約視点で検出する `architecture-reviewer` を別レイヤで走らせる。trivial/small/standard では走らせない（毎 PR は高コストなため。**per-PR コスト方針＝large / opt-in のときのみ**）。standard で必要と判断したときは明示的に `--arch` を付けて起動してよい。
- **二重 review の扱い（決定: 併用＝役割分離）**: standard/large では `/sdd` 内蔵 review（=開発中の自己 review）と本 `/multi-review`（=最終 PR への独立 second opinion）を**役割分離で併用**する（置換・skip しない）。指摘は一次ソースで検証してから対応。
- **（large の adversarial 強化）**: `/multi-review` 後に **adversarial verify protocol**（独立 reviewer 視点で MUST を反証し、過半が反証→棄却）を inline で 1 ラウンド追加する（外部 skill ではなく手順）。

## Phase 6-7: PR resolution + CI

- `/review-resolve-loop`（PR review への autonomous 対応。**内部で CI 監視まで行う**）。
- `/monitor-ci` は `/review-resolve-loop` が CI 監視を内包するため、**最終確認 or fallback として条件付き**で呼ぶ（無条件には呼ばない＝二重 wait 回避）。
- CI fail 時の修復・retry budget（最大 3 回）は **pr-workflow 側で管理**する（カウントの所在を明確化）。3 回 fail → user。

## GATE（orchestration の節目）

| Gate | タイミング | default | `--strict`（tier=large 含む） |
|------|-----------|---------|------------------------------|
| GATE 1 | **PR 作成検知後**（trivial/small=`/create-pr` 後、standard/large=`/sdd` 完了＝PR 作成済を検知して pr-workflow 再開） | auto-proceed | user 承認待ち |
| GATE 2 | `/multi-review` 完了後 | auto-proceed | user 承認待ち |
| GATE 3 | CI green 検出後 | **merge-ready handoff（merge は user）** | 同じ |

> GATE は pr-workflow の節目。委譲先 skill（`/multi-review`/`/commit`/`/create-pr`）が持つ独自の user 確認はそのまま残る（GATE 数＝総承認回数ではない）。

## Failure mode / recovery（主要）

| 局面 | 対処 |
|------|------|
| Phase 4 実装失敗 | RED→GREEN 規律で再試行、3 回 retry → user |
| Phase 5 multi-review CRITICAL | `/review-resolve-loop` で autonomous 修正 |
| Phase 5 adversarial で重大反証 | 内部 Fix cycle、収束不能 → **user エスカレート**（対話 skill を自動起動しない） |
| Phase 6 commit 失敗（1Password） | `osascript` で通知音付き push 通知 → 中断 |
| Phase 7 CI fail | pr-workflow が修復、3 回 fail → user |
| Phase 7 merge conflict | 解消（general-purpose 委任可）、解決不能 → user |
| GATE 3 で user reject | pr-workflow 停止（merge しない） |

## 注意

- 本 skill は orchestrator。重い処理は各 skill に委譲し、分類・GATE・統合判断に専念する。
- **マージは user**（GATE 3 を通しても自動マージしない）。
