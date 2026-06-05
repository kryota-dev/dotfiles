---
name: cc-security-review
description: |
  `cc-security-review` エージェントを起動して独立したコンテキストでセキュリティレビューを実行する。
  OWASP Top 10 および一般的なセキュリティベストプラクティスに基づいた分析を行う。
  トリガー: "cc-security-review", "ccでセキュリティレビュー", "脆弱性チェック", "セキュリティ分析", "security check"
  使用場面: (1) PR差分のセキュリティ分析 (2) コードベースのセキュリティ監査 (3) 特定ファイル/ディレクトリのセキュリティレビュー
argument-hint: "[PR番号 | PR URL | ブランチ名 | ファイルパス | ディレクトリパス]（省略可）"
---

# セキュリティレビュー

`cc-security-review` エージェント（`~/.claude/agents/cc-security-review.md`）を Agent ツールで起動し、セキュリティ専門の観点でコードレビューを実行する。OWASP Top 10 を含む包括的なチェックリストはエージェント定義の system prompt に内蔵されている。

## SSOT としての位置づけ

- **セキュリティレビューのペルソナ・OWASP チェックリスト・出力形式・「（未確認）」ルール・差分取得方法** は **エージェント定義** `~/.claude/agents/cc-security-review.md` が Single Source of Truth。本 skill では再定義しない。
- **本 skill** はレビュー対象の特定とエージェント起動を担うオーケストレーション層。
- `multi-review` skill から呼ばれる場合も、同じ `cc-security-review` エージェントを起動する。

## 引数の解釈

`$ARGUMENTS` を以下の優先順で判定する:

1. **PR番号** (`^\d+$` または `^#\d+$`)
2. **PR URL** (`github.com` を含む URL): URL から PR 番号を抽出
3. **ファイルパス** (`.` を含む拡張子)
4. **ディレクトリパス** (ディレクトリとして存在)
5. **ブランチ名** (上記に該当しない文字列): `<branch>...HEAD` の差分
6. **引数なし**: デフォルトブランチとの差分

## 実行手順

1. **引数を解析**してレビュー対象を特定する
2. **`cc-security-review` エージェントを起動**する（Agent ツール、`subagent_type: cc-security-review`）。プロンプトには「レビュー対象の指定 + 差分取得コマンド + 作業ディレクトリの絶対パス」を渡す。**差分はエージェント自身が取得**するため、本 skill 側で差分を取得・埋め込みしない。チェックリスト・出力形式もエージェント定義に内蔵されているため再掲しない。
3. **エージェントの最終メッセージ（分析結果）をユーザーに提示**する

### Agent ツール呼び出し例

```
Agent(
  subagent_type: "cc-security-review",
  description: "PR #123 のセキュリティレビュー",
  prompt: """
  GitHub PR #123（リポジトリ <owner>/<repo>）のコード差分をセキュリティ観点でレビューしてください。
  作業ディレクトリ: <repo の絶対パス>
  差分取得: `gh pr diff 123`

  認証・認可・入力処理・機密情報・外部通信・シリアライズに関わる変更を重点的に、周辺コードを Read/Grep で確認してから評価してください。
  """
)
```

- ディレクトリ全体の監査では差分の代わりに対象ディレクトリのパスを渡し、エージェントに Read/Glob/Grep で自律探索させる。
- `multi-review` から並列起動する場合は `run_in_background: true` を付ける。
- エージェントは Bash を `gh` / `git diff` / `grep` / `find` / `git log` / `cat` 等の読み取り専用にのみ使う。

## 注意事項

### コスト管理
- エージェントはメインセッションのモデルを継承（`model: inherit`）。ディレクトリ全体監査はターン数が増えコストが高い。対象を絞ることを推奨。

### エラーハンドリング
- 差分が空: エージェントがその旨を報告
- エージェントが途中でスキップ/失敗した場合: 1 回リトライ。再失敗ならその旨を報告

### チェックリストのカスタマイズ
- チェック項目を追加・変更する場合は **エージェント定義** `~/.claude/agents/cc-security-review.md`（ソース: `~/dotfiles/home/dot_claude/agents/cc-security-review.md`）の OWASP チェックリスト節を編集する。
