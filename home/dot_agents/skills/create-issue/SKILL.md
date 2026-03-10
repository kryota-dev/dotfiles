---
name: create-issue
description: GitHub Issueを作成する際に使用。リポジトリのIssueテンプレートに準拠した内容を生成し、ghコマンドで投稿する。
argument-hint: "[issue-type] [repository]"
disable-model-invocation: true
allowed-tools: Bash, Read, WebFetch
---

# GitHub Issue Generator

GitHubのIssueをテンプレート（タスク/フィーチャー/バグ/エピック）に基づいて生成・投稿します。
ソフトウェアエンジニアと熟練のプロダクトマネージャーの知見を活用し、品質の高いIssueを作成します。

## ⚠️ 必ず厳守すべき事項

**重要**: 以下の事項は絶対に守ってください：

1. **Issue作成前の確認は必須** - プロンプトでIssue作成を依頼されていた場合でも、実際にIssueを作成する前に必ず最終確認を行い、ユーザーの明示的な許可を得ること
2. **ラベルとメタデータの扱い** - ラベルはAIが自動的に選択・設定する。マイルストーン、担当者などの他のメタデータは追加しないこと
3. **ユーザー承認なしの作成禁止** - ユーザーが "yes" と明確に回答しない限り、Issueを作成しないこと
4. **タイトルのプレフィックス禁止** - IssueタイトルにGitコミットメッセージ形式のプレフィックス（feat:、fix:、refactor:、docs:、chore:、style:、perf:、test:など）を付けないこと。Issueには明確で読みやすいタイトルを付けること

## 使用方法

```bash
/github-issue [<issue-type>] [<repository>]
```

### パラメータ

- `issue-type` (任意): task, feature, bug, epic のいずれか（デフォルト: 対話的に選択）

## 処理フロー

### 1. 初期化と環境確認

```bash
# GitHubの認証状態を確認
gh auth status

# 現在のディレクトリからリポジトリを推定（指定されていない場合）
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)

if [ -z "$REPO" ]; then
    echo "リポジトリが指定されていません。以下の形式で入力してください："
    echo "例: owner/repository"
    read -p "リポジトリ名: " REPO
fi

# リポジトリの存在確認
gh repo view $REPO --json name >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "エラー: リポジトリ '$REPO' にアクセスできません"
    exit 1
fi
```

### 2. Issue種別の選択

```bash
# Issue種別が指定されていない場合は対話的に選択
if [ -z "$ISSUE_TYPE" ]; then
    echo "Issue種別を選択してください："
    echo "1) Task - 具体的な実装タスク"
    echo "2) Feature - 新機能の要求"
    echo "3) Bug - 不具合報告"
    echo "4) Epic - 大規模な機能群"
    read -p "選択 (1-4): " CHOICE

    case $CHOICE in
        1) ISSUE_TYPE="task" ;;
        2) ISSUE_TYPE="feature" ;;
        3) ISSUE_TYPE="bug" ;;
        4) ISSUE_TYPE="epic" ;;
        *) echo "無効な選択です"; exit 1 ;;
    esac
fi
```

### 3. テンプレートディレクトリの確認

```bash
# デフォルトのテンプレートディレクトリパス
DEFAULT_TEMPLATE_DIRS=(
    ".github/ISSUE_TEMPLATE"
    ".github/issue_templates"
    "docs/templates/issues"
    "templates/issues"
)

# テンプレートディレクトリを自動検出
TEMPLATE_DIR=""
echo "テンプレートディレクトリを検索中..."

for dir in "${DEFAULT_TEMPLATE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "✓ テンプレートディレクトリを発見: $dir"
        TEMPLATE_DIR="$dir"
        break
    fi
done

# テンプレートディレクトリが見つからない場合のみユーザーに確認
if [ -z "$TEMPLATE_DIR" ]; then
    echo "⚠️ デフォルトのテンプレートディレクトリが見つかりません。"
    echo "確認した場所:"
    for dir in "${DEFAULT_TEMPLATE_DIRS[@]}"; do
        echo "  - $dir"
    done
    read -p "テンプレートディレクトリのパスを入力してください: " TEMPLATE_DIR
fi

# テンプレートファイルの確認
TEMPLATE_FILE="$TEMPLATE_DIR/${ISSUE_TYPE}.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "警告: テンプレートファイル '$TEMPLATE_FILE' が見つかりません"
    echo "デフォルトテンプレートを使用します"
    USE_DEFAULT_TEMPLATE=true
fi
```

