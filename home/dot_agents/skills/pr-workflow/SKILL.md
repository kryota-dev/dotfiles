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

**委譲先 skill の対話性は尊重する（ただし二重確認はしない）**: `/commit` `/create-pr` `/multi-review` `/sdd` `/grill-me` `/review-resolve-loop` は各々が独自に user 確認を持つ。pr-workflow はそれらの **standalone 確認を置換・抑止しない**。一方で、**pr-workflow が追加する GATE のうち、委譲先が既に確認した事項を再確認するもの（GATE 1・GATE 2）は auto-proceed に集約**し、二重確認による approval fatigue（反射的 rubber-stamping）を防ぐ。承認は**意味ある決定点**（intent 承認・人間レビュアーへの返信・merge handoff）に絞る。全体像は『承認点インベントリと集約方針（#225）』参照。

**model-tier（task #28）**: 分類・設計・統合判断は **Opus（Leader）**。機械的実装は **Sonnet 委任**（small tier の general-purpose 起動）、cross-model diversity は **codex**（multi-review）。

**マージは user**: 設計決定（task #21 原案の「merge 自動実行」を上書き）として、本 skill は**絶対に自動マージしない**。GATE 3 は merge-ready の handoff であり、merge は user の明示操作。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<task description>` | - | 実装したいタスク（自由記述。GitHub Issue URL / `#番号` 可） |
| `--size` | 自動判定 | `trivial`/`small`/`standard`/`large`。下記基準の override |
| `--operation` | 自動判定 | `add-feature`/`change-feature`/`fix-defect`/`refactor`/`mvp` |
| `--strict` | off | 集約された GATE 1・2 を承認待ちに戻す escape hatch（#225 の auto-proceed 集約を opt-out する）。GATE 3 は元々常に user |

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

**tier=large の GATE も集約される（auto-proceed）**。#225 の集約は tier に依らず default で効くため、`large` でも GATE 1・2 は自動進行する。全 GATE を明示的に止めたいときのみ `--strict` を付ける（下記 GATE 表の escape hatch）。

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
- **二重 review の扱い（決定: 併用＝役割分離）**: standard/large では `/sdd` 内蔵 review（=開発中の自己 review）と本 `/multi-review`（=最終 PR への独立 second opinion）を**役割分離で併用**する（置換・skip しない）。指摘は一次ソースで検証してから対応。
- **（large の adversarial 強化）**: `/multi-review` 後に **adversarial verify protocol**（独立 reviewer 視点で MUST を反証し、過半が反証→棄却）を inline で 1 ラウンド追加する（外部 skill ではなく手順）。

## Phase 6-7: PR resolution + CI

- `/review-resolve-loop`（PR review への autonomous 対応。**内部で CI 監視まで行う**）。
- `/monitor-ci` は `/review-resolve-loop` が CI 監視を内包するため、**最終確認 or fallback として条件付き**で呼ぶ（無条件には呼ばない＝二重 wait 回避）。
- CI fail 時の修復・retry budget（最大 3 回）は **pr-workflow 側で管理**する（カウントの所在を明確化）。3 回 fail → user。

## GATE（orchestration の節目）

| Gate | タイミング | 役割 | default | `--strict`（明示時のみ / escape hatch） |
|------|-----------|------|---------|------------------------------|
| GATE 1 | **PR 作成検知後**（trivial/small=`/create-pr` 後、standard/large=`/sdd` 完了＝PR 作成済を検知して pr-workflow 再開） | 進行チェックポイント | auto-proceed | **user 承認待ち（#225 集約を opt-out）** |
| GATE 2 | `/multi-review` 完了後 | 進行チェックポイント | auto-proceed | **user 承認待ち（#225 集約を opt-out）** |
| GATE 3 | CI green 検出後 | **不可逆操作の最終確認** | **merge-ready handoff（merge は user）** | 同じ |

> **#225 の集約**: GATE 1・GATE 2 は **進行チェックポイント**であり、PR が作られた/レビュー結果が揃った事実の再確認に過ぎない（intent は #222 の intent gate が上流で担保済）。default では **auto-proceed に集約**して二重確認 = approval fatigue を避ける。全 GATE を明示的に止めたい特殊時のみ `--strict` で承認待ちに戻せる（escape hatch）。GATE 3（merge handoff）は**不可逆操作の最終確認**として default でも `--strict` でも必ず user を経る（merge は常に user）。委譲先 skill の standalone 確認はそのまま残る（GATE 数＝総承認回数ではない）。役割分担の全体像は次節『承認点インベントリと集約方針』参照。

