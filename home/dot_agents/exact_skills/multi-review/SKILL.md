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

**実行するときは、Phase 1 の前に [`references/execution.md`](references/execution.md) を Read する。** 各 leg に渡す観点は [`references/perspectives.md`](references/perspectives.md)、別モデルの leg の起動形は [`references/other-model-legs.md`](references/other-model-legs.md)、裏取りは [`references/fact-check.md`](references/fact-check.md)。

## leg の種類

| 種類 | 実体 |
|---|---|
| **subagent** | 実行中のハーネスの subagent（Claude Code の Agent、Codex の spawn_agent） |
| **other-model** | もう一方のハーネスの CLI。Claude Code からは `codex exec`、Codex からは `claude -p`。使えなければ subagent で代える（モデルの多様性が欠けることを統合サマリーに書く） |

## tier の確定

1. `--tier` が渡ればそれを使う（pr-workflow は Phase 0 の tier を渡す）。4 値以外は空として扱う。空なら diff から推定する。判定軸は `pr-workflow` の「size tier」表に従い、迷ったら上に切り上げる。
2. **security フロア**: 変更ファイルのパスに `auth` / `session` / `token` / `secret` / `credential` / `permission` / `jwt` / `oauth` / `cookie` / `apikey` / `cert` / `ssh` / `.env` / `.github/workflows/` などが含まれれば、明示の tier に関わらず `standard` 以上にする。

## roster

leg は、汎用のパスが構造的に見落とすレンズ（intent・simplicity）と、取り返しがつかず専門知識が要る領域（database・IaC）で分ける。言語ごとの specialist は置かない（general と観点が重なり、型や lint の違反は CI が見る）。

| tier | general | security | intent | simplicity | database / IaC |
|---|---|---|---|---|---|
| trivial | other-model | — | — | — | — |
| small | other-model | — | — | subagent | — |
| standard | other-model（effort xhigh） | subagent | subagent | other-model | 条件に合えば other-model |
| large | other-model（effort xhigh）＋ subagent | subagent | subagent | other-model | 条件に合えば other-model |

- trivial 以外は、subagent と other-model を 1 本以上ずつ立てる（モデルの多様性）。
- intent は PR の本文・リンク先の issue・spec を辿るので subagent にする（Codex の sandbox からは `gh` の認証が届かない）。
- general を 2 本にするのは large だけ。同じ観点を 2 つのモデルで回すと、差分が小さいうちは重複が大半になる。

| 領域 | 立てる条件（パスか diff 本文のどちらかに当たれば立てる） |
|---|---|
| database | パス: `*.sql`、`migrations/`、`migrate/`、`schema.prisma`、`*.schema.ts`。diff 本文（大文字小文字を区別しない）: `create table` / `alter table` / `create index` / `drop table` |
| IaC | パス: `*.tf` / `*.tfvars` / `*.tf.json`。diff 本文: 同じファイルの追加行に `apiVersion:` と `kind:` の両方がある |

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

### セキュリティ
- 総合リスクレベル: <Level> / 検出された脆弱性数: N件

### PR 単位の問い
{intent の問い。無ければ節ごと省く}

### [MUST] / [SHOULD] / [NITS]
{ファイル:行番号でまとめた指摘}

### 参考: 変更前からある問題
{この PR が原因ではない [MUST] 級の問題。この PR では直さない。無ければ節ごと省く}

### 良かった点
{親が特に良いと判断した点を 1〜2 行。無ければ節ごと省く}

### 事実検証で棄却した指摘
{指摘の要約 — 棄却理由と根拠}
```

「事実検証で棄却した指摘」は、次のラウンドで同じ誤指摘を出させないための台帳になる。