### 4. テンプレートからIssue Typeを抽出

```bash
# テンプレートのfrontmatterからtypeフィールドを抽出
ISSUE_TYPE_NAME=""
if [ -f "$TEMPLATE_FILE" ]; then
    # frontmatter内のtype:行を抽出（YAMLフロントマター内）
    ISSUE_TYPE_NAME=$(sed -n '/^---$/,/^---$/p' "$TEMPLATE_FILE" | grep '^type:' | sed 's/type:[[:space:]]*//' | tr -d '\r')

    if [ -n "$ISSUE_TYPE_NAME" ]; then
        echo "✓ テンプレートからIssue Typeを検出: $ISSUE_TYPE_NAME"
    fi
fi
```

### 5. Organization Issue Typesの取得

```bash
# OrganizationのIssue Typesを取得（GraphQL API）
ISSUE_TYPE_ID=""
if [ -n "$ISSUE_TYPE_NAME" ]; then
    echo "Organization Issue Typesを取得中..."

    ORG_NAME="${REPO%/*}"
    ISSUE_TYPES_JSON=$(gh api graphql \
      -H "GraphQL-Features: issue_types" \
      -f query="
      query {
        organization(login: \"$ORG_NAME\") {
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
      }" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$ISSUE_TYPES_JSON" ]; then
        # テンプレートのtype名と一致するIssue Type IDを検索
        ISSUE_TYPE_ID=$(echo "$ISSUE_TYPES_JSON" | jq -r --arg name "$ISSUE_TYPE_NAME" '.data.organization.issueTypes.nodes[] | select(.name == $name and .isEnabled == true) | .id')

        if [ -n "$ISSUE_TYPE_ID" ]; then
            echo "✓ Issue Type IDを取得: $ISSUE_TYPE_NAME ($ISSUE_TYPE_ID)"
        else
            echo "⚠️ テンプレートのtype '$ISSUE_TYPE_NAME' に対応するIssue Typeが見つかりません"
            echo "   利用可能なIssue Types:"
            echo "$ISSUE_TYPES_JSON" | jq -r '.data.organization.issueTypes.nodes[] | "   - \(.name): \(.description // "")"'
        fi
    else
        echo "⚠️ Organization Issue Typesの取得に失敗しました（Issue Type機能が有効でない可能性があります）"
    fi
fi
```

### 6. ラベルの自動選択

