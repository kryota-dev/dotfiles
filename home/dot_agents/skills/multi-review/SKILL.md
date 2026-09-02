---
name: multi-review
description: |
  tier に応じたレビュー roster（Claude 汎用/セキュリティ + Codex generalist/specialist）を
  並列でバックグラウンド実行し、レビュー負荷の大半を Codex へ offload する。
  結果を統合サマリーにまとめた上で、GitHub PR にレビュー（body サマリー + インラインコメント）として投稿する。
  PRの包括的レビューを一度に実行したい場合に使用する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー", "tierレビュー"
  使用場面: PRのコードレビュー・セキュリティレビュー・Codexレビューを一括で実行したい場合
argument-hint: "<PR番号 | owner/repo#PR番号 | PR URL> [--tier=trivial|small|standard|large] [--arch] [--spec-context <dir>]"
---

# Multi Review

**tier に応じたレビュー roster（Claude + Codex）** を並列でバックグラウンド実行し、結果を統合サマリーにまとめる。
roster は tier で gating し（過剰起動を抑制）、レビュー負荷の大半を Codex へ offload する（Claude は security / architecture / adversarial に集中）。
既存レビュー（CodeRabbit / Devin / claude[bot] / 人間レビュアー）と重複する指摘を除外したうえで、
統合結果をユーザーに提示し、承認があれば GitHub PR にレビュー（body サマリー + インラインコメント、または インラインのみ）を投稿する（投稿方法はユーザーが選択）。

```
引数解析(--tier 抽出) → 差分取得 → tier 確定(明示 or 自動推定) → 既存レビュー取得
  + tier 別 roster 並列実行(Claude Agent + Codex bash, --json 観測) → 結果収集 → 統合サマリー
  → 既存レビューとの重複除外 → ユーザー確認(投稿方法を選択) → 投稿
```

**重複除外の意義**: 既存レビュアーが既に同じ指摘をしている場合、再投稿は冗長でレビュアーの認知負荷を増やす。
重複を除外することで、新規視点・追加価値のある指摘のみが投稿される。

## この SKILL.md の責務（reviewer registry）

**この SKILL.md が持つのは 2 つだけ** —— (1) **reviewer roster**（どの tier で誰を、どのモデル・
effort で起動するか、rubric の SSOT はどこか）と、(2) **finding schema**（指摘のカテゴリ・確信度・
統合サマリーの形・投稿プレフィクス）。**呼び出し元（`pr-workflow` Phase 6・`review-fleet`・
standalone）や他の reviewer 実装は、この 2 つを参照するためにこのファイルを読む。**

**実行手順そのものは `references/` が持つ。縮退で規範を削ったわけではない**（記述は移しただけで、
どれも省略可能になっていない）。**レビューを実際に走らせるときは、Phase 1 に入る前に
[`references/execution-protocol.md`](references/execution-protocol.md) を Read すること**（そこから
残りの reference へ辿れる）。

| ファイル | 内容 |
|---|---|
| `SKILL.md`（本ファイル） | reviewer roster registry ＋ finding schema ＋ 起動時の gate ＋ コスト管理 |
| [`references/execution-protocol.md`](references/execution-protocol.md) | Phase 1〜5 の実行手順（準備・既存レビュー取得・並列実行・統合・重複除外・投稿確認） |
| [`references/target-resolution.md`](references/target-resolution.md) | 引数からの owner/repo + PR 番号の解決（URL / `owner/repo#N` / 番号のみ） |
| [`references/codex-legs.md`](references/codex-legs.md) | Codex leg の起動形・`<SANDBOX_MODE>`・並列上限・ライブ観測・resume |
| [`references/fact-check.md`](references/fact-check.md) | 統合時の事実確認（技術的主張 / 「無いことを根拠とする指摘」） |
| [`references/posting.md`](references/posting.md) | PR レビュー投稿手順（body 付き submit / Pending Review） |
| [`references/operations.md`](references/operations.md) | エラーハンドリングと Bash ツール固有の注意 |

## 起動時の gate

