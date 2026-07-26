---
name: model-fitness-check
description: |
  現在のセッションの model / effort が、実行しようとしている作業の §4 contract を満たすかを検出し、満たさなければ実装・レビュー実行に入る前に停止する共有ゲート。skill はセッションの model / effort を変更できない（`/model` `/effort` は user のみ）ため、「検出 → 提案 → 停止」を担う。
  `pr-workflow` / `sdd` / `multi-review` が各 entry から呼ぶ。contract テーブルはこの skill が唯一の SSOT。
argument-hint: "<work tier>（例: orchestration / large / trivial-small）"
---

# model-fitness-check

セッションの model / effort が作業の要求水準（§4 contract）を満たすかを検査し、満たさない場合は**実装・レビュー実行に入る前に停止**して user に切り替えを提案する共有ゲート。

## SSOT としての位置づけ

**§4 contract テーブルはこの skill が唯一の SSOT**。`pr-workflow` / `sdd` / `multi-review` はこのテーブルを複製せず、各 entry から本 skill を 1 行で呼ぶだけにする（複製すると Codex pin が 3 箇所で drift した失敗を Claude 側で再演することになる）。

## §4 contract（Model/effort テーブル）

テーブルが規定するのは**セッション自身**の model / effort であり、**委譲先 worker の tier は各 agent 定義の frontmatter が SSOT**（例: adversarial verification 行は「その作業を主導するセッション」に Opus 5 @ xhigh を要求するのであって、`adversarial-verifier` agent が Opus であるべきという意味ではない）。

| 作業 | Model | Effort | 行種別 |
|------|-------|--------|--------|
| `pr-workflow` の分類 / GATE / 統合; `sdd` Phase 1–3 の spec 執筆; `multi-review` の統合・裁定 | Opus 5 | high（既定。ゲートは言及しない） | **floor**（blocking） |
| large tier / PRD 審議 / adversarial verification / 横断設計 | Opus 5 | xhigh | **floor**（blocking） |
| trivial / small tier のみ | Sonnet 5 | medium | **cost hint**（non-blocking FYI） |
| Fable-orchestrator セッション（`cldf` 系） | Fable 5 | セッション既定 | floor 判定は常に pass（monotonic ルール）。over-provision 閾値ゲートは適用 |

## capability 順序（monotonic）

能力順序を **Fable > Opus > Sonnet > Haiku** と定義する。同一 family 内では **generation が効く**（Opus 4.8 は Opus 5 の floor を**満たさない**）。判定は「現在の tier ≥ 行が要求する tier」なら**無条件で silent pass**（プロンプトを出さない）。

- **Fable / cldf セッションは floor 行（上方向）の switch 提案を受けない**。Fable は全 floor の要求を満たす（monotonic の最上位）うえ、`fable-orchestrator-prompt.md` で独自の委譲契約を持つため、Opus 契約に合わせる上方向の提案は構造的に矛盾する。下方向（過剰スペックの解消）は「over-provision 閾値ゲート」の対象で、**Fable セッションも免除されない**。
- over-provisioning（Fable で trivial をこなす等）は毎回は停止しないが、累積が閾値を超えたら 1 回だけ blocking する（「over-provision 閾値ゲート」参照）。cldf でも exit → `cld --continue` で orchestrator 契約ごと降りられるため、「是正不能」ではない。

## model の検出

1. **主経路**: セッションの system-prompt に埋め込まれた model identity（自己申告。「You are powered by ...」等）を読む。
   **主経路が Fable と解決したら、この時点で silent pass し副経路の cross-check も行わない**。`cldf` 系は `--model claude-fable-5` を argv で渡す（`home/dot_config/zsh/claude.zsh` の `_claude_fable`）ため settings.json とは**構造的に必ず乖離**し、cross-check は常に偽陽性になる。
2. **副経路（cross-check）**: **主経路が Fable 以外のときのみ実行する**。`~/.claude/settings.json` の `model` を Read で読む（`cld-r06` セッションでも同じパスでよい —— `~/.claude-r06/settings.json` は `~/.claude/settings.json` への symlink であり、両アカウントは 1 つの settings.json を共有する。chezmoi source: `dot_claude-r06/symlink_settings.json.tmpl`）。これは `/model` によるセッション内変更を反映しない可能性があるため、**主経路と乖離したら silent に解決せず surface する**（どちらが有効かを user に提示して確認）。

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
- effort はセッション内から確実には読めないため、**推論せず提示して確認する**（`effortLevel` は settings.json から読めるが、`/effort` によるセッション内状態と乖離しうるため）。statusline snapshot（「over-provision 閾値ゲート」参照）の `effort` は harness 実出力由来の参考値として使えるが、描画タイミングにより stale がありうるため、これも確定値としては扱わない。

### trivial / small 行

**non-blocking の一行 FYI** に留める。「trivial/small tier は Sonnet 5 @ medium で十分（現在より下げればコストが浮く）」程度の cost hint を出すだけで、**workflow を止めない**。trivial/small は分類が実行前に終わらないため、ここで停止させると軽い path の摩擦を最大化する。

