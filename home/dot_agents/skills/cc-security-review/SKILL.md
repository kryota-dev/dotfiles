---
name: cc-security-review
description: |
  Claude Code CLI（claude -p）を使用して独立したコンテキストでセキュリティレビューを実行する。
  OWASP Top 10 および一般的なセキュリティベストプラクティスに基づいた分析を行う。
  トリガー: "cc-security-review", "ccでセキュリティレビュー", "脆弱性チェック", "セキュリティ分析", "security check"
  使用場面: (1) PR差分のセキュリティ分析 (2) コードベースのセキュリティ監査 (3) 特定ファイル/ディレクトリのセキュリティレビュー
argument-hint: "[PR番号 | PR URL | ブランチ名 | ファイルパス | ディレクトリパス]（省略可）"
---

# Claude Code セキュリティレビュー

`claude -p`（非対話型モード）で別の Claude Code インスタンスを起動し、セキュリティ専門の観点でコードレビューを実行する。
OWASP Top 10 を含む包括的なセキュリティチェックリストが `--append-system-prompt-file` 経由で注入される。

## 起動オプション

| オプション | 値 | 理由 |
|------------|-----|------|
| `--allowedTools` | `"Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)"` | 読み取り + 機密情報パターン検索 |
| `--max-turns` | `10` | セキュリティ分析は広範囲のファイル参照が必要 |
| `--effort` | `max` | セキュリティレビューの品質を最大化 |
| `--output-format` | `text` | 人間が読みやすいテキスト形式 |
| `--append-system-prompt-file` | チェックリストファイルパス | OWASP Top 10 + 追加チェック項目を注入 |

**注意**: `--bare` は使わない（OAuth 認証が通らなくなる）。`--model` はデフォルト（ユーザー設定を継承）。

## チェックリストファイルの参照

`references/security-checklist.md` を `--append-system-prompt-file` で注入する。
パスは以下の優先順で解決する:

```bash
# 1. chezmoi 展開先（通常はこちら）
CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"

# 2. 存在しない場合はチェックリストなしで実行（警告を出力）
if [ ! -f "$CHECKLIST" ]; then
  echo "警告: セキュリティチェックリストが見つかりません: $CHECKLIST"
  echo "チェックリストなしでレビューを実行します"
  CHECKLIST=""
fi
```

## 引数の解釈

`$ARGUMENTS` を以下の優先順で判定する:

1. **PR番号** (`^\d+$` または `^#\d+$`): `gh pr diff <番号>` で差分取得
2. **PR URL** (`github.com` を含む URL): URL から PR 番号を抽出し、`gh pr diff` で差分取得
3. **ファイルパス** (`.` を含む拡張子): `cat <path>` でファイル内容を取得
4. **ディレクトリパス** (ディレクトリとして存在): そのディレクトリを対象にレビュー
5. **ブランチ名** (上記に該当しない文字列): `git diff <branch>...HEAD` で差分取得
6. **引数なし**: デフォルトブランチとの差分を取得

## プロンプトのルール

**重要**: `claude -p` に渡すプロンプトには、以下の指示を必ず含めること:

> 「確認や質問は不要です。具体的な分析結果と修正案を自主的に出力してください。」

## プロンプトテンプレート

```
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
```

## 実行手順

1. **引数を解析**してレビュー対象を特定する
2. **差分/対象を取得**する。差分が空の場合は「レビュー対象がありません」と報告して終了
3. **チェックリストファイルのパスを解決**する（上記「チェックリストファイルの参照」参照）
4. **プロンプトを構築**する（heredoc 使用。シェルのクォート問題を回避）
5. **`claude -p` を実行**する（Bash の timeout は **600000ms = 10分** に設定）
   - チェックリストが存在する場合: `--append-system-prompt-file` を付与
   - チェックリストが存在しない場合: プロンプト本文に基本的な OWASP 観点を含める
6. **結果をユーザーに表示**する

### コマンド例

```bash
# PR差分のセキュリティレビュー
CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"

gh pr diff 123 | claude -p \
  --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
  --max-turns 10 \
  --effort max \
  --output-format text \
  --append-system-prompt-file "$CHECKLIST" \
  "$(cat <<'PROMPT'
あなたはセキュリティエンジニアです。以下のコードをセキュリティ観点でレビューしてください。
...（プロンプトテンプレート）
PROMPT
)"

# デフォルトブランチとの差分（引数なし）
DEFAULT_BRANCH=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||')
git diff "${DEFAULT_BRANCH:-main}...HEAD" | claude -p \
  --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
  --max-turns 10 \
  --effort max \
  --output-format text \
  --append-system-prompt-file "$CHECKLIST" \
  "$(cat <<'PROMPT'
...（プロンプトテンプレート）
PROMPT
)"

# ディレクトリ全体のセキュリティ監査（ファイル指定不要、Read ツールで自律探索）
claude -p \
  --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
  --max-turns 15 \
  --effort max \
  --output-format text \
  --append-system-prompt-file "$CHECKLIST" \
  "$(cat <<'PROMPT'
src/features/auth/ ディレクトリのセキュリティ監査を実施してください。
...（プロンプトテンプレート）
PROMPT
)"
```

## 注意事項

### コスト管理

- デフォルトモデルで実行される。セキュリティレビューは `--max-turns 10` で通常のレビューより多くのターンを消費する
- コストを抑えたい場合は `--model sonnet` を追加する。ただし CLAUDE.md が大きいプロジェクトでは "Prompt is too long" エラーが発生する場合がある（sonnet の context window は 200k）
- ディレクトリ全体の監査（`--max-turns 15`）は特にコストが高い。対象を絞ることを推奨

### エラーハンドリング

- `claude` コマンドが見つからない場合: Claude Code CLI のインストールを案内
- 空の差分: 事前チェックで即座に報告
- タイムアウト: Bash の timeout 600000ms で保護
- "Prompt is too long": CLAUDE.md が大きいプロジェクトで sonnet を使用した場合に発生。モデルを変更するか、`--bare` + `ANTHROPIC_API_KEY` 環境変数を設定
- チェックリスト不在: 警告を出力し、基本的なセキュリティ観点のみでレビュー続行

### チェックリストのカスタマイズ

`references/security-checklist.md` を編集することで、チェック項目を追加・変更できる。
プロジェクト固有のセキュリティ要件がある場合は、プロジェクトの `.claude/skills/` にカスタマイズ版を配置することを推奨する。