**Phase 1 の前に `/execution-readiness-check <review context>` と `/model-fitness-check orchestration` を両方起動する**（`multi-review` に Phase 0 は無いため Phase 1 の直前で呼ぶ）。前者は review provider の adapter capability、account scope、rollout、permission manifest、risk を確認し、**current session model だけを理由に roster を block しない**。後者は統合・裁定を行うセッション自身の model / effort floor を判定する（blocking）。**行種別も要求される model / effort 値もここに書かない**（テーブルと行種別判定はいずれも `/model-fitness-check` が唯一の SSOT）。2 つは直交する gate であり、片方で他方を代替しない。

## レビュー対象の解決

引数は **owner/repo と PR 番号の 2 つ組**へ解決する。**以降の全 `gh` 呼び出しに `--repo <owner/repo>`
を明示する**（cross-repo バッチで cwd の repo に暗黙解決される事故を防ぐ）。URL / `owner/repo#N` /
番号のみ / 引数なしの判定順序、拒否すべき形状、post-regex の `case` チェックは
[`references/target-resolution.md`](references/target-resolution.md) が SSOT。**cross-repo バッチ
（`review-fleet` 等）から委譲するときは PR 番号のみを渡さない。**

## tier → roster 予算（tier-aware gating）

**tier がレビュー起動数とモデル配分を決める主レバー**。手順 0 の `TIER` を使い、下表の層だけを spawn する。tier を見ずに全 roster を組む旧挙動は廃止（小 PR の過剰起動を防ぐ）。

### tier の確定（自動推定 + security フロア）

**手順（順序が重要）**: (1) `TIER` を確定（明示 or 自動推定）→ (2) 確定後に security フロアを**無条件適用**する。フロアを (1) の枝分岐に埋め込まず、確定 `TIER` に対する後段の上書きとして書くことで、明示 `--tier` 経路もフロアの対象に含める。

1. **`TIER` の確定**:
   - `TIER` が渡っていればそれを使う（pr-workflow からは Phase 6 で明示 `--tier=<Phase0 の tier>` が渡る）。**ただし手順 0 で未定義値（4 値以外）は既に空扱いに落とされている**ため、ここに載る `TIER` は常に `trivial|small|standard|large` のいずれか（fail-open 禁止の担保）。`--tier` が複数回渡った場合は**最後の有効値**を採る（残りは無視）。
   - **未指定（standalone）なら diff から自動推定**する。判定軸は **pr-workflow『size tier の判定軸』表を SSOT として流用**する（`~/.agents/skills/pr-workflow/SKILL.md` の Phase 0）。**ここで軸を再掲・paraphrase しない**（新閾値を発明せず、pr-workflow 表との drift を作らない）。`${DIFF}`（Phase 1 手順 2）の変更行数・変更ファイル数・変更特性をその表に当てて tier を選ぶ。
   - **fail-safe 切り上げ**: 迷う・境界上・契約/migration/security surface（認証/認可/機密/外部通信）の兆候があれば**上位 tier に切り上げる**。誤分類は over-tiering 側に倒す。

2. **security フロア（tier 確定後に無条件適用・決定的バックストップ）**: 上記で確定した `TIER` に対し、**明示指定か自動推定かに関わらず**、差分の変更パスに security surface の兆候を検出したら `TIER` を **`standard` 未満なら `standard` へ引き上げる**（`final = max(TIER, standard)`）。**明示 `--tier=trivial|small` であっても上書きする**（フロアは明示指定より優先。security 変更が薄い roster を素通りするのを防ぐ）。
   - **検出対象キーワード（大文字小文字を無視した部分一致）**: `auth` / `session` / `token` / `secret` / `credential` / `permission` / `jwt` / `oauth` / `cookie` / `apikey` / `cert` / `ssh` / `.env`（`.env.*` を含む）等。変更ファイルのパス一覧（`diff --git` ヘッダ / `--name-only`）に対して評価する。
   - **これは floor であって ceiling ではない**: パス名ベースの機械的な最低保証であり、diff 本文の内容判定（上記 fail-safe 切り上げ）を置き換えない。汎用ファイル名で中身が security-critical な変更は引き続き fail-safe 判断が主軸。
   - **pr-workflow 経由との関係**: pr-workflow は Phase 0 の分類でも security surface を `standard` 以上とみなすが、それは LLM 判断（プローズ）。本フロアは multi-review 側の**決定的なバックストップ**として、pr-workflow が明示 `--tier` を forward した場合でも（分類の見落とし・誤操作・自動化による `--tier` 注入に対して）機械的に効く。

