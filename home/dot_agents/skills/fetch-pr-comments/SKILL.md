---
name: fetch-pr-comments
description: "PRのコメント・レビューを取得する。引数: <pr-number-or-url>"
argument-hint: "[pr-number-or-url]"
---

# GitHub PR コメント取得タスク

## 概要

指定されたPull Requestの本文、レビュー、コメントを取得します。

## 引数

$ARGUMENTS

- PR番号（例: `8597`）
- またはPR URL（例: `https://github.com/<OWNER>/<REPO>/pull/8597`）

## 実行手順

### 1. 引数の解析

引数からPR情報を抽出してください：

- **PR URLの場合**: URLから `owner`, `repo`, `PR番号` を抽出
- **PR番号のみの場合**: 現在のリポジトリから `owner`, `repo` を取得（`git remote get-url origin` を使用）

### 2. PR本文の取得

```bash
gh pr view {PR番号} --json body,title,author --repo {owner}/{repo}
```

### 3. レビューの取得

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --paginate | \
  jq '[.[] | select(.body | length > 0) | {user: .user.login, state: .state, body: .body}]'
```

### 4. レビューコメントの取得（差分へのコメント）

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments --paginate | \
  jq '[.[] | {user: .user.login, path: .path, body: .body, line: .line}]'
```

### 5. Issueコメントの取得（PR全体へのコメント）

```bash
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate | \
  jq '[.[] | {user: .user.login, body: .body}]'
```

## 出力形式

取得した情報を以下の形式で整理して報告してください：

```markdown
## PR #{番号} の内容

### タイトル
{タイトル}

### 作者
{作者}

### PR本文
{本文}

---

## レビュー

### {ユーザー名} ({状態})
> {レビュー本文}

---

## レビューコメント（ファイル別）

### {ユーザー名} のコメント
**ファイル**: {path}:{line}
> {コメント本文}

---

## Issueコメント

### {ユーザー名}
> {コメント本文}
```
