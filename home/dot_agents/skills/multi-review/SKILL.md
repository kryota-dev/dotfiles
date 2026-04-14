---
name: multi-review
description: |
  3つのレビューツール（Claude Code, Claude Code Security, Codex）を並列でバックグラウンド実行し、
  結果を統合サマリーにまとめた上で、GitHub PR に Pending Review としてインラインコメントを投稿する。
  PRの包括的レビューを一度に実行したい場合に使用する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー", "3ツールレビュー"
  使用場面: PRのコードレビュー・セキュリティレビュー・Codexレビューを一括で実行したい場合
argument-hint: "<PR番号> (#付きまたは数字のみ)"
---

# Multi Review

3つのレビューツールを並列でバックグラウンド実行し、結果を統合サマリーにまとめる。
統合結果をユーザーに提示した後、承認があれば GitHub PR に Pending Review としてインラインコメントを投稿する。

```
引数解析 → 差分取得 → 3ツール並列実行 → 結果収集 → 統合サマリー → ユーザー確認 → Pending Review 投稿
```

## 引数の解釈

以下の優先順で判定する:

1. **PR番号** (`^\d+$` または `^#\d+$`): `gh pr diff <番号>` で差分取得
2. **PR URL** (`github.com` を含む URL): URL から PR 番号を抽出し、`gh pr diff` で差分取得
3. **引数なし**: 現在のブランチに関連する PR を `gh pr view --json number --jq '.number'` で自動検出

## 各レビューツールの設定

| ツール | コマンド | 主要オプション | タイムアウト |
|--------|---------|---------------|------------|
| cc-review | `claude -p` | `--allowedTools "Read,Glob,Grep"`, `--max-turns 10`, `--effort max` | 300000ms |
| cc-security-review | `claude -p` | `--allowedTools "Read,Glob,Grep,Bash(grep *),..."`, `--max-turns 10`, `--effort max`, `--append-system-prompt-file` | 600000ms |
| codex | `codex exec` | `--full-auto`, `--sandbox read-only` | 300000ms |

**注意**: `--bare` は使わない（OAuth 認証が通らなくなる）。`--model` はデフォルト（ユーザー設定を継承）。

## 実行手順

### Phase 1: 準備

1. **引数を解析**してPR番号を特定する
2. **差分を取得**する: `gh pr diff <PR番号>` を実行。差分が空の場合は「レビュー対象の差分がありません」と報告して終了
3. **リポジトリ情報を取得**する: `gh repo view --json nameWithOwner --jq '.nameWithOwner'` で owner/repo を取得
4. **セキュリティチェックリストのパスを解決**する:
   ```bash
   CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"
   ```

### Phase 2: 並列実行

3つのツールを **同一メッセージ内の独立した Bash ツール呼び出し** として、すべて `run_in_background: true` で並列発行する。

#### cc-review

```bash
gh pr diff <PR番号> | claude -p \
  --allowedTools "Read,Glob,Grep" \
  --max-turns 10 \
  --effort max \
  --output-format text \
  "$(cat <<'PROMPT'
あなたはシニアソフトウェアエンジニアです。以下のコード差分をレビューしてください。

## レビュー観点

1. バグ・論理エラー: 明らかなバグ、エッジケースの未処理、オフバイワンエラー
2. 設計・アーキテクチャ: 既存パターンとの一貫性、適切な抽象化、責務の分離
3. 可読性・保守性: 命名の適切さ、コメントの過不足、コード複雑度
4. エラーハンドリング: 例外処理の網羅性、エラーメッセージの適切さ
5. パフォーマンス: N+1問題、不要な計算・再描画、メモリリーク
6. テスト: テストの有無、カバレッジ、エッジケースのテスト

## 出力形式

各指摘を以下のカテゴリで分類:
- [MUST] 修正必須（バグ、セキュリティ、設計違反）
- [SHOULD] 修正推奨（品質向上、可読性改善）
- [NITS] 軽微な提案（命名、フォーマット）
- [GOOD] 良い実装（称賛すべき点）

各指摘に、ファイル名:行番号、問題の説明、具体的な修正案を含めてください。
最後にレビューサマリー（カテゴリ別件数 + 総合評価）を付けてください。

確認や質問は不要です。具体的な指摘と修正案を自主的に出力してください。
PROMPT
)"
```

#### cc-security-review

```bash
CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"

if [ -f "$CHECKLIST" ]; then
  gh pr diff <PR番号> | claude -p \
    --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
    --max-turns 10 \
    --effort max \
    --output-format text \
    --append-system-prompt-file "$CHECKLIST" \
    "$(cat <<'PROMPT'
あなたはセキュリティエンジニアです。以下のコードをセキュリティ観点でレビューしてください。
システムプロンプトで提供されたセキュリティチェックリストに基づいて網羅的に分析してください。

## 分析の進め方

1. まず差分を読み、変更の全体像を把握する
2. セキュリティ上重要な変更を特定する（認証、認可、入力処理、機密情報、外部通信）
3. 必要に応じて Read ツールで周辺コードを参照し、コンテキストを補完する
4. 各脆弱性について、実際の攻撃経路が存在するかを評価する

## 出力形式

### セキュリティサマリー
- 総合リスクレベル: Critical / High / Medium / Low
- 検出された脆弱性数: N件（重大度別）

### 脆弱性一覧
（チェックリストの出力フォーマットに従う）

### 良い実装
セキュリティ上、適切に実装されている点を列挙

### 推奨事項
追加で検討すべきセキュリティ改善策

確認や質問は不要です。具体的な分析結果と修正案を自主的に出力してください。
PROMPT
)"
else
  gh pr diff <PR番号> | claude -p \
    --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
    --max-turns 10 \
    --effort max \
    --output-format text \
    "$(cat <<'PROMPT'
あなたはセキュリティエンジニアです。以下のコードをセキュリティ観点でレビューしてください。
OWASP Top 10 を含む包括的なセキュリティ観点で分析してください。
（上記と同じ分析の進め方・出力形式）
確認や質問は不要です。具体的な分析結果と修正案を自主的に出力してください。
PROMPT
)"
fi
```