### roster gating table（spawn する = ✓、モデルと effort 付き）

| tier | cc-code-review<br>(Claude 汎用) | cc-security-review<br>(Claude security) | codex generalist<br>(Codex) | specialists<br>(Codex) | architecture<br>(Claude, `--arch`) | adversarial<br>(pr-workflow Phase 6) |
|---|---|---|---|---|---|---|
| **trivial** | — | — | ✓ effort=high | — | — | — |
| **small** | ✓ | — | ✓ effort=high | — | — | — |
| **standard** | — | ✓ | ✓ effort=xhigh | ✓ effort=high | — | — |
| **large** | — | ✓ | ✓ effort=xhigh | ✓ effort=high | ✓（large または `--arch`） | ✓（cross-model） |

- **多様性フロア（non-trivial で Claude≥1 + Codex≥1 を保証）**: small=cc-code(Claude)+codex(Codex)、standard/large=cc-security(Claude)+codex/specialists(Codex)。trivial のみ単一モデル（Codex）を許容する。
- **generalist は Codex 単独**（規模でコスト爆発する層を offload）。small だけは diff が小さくコストが低いため Claude generalist(cc-code) を安価なフロア anchor として併走させる。standard 以上では security(Claude) が anchor を担い、generalist は完全に Codex へ移す。
- **specialists（言語 roster + 横断 roster のマッチ分）は全て Codex 実行**（従来の Claude subagent spawn を置換。実行形は[`references/codex-legs.md`](references/codex-legs.md)、rubric は agent `.md` が SSOT）。**マッチ 0 件なら spawn しない**現行挙動は不変。
- **architecture は tier gating の対象外**（フラグ/tier のみで判定）: **`--arch`（tier 不問）または tier=large** のとき spawn する。gating table の trivial/small/standard 行の `—` は「通常 `--arch` を付けない運用上の目安」であって、`--tier=small --arch` のように明示すれば spawn する（起動内容表・「aggregate-view reviewer」節と一致）。
- **architecture / adversarial は Claude 側**（architecture=whole-repo 深い推論・`--arch`/large のみ、adversarial=pr-workflow Phase 6 で cross-model）。
- **Codex effort は `-c model_reasoning_effort=<high|xhigh>` で leg 別に上書き**する（`codex-model-pin.toml` は変更しない。デフォルト xhigh を fail-safe に据え置き、上表どおり specialist と 軽量 tier generalist だけ high に下げる）。

## SSOT（Single Source of Truth）

レビューの実体（ペルソナ・観点・出力形式・「（未確認）」ルール）は各ツール側に集約し、multi-review 側で重複定義しない。

| ツール | 実行方式 | SSOT |
|--------|---------|------|
| cc-code-review | カスタムサブエージェント（Agent ツール、`subagent_type: cc-code-review`） | エージェント定義 `~/.claude/agents/cc-code-review.md`（レビュー観点・出力形式）／ skill `~/.agents/skills/cc-code-review/SKILL.md`（対象解決・起動方法） |
| cc-security-review | カスタムサブエージェント（Agent ツール、`subagent_type: cc-security-review`） | エージェント定義 `~/.claude/agents/cc-security-review.md`（OWASP チェックリスト・出力形式）／ skill（対象解決・起動方法） |
| codex | CLI（`codex exec`、バックグラウンド Bash） | skill `~/.agents/skills/codex/SKILL.md`（実行コマンド・`-o` 出力・stdin 堅牢化・プロンプトルール・**wrapper 経由の account/`--profile shared` 自動注入**） |

- **cc-code-review / cc-security-review**: レビュー観点・出力形式・OWASP チェックリストはエージェント定義（system prompt）に内蔵されており、サブエージェント起動時に自動適用される。multi-review はプロンプトに「対象の説明 + 差分 + 作業ディレクトリの絶対パス」のみを渡し、観点・出力形式を再掲しない。エージェント定義は起動時に自動ロードされるため multi-review 側で Read する必要はない。
- **codex**: Phase 2 開始前に `~/.agents/skills/codex/SKILL.md` を Read し、`-o <FILE>` 出力・stdin 堅牢化・タイムアウト・「（未確認）」ルールに従ってコマンドを組み立てる。

### 動的 specialist roster（言語/ドメイン特化レビュアー）

