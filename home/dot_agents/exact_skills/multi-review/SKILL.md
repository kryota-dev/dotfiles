---
name: multi-review
description: |
  tier に応じたレビュー roster（同じハーネスの subagent ＋ 別モデルの CLI）を並列に走らせ、
  結果を一次ソースで裏取りして統合し、GitHub PR にレビュー（body サマリー ＋ インラインコメント）として投稿する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー"
  使用場面: PR のコードレビュー・セキュリティレビューを、複数の観点とモデルで一度に行いたいとき。
argument-hint: "<PR番号 | owner/repo#PR番号 | PR URL> [--tier=trivial|small|standard|large] [--spec-context <dir>]"
---

# multi-review

tier で絞った roster を並列に走らせ、統合し、既存のレビューと重複する指摘を除いてから、user の承認を得て PR に投稿する。

**実行するときは、Phase 1 の前に [`references/execution.md`](references/execution.md) を Read する。** 各 leg に渡す観点は [`references/perspectives.md`](references/perspectives.md)、leg の起動形は [`references/other-model-legs.md`](references/other-model-legs.md)、役割とモデルの割り当ては [`pr-workflow/references/model-roles.md`](../pr-workflow/references/model-roles.md)、裏取りは [`references/fact-check.md`](references/fact-check.md)。

## leg と役割

各 leg は、model-roles.md の役割（モデルとエフォートの組）で起動する。役割の系統（Claude / GPT）と実行中のハーネスで、起動のしかたが決まる。

| 役割の系統 | Claude Code から | Codex から |
|---|---|---|
| Claude | `claude -p`（model-roles.md の `claude_leg`） | `claude -p`（同じ） |
| GPT | `codex exec` | `spawn_agent`（`agent_type` に役割名）。親の sandbox が read-only でないときは `codex exec --sandbox read-only` |

Claude の役割を Claude Code の subagent で走らせないのは、親の広い permission を継承させないためと、cyber safeguard の fallback を親から隔離して `modelUsage` で検出するため（理由の詳細は model-roles.md）。

もう一方のハーネスの CLI が使えないときは、実行中のハーネスの新規 subagent で代える。代替した leg・理由・失われるモデルの多様性と検証の限界を統合サマリーに書く（同じモデルの新規起動だけでは、別モデルの独立性は補えない）。

全 leg は毎回新規セッションで起動し、親の実装履歴・過去のレビュー結果を渡さない。Codex subagent は `fork_turns: "none"` を明示する。起動方法・入力・実行記録は execution.md を参照する。この契約は pr-workflow 経由でも同じとする。

## tier の確定

1. `--tier` が渡ればそれを使う（pr-workflow は Phase 0 の tier を渡す）。4 値以外は空として扱う。空なら diff から推定する。判定軸は `pr-workflow` の「size tier」表に従い、迷ったら上に切り上げる。
2. **security フロア**: 変更ファイルのパスに `auth` / `session` / `token` / `secret` / `credential` / `permission` / `jwt` / `oauth` / `cookie` / `apikey` / `cert` / `ssh` / `.env` / `.github/workflows/` / `.github/actions/` / `action.yml` / `action.yaml` / `.github/dependabot.yml` / `renovate.json` / `CODEOWNERS` などが含まれれば、明示の tier に関わらず `standard` 以上にする。

## roster

leg は、汎用のパスが構造的に見落とすレンズ（intent・simplicity）と、取り返しがつかず専門知識が要る領域（database・IaC）で分ける。言語ごとの specialist は置かない（general と観点が重なり、型や lint の違反は CI が見る）。

| tier | general | security | intent | simplicity | database / IaC |
|---|---|---|---|---|---|
| trivial | `review-general-light` | — | — | — | — |
| small | `review-general-light` | — | — | `review-simplicity` | — |
| standard | `review-general` | `review-security` | `review-intent` | `review-simplicity` | 条件に合えば `reviewer-gpt` |
| large | `review-general` ＋ `reviewer-gpt` | `review-security` | `review-intent` | `review-simplicity` | 条件に合えば `reviewer-gpt` |