#### codex

```bash
codex exec \
  --full-auto \
  --sandbox read-only \
  --cd $(pwd) \
  "$(cat <<'PROMPT'
PR #<PR番号> のコード差分をレビューしてください。
まず `gh pr diff <PR番号>` で差分を取得し、以下の観点で分析してください。

## レビュー観点
1. バグ・論理エラー
2. 設計・アーキテクチャの一貫性
3. 可読性・保守性
4. エラーハンドリング
5. パフォーマンス
6. テストの十分性

各指摘を以下のカテゴリで分類:
- [MUST] 修正必須
- [SHOULD] 修正推奨
- [NITS] 軽微な提案
- [GOOD] 良い実装

確認や質問は不要です。具体的な提案・修正案・コード例まで自主的に出力してください。
PROMPT
)"
```

### Phase 3: 結果収集と統合

1. 各バックグラウンドタスクの完了通知を待つ
2. 完了したタスクの出力ファイルを Read で読み取る
3. **失敗したツールがあればリトライ**（最大1回）。リトライも失敗した場合は該当ツールをスキップ
4. 全ツールの結果を統合サマリーにまとめる

#### 統合サマリーのフォーマット

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価

| カテゴリ | cc-review | cc-security-review | codex |
|---------|-----------|-------------------|-------|
| MUST    | N件       | N件               | N件   |
| SHOULD  | N件       | N件               | N件   |
| NITS    | N件       | N件               | N件   |
| GOOD    | N件       | N件               | N件   |

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

### Phase 4: ユーザー確認と PR コメント投稿

1. 統合サマリーをユーザーに表示する
2. **ユーザーに確認する**: 「Pending Review としてインラインコメントを投稿しますか？」
   - `notify` コマンドで通知音を鳴らす
3. **承認された場合**: Pending Review を作成してインラインコメントを投稿する（下記「PR コメント投稿手順」に従う）
4. **拒否された場合**: 統合サマリーの表示のみで終了

## PR コメント投稿手順

### 署名ルール

Claude がレビューコメントを作成する際は、コメント末尾に必ず署名を付与する:

```
コメント本文

---
*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*
```

### 1. 既存の Pending Review を確認

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews \
  --jq '.[] | select(.state == "PENDING") | {id, state, user: .user.login}'
```

### 2. Pending Review がない場合: 新規作成

`event` フィールドを **省略** すると pending 状態になる（`event: "PENDING"` を明示的に指定すると `422` エラー）。

```bash
cat <<'PAYLOAD' | gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --method POST --input -
{
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[imo] コメント本文\n\n---\n*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*"
    }
  ]
}
PAYLOAD
```

### 3. Pending Review が既にある場合: GraphQL でコメント追加

REST API では既存の pending review にコメントを追加できないため、GraphQL API を使用する。

#### 3.1. Node ID を取得

```bash
gh api graphql -f query='
{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {PR番号}) {
      reviews(states: PENDING, first: 5) {
        nodes {
          id
          state
          author { login }
        }
      }
    }
  }
}'
```

#### 3.2. コメントを追加

```bash
cat <<'GQL' | gh api graphql --input -
{
  "query": "mutation($input: AddPullRequestReviewThreadInput!) { addPullRequestReviewThread(input: $input) { thread { id comments(first: 1) { nodes { id body } } } } }",
  "variables": {
    "input": {
      "pullRequestReviewId": "PRR_kwDOxxxxxxx",
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[imo] コメント本文\n\n---\n*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*"
    }
  }
}
GQL
```

### コメント対象の選定

- **[MUST]** と **[SHOULD]** の指摘をインラインコメントとして投稿する
- **[GOOD]** は称賛コメントとして投稿する（数が多い場合は代表的なものに絞る）
- **[NITS]** は投稿するかどうかをユーザー判断に委ねる
- submit はユーザーに委ねる（Pending 状態のまま）

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| `claude` コマンド未発見 | Claude Code CLI のインストールを案内して終了 |
| `codex` コマンド未発見 | 警告を出力し、残り2ツール（cc-review, cc-security-review）のみで続行 |
| 個別ツールのタイムアウト | 1回リトライ。2回目も失敗なら該当ツールをスキップ |
| 空の差分 | 「レビュー対象の差分がありません」と報告して終了 |
| PR番号が無効 | エラーメッセージを表示して終了 |
| `Reached max turns` エラー | `--max-turns` を増やしてリトライ |
| Pending Review 作成失敗 | エラー内容を表示してユーザーに報告 |
| 全ツール失敗 | エラーサマリーを出力して終了 |

## 注意事項

### コスト管理

- 3ツール並列実行は合計コストが高い（Claude Code 2セッション + Codex 1セッション）
- コストを抑えたい場合は個別スキル（`cc-review` 等）を直接使用することを推奨

### jq の否定演算子

Claude Code の Bash ツールでは `!` が履歴展開として解釈されるため、jq の否定比較演算子は使用できない。代わりに `select(.user.login | startswith("coderabbitai") | not)` パターンを使用する。

### セキュリティチェックリスト

`$HOME/.agents/skills/cc-security-review/references/security-checklist.md` を参照する。ファイルが存在しない場合はチェックリストなしでレビューを続行する。
