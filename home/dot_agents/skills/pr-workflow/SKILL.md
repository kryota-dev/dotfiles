---
name: pr-workflow
description: |
  タスクから PR マージ手前までの開発ワークフロー全体を orchestrate する skill。
  size tier（trivial/small/standard/large）と operation variant を判定し、tier 別 path で
  実装 → review → PR 対応 → CI を進め、3 GATE で承認連投を最小化する。
  トリガー: "pr-workflow", "ワークフローで進めて", "tier 判定して実装から PR まで", "一気通貫で PR まで"
  使用場面: 規模の異なるタスクを、tier に応じた最適な深さ（inline〜grill-me+sdd+santa）で PR 化したいとき。
argument-hint: "<task description> [--size=trivial|small|standard|large] [--operation=add-feature|change-feature|fix-defect|refactor|mvp] [--strict]"
---

# pr-workflow

タスクの **size tier** と **operation variant** を判定し、tier に応じた path で「実装 → review → PR 対応 → CI」を orchestrate する。各既存 skill（`/sdd` `/multi-review` `/review-resolve-loop` `/monitor-ci` `/grill-me` `/commit` `/create-pr`）を束ねる**司令塔**であり、自分は薄く保ち、重い処理は各 skill に委譲する。

**model-tier（task #28）**: 分類・設計・統合判断は **Opus（Leader）**が保持。機械的実装は **Sonnet 委任**（small tier の general-purpose 起動等）、cross-model diversity は **codex**（multi-review）。高推論の Opus→Opus 委任は速度利得ゼロのため避ける。

**マージは user（絶対に自動マージしない）**: GATE 3 を通っても merge 自体は user の明示操作。本 skill は merge-ready 状態 + checklist を提示して停止する。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<task description>` | - | 実装したいタスク（自由記述。GitHub Issue URL / `#番号` も可） |
| `--size` | 自動判定 | `trivial`/`small`/`standard`/`large`。text 分析の override |
| `--operation` | 自動判定 | `add-feature`/`change-feature`/`fix-defect`/`refactor`/`mvp` |
| `--strict` | off | GATE を全段 user 承認にする（tier=large は自動 on） |

## Phase 0: Classify（分類）

- **size tier 判定**: text 分析（変更範囲・新規性・リスク）+ `--size` override。
- **operation variant 判定**: text 分析 + `--operation` override。
- **tier=large は auto-strict**（`--strict` を自動付与）。

## Phase 1-4: tier 別 path

| tier | path |
|------|------|
| `trivial` | inline Edit（spec/planning skip） |
| `small` | **general-purpose サブエージェント（`model: sonnet`）**に inline prompt で委任（旧 sdd-worker は task #25 で削除済のため named agent は使わない）。tdd-workflow の RED→GREEN 規律を prompt に含める |
| `standard` | `/sdd`（autonomous Phase 0-7） |
| `large` | `/grill-me`（設計先行、`--output-prd` で PRD 固定可）→ `/sdd`（PRD/Plan を `--prd`/`--plan` で渡す）→ Phase 5 で santa-method 追加 |

`/sdd` の autonomous 性は破壊しない: GATE は `/sdd` の**内側に注入せず**、pr-workflow の orchestration の継ぎ目（PR 作成後・review 後・CI 後）に置く。

## Phase 5: review（全 tier 共通）

- `/multi-review`（cc-code-review + cc-security-review + codex 並列）。
- **（large のみ）santa-method**: Reviewer B + C による adversarial verify（Verdict Gate）。
- **二重 review の扱い（決定: 併用＝役割分離）**: standard/large では `/sdd` 内蔵 Phase 5 review（=開発中の自己 review）と本 `/multi-review`（=最終 PR への独立 second opinion）が**役割分離で併用**される。置換・skip はしない（独立した視点を確保するため）。指摘は一次ソースで検証してから対応する。

## Phase 6-7: PR resolution + CI（全 tier 共通）

- `/review-resolve-loop`（PR review への autonomous 対応）。
- `/monitor-ci`（CI green 待機）。
- merge は **user**（下記 GATE 3）。

## GATE（3 個）

| Gate | タイミング | default | `--strict`（tier=large 含む） |
|------|-----------|---------|------------------------------|
| GATE 1 | PR 作成後 | auto-proceed | user 承認待ち |
| GATE 2 | `/multi-review` 完了後 | auto-proceed | user 承認待ち |
| GATE 3 | CI green 検出後（**merge 直前**） | **常に user 承認待ち** | 同じ |

→ default は **merge 前 1 回承認**（GATE 3 のみ）。tier=large or `--strict` で **3 連投**。GATE 3 承認後も merge は user が実行する（自動マージ禁止）。

## Failure mode / recovery（主要）

| 局面 | 対処 |
|------|------|
| Phase 4 実装失敗 | tdd-workflow の RED gate を再 invoke、3 回 retry → user |
| Phase 5 multi-review CRITICAL | `/review-resolve-loop` で autonomous 修正 |
| Phase 5 santa-method NAUGHTY | 内部 Fix cycle、収束不能（freeze）→ `/grill-me` |
| Phase 6 commit 失敗（1Password） | `osascript` で通知音付き push 通知 → 中断 |
| Phase 7 CI fail | カテゴリ別に自動修復、3 回 fail → user |
| Phase 7 merge conflict | conflict を解消（general-purpose 委任可）、解決不能 → user |
| GATE 3 で user reject | pr-workflow 停止（merge しない） |

## 関連 skill / 前提

- 既存: `/sdd` `/multi-review` `/review-resolve-loop` `/monitor-ci` `/commit` `/create-pr` `/grill-me` `/pr-draft-summary`、tdd-workflow。
- Plan-PRD pipeline（task #22）と統合: pr-workflow が `<task description>` / PRD path / Plan path を受け、tier 別に `/grill-me --output-prd` → `/planning --output-plan` → `/sdd --prd --plan` を起動できる。`--strict` 等の mode は全 step に inherit する。

## 注意

- 本 skill は orchestrator。重い処理は各 skill に委譲し、pr-workflow 自身は分類・GATE・統合判断に専念する。
- **マージは user**。GATE 3 を通しても自動マージしない（global policy 優先、#21 原案の「merge 自動実行」を上書き）。