## 承認点インベントリと集約方針（#225）

pr-workflow は GATE を**追加**する一方で委譲先の確認を減らさないため、`large` path では承認が積み上がり **approval fatigue（反射的 rubber-stamping）** を招きやすい。反射的 rubber-stamping は「浅い理解」の再来であり、intent 確認（#222）の価値を空洞化させる。これを防ぐため、承認点を**意味ある決定点に集約**し、GATE と委譲先確認の役割を明示する。

### 承認点インベントリ（standard / large path）

| # | 承認点 | 発生元 | 役割 | 集約後の扱い |
|---|--------|--------|------|-------------|
| 1 | intent / 設計承認（large=`/grill-me --mode=auto` の PRD 承認 / standard=軽量 intent gate） | pr-workflow Phase 1-4（#222） | **不可逆前の意味ある決定** | **残す**（理解を担保する核） |
| 2 | worktree 戦略の選択 | `/sdd` Phase 0-4 | 進行チェックポイント（setup） | 委譲先の standalone 確認として残す（低コスト）。pr-workflow は再確認しない |
| 3 | GATE 1（PR 作成検知後） | pr-workflow GATE | 進行チェックポイント | **auto-proceed に集約**（PR が作られた事実の再確認は冗長。intent は #222 で上流担保済。`--strict` 明示時のみ承認待ちに戻せる） |
| 4 | multi-review の投稿方法（3 択） | `/multi-review` Phase 5 | 進行チェックポイント（外向き投稿の選択） | 委譲先の standalone 確認として残す。pr-workflow は GATE 2 で二重に問わない |
| 5 | GATE 2（multi-review 完了後） | pr-workflow GATE | 進行チェックポイント | **auto-proceed に集約**（multi-review が結果提示 + 投稿方法を既に確認済。`--strict` 明示時のみ承認待ちに戻せる） |
| 6 | review 対応方針の一括承認 | `/review-resolve-loop` 2-4 | 意味ある決定（対応方針） | 委譲先の standalone 確認として残す |
| 7 | 人間レビュアーへの返信内容承認 | `/review-resolve-loop` 4-1b | **不可逆・外向きの最終確認** | **残す**（外向き返信は user 承認必須） |
| 8 | GATE 3（CI green = merge-ready handoff） | pr-workflow GATE | **不可逆操作の最終確認**（merge は user） | **残す**（merge は常に user。Out of Scope 事項で不変） |

> `standard`/`large` では commit + PR 作成を `/sdd` が内部で自律実行するため、`/commit`/`/create-pr` の確認はこの path では発生しない（それらは trivial/small path の承認点）。

### 集約方針（duplicate / low-value confirmation の統合）

- **委譲先が既に確認した事項を GATE で再確認しない**（二重確認の禁止）。GATE 1・GATE 2 は委譲先確認（PR 作成・multi-review 提示）と実質同一の節目なので default で **auto-proceed に集約**する（`--strict` を明示したときのみ承認待ちに戻す escape hatch）。
- **意味ある決定点に承認を絞る**: (a) intent / 設計承認（#222）、(b) review-resolve-loop の対応方針・人間返信、(c) GATE 3 の merge-ready handoff。これらは残す。
- **委譲先の standalone 確認は抑止しない**: 各 skill 単体起動時の確認（worktree 選択・投稿方法・commit 計画等）は**変更しない**。pr-workflow は自分が**追加した** GATE のうち冗長なものを畳むだけで、委譲先の内部確認には手を入れない（standalone 動作を壊さない）。

### GATE と委譲先確認の役割分担

| 種別 | 定義 | 例 | 既定の扱い |
|------|------|----|-----------|
| **進行チェックポイント** | 進行の節目。危険がなければ自動で進む | GATE 1, GATE 2, worktree 選択, multi-review 投稿方法 | auto-proceed（二重確認しない） |
| **不可逆操作の最終確認** | 取り消しにくい / 外向きの操作の直前確認 | intent/設計承認, 人間レビュアーへの返信, GATE 3（merge handoff） | user 承認を必ず経る |

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