**差分の言語・ドメインに応じて専門レビュアーを動的に追加**する。汎用レビュー（generalist）が見落としがちな言語固有・データ層固有の観点を補強するため。**実行は Codex**（tier gating table 参照。standard/large でのみ spawn、effort=high）。**rubric（観点・出力形式・「（未確認）」ルール）は agent 定義 `~/.claude/agents/<lang>-reviewer.md` 本文が SSOT**で、Codex heredoc に注入する（frontmatter は除去。実行形は[`references/codex-legs.md`](references/codex-legs.md)）。rubric は常設ツールと同一の `[MUST]/[SHOULD]/[NITS]/[GOOD]`。

| specialist | subagent_type | spawn 条件（変更ファイル） |
|------------|---------------|--------------------------|
| TypeScript | `typescript-reviewer` | `.ts` / `.tsx` / `.mts` / `.cts` |
| React | `react-reviewer` | `.tsx` / `.jsx`（JSX コンポーネント） |
| Python | `python-reviewer` | `.py` / `.pyi` |
| Database | `database-reviewer` | `*.sql` / `migrations/` 配下 / `schema.prisma` / `*.schema.ts`（drizzle 等の schema） |

- **検出方法**: Phase 1 の手順 2（[`references/execution-protocol.md`](references/execution-protocol.md)）で確保した `${DIFF}` のヘッダ行（`diff --git a/<path> b/<path>`）、または `gh pr diff --repo <owner/repo> <番号> --name-only` で変更ファイルのパス一覧を取得し、上表のマッチ基準で specialist を選ぶ。マッチ基準は列ごとに異なる: **拡張子一致**（`.ts` / `.tsx` / `.mts` / `.cts` / `.jsx` / `.py` / `.pyi` / `*.sql` / `*.schema.ts`）、**パスに `migrations/` を含む**、**basename が `schema.prisma`**（パス不問）。
- **重複 spawn 可**: 例えば `.tsx` を含む PR では typescript-reviewer と react-reviewer の両方が立つ（観点が直交するため許容）。
- **マッチ 0 件なら言語 specialist を spawn しない**（tier gating table の非 specialist leg のみが立つ）。dotfiles（shell/zsh/bats）のような非対象言語の PR では言語 specialist を spawn しない。
- **roster 外の agent**: `renovate-analyzer` 等の専用 skill / フローから起動するエージェントは本動的 roster の spawn 対象外。今後 specialist を増やす場合も「diff の言語・ドメインで自動 spawn する reviewer」のみを上表に載せる。
- **SSOT**: 各 specialist の観点・出力形式・「（未確認）」ルールはエージェント定義（`~/.claude/agents/<lang>-reviewer.md`）本文に内蔵。**Codex 実行では multi-review がこの本文を Read → frontmatter を剥がして heredoc に注入**し、そこへ「対象説明 + 差分取得コマンド + 作業ディレクトリ + 棄却台帳（+ spec-context があればそのパス）」を添える（観点は再掲・複製しない = drift ゼロ）。agent `.md` 本文は harness 中立化済みで、Claude subagent としても latent に成立する（多様性フロアの逃げ道）。

### 横断観点 specialist roster（変更特性ベース, #347）

言語 roster（拡張子ベース）とは別に、**変更の特性**に応じて横断観点の specialist を動的に追加する。sdd の内蔵レビューを廃止（single-pass 化, #347）したことで失われる performance / test / ux 観点を multi-review 側で補うためのレイヤ。言語 roster と同じく **Codex 実行**（tier gating table 参照、standard/large でのみ spawn、effort=high。rubric は agent 定義本文を heredoc 注入）で、rubric は `[MUST]/[SHOULD]/[NITS]/[GOOD]`。

| specialist | subagent_type | spawn 条件（変更ファイル・特性） |
|------------|---------------|--------------------------------|
| Test | `test-reviewer` | テストファイルの追加・変更（`*.test.*` / `*.spec.*` / `*_test.*` / `tests/` 配下 / `__tests__/` 配下 / `*.bats`） |
| UX | `ux-reviewer` | UI ファイルの変更（`.tsx` / `.jsx` / `.vue` / `.svelte` / `.astro` / `.css` / `.scss` / `.sass` / `.less` / `.html`） |
| Performance | `performance-reviewer` | データ層 / hot-path（`*.sql` / `migrations/` 配下 / `schema.prisma` / `*.schema.ts`）を含む、**または**呼び出し元が spec-context の `requirements.md` に性能要件（NFR）を検出して要請したとき |

