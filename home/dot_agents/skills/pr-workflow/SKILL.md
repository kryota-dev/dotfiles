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

### fail-safe 化（#224）

tier 分類は staging（tier 別 path）の前提であり、**誤分類（例: `large` を `small` と判定）は safety model を反転させる single point of failure** になる。これを fail-safe にするため、次の 2 つを既定にする:

- **round-up default（迷ったら上位 tier に切り上げる）**: 判定軸の複数解釈が可能で確信が持てない場合、**必ず上位 tier を採用**する。全境界（trivial↔small↔standard↔large）に適用する。over-tier による多少のコスト増（不要に重い path を通す）は許容し、**見逃し（危険な変更を軽い path に流す fail-unsafe）を最優先で防ぐ**。判定に迷った旨と切り上げ理由は簡潔に記録する。
- **mid-flight escalation（実装中の格上げ）**: 軽 tier（trivial/small）の実装中に、**contract 変更 / migration / security surface**（認証・認可・入力処理・機密情報・外部通信）への変更が判明したら、その場で tier を格上げし、格上げ後 tier の path（review 強化・GATE の user 承認待ち等）に乗せ換える。Phase 0 の入口分類は一度きりだが、**危険な surface を検知した時点で再分類する**（入口の分類だけに safety を依存させない）。

## Phase 1-4: tier 別 path

| tier | path |
|------|------|
| `trivial` | inline Edit。**ただし spec/planning の skip は「既に承認済みの計画があるとき」のみ**（global 指示「実装前は `$planning`」を上書きしない。曖昧なら `/planning` を通す）。→ `/commit` → `/create-pr`。**実装中に contract / migration / security surface を検知したら Phase 0 の mid-flight escalation で格上げする**。 |
| `small` | **general-purpose サブエージェント（`model: sonnet`）**に inline prompt で委任（named worker は使わない）。prompt に **TDD の RED→GREEN 規律**（テスト先行・最小実装。inline protocol、外部 skill ではない）を含める。→ `/commit` → `/create-pr`。**実装中に contract / migration / security surface を検知したら Phase 0 の mid-flight escalation で格上げする**（委任先 prompt にもこの検知・報告義務を含める）。 |
| `standard` | `/sdd`（完全自律実行）。**`/sdd` は内部で自前に commit + PR 作成まで行う**ため、この path では `/commit`/`/create-pr` を別途呼ばない（二重実行回避）。 |
| `large` | （任意で）先に `/grill-me` で設計を詰める → `/sdd`（完全自律実行）。**`/grill-me` は対話型のため、pr-workflow から自動 invoke せず user が事前に実行する**前提。 |

**Plan-PRD pipeline（task #22 / PR10b）連携**: PR10b マージ後は `/grill-me --output-prd` → `/planning --output-plan` → `/sdd --prd --plan` の file handoff を使える。**PR10b 未マージ時はこれらの flag は存在しない**ため、PRD/Plan は手動で渡す。

## Phase 5: review

- **PR が存在する状態で** `/multi-review`（cc-code-review + cc-security-review + codex 並列）を起動する。trivial/small は Phase 1-4 で `/create-pr` 済、standard/large は `/sdd` が PR 作成済。
- **二重 review の扱い（決定: 併用＝役割分離）**: standard/large では `/sdd` 内蔵 review（=開発中の自己 review）と本 `/multi-review`（=最終 PR への独立 second opinion）を**役割分離で併用**する（置換・skip しない）。指摘は一次ソースで検証してから対応。
- **（large の adversarial 強化）**: `/multi-review` 後に **adversarial verify protocol**（独立 reviewer 視点で MUST を反証し、過半が反証→棄却）を inline で 1 ラウンド追加する（外部 skill ではなく手順）。
  - **recall sink 化の防止（#224）**: Opus 4.8 は保守的な指示に忠実で recall を下げうるため、verify 段階が **本物の finding を落とす recall sink** になる余地がある。したがって **判断が割れた／確信が持てない finding は「残す」側にバイアスする**（過半が明確に反証したものだけ棄却。反証が僅差・不確実なら残す）。棄却する場合は棄却理由を一次情報とともに記録する（finding 段階の coverage を verify 段階で無為に打ち消さない）。
  - **測定（AC #224）**: この adversarial verify が recall sink になっていないかを軽量プロトコルで測定する。下記「recall 測定プロトコル」参照。

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

## recall 測定プロトコル（#224）

reviewer の recall（本物の bug を取りこぼさず surface できているか）と、adversarial verify が recall sink 化していないかを、**軽量な手動／定期プロトコル**で測定する（runtime 自動化はしない）。coverage-first reword（reviewer 定義側）と verify 段階の残す側バイアス（Phase 5）の効果を、定量的にではなく **サンプルで確認**するのが目的。

1. **サンプル抽出**: 直近の standard/large PR を数件サンプルする（既知 bug を含む PR や、後から regression が判明した PR を優先）。
2. **finding→verify の追跡**: 各 PR で multi-review が surface した finding 数と、adversarial verify で **棄却された finding 数（drop 数）**・**棄却理由**を記録する。
3. **drop の妥当性判定**: 棄却された finding を一次情報で見直し、「正しく棄却（誤指摘）」か「本物を落とした（recall sink）」かを分類する。**本物を落としていた場合は recall sink** と判断し、verify 段階の bias（Phase 5）や reviewer 定義の wording を更に調整する。
4. **precision-leaning wording の影響確認**: 「（未確認）」marking 付き finding が downstream（親 Claude / verify）で適切に裏取り・採否判断されているかを確認する。marking が付いた finding が無検証で drop されていれば、それも recall 損失として扱う。
5. **記録**: 結果（drop 率の傾向・recall sink の有無・許容可能かの判断）を PR や作業ログに簡潔に残す。損失が確認されたら wording/バイアスを是正し、許容範囲なら「confirmed acceptable」と記録する。

## 注意

- 本 skill は orchestrator。重い処理は各 skill に委譲し、分類・GATE・統合判断に専念する。
- **マージは user**（GATE 3 を通しても自動マージしない）。
