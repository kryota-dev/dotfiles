---
name: security-review
model: claude-opus-4-6
description: |
  自分が開発・運用・保守するプロジェクトのセキュリティレビューを、マルチモデル オーケストレーションで実施する。
  Fable 5.1（ソースコード脆弱性発見）と Codex（脅威モデリング・設定検証）をフェーズごとに使い分け、
  セーフガードによるフォールバックを避けながら、防御的セキュリティレビューの品質を最大化する。
  トリガー: "security-review", "セキュリティレビュー", "脆弱性チェック", "脅威モデリング", "攻撃面を洗い出して"
  使用場面: 自分のプロジェクトのセキュリティを体系的にレビューしたいとき。PR 単位のレビューには multi-review を使う。
argument-hint: "[--phase=1|2|3|4|5|all] [--scope=<対象ディレクトリ>]"
user-invocable: true
---

# security-review

自分が所有・運用するプロジェクトの防御的セキュリティレビューを、5 つのフェーズに分けてマルチモデルで実施する。
PR 単位の差分レビュー（`multi-review`）ではなく、プロジェクト全体を対象とする体系的なレビュー。

**実行するときは、Phase 1 の前に [`references/checklists.md`](references/checklists.md) を Read する。**
各フェーズのプロンプトテンプレート・設計原則・検査項目の詳細はそちらに置く。

## 前提

- **対象は自分が所有・運用するシステムに限る**（正当な防御的セキュリティ作業）
- AI の出力は偽陽性・偽陰性を含む。Critical / High の発見は必ず手動で検証する
- このレビューは専門的なペネトレーションテストを代替するものではなく、補完するもの

## なぜ Opus 4.6 を親に使うか

セーフガードのリアルタイムサイバー分類器は Opus 4.7（2026-04）から導入された。
Fable 5.1 / Opus 5.5 / Sonnet 5.5 はいずれも Fable レベルのサイバーセーフガードを持ち、
攻撃シナリオの列挙中にフォールバック（Opus 4.8 への降格）が発生しうる。
Opus 4.6（2026-02）はサイバー分類器の搭載前で、フロンティアクラスの推論能力を持つ。
フォールバックなしにオーケストレーションを完遂できる。

## フェーズ別のモデルと effort

見落としのコスト（偽陰性）がレビュー時間のコストより遥かに高いため、脆弱性発見と脅威モデリングには high を使う。

| フェーズ | モデル | effort | 根拠 |
|---|---|---|---|
| Phase 1: 偵察 | 親（Opus 4.6） | medium | 構造の読み取りと整理。深い推論は不要 |
| Phase 2: 脆弱性発見 | **Fable 5.1** subagent（Codex なら既定モデル） | **high** | GA で許可されている最強の解析能力。見落としが致命的 |
| Phase 3: 脅威モデリング | **Codex**（既定モデル） | high | Claude のセーフガードが攻撃シナリオの詳述をブロックしうる |
| Phase 4: 設定検証 | **Codex**（既定モデル） | medium | チェックリスト的。網羅性が重要で深い推論は不要 |
| Phase 5: 統合レポート | 親（Opus 4.6） | medium | 既存の発見を整理・優先度付けする作業 |

## 引数

| 引数 | 既定 | 意味 |
|---|---|---|
| `--phase` | `all` | 実行するフェーズ（`1`〜`5` で個別指定、`all` で全フェーズ） |
| `--scope` | リポジトリ全体 | レビュー対象を特定のディレクトリに絞る |

## Phase 1: 偵察（親 Opus 4.6 — effort: medium）

プロジェクトの構造を把握し、以下の攻撃面マップを作る。以降のフェーズに渡す。

```
攻撃面マップの構造:
- 公開面: [エンドポイント / UI / Worker のリスト]
- 認証・認可: [仕組みの概要、アクセス制御の実装箇所]
- データフロー: [入力 → 処理 → 保存 → 出力の経路]
- 信頼境界: [クライアント / サーバー / 外部サービスの境界]
- シークレット: [管理方法と参照箇所]
- 既知の設計判断: [セキュリティに関する意図的な判断とその理由]
```

プロジェクト固有の設計文書（README、CLAUDE.md、docs/、ADR 等）を読み、
セキュリティに関する設計判断とその理由を抽出して攻撃面マップに含める。

## Phase 2: ソースコード脆弱性発見（Fable 5.1 subagent — effort: high）

`references/checklists.md` の「Phase 2 プロンプトテンプレート」を読み、攻撃面マップを埋め込んで渡す。

**Claude Code:** `Agent(model: fable, prompt: "Phase 2 プロンプト + 攻撃面マップ")`

**Codex:** Fable subagent は使えない。`codex` skill の相談モードで起動し、effort は
`-c model_reasoning_effort=high` にする。品質差をレポートの「対象外・制約事項」に記す。

## Phase 3: 脅威モデリング（Codex — effort: high）

Claude のセーフガードが攻撃シナリオの詳述をブロックしうるため、Codex に委譲する。
`codex` skill の相談モードで起動し、effort は `-c model_reasoning_effort=high` にする。
`references/checklists.md` の「Phase 3 プロンプトテンプレート」を読み、攻撃面マップを埋め込んで渡す。
結果は `-o` のファイルを読む。

## Phase 4: セキュリティ設定検証（Codex — effort: medium）

`codex` skill の相談モードで起動し、effort は `-c model_reasoning_effort=medium` にする。
`references/checklists.md` の「Phase 4 プロンプトテンプレート」を読み、Codex に渡す。

## Phase 5: 統合レポート（親 Opus 4.6 — effort: medium）

Phase 2〜4 の結果を統合し、`references/checklists.md` の「Phase 5 レポートテンプレート」に従ってレポートを作成する。出力先は user に確認する。

## セーフガード発動時のフォールバック戦略

| 状況 | 対処 |
|---|---|
| Fable がソースコード解析中にフォールバック | 問題のファイル / 関数を特定し、Codex に個別委譲 |
| Codex が脅威モデリングを拒否 | プロンプトを防御的な文脈に書き換え再試行。それでも拒否なら手動で列挙 |
| 特定の CWE パターンの検査がブロック | 検査項目を分割し、1 項目ずつ実行 |
| レポートの攻撃シナリオ記述がブロック | 「影響と緩和策」のみを記述し、攻撃手順は省略 |

## 正規プログラムの申請

より深いレビューが必要なら、各社の正規プログラムに申請する:

- **Anthropic CVP Defense Access**（個人可）: `portal.anthropic.com/programs/cvp`
  — Fable 5.1 / Opus 5.5 のセーフガード緩和。MFA 必須
- **OpenAI Trusted Access for Cyber**: `platform.openai.com/trusted-access`
  — GPT-Daybreak-Blue（防御的セキュリティ向け低拒否モデル）へのアクセス