- **検出方法**: 言語 roster と同じく Phase 1 の手順 2（[`references/execution-protocol.md`](references/execution-protocol.md)）で確保した `${DIFF}` のヘッダ行（`diff --git a/<path> b/<path>`）、または `gh pr diff --repo <owner/repo> <番号> --name-only` のパス一覧を上表のマッチ基準で判定する。performance は差分特性に加え **caller 要請**でも spawn しうる（性能は差分の字面だけでは判定しづらいため、spec-context や large tier のヒントを併用する）。
- **language roster と重複 spawn 可**: 例えば `.tsx` を含む PR では typescript-reviewer / react-reviewer（言語 roster）と ux-reviewer（横断観点）が同時に立つ（観点が直交するため許容）。DB 系 PR（`*.sql` / `migrations/` / `schema.prisma` / `*.schema.ts`）では database-reviewer（スキーマ安全性・injection）と performance-reviewer（クエリ効率・N+1）が両方立つ —— 追加コストが最も大きい重複パターンだが、観点が異なるため意図的に許容する。
- **マッチ 0 件なら spawn しない**: 非対象の変更（例: shell/zsh のみの dotfiles PR）では横断観点 specialist を spawn しない。
- **SSOT**: 各 specialist の観点・出力形式・「（未確認）」ルールはエージェント定義（`~/.claude/agents/{performance,test,ux}-reviewer.md`）本文に内蔵。**Codex 実行では multi-review がこの本文を heredoc 注入**し、「対象説明 + 差分取得コマンド + 作業ディレクトリ + 棄却台帳（+ spec-context があればそのパス）」を添える（観点は再掲・複製しない）。

### aggregate-view reviewer（repo/architecture 集約視点, #223）

diff 起動の specialist roster とは **別レイヤ**の reviewer。diff 起動の leg（generalist・security・specialist いずれも）は **diff 起点**のため、「既存抽象との重複」「不要な結合」「意図した設計からの drift」のような **単一 PR の差分だけでは見えない集約視点の問題**は誰も検出できない。それを埋めるのが `architecture-reviewer`（`~/.claude/agents/architecture-reviewer.md`、`model: sonnet` 固定 = #28 model-tier 整合）。

- **対象が違う**: 上記 roster は diff を起点にするが、architecture-reviewer は **repo tree・既存モジュール・設計ドキュメント（`docs/architecture/`・design-rationale・steering docs）を横断スキャン**する（diff は探索の起点に過ぎない）。よって roster の「diff 言語で自動 spawn」ロジックには載せず、別レイヤとして扱う。
- **gated（毎 PR は走らせない・コスト方針）**: whole-repo スキャンは高コストなため、**opt-in（`--arch`）または pr-workflow の large tier から要請されたときのみ** spawn する。デフォルト（無印の multi-review）では spawn しない。この gating が #223 の「per-PR vs periodic」コスト方針の SSOT（＝毎 PR ではなく large/opt-in の per-PR）。
- **SSOT**: 観点・出力形式・「（未確認）」ルールはエージェント定義（`~/.claude/agents/architecture-reviewer.md`）に内蔵。multi-review は「対象 PR 説明 + 差分取得コマンド + 作業ディレクトリ絶対パス + 棄却台帳」のみ渡す（cc-code-review と同形。差分はエージェント自身が取得し、そこから repo 全体へ探索を広げる）。

### spec-context 入力（呼び出し元からの spec 整合コンテキスト, #347）

`--spec-context <dir>`（手順 0 で抽出）が渡されたとき、`<dir>` は spec ドキュメント（`requirements.md` / `design.md` / `tasks.md`）を含むディレクトリ（例: `.spec-workflow/specs/<name>/`）を指す。sdd の内蔵レビューを廃止（single-pass 化, #347）したことで失われる **spec-implementation 整合チェック**（実装が要件・設計・タスクに整合しているか）を multi-review 側で補うための入力。

