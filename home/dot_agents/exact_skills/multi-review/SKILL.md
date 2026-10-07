---
name: multi-review
description: |
  tier に応じたレビュー roster（同じハーネスの subagent ＋ 別モデルの CLI）を並列に走らせ、
  結果を一次ソースで裏取りして統合し、GitHub PR にレビュー（body サマリー ＋ インラインコメント）として投稿する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー"
  使用場面: PR のコードレビュー・セキュリティレビューを、複数の観点とモデルで一度に行いたいとき。
argument-hint: "<PR番号 | owner/repo#PR番号 | PR URL> [--tier=trivial|small|standard|large] [--arch] [--spec-context <dir>]"
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
2. **security フロア**: 変更ファイルのパスに `auth` / `session` / `token` / `secret` / `credential` / `permission` / `jwt` / `oauth` / `cookie` / `apikey` / `cert` / `ssh` / `.env` などが含まれれば、明示の tier に関わらず `standard` 以上にする。

## roster

| tier | general | security | specialist | architecture |
|---|---|---|---|---|
| trivial | other-model | — | — | — |
| small | subagent ＋ other-model | — | — | — |
| standard | other-model（effort 高） | subagent | other-model | — |
| large | other-model（effort 高） | subagent | other-model | subagent |

- trivial 以外は、subagent と other-model を 1 本以上ずつ立てる（モデルの多様性）。
- architecture は large か `--arch` のときだけ立てる（リポジトリ全体を読むので高くつく）。
- specialist は standard / large で、変更ファイルに合うものだけを立てる。

| specialist | 立てる条件 |
|---|---|
| typescript | `.ts` / `.tsx` / `.mts` / `.cts` |
| react | `.tsx` / `.jsx` |
| python | `.py` / `.pyi` |
| database | `*.sql`、パスに `migrations/`、`schema.prisma`、`*.schema.ts` |
| test | `*.test.*` / `*.spec.*` / `*_test.*` / `tests/` / `__tests__/` / `*.bats` |
| ux | `.tsx` / `.jsx` / `.vue` / `.svelte` / `.astro` / `.css` / `.scss` / `.less` / `.html` |
| performance | database と同じデータ層の変更、または spec の要件に性能要件があるとき |

## spec-context

`--spec-context <dir>`（`requirements.md` / `design.md` / `tasks.md` を含むディレクトリ）が渡されたら、その絶対パスと「実装が spec に整合しているか（要件の取りこぼし・設計からの逸脱・未完了のタスク）も確かめる」という指示を全 leg に渡す。本文は埋め込まない。作業ディレクトリ配下で `..` を含まないことを確かめてから渡す。

## finding schema

| 分類 | 用途 |
|---|---|
| `[MUST]` | 修正必須（バグ・セキュリティ・設計違反） |
| `[SHOULD]` | 修正推奨 |
| `[NITS]` | 軽微な提案 |
| `[GOOD]` | 称賛 |

各指摘に、ファイル:行番号、問題、修正案、確信度を付ける。security leg の重大度は、Critical・High を `[MUST]`、Medium を `[SHOULD]`、Low・Info を `[NITS]` に写す。PR 本文に独自の prefix 規約（`[must]/[imo]/[nits]/[fyi]` など）があれば、投稿時にそれに合わせ、合わせたことを user に伝える。

統合サマリーの形:

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価
| カテゴリ | <立てた leg ごとの列> |
|---|---|
| MUST / SHOULD / NITS / GOOD | N件 … |

### セキュリティ
- 総合リスクレベル: <Level> / 検出された脆弱性数: N件

### [MUST] / [SHOULD] / [NITS] / [GOOD]
{ファイル:行番号でまとめた指摘}

### 事実検証で棄却した指摘
{指摘の要約 — 棄却理由と根拠}
```

「事実検証で棄却した指摘」は、次のラウンドで同じ誤指摘を出させないための台帳になる。
