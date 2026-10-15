---
name: security-review
description: |
  自分が開発・運用・保守するプロジェクトのセキュリティレビューを、マルチモデル オーケストレーションで実施する。
  Fable 5.1（ソースコード脆弱性発見）と Codex GPT-5.4（脅威モデリング・設定検証）をフェーズごとに使い分け、
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
各フェーズのプロンプトテンプレートと検査項目の詳細はそちらに置く。

## 前提

- **対象は自分が所有・運用するシステムに限る**（正当な防御的セキュリティ作業）
- AI の出力は偽陽性・偽陰性を含む。Critical / High の発見は必ず手動で検証する
- このレビューは専門的なペネトレーションテストを代替するものではなく、補完するもの

## モデル選定

セーフガードのリアルタイムサイバー分類器は Opus 4.7（2026-04）から導入された。
Fable 5.1 / Opus 5.5 / Sonnet 5.5 はいずれも Fable レベルのサイバーセーフガードを持ち、
攻撃シナリオの列挙中にフォールバック（Opus 4.8 への降格）が発生しうる。

**親セッション（この skill を実行するモデル）はフォールバックを受けない**ことを前提とする。
親が Fable / Opus 5.5 / Sonnet 5.5 で動いている場合、Phase 3（脅威モデリング）の
コーディネーションでフォールバックが発生する可能性がある。その場合は Phase 3 を
丸ごと Codex に委ね、親はプロンプトの受け渡しのみを行う。

| フェーズ | モデル | effort | 根拠 |
|---|---|---|---|
| Phase 1: 偵察 | 親 | medium | 構造の読み取りと整理。深い推論は不要 |
| Phase 2: 脆弱性発見 | **Fable 5.1** subagent | **high** | GA で許可されている最強の解析能力。見落としが致命的 |
| Phase 3: 脅威モデリング | **Codex** GPT-5.4 | high | Claude のセーフガードが攻撃シナリオの詳述をブロックしうる |
| Phase 4: 設定検証 | **Codex** GPT-5.4 | medium | チェックリスト的。網羅性が重要で深い推論は不要 |
| Phase 5: 統合レポート | 親 | medium | 既存の発見を整理・優先度付けする作業 |

### effort の考え方

セキュリティレビューでは**見落としのコスト（偽陰性）がレビュー時間のコストより遥かに高い**。
脆弱性の発見と認可ロジックの検証には必ず high を使う。偵察やレポート統合のように
「読んで整理する」フェーズでは medium で十分であり、high にしても発見の質は変わらず
トークンを浪費する。

## 引数

| 引数 | 既定 | 意味 |
|---|---|---|
| `--phase` | `all` | 実行するフェーズ（`1`〜`5` で個別指定、`all` で全フェーズ） |
| `--scope` | リポジトリ全体 | レビュー対象を特定のディレクトリに絞る |

## Phase 1: 偵察（親 — effort: medium）

プロジェクトの構造を把握し、攻撃面マップを作る。

1. 以下の情報を収集する:
   - 言語・フレームワーク・ランタイム
   - 認証・認可の仕組み（IdP、セッション管理、アクセス制御）
   - データストア（DB、キャッシュ、ファイルストレージ）
   - 外部サービス連携（API、Webhook、OAuth）
   - デプロイ先（クラウドプロバイダ、CDN、エッジ）
   - 公開面（Web UI、API エンドポイント、Worker / Function）
   - シークレット管理（env、Vault、KMS）
   - CI/CD パイプライン

2. プロジェクト固有の設計文書（README、CLAUDE.md、docs/、ADR 等）を読み、
   セキュリティに関する設計判断とその理由を抽出する。

3. 結果を**攻撃面マップ**として構造化する。攻撃面マップは以降のフェーズに渡す。

```
攻撃面マップの構造:
- 公開面: [エンドポイント / UI / Worker のリスト]
- 認証・認可: [仕組みの概要、アクセス制御の実装箇所]
- データフロー: [入力 → 処理 → 保存 → 出力の経路]
- 信頼境界: [クライアント / サーバー / 外部サービスの境界]
- シークレット: [管理方法と参照箇所]
- 既知の設計判断: [セキュリティに関する意図的な判断とその理由]
```

## Phase 2: ソースコード脆弱性発見（Fable 5.1 subagent — effort: high）

Fable 5.1 の subagent を起動する。Fable 5.1 はソースコードの脆弱性発見が GA で許可されており、
この用途では最強の解析能力を持つ。

`references/checklists.md` の「Phase 2 プロンプトテンプレート」を読み、攻撃面マップを埋め込んで
subagent に渡す。

### Claude Code での起動

```
Agent(model: fable, prompt: "Phase 2 プロンプト + 攻撃面マップ")
```

### セーフガード発動時

Fable がフォールバックした場合、問題のファイル / 関数を特定し、Codex に個別委譲する。
Codex への委譲は `codex` skill の相談モード（`--sandbox read-only`）を使う。

## Phase 3: 脅威モデリング（Codex GPT-5.4 — effort: high）

Claude のセーフガードが攻撃シナリオの詳述をブロックしうるため、Codex に委譲する。
`codex` skill の相談モード（`--sandbox read-only`）で起動する。

`references/checklists.md` の「Phase 3 プロンプトテンプレート」を読み、攻撃面マップを
埋め込んで Codex に渡す。

### Claude Code での起動

```bash
RESULT="/tmp/security-review-phase3-$(date +%s).md"
LOG="/tmp/security-review-phase3-$(date +%s).log"
codex exec --sandbox read-only --cd <project-dir> --color never \
  -c model_reasoning_effort=high -o "$RESULT" - <<'PROMPT' > "$LOG" 2>&1
[Phase 3 プロンプト + 攻撃面マップ]
PROMPT
```

結果は `$RESULT` を読む（`$LOG` ではない）。

## Phase 4: セキュリティ設定検証（Codex GPT-5.4 — effort: medium）

Codex に委譲する。Phase 3 と同じく `codex` skill の相談モードを使う。

`references/checklists.md` の「Phase 4 プロンプトテンプレート」を読み、Codex に渡す。

### Claude Code での起動

```bash
RESULT="/tmp/security-review-phase4-$(date +%s).md"
LOG="/tmp/security-review-phase4-$(date +%s).log"
codex exec --sandbox read-only --cd <project-dir> --color never \
  -c model_reasoning_effort=medium -o "$RESULT" - <<'PROMPT' > "$LOG" 2>&1
[Phase 4 プロンプト]
PROMPT
```

## Phase 5: 統合レポート（親 — effort: medium）

Phase 2〜4 の結果を統合し、レポートを作成する。
`references/checklists.md` の「Phase 5 レポートテンプレート」に従う。

### レポートの出力先

user に確認する。選択肢:
- Artifact として公開（共有しやすい）
- プロジェクトの `docs/` に Markdown で保存（git 履歴に残る）
- 標準出力に表示（一時的な確認）

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
