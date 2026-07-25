---
name: model-fitness-check
description: |
  現在のセッションの model / effort が、実行しようとしている作業の §4 contract を満たすかを検出し、満たさなければ実装フェーズに入る前に停止する共有ゲート。skill はセッションの model / effort を変更できない（`/model` `/effort` は user のみ）ため、「検出 → 提案 → 停止」を担う。
  `pr-workflow` / `sdd` / `multi-review` が各 entry（実装フェーズ前）から呼ぶ。contract テーブルはこの skill が唯一の SSOT。
argument-hint: "<work tier>（例: orchestration / large / trivial-small）"
---

# model-fitness-check

セッションの model / effort が作業の要求水準（§4 contract）を満たすかを検査し、満たさない場合は**実装に入る前に停止**して user に切り替えを提案する共有ゲート。

## SSOT としての位置づけ

**§4 contract テーブルはこの skill が唯一の SSOT**。`pr-workflow` / `sdd` / `multi-review` はこのテーブルを複製せず、各 entry から本 skill を 1 行で呼ぶだけにする（複製すると Codex pin が 3 箇所で drift した失敗を Claude 側で再演することになる）。

## §4 contract（Model/effort テーブル）

| 作業 | Model | Effort | 行種別 |
|------|-------|--------|--------|
| `pr-workflow` の分類 / GATE / 統合; `sdd` Phase 1–3 の spec 執筆; `multi-review` の統合・裁定 | Opus 5 | high（既定。ゲートは言及しない） | **floor**（blocking） |
| large tier / PRD 審議 / adversarial verification / 横断設計 | Opus 5 | xhigh | **floor**（blocking） |
| trivial / small tier のみ | Sonnet 5 | medium | **cost hint**（non-blocking FYI） |
| Fable-orchestrator セッション（`cldf` 系） | Fable 5 | セッション既定 | 常に pass（monotonic ルール） |

## capability 順序（monotonic）

能力順序を **Fable > Opus > Sonnet > Haiku** と定義する。同一 family 内では **generation が効く**（Opus 4.8 は Opus 5 の floor を**満たさない**）。判定は「現在の tier ≥ 行が要求する tier」なら**無条件で silent pass**（プロンプトを出さない）。

- **Fable / cldf セッションはどの行に対しても switch 提案を受けない**。Fable は全行の要求を満たす（monotonic の最上位）うえ、`fable-orchestrator-prompt.md` で独自の委譲契約を持つため、Opus 契約に無理に合わせる提案は構造的に矛盾する。
- over-provisioning（Fable で trivial をこなす等）は停止対象にしない（user が cldf を起動した時点で下せない決定であり、指摘しても是正不能）。

## model の検出

1. **主経路**: セッションの system-prompt に埋め込まれた model identity（自己申告。「You are powered by ...」等）を読む。
2. **副経路（cross-check）**: `~/.claude/settings.json` の `model` を Read で読む。これは `/model` によるセッション内変更を反映しない可能性があるため、**主経路と乖離したら silent に解決せず surface する**（どちらが有効かを user に提示して確認）。

### 正規化ルール

- `[1m]` などの context-window suffix を除去してから比較する。
- alias（`opus` / `sonnet` / `haiku` / `fable`）を現行 generation に解決する。
- **family + generation** で比較する（Opus 4.8 は Opus 5 floor を満たさない）。
- 判定不能な unknown 文字列は **fail-safe**（silent pass せず、チェックを提示する）。

## 判定と出力

作業の行種別に応じて分岐する:

### floor 行（Opus 5 @ high / Opus 5 @ xhigh）で mismatch

`AskUserQuestion` で **blocking** し、次の 3 択を提示する:

1. **switch して再実行**: literal な切り替えコマンドを表示する（例: `/model opus`、xhigh 行なら加えて `/effort xhigh`）。user が切り替えてから再開。
2. **continue anyway**: このまま進む。**どの phase の品質が劣化する見込みか**を 1 行記録する（decision log / PR の 1 行）。
3. **abort**: 作業を中止する。

- **effort は xhigh を要求する行でのみ言及する**。既定 high で足りる行では effort に一切触れない（`/effort` コマンドも出さない）。
- effort はセッション内から確実には読めないため、**推論せず提示して確認する**（`effortLevel` は settings.json から読めるが、`/effort` によるセッション内状態と乖離しうるため）。

### trivial / small 行

**non-blocking の一行 FYI** に留める。「trivial/small tier は Sonnet 5 @ medium で十分（現在より下げればコストが浮く）」程度の cost hint を出すだけで、**workflow を止めない**。trivial/small は分類が実行前に終わらないため、ここで停止させると軽い path の摩擦を最大化する。

### 検出不能時の fallback

model 検出が主経路・副経路とも失敗した場合、**silent skip せず**、常にチェック内容（要求水準と現在の不確実性）を提示する（fail-safe）。

## 呼び出し規約

- `pr-workflow`: Phase 0（分類直後、実装フェーズ前）
- `sdd`: Phase 0（準備、実装フェーズ前）
- `multi-review`: Phase 1 の前（`multi-review` に Phase 0 は無い）

各 skill は本 skill を呼ぶ 1 行を持つのみで、**§4 テーブルを再掲しない**。
