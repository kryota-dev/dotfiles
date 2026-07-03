---
name: github-sub-issues
description: This skill should be used when the user asks about "sub-issues", "sub-issue", "サブイシュー", "子イシュー", "issue type", "Issue Type", mentions "parent issue", "親issue", or discusses managing hierarchical GitHub issues. Provides operations for listing, adding, removing sub-issues, and setting Issue Types.
version: 2.0.0
---

# GitHub Sub-issues & Issue Types Management Skill

GitHub の Sub-issue 機能および Issue Types 機能を、gh CLI 2.94.0+ で first-class 化された
native コマンド（`gh issue create/edit/view`）で操作するスキルです。従来の `gh api graphql`
ワークアラウンド（`GraphQL-Features` ヘッダー・Node ID 解決）は不要になりました。

## 前提と graceful fallback

| 機能 | 必要な gh バージョン | 必要な GitHub 環境 |
|------|---------------------|--------------------|
| Sub-issues（`--parent` / `--add-sub-issue` / `--remove-sub-issue`） | gh 2.94.0+ | GitHub.com / GHES 3.17+ |
| Issue Types（`--type`） | gh 2.94.0+ | GitHub.com / GHES 3.17+ |
| Relationships（`--blocked-by` / `--blocking`） | gh 2.94.0+ | GitHub.com / GHES 3.19+ |

上記を満たさない環境（古い gh、または GHES 3.17 未満）では native フラグが使えないため、
末尾の「Fallback: GraphQL API」に記載した `gh api graphql`（`GraphQL-Features` ヘッダー付き）
へフォールバックする。

## Sub-issue 操作

### 1. Parent Issue の Sub-issues 一覧を取得

```bash
# subIssues と subIssuesSummary を native に取得（Node ID 解決は不要）
gh issue view ISSUE_NUMBER --repo OWNER/REPO \
  --json number,title,subIssues,subIssuesSummary \
  --jq '{number, title, summary: .subIssuesSummary, subIssues: [.subIssues.nodes[] | {number, title, state}]}'
```

### 2. 既存の Issue を Sub-issue として追加

```bash
# Parent（PARENT_NUMBER）に Child（CHILD_NUMBER）を sub-issue として追加
# カンマ区切りで複数同時に追加可能（番号でも URL でも可）
gh issue edit PARENT_NUMBER --repo OWNER/REPO --add-sub-issue CHILD_NUMBER

# 例: 複数追加
gh issue edit 100 --repo OWNER/REPO --add-sub-issue 123,124

# Child 側から親を設定しても等価（--parent は sub-issue 関係の裏返し）
gh issue edit CHILD_NUMBER --repo OWNER/REPO --parent PARENT_NUMBER
```

### 3. Sub-issue を親から削除

```bash
gh issue edit PARENT_NUMBER --repo OWNER/REPO --remove-sub-issue CHILD_NUMBER

# Child 側から親を外しても等価
gh issue edit CHILD_NUMBER --repo OWNER/REPO --remove-parent
```

### 4. Issue の Parent Issue を取得

```bash
gh issue view ISSUE_NUMBER --repo OWNER/REPO --json number,title,parent \
  --jq '{number, title, parent}'
```

## Issue Types 操作

### 1. Organization の Issue Types 一覧を取得

Issue Type 名の列挙に相当する native コマンドは存在しないため、この確認のみ GraphQL を使用する。
`gh issue edit --type <name>` は名前で設定するため、通常この一覧取得は「利用可能な type 名の確認」
にのみ必要。

```bash
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query='
query {
  organization(login: "ORG_NAME") {
    issueTypes(first: 25) {
      nodes {
        name
        description
        isEnabled
      }
    }
  }
}' --jq '.data.organization.issueTypes.nodes[] | select(.isEnabled == true) | "\(.name): \(.description // "")"'
```

### 2. Issue の現在の Issue Type を取得

```bash
gh issue view ISSUE_NUMBER --repo OWNER/REPO --json number,title,issueType \
  --jq '{number, title, issueType: .issueType.name}'
```

### 3. Issue の Issue Type を設定・変更

```bash
# 名前で直接指定（Node ID / Issue Type ID の解決は不要）
gh issue edit ISSUE_NUMBER --repo OWNER/REPO --type "Enhancement"

# Issue Type を外す
gh issue edit ISSUE_NUMBER --repo OWNER/REPO --remove-type
```

## 実践例: Epic の全 Sub-issues に Issue Type を一括設定

```bash
#!/bin/bash
# Epic #123 の全 sub-issues を Enhancement に設定する例

REPO="<OWNER>/<REPO>"
EPIC_NUMBER=123
ISSUE_TYPE_NAME="Enhancement"

# 1. Sub-issues の番号を native に取得（Node ID 解決は不要）
SUB_ISSUE_NUMBERS=$(gh issue view "$EPIC_NUMBER" --repo "$REPO" \
  --json subIssues --jq '.subIssues.nodes[].number')

# 2. 各 sub-issue に Issue Type を名前で設定
for issue_num in $SUB_ISSUE_NUMBERS; do
  echo "Setting Issue Type '$ISSUE_TYPE_NAME' for #$issue_num..."
  gh issue edit "$issue_num" --repo "$REPO" --type "$ISSUE_TYPE_NAME"
done
```

## Fallback: GraphQL API（native が使えない環境向け）

古い gh（2.94.0 未満）や GHES 3.17 未満では native フラグが使えないため、従来どおり
`gh api graphql` に `GraphQL-Features: sub_issues` / `issue_types` ヘッダーを付けて操作する。
Node ID は `gh api graphql` の `repository(...).issue(number:).id` で取得する。

```bash
# Sub-issue 追加（fallback）
PARENT_ID=$(gh api graphql -f query='
query { repository(owner: "OWNER", name: "REPO") { issue(number: PARENT_NUMBER) { id } } }' \
  --jq '.data.repository.issue.id')
CHILD_ID=$(gh api graphql -f query='
query { repository(owner: "OWNER", name: "REPO") { issue(number: CHILD_NUMBER) { id } } }' \
  --jq '.data.repository.issue.id')
gh api graphql -H "GraphQL-Features: sub_issues" -f query="
mutation {
  addSubIssue(input: { issueId: \"$PARENT_ID\", subIssueId: \"$CHILD_ID\" }) {
    issue { number title }
  }
}"

# Sub-issue 削除は removeSubIssue、Issue Type 設定は updateIssueIssueType（要 issue_types ヘッダー）を使う。
```

## 制限事項

### Sub-issues
- 1つの Parent Issue に最大 100 個の Sub-issue を追加可能
- 最大 8 レベルまでネスト可能
- native コマンドは gh 2.94.0+ かつ GitHub.com / GHES 3.17+ が必要（それ未満は GraphQL fallback）

### Issue Types
- Organization でのみ利用可能（個人リポジトリでは使用不可）
- 1つの Organization に最大 25 個の Issue Types を作成可能
- Pull Request は非対応（Issue のみ）
- 利用可能な type 名の列挙は native 未対応のため GraphQL を使用する

## 参考リンク

- [Introducing sub-issues - The GitHub Blog](https://github.blog/engineering/architecture-optimization/introducing-sub-issues-enhancing-issue-management-on-github/)
- [Sub-issues Public Preview Discussion](https://github.com/orgs/community/discussions/148714)
- [Issue Types Public Preview Discussion](https://github.com/orgs/community/discussions/139933)
