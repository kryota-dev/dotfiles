---
name: security-review
description: |
  自分が開発・運用・保守するプロジェクトのセキュリティレビューを、マルチモデル オーケストレーションで実施する。
  脆弱性の発見は Claude（Opus 5.5）と GPT（GPT-6.1 Sol）を並列に走らせて合わせ、脅威モデリングと設定検証は GPT に任せる。
  cyber safeguard の fallback で親のセッションが格下のモデルに固定されないよう、攻撃シナリオを扱う作業は別プロセスで行う。
  トリガー: "security-review", "セキュリティレビュー", "脆弱性チェック", "脅威モデリング", "攻撃面を洗い出して"
  使用場面: 自分のプロジェクトのセキュリティを体系的にレビューしたいとき。PR 単位のレビューには multi-review を使う。
argument-hint: "[--phase=1|2|3|4|5|all] [--scope=<対象ディレクトリ>] [--deep]"
user-invocable: true
---

# security-review

自分が所有・運用するプロジェクトの防御的セキュリティレビューを、5 つのフェーズに分けてマルチモデルで実施する。
PR 単位の差分レビュー（`multi-review`）ではなく、プロジェクト全体を対象とする体系的なレビュー。

**実行するときは、Phase 1 の前に [`references/checklists.md`](references/checklists.md) を Read する。**
各フェーズのプロンプトテンプレート・設計原則・検査項目の詳細はそちらに置く。役割（モデルとエフォート）・起動のしかた・
fallback の検出は [`pr-workflow/references/model-roles.md`](../pr-workflow/references/model-roles.md) に従う。

## 前提

- **対象は自分が所有・運用するシステムに限る**（正当な防御的セキュリティ作業）
- AI の出力は偽陽性・偽陰性を含む。Critical / High の発見は必ず手動で検証する
- このレビューは専門的なペネトレーションテストを代替するものではなく、補完するもの

## cyber safeguard とモデルの選び方

- Opus 5.5・Sonnet 5.5・Fable 5.1 は、ソースコードの脆弱性の走査・セキュリティ問題のトリアージ・安全なコードの作成には
  そのまま使える。exploit の生成や攻撃手順の詳述は classifier に当たり、Opus 4.8 などに fallback しうる。
- Claude Code 2.1.229 以降は、fallback するとセッションの残りがそのモデルに固定される。親が攻撃シナリオを書くと、
  以降の統合の判断まで格下のモデルで行うことになる。
- そこで、Claude の leg は親のセッションの外（`claude -p` の別プロセス）で走らせ、攻撃シナリオを詳述する Phase 3 は
  GPT に任せる。親は攻撃面の整理と統合だけを行う。
- 以前は classifier の導入前の Opus 4.6 を親にしていたが、やめた。Opus 4.6 は API で非推奨になっており、
  ソースの走査は 5.5 世代で許可されているので、能力を落とす理由が無い。

## フェーズ別の役割

見落としのコスト（偽陰性）がレビュー時間のコストより遥かに高いため、脆弱性の発見は 2 つの系統で独立に行う。

| フェーズ | 役割 | 起動 | 根拠 |
|---|---|---|---|
| Phase 1: 偵察 | 親 | — | 構造の読み取りと整理。深い推論は不要 |
| Phase 2: 脆弱性発見 | `review-security` ＋ `reviewer-gpt-focused`（並列）。`--deep` なら `review-security-deep` も | Claude は `claude -p`、GPT は `codex exec`（Codex なら `spawn_agent`） | 系統ごとに見落としが違う。Fable 5.1 は最難の問題でだけ上積みがあり、単価が高い |
| Phase 3: 脅威モデリング | `reviewer-gpt-focused` | `codex exec`（Codex なら `spawn_agent`） | 攻撃経路の詳述は Claude の classifier に当たりうる |
| Phase 4: 設定検証 | `checker-gpt` | 同上 | チェックリスト的。網羅性が重要で深い推論は不要 |
| Phase 5: 統合レポート | 親 | — | 既存の発見を整理・優先度付けする作業 |

## 引数