- **未指定時は従来動作**（spec 整合チェックなし・差分のみのレビュー）を完全に維持する。opt-in。
- **指定時の扱い**: Phase 2 で各 reviewer（その回に spawn した全 leg）のプロンプトに、spec ドキュメントの**絶対パス**（`<dir>/requirements.md` 等）と「実装差分が spec に整合しているか（要件の取りこぼし・設計からの逸脱・未完了タスク）も併せて確認せよ」という指示を追加する。**spec ドキュメント本文は埋め込まず、パスを渡して reviewer に Read させる**（`.spec-workflow/` は gitignore されうるため、reviewer は絶対パスで Read する）。`<dir>` が相対パスで渡された場合は、呼び出し元セッションの作業ディレクトリ（cwd）の絶対パスと結合して解決する。**解決後のパスは作業ディレクトリ配下に収まり `..` を含まないことを検証してから reviewer に渡す**（外部の任意パスを spec の「正」として読ませない）。
- **codex leg への spec-context 反映**: codex の primary path（promptless の `review --base`）はカスタムプロンプトを持たず spec パスを受け取れないため、`--spec-context` 指定時の codex leg は heredoc プロンプト方式（`${DIFF}` + spec ドキュメントの絶対パス + spec 整合チェック指示を埋め込む）で起動する。
- **pr-workflow からの呼び出し**: standard/large tier では sdd が生成した spec ディレクトリのパスが `--spec-context` として渡される（pr-workflow Phase 6 のオーバーライド指示参照）。

## finding schema

**全 leg（Claude / Codex、generalist / specialist / architecture）が共通で使う指摘の型**。roster と
並ぶ本 registry のもう一方の柱で、**呼び出し元と各 reviewer 定義はこの節を参照する**。

### カテゴリとプレフィクス

multi-review が投稿するインラインコメントの本文先頭には、必ず統合分類に対応するプレフィクスを付ける:

| 統合分類 | プレフィクス | 用途 |
|---------|-----------|------|
| MUST    | `[MUST]`     | 修正必須（バグ・セキュリティ・設計違反） |
| SHOULD  | `[SHOULD]`   | 修正推奨 |
| NITS    | `[NITS]`     | 軽微な提案 |
| GOOD    | `[GOOD]`     | 称賛 |

**プロジェクト独自 prefix の自動判定**: PR 本文に独自のレビュー prefix 規約（例: `<!-- for AI code review rule -->` ブロックや「以下の prefix をつけてください」という記述で `[must]/[imo]/[nits]/[typo]/[ask]/[fyi]` 等が指定されている場合）があれば、Phase 1.5（[`references/execution-protocol.md`](references/execution-protocol.md)）で取得した PR 本文から検出し、**そのプロジェクト規約に合わせて投稿する**。統合分類との対応例: MUST→`[must]`、SHOULD→`[imo]`、NITS→`[nits]`、GOOD→`[fyi]` または称賛。検出した規約はユーザーへの提示時に「PR 規約の prefix（`[must]/[imo]` 等）に合わせる」と明示する。

**デフォルト**: 独自規約が検出できない場合は `[MUST]/[SHOULD]/[NITS]/[GOOD]` の 4 種に統一する。Conventional Comments 記法（`[imo]` `[ask]` `[fyi]` 等）はデフォルトでは使わない。判断に迷う場合はユーザーに確認する。

### 確信度と coverage / precision の分業

**finding 段は coverage 優先 / 親が downstream filter（#224）**: 各 reviewer 定義は「finding 段では重要度・確信度で自己検閲せず、不確実・低 severity でも `確信度: high | medium | low` を付けて surface する」coverage-first に統一されている（SSOT はエージェント定義）。したがって **取捨選択・ランク付け・裏取りは親 Claude の責務**。サブエージェントが付けた確信度（confidence）と「（未確認）」マークをランク付けの手がかりとして使い、低確信・未確認の指摘は投稿前に一次情報で裏取りしてから採否を決める（coverage を finding 段で担保し、precision を親側の filter で担保する分業）。**確信度が低い / 未確認というだけで finding を黙って落とさない**——裏取りで否定できたときのみ削除し、否定しきれないものは（未確認の可能性ありと明示して）残す。

### 統合サマリーのフォーマット

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価

**その回に spawn した leg の列だけを出す**（tier gating で cc-code-review と cc-security-review は排他＝同時に揃わない。spawn しなかった leg・specialist の列は出さない）。以下は standard/large の例:

| カテゴリ | cc-security-review | codex generalist | test-reviewer | （spawn 時）typescript-reviewer | … |
|---------|-----------|-------------------|-------|--------------------------------|---|
| MUST    | N件       | N件               | N件   | N件                            | … |
| SHOULD  | N件       | N件               | N件   | N件                            | … |
| NITS    | N件       | N件               | N件   | N件                            | … |
| GOOD    | N件       | N件               | N件   | N件                            | … |

### セキュリティ
- 総合リスクレベル: <Level>
- 検出された脆弱性数: N件

### [MUST] 修正必須（全ツール統合）
{ファイル:行番号でグループ化した指摘一覧}

### [SHOULD] 修正推奨（全ツール統合）
{ファイル:行番号でグループ化した指摘一覧}

### [NITS] 軽微な提案
{指摘一覧}

### [GOOD] 良い実装
{称賛すべき点の一覧}

### 横断まとめ

| 観点 | 結果 |
|------|------|
| バグ・論理エラー | ... |
| 設計・アーキテクチャ | ... |
| セキュリティ | ... |
| 後方互換性 | ... |
| テスト | ... |
```

## 実行手順

**実行に入る前に [`references/execution-protocol.md`](references/execution-protocol.md) を Read する。**
Phase 1（準備）→ 1.5（既存レビュー取得）→ 2（並列実行）→ 3（結果収集と統合）→ 4（重複除外）→
5（ユーザー確認と投稿）の全手順と、Claude leg の結果回収契約・安全境界・棄却台帳をそこが持つ。
**節を飛ばして着手しない**（各 Phase の規範は registry 化の前後で一切変わっていない）。

## 注意事項

### コスト管理

- **tier gating が第一のコストレバー**（「tier → roster 予算」節）。小 PR は spawn 数が激減し（trivial=Codex 1 本、small=2 本）、大 PR でのみ specialist を含む網羅 roster が立つ。tier を見ずに全 roster を組む旧挙動は廃止。
- **Codex への offload**: generalist（全 tier）と specialists（standard/large）は **Codex 実行**で Claude 予算から外れる。Claude が残るのは cc-code-review（small のフロア anchor）／ cc-security-review（standard/large のフロア anchor）／ architecture-reviewer（large の集約視点）／ adversarial（pr-workflow Phase 6、cross-model）に限られる。**多様性フロア**（non-trivial で Claude≥1 + Codex≥1）は守る。
- **Codex effort（`-c model_reasoning_effort=`）**: generalist=xhigh（standard/large の唯一の広い網ゆえ品質バー維持）／ specialist=high。`codex-model-pin.toml` は変更せず、デフォルト xhigh を fail-safe に据え置いたうえで leg 別に上書きする。model は `gpt-5.6-terra` 単一。
- **Claude leg の model / effort の SSOT は各エージェント定義の frontmatter**（cc-code-review / cc-security-review = `model: sonnet` + `effort: xhigh`、architecture-reviewer = `model: sonnet`）。specialist の agent 定義（`model: sonnet` + `effort: high`）は **Codex 実行では未使用**（frontmatter は剥がされる）だが、Claude subagent としての latent 起動時に適用される（多様性フロアの逃げ道）。security-critical / large では Claude leg の Agent 呼び出し時に `model: "opus"` 等を明示指定して品質を上げる opt-in を維持する。
- **Codex 並列は `CODEX_MAX_CONCURRENCY`（=3）で上限**（[`references/codex-legs.md`](references/codex-legs.md)）。超過分はバッチ順次で、未検証の高並列競合を構造回避する。
- **architecture-reviewer（#223）は最もコストが高い**（repo tree・既存モジュール・設計ドキュメントを横断スキャン）。**`--arch` opt-in または pr-workflow の large tier のときのみ** spawn する（＝ #223 の per-PR コスト方針）。
- **codex の起動経路・禁止事項は `codex/SKILL.md` が SSOT**（`codex:codex-rescue` を起動しない理由もそこに集約。ここでは再掲しない）。レビュー leg は read-only なので `--profile shared` を使う。

### そのほかの実行上の注意

エラーハンドリング（leg 失敗時の縮退・リトライ）と Bash ツール固有の注意（jq の否定演算子）は
[`references/operations.md`](references/operations.md) を参照する。