```bash
# リポジトリの既存labelを取得
echo ""
echo "ラベルを自動選択中..."

LABELS_JSON=$(gh api repos/$REPO/labels 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$LABELS_JSON" ]; then
    echo "⚠️ ラベルの取得に失敗しました。ラベルなしで続行します。"
    SELECTED_LABELS=""
else
    # ラベル情報を整形（名前と説明）
    LABELS_INFO=$(echo "$LABELS_JSON" | jq -r '.[] | "\(.name)|\(.description // "")"')

    # AIがIssue種別、タイトル、本文を分析して自動的に適切なラベルを選択
    # Claude Codeは利用可能なラベル一覧とIssue情報から最適なラベルを自動判定します
    #
    # 以下は基本的なマッピング例（実際のAI実装では、より高度な分析が行われます）
    # AI実装者への指示：
    # - LABELS_INFO変数に全ての利用可能なラベルが含まれています
    # - ISSUE_TYPE, TITLE, ISSUE_BODY変数を参照してコンテキストを理解してください
    # - 適切なラベルをカンマ区切りでSELECTED_LABELS変数に設定してください
    # - ラベル名は完全一致で指定する必要があります

    # デフォルトのマッピング（AIが上書き可能）
    case $ISSUE_TYPE in
        "task")
            SELECTED_LABELS="backend,feature,usecase"
            ;;
        "feature")
            SELECTED_LABELS="enhancement,feature"
            ;;
        "bug")
            SELECTED_LABELS="bugfix"
            ;;
        "epic")
            SELECTED_LABELS="feature,enhancement,product"
            ;;
        *)
            SELECTED_LABELS=""
            ;;
    esac

    # 選択されたラベルが実際に存在するか確認
    if [ -n "$SELECTED_LABELS" ]; then
        VALIDATED_LABELS=""
        IFS=',' read -ra LABEL_ARRAY <<< "$SELECTED_LABELS"
        for label in "${LABEL_ARRAY[@]}"; do
            # 空白を削除
            label=$(echo "$label" | xargs)
            # ラベルが存在するか確認
            if echo "$LABELS_INFO" | grep -q "^${label}|"; then
                if [ -z "$VALIDATED_LABELS" ]; then
                    VALIDATED_LABELS="$label"
                else
                    VALIDATED_LABELS="$VALIDATED_LABELS,$label"
                fi
            fi
        done
        SELECTED_LABELS="$VALIDATED_LABELS"
    fi

    if [ -n "$SELECTED_LABELS" ]; then
        echo "✓ 自動選択されたラベル: $SELECTED_LABELS"
    else
        echo "✓ 該当するラベルが見つかりませんでした（ラベルなしで続行）"
    fi
fi
```

### 7. Issueのプレビューと確認

```bash
# Issueのプレビュー
echo ""
echo "
=================================
📋 Issue プレビュー
=================================
リポジトリ: $REPO
種別: $ISSUE_TYPE
タイトル: $TITLE
ラベル: ${SELECTED_LABELS:-なし}

--- 本文 ---
$ISSUE_BODY
=================================
"

# 重要な確認事項を表示
echo "
⚠️ 重要な確認事項:
1. タイトルと本文の内容は適切ですか？
2. ラベルは適切ですか？
3. 個人情報や機密情報は含まれていませんか？
4. Issue の内容は正確で必要十分ですか？
5. 作成後は修正や削除が必要になる場合があります
"

# 最終確認（必須）
# `AskUserQuestion`ツールを使用してユーザーに確認を取ること
# パラメータ:
#   question: "このIssueを作成してよろしいですか？"
#   header: "Issue作成"
#   options:
#     - { label: "はい", description: "このIssueを作成する" }
#     - { label: "いいえ", description: "Issue作成をキャンセルする" }
#   multiSelect: false
# ユーザーが "はい" を選択した場合のみ次のステップに進む
# ユーザーが "いいえ" を選択した場合は「Issue作成をキャンセルしました。内容を修正してから再度実行してください」と表示して終了する
```

### 8. Issue の作成

```bash
# gh issue create コマンドの構築
CREATE_CMD="gh issue create --repo $REPO"
CREATE_CMD="$CREATE_CMD --title \"$TITLE\""
CREATE_CMD="$CREATE_CMD --body \"$ISSUE_BODY\""

# ラベルが選択されている場合は追加
if [ -n "$SELECTED_LABELS" ]; then
    # カンマ区切りのラベルをスペース区切りの--labelオプションに変換
    IFS=',' read -ra LABEL_ARRAY <<< "$SELECTED_LABELS"
    for label in "${LABEL_ARRAY[@]}"; do
        CREATE_CMD="$CREATE_CMD --label \"$label\""
    done
fi

# Issueの作成実行
echo "Issueを作成しています..."
ISSUE_URL=$(eval "$CREATE_CMD")

if [ $? -eq 0 ]; then
    echo "✅ Issueが正常に作成されました！"
    echo "URL: $ISSUE_URL"

    # Epic の場合、Sub-issue作成の提案
    if [ "$ISSUE_TYPE" = "epic" ]; then
        echo ""
        echo "💡 ヒント: EpicにSub-issueを追加する場合は、以下のコマンドを使用してください："
        echo "gh issue edit $ISSUE_URL --add-project <project-name>"
    fi
else
    echo "❌ エラー: Issueの作成に失敗しました"
    exit 1
fi
```