- **general は実装と別の系統で見る。** 実装は GPT が行う（pr-workflow）ので、general の主担当は Claude にする。large だけ GPT の general を足し、同じ系統の目でも見る。同じ観点を 2 つのモデルで回すと、差分が小さいうちは重複が大半になるので、2 本にするのは large だけにする。
- 親がほとんどを自分で書いた PR（trivial や、secret に触れるので委任しなかったタスク）や、人が書いた PR でも、roster は変えない。実装の系統が Claude なら、統合サマリーに「general が実装と同じ系統」と書く。
- Claude の leg が cyber safeguard で fallback したら（`modelUsage` に要求していないモデルがある）、model-roles.md の「fallback の検出」に従って `reviewer-gpt` で走らせ直し、実行記録に残す。
- intent は PR の本文・リンク先の issue・spec を辿る。未検証の本文を最も深く読む leg で、`review-intent` は Bash も `gh` も持たない。親が、本文がリンクする同じ repo の issue / PR（`gh … --repo "$OWNER/$REPO"`）の要件と本文だけを取得してファイルに書き、そのパスと spec を渡す。レビュー・コメントの履歴と、本文中の外部 URL は取得しない。
- spec-context が渡されたら、tier に関わらず intent を立てる（spec との整合を報告するのは intent だけなので）。
- general を 2 本にするのは large だけ。同じ観点を 2 つのモデルで回すと、差分が小さいうちは重複が大半になる。

| 領域 | 立てる条件（パスか diff 本文のどちらかに当たれば立てる） |
|---|---|
| database | パス: `*.sql`、`migrations/`、`migrate/`、`schema.prisma`、`*.schema.ts`。diff 本文（大文字小文字を区別しない）: `create table` / `alter table` / `create index` / `drop table` |
| IaC | パス: `*.tf` / `*.tfvars` / `*.tf.json`。中身: 変更した YAML ファイルの内容に `apiVersion:` と `kind:` の両方がある（diff の追加行だけで判定すると、既存の manifest の変更を取りこぼす） |

## spec-context

`--spec-context <dir>`（`requirements.md` / `design.md` / `tasks.md` を含むディレクトリ）が渡されたら、その絶対パスを全 leg に渡す。どの leg も判断の前提（spec が求める複雑さ、設計どおりの挙動）として読むが、「spec に整合しているか」の指摘を出すのは intent だけにする（同じ取りこぼしを複数の leg が出すのを防ぐ）。本文は埋め込まない。作業ディレクトリ配下で `..` を含まないことを確かめてから渡す。

## finding schema

| 分類 | 用途 |
|---|---|
| `[MUST]` | 修正必須（バグ・セキュリティ・設計違反） |
| `[SHOULD]` | 修正推奨 |
| `[NITS]` | 軽微な提案 |

各指摘に、ファイル:行番号、問題、実害、修正案を付ける。経路を追い切れなかった `[MUST]` には「（未確認）」が付く。security leg の重大度は、Critical・High を `[MUST]`、Medium を `[SHOULD]`、Low・Info を `[NITS]` に写す。intent は行を持たない PR 単位の問いを返す。PR 本文に独自の prefix 規約（`[must]/[imo]/[nits]/[fyi]` など）があれば、投稿時にそれに合わせ、合わせたことを user に伝える。

統合サマリーの形:

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価
| カテゴリ | <立てた leg ごとの列> |
|---|---|
| MUST / SHOULD / NITS | N件 … |

### 実行条件と確認根拠
| leg / ラウンド | HEAD / base | ハーネス / モデル / 推論設定 | 履歴継承 / セッションID | 状態 / 代替 |
|---|---|---|---|---|
| … | … | 要求値と確認できた実行値。不明は不明 | なし / … | … |

{leg ごとの確認ファイル・経路・疑って棄却した点・未確認事項。0件でも省略しない。代替時は失われる独立性と検証の限界を記す。公開時は個人情報・秘密情報・不要なローカルパスを除く。}

### 候補の採否
| 候補ID / leg | 生候補の要約 | 重複判定と重複先 | 事実検証後の採否 / 根拠 |
|---|---|---|---|
| … | … | … | 採用 / 訂正 / 棄却 / 未確認。一次ソースや再現結果 |

{0件なら候補0件と記す。カテゴリ別に候補 → 重複除外後 → 検証後の件数を示す。}

### セキュリティ
- 総合リスクレベル: <Level> / 検出された脆弱性数: N件

### PR 単位の問い
{intent の問い。無ければ節ごと省く}

### [MUST] / [SHOULD] / [NITS]
{ファイル:行番号でまとめた指摘}

### 参考: 変更前からある問題
{この PR が原因ではない [MUST] 級の問題。この PR では直さない。security leg 由来のものは書かず、user にだけ報告する。無ければ節ごと省く}

### 良かった点
{親が特に良いと判断した点を 1〜2 行。無ければ節ごと省く}

### 事実検証で棄却した指摘
{指摘の要約 — 棄却理由と根拠}
```

「事実検証で棄却した指摘」は、親が次のラウンドの重複除外・再検証に使う台帳になる。leg には渡さず、独立して再提起された候補も親が根拠と照合して判定する。指摘件数ではなく、妥当性と確認範囲を評価する。単一の比較から履歴分離の効果やモデルの優劣を断定しない。
