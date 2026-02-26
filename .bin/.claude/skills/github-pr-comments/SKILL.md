---
name: github-pr-comments
description: GitHub PRのコメント・レビュー取得・作成。PRコメント、レビューコメント、pending review、coderabbitai除外フィルタリングに対応。PR URL や番号を指定して操作する。
version: 2.0.0
---

# GitHub PR Comments Skill

GitHub Pull Request のコメント・レビューの取得と作成を行うスキルです。ボットコメント（coderabbitai 等）の除外フィルタリング、および Pending Review へのレビューコメント追加（REST API / GraphQL）に対応しています。

## 重要: Claude Code での jq 使用時の注意点

### jq の否定演算子の問題

Claude Code の Bash ツールでは、`!` が履歴展開として解釈されるため、jq の否定比較演算子は使用できません。

代わりに以下の代替パターンを使用してください:

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
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | select(.body | length > 0) | {user: .user.login, state: .state, body: .body}]'
```

**取得できる情報:**
- `user`: レビュアー名
- `state`: `APPROVED`, `COMMENTED`, `CHANGES_REQUESTED` など
- `body`: レビュー本文

### 3. レビューコメント（差分へのインラインコメント）の取得（coderabbitai 除外）

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, path: .path, body: .body, line: .line}]'
```

**取得できる情報:**
- `user`: コメント者
- `path`: ファイルパス
- `body`: コメント本文
- `line`: 行番号

### 4. Issue コメント（PR の一般的なコメント）の取得（coderabbitai 除外）

```bash
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate | \
  jq '[.[] | select(.user.login | startswith("coderabbitai") | not) | {user: .user.login, body: .body}]'
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
OWNER="<OWNER>"
REPO="<REPO>"
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
| レビューコメント一覧 | `GET /repos/{owner}/{repo}/pulls/{pull_number}/comments` | 差分への行コメント（一覧） |
| レビューコメント個別 | `GET /repos/{owner}/{repo}/pulls/comments/{comment_id}` | 個別コメントの取得・更新・削除 |
| Issue コメント | `GET /repos/{owner}/{repo}/issues/{issue_number}/comments` | PR 全体へのコメント |

> **注意**: レビューコメントの個別操作（取得・更新・削除）は `/pulls/comments/{comment_id}` を使用する。`/pulls/{pull_number}/comments/{comment_id}` ではない（404 エラーになる）。

## PR レビューコメントの作成（Pending Review）

### 概要

PR にレビューコメントを作成する際、pending（保留）状態で追加し、後からまとめて submit できる。

### 署名ルール

Claude がレビューコメントを作成する際は、コメント末尾に必ず署名を付与する。署名はMarkdownの斜体で記述する。

```
コメント本文

---
*Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>*
```

> **注意**: 署名のモデル名は実際に使用しているモデル名に合わせること。

### 1. 既存の Pending Review を確認する

1つのPRに対して、ユーザーは **1つしか pending review を持てない**。新規作成前に必ず確認する。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews \
  --jq '.[] | select(.state == "PENDING") | {id, state, user: .user.login}'
```

### 2. Pending Review が存在しない場合: 新規作成

`event` フィールドを **省略** すると pending 状態になる。

> **注意**: `event: "PENDING"` を明示的に指定すると `422 Unprocessable Entity` エラーになる。省略が正解。

```bash
cat <<'PAYLOAD' | gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --method POST --input -
{
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[imo] コメント本文\n\n---\n*Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>*"
    }
  ]
}
PAYLOAD
```

### 3. Pending Review が既に存在する場合: GraphQL でコメント追加

REST API では既存の pending review にコメントを追加できない（パラメータ制約により `422` エラーになる）。
**GraphQL API の `addPullRequestReviewThread` mutation を使用する。**

#### 3.1. Pending Review の Node ID を取得

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

レスポンス例:
```json
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviews": {
          "nodes": [
            {
              "id": "PRR_kwDOxxxxxxx",
              "state": "PENDING",
              "author": { "login": "username" }
            }
          ]
        }
      }
    }
  }
}
```

#### 3.2. コメントを追加

取得した `id`（例: `PRR_kwDOxxxxxxx`）を `pullRequestReviewId` に指定する。

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
      "body": "[imo] コメント本文\n\n---\n*Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>*"
    }
  }
}
GQL
```

### 4. レビューコメントの個別更新

submit 済みのレビューコメントを更新する場合は、REST API の `PATCH` を使用する。

> **注意**: エンドポイントは `/pulls/comments/{comment_id}` であり、`/pulls/{pull_number}/comments/{comment_id}` ではない（後者は 404 エラーになる）。

```bash
# コメント ID の確認
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments --paginate | \
  jq '[.[] | select(.user.login == "{自分のユーザー名}") | {id, path: .path, body: .body[:60]}]'

# コメントの更新
cat <<'BODY' | gh api repos/{owner}/{repo}/pulls/comments/{comment_id} --method PATCH --input -
{
  "body": "更新後のコメント本文\n\n---\n*Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>*"
}
BODY
```

### 5. Pending Review の確認（既存コメント一覧）

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews/{review_id}/comments \
  --jq '.[] | {path: .path, body: .body[:80]}'
```

### レビューコメントの作成フロー（まとめ）

```
1. 既存の pending review があるか確認
   ├── なし → REST API で新規 pending review + コメントを作成
   └── あり → GraphQL で node ID を取得
              → addPullRequestReviewThread でコメントを追加
2. 必要に応じてコメントを追加（3.2 を繰り返す）
3. submit はユーザーに委ねる（または submit API を呼ぶ）
4. submit 後にコメントを修正する場合は PATCH で個別更新
※ すべてのコメントに署名を付与すること
```

## 注意事項

1. **`gh pr view --comments` は使用しない**: プレーンテキスト形式で出力されるため、jq でフィルタリングできない
2. **`--paginate` オプション**: 結果が多い場合のページネーション対応に必須
3. **空の body を除外**: レビューでは空の body が多いため、`select(.body | length > 0)` を追加するとよい
4. **Pending Review は1ユーザー1PRにつき1つ**: 既存の pending review がある状態で新規作成しようとすると `422` エラーになる
5. **REST API の `event: "PENDING"` は無効**: pending review を作成するには `event` フィールドを省略する
6. **既存 pending review へのコメント追加は GraphQL のみ**: REST API では対応できないため、`addPullRequestReviewThread` mutation を使用する
7. **レビューコメント個別操作のエンドポイント**: `/pulls/comments/{comment_id}` を使用する。`/pulls/{pull_number}/comments/{comment_id}` は 404 エラーになる
8. **署名の付与**: Claude がコメントを作成・更新する際は、末尾に区切り線（`---`）と斜体の署名 `*Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>*` を付与する
