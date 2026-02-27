# GitHub Projects Management Skill

GitHub Projects (ProjectV2) の操作を行うスキルです。issueのステータス管理やプロジェクト情報の取得を行います。

## 使用可能な操作

### 1. プロジェクト一覧の取得

組織のプロジェクト一覧を取得します。

```bash
gh project list --owner <org-name> --format json | jq '.projects[] | {number: .number, id: .id, title: .title}'
```

### 2. プロジェクトのフィールド情報取得

プロジェクトのStatusフィールドとその選択肢を取得します。

```bash
gh api graphql -f query='
query {
  node(id: "<PROJECT_ID>") {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}' --jq '.data.node.fields.nodes[] | select(.name == "Status")'
```

**出力例:**
```json
{
  "id": "PVTSSF_xxxxx",
  "name": "Status",
  "options": [
    {"id": "485d3f18", "name": "Icebox"},
    {"id": "f75ad846", "name": "New"},
    {"id": "82702c42", "name": "Backlog"},
    {"id": "6130c3ec", "name": "In Progress"},
    {"id": "3b3bbb74", "name": "Review"},
    {"id": "98236657", "name": "Done"}
  ]
}
```

### 3. issueが属するプロジェクトアイテムの取得

特定のissueがどのプロジェクトに属しているか、そのステータスを取得します。

```bash
# 方法1: gh issue viewコマンド（簡易版）
gh issue view <issue-number> --json projectItems --jq '.projectItems[] | select(.title == "<PROJECT_NAME>") | {id: .id, status: .status.name}'

# 方法2: GraphQL API（詳細版）
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    issue(number: <ISSUE_NUMBER>) {
      projectItems(first: 10) {
        nodes {
          id
          project {
            title
            id
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field {
                  ... on ProjectV2SingleSelectField {
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.issue.projectItems.nodes[] | select(.project.title == "<PROJECT_NAME>") | .id'
```

### 4. プロジェクトアイテムのステータス更新

issueのプロジェクト内でのステータスを更新します。

**必要な情報:**
- `projectId`: プロジェクトのID（例: `PVT_kwDOA7Zc084AqojJ`）
- `itemId`: プロジェクトアイテムのID（例: `PVTI_lADOA7Zc084AqojJzgjM7PE`）
- `fieldId`: Statusフィールドのid（例: `PVTSSF_lADOA7Zc084AqojJzgh2QOQ`）
- `singleSelectOptionId`: 更新先のステータスのOption ID（例: `6130c3ec`）

```bash
gh api graphql -f query='
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "<PROJECT_ID>"
    itemId: "<ITEM_ID>"
    fieldId: "<FIELD_ID>"
    value: {
      singleSelectOptionId: "<OPTION_ID>"
    }
  }) {
    projectV2Item {
      id
    }
  }
}'
```

## 実行例: issueのステータスを"In Progress"に変更

```bash
# Step 1: プロジェクトIDを取得
PROJECT_ID=$(gh project list --owner <org-name> --format json | jq -r '.projects[] | select(.title == "<project-name>") | .id')

# Step 2: Statusフィールド情報を取得
FIELD_INFO=$(gh api graphql -f query="
query {
  node(id: \"$PROJECT_ID\") {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}" --jq '.data.node.fields.nodes[] | select(.name == "Status")')

FIELD_ID=$(echo "$FIELD_INFO" | jq -r '.id')
OPTION_ID=$(echo "$FIELD_INFO" | jq -r '.options[] | select(.name == "In Progress") | .id')

# Step 3: issueのProject Item IDを取得
ITEM_ID=$(gh api graphql -f query="
query {
  repository(owner: \"<org-name>\", name: \"<repo-name>\") {
    issue(number: <issue-number>) {
      projectItems(first: 10) {
        nodes {
          id
          project {
            title
          }
        }
      }
    }
  }
}" --jq '.data.repository.issue.projectItems.nodes[] | select(.project.title == "<project-name>") | .id')

# Step 4: ステータスを更新
gh api graphql -f query="
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: \"$PROJECT_ID\"
    itemId: \"$ITEM_ID\"
    fieldId: \"$FIELD_ID\"
    value: {
      singleSelectOptionId: \"$OPTION_ID\"
    }
  }) {
    projectV2Item {
      id
    }
  }
}"
```

## 複数issueのステータスを一括更新

```bash
#!/bin/bash

# 設定
ORG="<org-name>"
REPO="<repo-name>"
PROJECT_NAME="<project-name>"
TARGET_STATUS="In Progress"
ISSUE_NUMBERS=(100 101 102 103 104 105)

# プロジェクトIDを取得
PROJECT_ID=$(gh project list --owner $ORG --format json | jq -r ".projects[] | select(.title == \"$PROJECT_NAME\") | .id")

# Statusフィールド情報を取得
FIELD_INFO=$(gh api graphql -f query="
query {
  node(id: \"$PROJECT_ID\") {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}" --jq '.data.node.fields.nodes[] | select(.name == "Status")')

FIELD_ID=$(echo "$FIELD_INFO" | jq -r '.id')
OPTION_ID=$(echo "$FIELD_INFO" | jq -r ".options[] | select(.name == \"$TARGET_STATUS\") | .id")

echo "Project ID: $PROJECT_ID"
echo "Field ID: $FIELD_ID"
echo "Option ID for '$TARGET_STATUS': $OPTION_ID"
echo ""

# 各issueを更新
for issue_num in "${ISSUE_NUMBERS[@]}"; do
  echo "Processing issue #$issue_num..."

  # Project Item IDを取得
  ITEM_ID=$(gh api graphql -f query="
  query {
    repository(owner: \"$ORG\", name: \"$REPO\") {
      issue(number: $issue_num) {
        projectItems(first: 10) {
          nodes {
            id
            project {
              title
            }
          }
        }
      }
    }
  }" --jq ".data.repository.issue.projectItems.nodes[] | select(.project.title == \"$PROJECT_NAME\") | .id")

  if [ -n "$ITEM_ID" ]; then
    # ステータスを更新
    result=$(gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$PROJECT_ID\"
        itemId: \"$ITEM_ID\"
        fieldId: \"$FIELD_ID\"
        value: {
          singleSelectOptionId: \"$OPTION_ID\"
        }
      }) {
        projectV2Item {
          id
        }
      }
    }")

    if echo "$result" | jq -e '.data.updateProjectV2ItemFieldValue.projectV2Item.id' > /dev/null 2>&1; then
      echo "✓ Issue #$issue_num: Status updated to '$TARGET_STATUS'"
    else
      echo "✗ Issue #$issue_num: Update failed"
    fi
  else
    echo "✗ Issue #$issue_num: Not found in '$PROJECT_NAME' project"
  fi
  echo ""
done
```

## 注意事項

### 必要な権限

GitHub CLI のトークンに以下のスコープが必要です：

- **`project`**: プロジェクトの読み書き（ステータス更新に必要）
- `repo`: リポジトリアクセス
- `read:org`: 組織の読み取り

権限が不足している場合は以下のコマンドで追加：

```bash
gh auth refresh -s project
```

### トラブルシューティング

**エラー: "INSUFFICIENT_SCOPES"**
- 原因: `project` スコープが不足
- 解決: `gh auth refresh -s project` を実行

**エラー: "Invalid ARIA attribute value"**
- 原因: `itemId` または `optionId` が間違っている
- 解決: Step 2, 3 で取得したIDが正しいか確認

## 参考リンク

- [GitHub Projects V2 API Documentation](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub GraphQL API Explorer](https://docs.github.com/en/graphql/overview/explorer)