FYI を出すたびに over-provision カウンタを +1 する（「over-provision 閾値ゲート」参照）。毎回の FYI は non-blocking のまま維持し、blocking は閾値超過時の 1 回に限定する。

### 検出不能時の fallback

model 検出が主経路・副経路とも失敗した場合、**silent skip せず**、常にチェック内容（要求水準と現在の不確実性）を提示する（fail-safe）。

## over-provision 閾値ゲート

trivial/small の毎回 FYI とは別に、**過剰スペックの累積**を「カウンタ × 実測 quota 圧力」の 2 シグナルで監視し、閾値超過時のみ 1 回 blocking する。サブスクリプション（Max / Team）では over-provision の実害は金額ではなく **quota（全モデル共有プール）のクラウドアウト**——Fable / Opus で軽作業を続けると、重作業に必要な quota が先に尽きる——なので、圧力シグナルと組み合わせ、quota に余裕がある間は止めない（alert fatigue の回避。blocking の希少性が floor 停止の信頼性を支える）。

### シグナル 1: over-provision カウンタ（セッション内）

- 「現在の tier が行の要求より上位」と判定するたび（trivial/small FYI を出すたび）にカウンタを +1 する。
- セッション内でのみ保持する（永続化しない）。**floor 判定の idempotency とは別カウンタ**（idempotency は同一判定の再提示の抑制、本カウンタは累積の検出で、性質が逆）。
- ゲート発火時、および continue anyway 選択時にリセットする。

### シグナル 2: 実測 quota 圧力（statusline snapshot）

`~/.cache/claude-statusline/rate_limits_<profile>.json` を Read する（statusline が stdin の `rate_limits` を書き出す snapshot。`<profile>` は `CLAUDE_CONFIG_DIR` の basename、既定 `.claude`）。`five_hour.used_percentage` を圧力として使う。

- **staleness ガード**: `ts` が 15 分より古い、またはファイルが無い場合は quota 不明として count-only fallback（下表）に切り替える。silent skip はしない（fail-safe）。

### 発火条件（named constants）

帯域は statusline `pct_color` の色閾値（50 / 80）と一致させる:

| 5h used_percentage | 帯域 | 発火閾値（カウンタ） |
|---|---|---|
| < 50 | green | 発火しない（FYI のみ） |
| 50–79 | yellow | `OVERPROVISION_GATE_YELLOW = 5` 件 |
| ≥ 80 | red | `OVERPROVISION_GATE_RED = 2` 件 |
| snapshot 無し / stale | 不明 | `OVERPROVISION_GATE_FALLBACK = 5` 件（count-only） |

### 発火時の提示（`AskUserQuestion` で 1 回 blocking）

文面には snapshot の実測値をそのまま載せる（例: 「5h ウィンドウ 62% 消費（↻14:00 リセット）。直近 5 件は Sonnet で足りる軽作業でした。このペースだと重作業の前に上限に当たる見込みです」）。選択肢はセッション種別で分岐する:

- **cld 系（通常セッション）**:
  1. `/model sonnet` に下げて続行（推奨）
  2. continue anyway（カウンタをリセットし、次の閾値まで沈黙）
  3. abort
- **cldf 系（Fable orchestrator）**:
  1. exit → `cld --continue` で再開（推奨。orchestrator prompt は argv 注入のため再起動で契約ごと降りられ、会話文脈は保持される）
  2. `/model opus` 等でセッション内切替（**注記必須**: system-prompt の自己申告 model identity が古い値を残すため、以後の本 skill の主経路検出を信用せず、切替済みであることをセッション内に記録する）
  3. continue anyway（カウンタをリセット）

このゲートは **Fable / cldf セッションにも適用される**（floor 免除は上方向の switch 提案に限る）。

## 呼び出し規約

**行種別は引数で受け取る**（`/model-fitness-check <tier>`）。判定は行種別ごとに分岐するため、呼び出し側の散文ではなく引数で確定させる。

- `pr-workflow`: Phase 0 冒頭 —— `/model-fitness-check <tier>`（Phase 0 の分類結果をそのまま渡す）
- `sdd`: Phase 0 冒頭 —— `/model-fitness-check orchestration`（large 相当なら `large`）
- `multi-review`: Phase 1 の前 —— `/model-fitness-check orchestration`（`multi-review` に Phase 0 は無い）

各 skill は本 skill を呼ぶ 1 行を持つのみで、**§4 テーブルも行種別の説明も再掲しない**。

**idempotency（多重起動の抑制）**: `pr-workflow` → `sdd` → `multi-review` と連鎖すると 1 実行で最大 3 回同じ判定が走る。**同一セッションで一度 pass した行、および明示的に continue-anyway を選んだ行については再提示しない**（前回の判断を再利用する）。model / effort が変更された形跡があるときのみ再評価する。