### 9. 作成後の処理

```bash
# 作成したIssueの詳細を表示
echo ""
echo "=== 作成されたIssueの詳細 ==="
gh issue view $ISSUE_URL --repo $REPO

# Issue Typeの設定
if [ -n "$ISSUE_TYPE_ID" ] && [ -n "$ISSUE_URL" ]; then
    echo ""
    echo "Issue Typeを設定中..."

    # IssueのNode IDを取得
    ISSUE_NUMBER="${ISSUE_URL##*/}"
    ISSUE_NODE_ID=$(gh api graphql -f query="
    query {
      repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") {
        issue(number: $ISSUE_NUMBER) {
          id
        }
      }
    }" --jq '.data.repository.issue.id')

    if [ -n "$ISSUE_NODE_ID" ]; then
        # Issue Typeを設定（GraphQL mutation）
        RESULT=$(gh api graphql \
          -H "GraphQL-Features: issue_types" \
          -f query="
          mutation {
            updateIssueIssueType(input: {
              issueId: \"$ISSUE_NODE_ID\"
              issueTypeId: \"$ISSUE_TYPE_ID\"
            }) {
              issue {
                title
                number
                url
                issueType {
                  name
                  description
                  color
                }
              }
            }
          }" 2>&1)

        if [ $? -eq 0 ]; then
            ISSUE_TYPE_SET=$(echo "$RESULT" | jq -r '.data.updateIssueIssueType.issue.issueType.name')
            echo "✅ Issue Type '$ISSUE_TYPE_SET' を設定しました"
        else
            echo "⚠️ Issue Typeの設定に失敗しました"
            echo "$RESULT"
        fi
    else
        echo "⚠️ Issue Node IDの取得に失敗しました"
    fi
fi

# Sub-issue設定（Parent Issueへの追加）
# `AskUserQuestion`ツールを使用してユーザーに確認を取ること
# パラメータ:
#   question: "このIssueを既存のIssueのsub-issueとして追加しますか？"
#   header: "Sub-issue"
#   options:
#     - { label: "はい", description: "既存Issueのsub-issueとして追加する" }
#     - { label: "いいえ", description: "sub-issueとして追加しない" }
#   multiSelect: false
# ユーザーが "はい" を選択した場合、続けてParent IssueのIssue番号を質問する
ADD_AS_SUBISSUE="y"  # AskUserQuestionの結果に応じて設定
if [ "$ADD_AS_SUBISSUE" = "y" ]; then
    # `AskUserQuestion`ツールを使用してParent IssueのIssue番号を質問すること
    # パラメータ:
    #   question: "Parent IssueのIssue番号を入力してください"
    #   header: "Parent"
    #   options:
    #     - { label: "番号を入力", description: "Parent IssueのIssue番号を指定する" }
    #   multiSelect: false
    # ※ユーザーは「Other」からIssue番号を自由入力する想定
    PARENT_ISSUE_NUMBER=""  # AskUserQuestionの結果を設定

    # 作成したIssueのNode IDを取得
    SUBISSUE_NODE_ID=$(gh api graphql -f query="
    query {
      repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") {
        issue(number: ${ISSUE_URL##*/}) {
          id
        }
      }
    }" --jq '.data.repository.issue.id')

    # Parent IssueのNode IDを取得
    PARENT_NODE_ID=$(gh api graphql -f query="
    query {
      repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") {
        issue(number: $PARENT_ISSUE_NUMBER) {
          id
        }
      }
    }" --jq '.data.repository.issue.id')

    # Sub-issueとして追加（GraphQL-Features: sub_issuesヘッダーが必須）
    echo "Sub-issueとして追加中..."
    RESULT=$(gh api graphql \
      -H "GraphQL-Features: sub_issues" \
      -f query="
      mutation {
        addSubIssue(input: {
          issueId: \"$PARENT_NODE_ID\"
          subIssueId: \"$SUBISSUE_NODE_ID\"
        }) {
          issue {
            number
            title
          }
          subIssue {
            number
            title
          }
        }
      }")

    if [ $? -eq 0 ]; then
        echo "✅ Issue #${ISSUE_URL##*/} を Issue #$PARENT_ISSUE_NUMBER のsub-issueとして追加しました"
    else
        echo "❌ エラー: Sub-issueの追加に失敗しました"
        echo "$RESULT"
    fi
fi

# プロジェクトボードへの追加（オプション）
# `AskUserQuestion`ツールを使用してユーザーに確認を取ること
# パラメータ:
#   question: "プロジェクトボードに追加しますか？"
#   header: "Project"
#   options:
#     - { label: "はい", description: "プロジェクトボードに追加する" }
#     - { label: "いいえ", description: "プロジェクトボードに追加しない" }
#   multiSelect: false
ADD_PROJECT="y"  # AskUserQuestionの結果に応じて設定
if [ "$ADD_PROJECT" = "y" ]; then
    # 利用可能なプロジェクトを取得
    PROJECTS=$(gh project list --owner ${REPO%/*} --format json | jq -r '.projects[].title')

    # `AskUserQuestion`ツールを使用してプロジェクト名を質問すること
    # パラメータ:
    #   question: "追加するプロジェクトを選択してください"
    #   header: "Project名"
    #   options: 取得したプロジェクト一覧から最大4件を選択肢として動的に設定
    #     - { label: "<プロジェクト名1>", description: "このプロジェクトに追加する" }
    #     - { label: "<プロジェクト名2>", description: "このプロジェクトに追加する" }
    #   multiSelect: false
    PROJECT_NAME=""  # AskUserQuestionの結果を設定
    gh issue edit $ISSUE_URL --add-project "$PROJECT_NAME"
fi
```

