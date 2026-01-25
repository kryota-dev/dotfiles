---
name: github-pr-comments
description: This skill should be used when the user asks to get PR comments, review comments, or discussions from a GitHub Pull Request, especially when filtering out bot comments like coderabbitai. Use when the user mentions "PRのコメント", "レビューコメント", "coderabbitaiを除外", "PRの議論", or asks to fetch comments from a specific PR URL or number.
version: 1.0.0
---

# GitHub PR Comments Fetching Skill

GitHub Pull Request のコメント・レビューを取得するスキルです。特に coderabbitai などのボットコメントを除外するフィルタリング方法を提供します。

## 重要: Claude Code での jq 使用時の注意点

### `!=` 演算子の問題

Claude Code の Bash ツールでは、`!` が履歴展開として解釈され、`\!` にエスケープされてしまいます。

**NG（エラーになる）:**
```bash
jq '.[] | select(.user.login != "coderabbitai")'
```

**OK（代替パターン）:**
```bash
# パターン1: == ... | not を使用
jq '.[] | select(.user.login == "coderabbitai" | not)'

# パターン2: startswith と not を使用（推奨）
jq '.[] | select(.user.login | startswith("coderabbitai") | not)'
```

### ボットのユーザー名

GitHub Apps のユーザー名は `[bot]` サフィックスが付きます：
- `coderabbitai[bot]`
- `github-actions[bot]`
- `dependabot[bot]`

`startswith()` を使うことで、サフィックスを気にせずフィルタリングできます。

## PR 情報取得コマンド

### 1. PR 本文の取得

```bash
gh pr view {PR番号} --json body,title,author --repo {owner}/{repo}
```

### 2. レビュー（承認・コメント）の取得（coderabbitai 除外）

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --paginate > /tmp/reviews.json && \
cat /tmp/reviews.json | jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | select(.body | length > 0) | {user: .user.login, state: .state, body: .body}]'
```

**取得できる情報:**
- `user`: レビュアー名
- `state`: `APPROVED`, `COMMENTED`, `CHANGES_REQUESTED` など
- `body`: レビュー本文

### 3. レビューコメント（差分へのインラインコメント）の取得（coderabbitai 除外）

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments --paginate > /tmp/review_comments.json && \
cat /tmp/review_comments.json | jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, path: .path, body: .body, line: .line}]'
```

**取得できる情報:**
- `user`: コメント者
- `path`: ファイルパス
- `body`: コメント本文
- `line`: 行番号

### 4. Issue コメント（PR の一般的なコメント）の取得（coderabbitai 除外）

```bash
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate > /tmp/issue_comments.json && \
cat /tmp/issue_comments.json | jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, body: .body}]'
```

**取得できる情報:**
- `user`: コメント者
- `body`: コメント本文

## 複数ボットを除外する場合

```bash
jq '[.[] | select(
  (.user.login | startswith("coderabbitai") | not) and
  (.user.login | startswith("github-actions") | not) and
  (.user.login | startswith("dependabot") | not)
)]'
```

## 完全な使用例

### PR番号から全コメントを取得（coderabbitai 除外）

```bash
OWNER="route06"
REPO="acsim"
PR_NUMBER=8597

# PR 本文
gh pr view $PR_NUMBER --json body,title,author --repo $OWNER/$REPO

# レビュー
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | select(.body | length > 0) | {user: .user.login, state: .state, body: .body}]'

# レビューコメント（差分へのコメント）
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, path: .path, body: .body, line: .line}]'

# Issue コメント
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, body: .body}]'
```

## GitHub API エンドポイント一覧

| 情報 | エンドポイント | 説明 |
|------|---------------|------|
| レビュー | `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews` | 承認・変更要求・コメントなど |
| レビューコメント | `GET /repos/{owner}/{repo}/pulls/{pull_number}/comments` | 差分への行コメント |
| Issue コメント | `GET /repos/{owner}/{repo}/issues/{issue_number}/comments` | PR 全体へのコメント |

## 注意事項

1. **`gh pr view --comments` は使用しない**: プレーンテキスト形式で出力されるため、jq でフィルタリングできない
2. **`--paginate` オプション**: 結果が多い場合のページネーション対応に必須
3. **空の body を除外**: レビューでは空の body が多いため、`select(.body | length > 0)` を追加するとよい
4. **一時ファイル経由**: パイプで直接 jq に渡すと問題が発生する場合、一時ファイル経由で処理する
