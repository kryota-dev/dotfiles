---
name: github-sub-issues
description: This skill should be used when the user asks about "sub-issues", "sub-issue", "サブイシュー", "子イシュー", "issue type", "Issue Type", mentions "parent issue", "親issue", or discusses managing hierarchical GitHub issues using GraphQL API. Provides operations for listing, adding, removing sub-issues, and setting Issue Types.
version: 1.0.0
---

# GitHub Sub-issues & Issue Types Management Skill

GitHub の Sub-issue 機能および Issue Types 機能を GraphQL API で操作するスキルです。

## 重要: 必須HTTPヘッダー

Sub-issue と Issue Types の機能を使用するには、GraphQL API リクエストに特別なヘッダーが必要です：

| 機能 | 必須ヘッダー |
|------|-------------|
| Sub-issues | `-H "GraphQL-Features: sub_issues"` |
| Issue Types | `-H "GraphQL-Features: issue_types"` |

## Sub-issue 操作

### 1. Parent Issue の Sub-issues 一覧を取得

```bash
# Step 1: Parent Issue の Node ID を取得
PARENT_ID=$(gh api graphql -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: ISSUE_NUMBER) { id }
  }
}' --jq '.data.repository.issue.id')

# Step 2: Sub-issues を取得
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query="
query {
  node(id: \"$PARENT_ID\") {
    ... on Issue {
      number
      title
      subIssues(first: 50) {
        nodes {
          number
          title
          state
        }
      }
      subIssuesSummary {
        total
        completed
        percentCompleted
      }
    }
  }
}"
```

### 2. 既存の Issue を Sub-issue として追加

```bash
# Parent と Sub-issue の Node ID を取得
PARENT_ID=$(gh api graphql -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: PARENT_NUMBER) { id }
  }
}' --jq '.data.repository.issue.id')

CHILD_ID=$(gh api graphql -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: CHILD_NUMBER) { id }
  }
}' --jq '.data.repository.issue.id')

# Sub-issue として追加
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query="
mutation {
  addSubIssue(input: {
    issueId: \"$PARENT_ID\"
    subIssueId: \"$CHILD_ID\"
  }) {
    issue { number title }
    subIssue { number title }
  }
}"
```

### 3. Sub-issue を親から削除

```bash
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query="
mutation {
  removeSubIssue(input: {
    issueId: \"$PARENT_ID\"
    subIssueId: \"$CHILD_ID\"
  }) {
    issue { number title }
  }
}"
```

### 4. Issue の Parent Issue を取得

```bash
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query="
query {
  node(id: \"$ISSUE_NODE_ID\") {
    ... on Issue {
      number
      title
      parent {
        number
        title
      }
    }
  }
}"
```

## Issue Types 操作

### 1. Organization の Issue Types 一覧を取得

```bash
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query='
query {
  organization(login: "ORG_NAME") {
    issueTypes(first: 25) {
      nodes {
        id
        name
        description
        color
        isEnabled
      }
    }
  }
}'
```

**出力例:**
```json
{
  "data": {
    "organization": {
      "issueTypes": {
        "nodes": [
          {"id": "IT_kwDOxxxxxx", "name": "Task", "description": "A specific piece of work", "isEnabled": true},
          {"id": "IT_kwDOyyyyyy", "name": "Bug", "description": "An unexpected problem", "isEnabled": true},
          {"id": "IT_kwDOzzzzzz", "name": "Enhancement", "description": "A request or new functionality", "isEnabled": true},
          {"id": "IT_kwDOwwwwww", "name": "Epic", "description": "A larger requirement", "isEnabled": true}
        ]
      }
    }
  }
}
```

### 2. Issue の現在の Issue Type を取得

```bash
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: ISSUE_NUMBER) {
      number
      title
      issueType {
        id
        name
        description
      }
    }
  }
}'
```

### 3. Issue の Issue Type を設定・変更

```bash
# Step 1: Issue の Node ID を取得
ISSUE_NODE_ID=$(gh api graphql -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: ISSUE_NUMBER) { id }
  }
}' --jq '.data.repository.issue.id')

# Step 2: Issue Type を設定
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query="
mutation {
  updateIssueIssueType(input: {
    issueId: \"$ISSUE_NODE_ID\"
    issueTypeId: \"IT_kwDOxxxxxx\"
  }) {
    issue {
      number
      title
      issueType { name }
    }
  }
}"
```

## 実践例: Epic の全 Sub-issues に Issue Type を一括設定

```bash
#!/bin/bash
# Epic #123 の全 sub-issues を Enhancement に設定する例

OWNER="route06"
REPO="acsim"
EPIC_NUMBER=123
ISSUE_TYPE_NAME="Enhancement"

# 1. Epic の Node ID を取得
EPIC_ID=$(gh api graphql -f query="
query {
  repository(owner: \"$OWNER\", name: \"$REPO\") {
    issue(number: $EPIC_NUMBER) { id }
  }
}" --jq '.data.repository.issue.id')

# 2. Sub-issues の番号を取得
SUB_ISSUE_NUMBERS=$(gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query="
query {
  node(id: \"$EPIC_ID\") {
    ... on Issue {
      subIssues(first: 50) {
        nodes { number }
      }
    }
  }
}" --jq '.data.node.subIssues.nodes[].number')

# 3. Organization から Issue Type ID を取得
ORG="${OWNER}"
ISSUE_TYPE_ID=$(gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query="
query {
  organization(login: \"$ORG\") {
    issueTypes(first: 25) {
      nodes { id name isEnabled }
    }
  }
}" --jq ".data.organization.issueTypes.nodes[] | select(.name == \"$ISSUE_TYPE_NAME\" and .isEnabled == true) | .id")

echo "Epic ID: $EPIC_ID"
echo "Issue Type ID for $ISSUE_TYPE_NAME: $ISSUE_TYPE_ID"
echo ""

# 4. 各 sub-issue に Issue Type を設定
for issue_num in $SUB_ISSUE_NUMBERS; do
  echo "Setting Issue Type for #$issue_num..."

  # Issue の Node ID を取得
  NODE_ID=$(gh api graphql -f query="
  query {
    repository(owner: \"$OWNER\", name: \"$REPO\") {
      issue(number: $issue_num) { id }
    }
  }" --jq '.data.repository.issue.id')

  # Issue Type を設定
  RESULT=$(gh api graphql \
    -H "GraphQL-Features: issue_types" \
    -f query="
  mutation {
    updateIssueIssueType(input: {
      issueId: \"$NODE_ID\"
      issueTypeId: \"$ISSUE_TYPE_ID\"
    }) {
      issue {
        number
        issueType { name }
      }
    }
  }")

  echo "$RESULT" | jq -c '.data.updateIssueIssueType.issue'
done
```

## 制限事項

### Sub-issues
- 1つの Parent Issue に最大 100 個の Sub-issue を追加可能
- 最大 8 レベルまでネスト可能
- GraphQL API でのみ利用可能（REST API では一部のみ対応）

### Issue Types
- Organization でのみ利用可能（個人リポジトリでは使用不可）
- 1つの Organization に最大 25 個の Issue Types を作成可能
- Pull Request は非対応（Issue のみ）

## 参考リンク

- [Introducing sub-issues - The GitHub Blog](https://github.blog/engineering/architecture-optimization/introducing-sub-issues-enhancing-issue-management-on-github/)
- [Sub-issues Public Preview Discussion](https://github.com/orgs/community/discussions/148714)
- [Issue Types Public Preview Discussion](https://github.com/orgs/community/discussions/139933)