## エラーハンドリング

### 認証エラー

```bash
# GitHubの認証が必要な場合
if ! gh auth status >/dev/null 2>&1; then
    echo "エラー: GitHub CLIの認証が必要です"
    echo "実行: gh auth login"
    exit 1
fi
```

### バリデーション

- 必須フィールドの確認
- Issue種別の妥当性チェック
- ラベルの存在確認
- マイルストーンの存在確認

### AI支援機能

- タイトルの自動生成
  - **重要**: タイトルにGitコミットメッセージ形式のプレフィックス（feat:、fix:、refactor:、docs:など）を付けないこと
  - Issue用の明確で簡潔なタイトルを生成すること
- 本文の自動生成
  - **重要**: 実装の詳細（具体的なコード例、実装方法、技術的な設計など）は含めないこと
  - 「何を達成すべきか」（What）と「なぜ必要か」（Why）に焦点を当てること
  - 「どのように実装するか」（How）は担当者が決定するため記載しないこと
  - 受け入れ条件（Acceptance Criteria）は最大2つまでに制限して簡潔に記載すること
- ラベルの自動選択
  - Issue種別、タイトル、本文を分析して適切なラベルを自動的に選択
  - リポジトリに登録されている既存のラベルから選択
  - 新しいラベルの作成は許可されない
  - 選択されたラベルは自動的に付与される（ユーザーの確認は不要）

## 使用例