| 引数 | 既定 | 意味 |
|---|---|---|
| `--phase` | `all` | 実行するフェーズ（`1`〜`5` で個別指定、`all` で全フェーズ） |
| `--scope` | リポジトリ全体 | レビュー対象を特定のディレクトリに絞る |
| `--deep` | off | Phase 2 に Fable 5.1（`review-security-deep`）を足す。費用は増える |

## Phase 1: 偵察（親）

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

## Phase 2: ソースコード脆弱性発見（Claude と GPT を並列）

`references/checklists.md` の「Phase 2 プロンプトテンプレート」に攻撃面マップを埋め込み、同じ内容を各 leg に渡す。
結果は leg ごとに親が決めたファイルに書かせ、そのファイルだけを読む。leg に他の leg の結果を渡さない。

**Claude の leg**（Claude Code からでも Codex からでも `claude -p`）:

```bash
M=$(claude_role review-security model) E=$(claude_role review-security effort)
claude -p --model "$M" --effort "$E" --output-format json \
  --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
  --allowedTools "Read" "Grep" "Glob" "Bash(git log:*)" "Bash(git show:*)" \
  < "$PROMPT_FILE" > "$RESULT" 2>"$RESULT.err"
```

`--deep` のときは、同じ形で `review-security-deep` も起動する。JSON の `modelUsage` で、実際に使われたモデルを確かめる。

**GPT の leg**: `reviewer-gpt-focused` を、Claude Code からは `codex` skill の「相談・分析」の起動形
（`-m` と `-c model_reasoning_effort=` は役割の定義から）、Codex からは `spawn_agent` で起動する。

## Phase 3: 脅威モデリング（GPT）

`reviewer-gpt-focused` を Phase 2 の GPT の leg と同じ形で起動し、「Phase 3 プロンプトテンプレート」に攻撃面マップを埋め込んで渡す。
Phase 2 の結果があれば、Critical / High の要約（ファイルと種類だけ）を Context に足してよい。

## Phase 4: セキュリティ設定検証（GPT）

`checker-gpt` を同じ形で起動し、「Phase 4 プロンプトテンプレート」を渡す。

## Phase 5: 統合レポート（親）

Phase 2〜4 の結果を統合し、`references/checklists.md` の「Phase 5 レポートテンプレート」に従ってレポートを作成する。

1. Phase 2 の発見を、ファイル:行番号と種類で突き合わせる。両方の系統が出したものは確度が高い。
2. 片方の系統だけが出した Critical / High は、親がコードで経路を確かめる。確かめきれなければ、もう一方の系統の役割に
   「この経路が成立するか」だけを、該当の箇所を添えて確かめさせる（攻撃手順は求めない）。
3. 各 leg の役割・要求したモデル・実際のモデル（fallback の有無）を、レポートの「使用モデル」に書く。

出力先は user に確認する。

## セーフガード発動時の対処

| 状況 | 対処 |
|---|---|
| Claude の leg が fallback（`modelUsage` に要求していないモデル） | 結果は捨てずに残し、「fallback した」と記録する。カバーが欠けた範囲を `reviewer-gpt-focused` に追加で渡す |
| 親のセッションが fallback した | 以降の統合の判断の質が落ちる。user に伝え、新しいセッションで Phase 5 をやり直すかを確認する |
| GPT が脅威モデリングを拒否 | プロンプトを防御的な文脈（緩和策を導くための列挙）に書き換えて再試行。それでも拒否なら、親が影響と緩和策だけを列挙する |
| 特定の CWE パターンの検査がブロック | 検査項目を分割し、1 項目ずつ実行する |
| レポートの攻撃シナリオ記述がブロック | 「影響と緩和策」のみを記述し、攻撃手順は省略する |

## 正規プログラムの申請

より深いレビューが必要なら、各社の正規プログラムに申請する:

- **Anthropic Cyber Verification Program**: `portal.anthropic.com/programs/cvp`
  — Fable 5.1 / Opus 5.5 のセーフガードの緩和。承認後に始めた新しいセッションから効く
- **OpenAI Daybreak（Trusted Access for Cyber）**: `platform.openai.com/trusted-access`
  — 承認されたら、`codex exec` に `--cyber-access-program daybreak_blue` を付けて防御的な用途の制限を緩める