```bash
# 対話的にIssueを作成
/github-issue

# バグレポートを作成
/github-issue bug

# Epicを作成
/github-issue epic

# Sub-issueとして追加（Issue作成後のプロンプトで設定）
# 1. Issueを作成
# 2. "このIssueを既存のIssueのsub-issueとして追加しますか？" に "y" と回答
# 3. Parent IssueのIssue番号を入力
```

### Sub-issue操作の独立したコマンド例

```bash
# 既存のIssueをSub-issueとして追加
# Step 1: Node IDを取得
PARENT_ID=$(gh api graphql -f query='
query {
  repository(owner: "owner", name: "repo") {
    issue(number: 100) { id }
  }
}' --jq '.data.repository.issue.id')

CHILD_ID=$(gh api graphql -f query='
query {
  repository(owner: "owner", name: "repo") {
    issue(number: 101) { id }
  }
}' --jq '.data.repository.issue.id')

# Step 2: Sub-issueとして追加
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

## Sub-issue機能の詳細

### Sub-issueとは

GitHubのSub-issue機能は、親子関係を持つIssueの階層構造を作成できる機能です。Epic配下にタスクを整理したり、大きな機能を小さな実装タスクに分割する際に便利です。

### GraphQL APIを使用したSub-issue管理

**重要**: Sub-issue機能を使用するには、GraphQL APIリクエストに `GraphQL-Features: sub_issues` ヘッダーが必須です。

#### 1. Issue番号からNode IDを取得

```bash
# Issue番号からNode IDを取得
gh api graphql -f query='
query {
  repository(owner: "owner", name: "repo") {
    issue(number: 123) {
      id
    }
  }
}' --jq '.data.repository.issue.id'
```

#### 2. Sub-issueを追加

```bash
# Parent IssueにSub-issueを追加
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query='
mutation {
  addSubIssue(input: {
    issueId: "I_kwDOxxxxxx"      # Parent IssueのNode ID
    subIssueId: "I_kwDOyyyyyy"   # Sub-issueのNode ID
  }) {
    issue {
      number
      title
    }
    subIssue {
      number
      title
    }
  }
}'
```

#### 3. Sub-issueを削除

```bash
# Sub-issueを親から削除
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query='
mutation {
  removeSubIssue(input: {
    issueId: "I_kwDOxxxxxx"
    subIssueId: "I_kwDOyyyyyy"
  }) {
    issue {
      number
      title
    }
  }
}'
```

#### 4. Sub-issuesの一覧を取得

```bash
# Parent IssueのSub-issuesを取得
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query='
query {
  node(id: "I_kwDOxxxxxx") {
    ... on Issue {
      number
      title
      subIssues(first: 20) {
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
}'
```

#### 5. Parent Issueを取得

```bash
# IssueのParent Issueを取得
gh api graphql \
  -H "GraphQL-Features: sub_issues" \
  -f query='
query {
  node(id: "I_kwDOyyyyyy") {
    ... on Issue {
      number
      title
      parent {
        number
        title
      }
    }
  }
}'
```

### GitHub CLI拡張機能

GitHub CLI本体にはSub-issue機能のサポートがないため、以下のサードパーティ拡張機能が利用可能です：

- **gh-sub-issue** (by agbiotech): https://github.com/agbiotech/gh-sub-issue
- **gh-sub-issue** (by yahsan2): https://github.com/yahsan2/gh-sub-issue

### 制限事項

- 1つのParent Issueに最大100個のSub-issueを追加可能
- 最大8レベルまでネスト可能
- Sub-issue機能はGraphQL APIでのみ利用可能（REST APIでは一部のみ対応）

### 参考リンク

- [Introducing sub-issues - The GitHub Blog](https://github.blog/engineering/architecture-optimization/introducing-sub-issues-enhancing-issue-management-on-github/)
- [Sub-issues Public Preview Discussion](https://github.com/orgs/community/discussions/148714)
- [Create GitHub issue hierarchy using the API](https://jessehouwing.net/create-github-issue-hierarchy-using-the-api/)

## Issue Types機能の詳細

### Issue Typesとは

GitHub Issue Typesは、Organizationレベルで定義されるIssueの分類機能です。デフォルトで「Bug」「Task」「Feature」「Enhancement」「Epic」などのタイプが用意されており、最大25個まで作成可能です。

### 自動設定の仕組み

このコマンドは、Issue Templateのfrontmatterに記載された`type`フィールドを読み取り、自動的にIssue Typeを設定します：

```yaml
---
name: 01_Task
about: 汎用的なタスクを作成するときに使うテンプレート
title: ""
type: Task
labels: ""
assignees: ""
---
```

### GraphQL APIを使用したIssue Type管理

**重要**: Issue Type機能を使用するには、GraphQL APIリクエストに `GraphQL-Features: issue_types` ヘッダーが必須です。

#### 1. Organization Issue Typesの取得

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

#### 2. IssueのTypeを取得

```bash
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query='
query {
  repository(owner: "OWNER", name: "REPO") {
    issue(number: 123) {
      title
      number
      issueType {
        name
        description
        color
      }
    }
  }
}'
```

#### 3. IssueのTypeを設定/変更

```bash
gh api graphql \
  -H "GraphQL-Features: issue_types" \
  -f query='
mutation($issueId: ID!, $issueTypeId: ID!) {
  updateIssueIssueType(input: {
    issueId: $issueId
    issueTypeId: $issueTypeId
  }) {
    issue {
      title
      issueType {
        name
      }
    }
  }
}' \
  -f issueId="ISSUE_NODE_ID" \
  -f issueTypeId="ISSUE_TYPE_ID"
```

#### 4. Organization Issue Typesの作成（REST API）

```bash
curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer <YOUR-TOKEN>" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/orgs/ORG/issue-types \
  -d '{
    "name": "Epic",
    "description": "An issue type for a multi-week tracking of work",
    "is_enabled": true,
    "color": "green"
  }'
```

### 制限事項

- **Organization機能**: Issue TypesはOrganizationでのみ利用可能（個人リポジトリでは使用不可）
- **Public Preview**: 現在プレビュー機能として提供中
- **最大数**: 1つのOrganizationに最大25個のIssue Typesを作成可能
- **Pull Requestは非対応**: 現時点ではIssueのみサポート

### テンプレートとの対応

Issue Templateの`type`フィールドは、Organizationで定義されたIssue Type名と一致する必要があります：

| Template type | Organization Issue Type | 説明               |
| ------------- | ----------------------- | ------------------ |
| Task          | Task                    | 具体的な実装タスク |
| Bug           | Bug                     | 不具合報告         |
| Enhancement   | Enhancement             | 機能改善           |
| Epic          | Epic                    | 大規模な機能群     |
| Feature       | Feature                 | 新機能の要求       |

### 参考リンク

- [Issue Types Public Preview Discussion](https://github.com/orgs/community/discussions/139933)
- [GitHub Issues: Scripts for working with Sub-Issues and Issue Types](https://josh-ops.com/posts/github-sub-issues-and-issue-types/)

## 注意事項

- テンプレートディレクトリパスは環境に応じて設定が必要
- GitHub CLIの認証が必須
- 適切な権限（Issue作成権限）が必要
- テンプレートファイルはMarkdown形式で作成
- Sub-issue機能を使用する場合は `GraphQL-Features: sub_issues` ヘッダーが必須
- Issue Type機能を使用する場合は `GraphQL-Features: issue_types` ヘッダーが必須
- Issue TypesはOrganizationでのみ利用可能（個人リポジトリでは自動設定されません）
- テンプレートの`type`フィールドは、Organizationで定義されたIssue Type名と完全一致する必要があります
