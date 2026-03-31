---
name: daily-planning
description: "GitHub DiscussionにDaily Planningを投稿する。「daily planning」「日報」「デイリー」などと言及された際に使用。"
argument-hint: ""
---

# Daily Planning 投稿スキル

## 概要

GitHub Discussionの「Daily planning」カテゴリにある、今月分のdiscussionを特定し、今日の行動履歴をもとにDaily Planningエントリを作成・投稿する。

## 実行手順

### 1. GitHubユーザー名とリポジトリ情報の取得

```bash
GH_USER=$(gh api user --jq '.login')
REPO_FULLNAME=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
REPO_OWNER=$(echo "${REPO_FULLNAME}" | cut -d'/' -f1)
REPO_NAME=$(echo "${REPO_FULLNAME}" | cut -d'/' -f2)
# GH_USER — GitHubユーザー名
# REPO_FULLNAME — "owner/repo" 形式（カレントディレクトリのリポジトリから自動取得）
# REPO_OWNER / REPO_NAME — GraphQL クエリの repository(owner:, name:) で使用
```

### 2. 今月のDaily Planning Discussionを特定

現在の年月を使って、GitHub Search APIで該当ユーザーの今月分のDiscussionを直接検索する。

**重要:**
- `gh api graphql` では `-f query=` がGraphQLクエリ本体に予約されているため、GraphQL変数には別名を使い、クエリ文字列内に直接埋め込むこと。
- `category:Daily planning` はスペースを含むためGraphQL検索クエリのパースエラーになる。検索クエリからは除外し、jqでカテゴリをフィルタすること。

**注意: macOS では `USERNAME` がシステム環境変数として予約されているため、変数名は `GH_USER` を使うこと。**

```bash
YEAR_MONTH=$(date +%Y-%m)

gh api graphql -f query="
{
  search(query: \"repo:${REPO_FULLNAME} ${GH_USER} ${YEAR_MONTH} in:title\", type: DISCUSSION, first: 5) {
    nodes {
      ... on Discussion {
        number
        title
        category { name }
      }
    }
  }
}" --jq '.data.search.nodes[] | select(.category.name == "Daily planning")'
```

### 3. 今日の行動履歴を収集

今日の日付（`YYYY-MM-DD`形式）を使って、以下の情報を**並列で**収集する。

**重要: `updated` ではなく、実際にユーザーがアクションを起こしたものだけを抽出すること。**

**タスク判定基準（コメントしただけでは「自分のタスク」に含めない）:**
- **Issue → やったこと**: 自分が**assignee**であること。assigneeでないIssueにコメントしただけでは含めない。
- **PR → やったこと**: 自分が**authorまたはassignee**であり、コミットをpushしていること。
- **PR → レビュー**: 自分が**レビュワーとしてrequest**されており、レビューを提出していること。requestされていないPRにコメントしただけでは含めない。
- **Issue作成**: 自分が**author**であること。

#### 3a. 今日コミットをpushしたPR

自分がauthorまたはassigneeのPRのうち、今日コミットをpushしたものを特定する。

```bash
# まず候補となるPRを取得（author + assignee、今日更新されたもの）
gh search prs --repo ${REPO_FULLNAME} --author ${GH_USER} --updated "${TODAY}..${TODAY}" --limit 100 --json number
gh search prs --repo ${REPO_FULLNAME} --assignee ${GH_USER} --updated "${TODAY}..${TODAY}" --limit 100 --json number

# 各PRについて、今日のコミットが自分のものか確認
gh api "/repos/${REPO_FULLNAME}/pulls/{PR_NUM}/commits" \
  --jq "[.[] | select(.commit.author.date | startswith(\"${TODAY}\")) | select(.author.login == \"${GH_USER}\")] | length"
```

コミット数が1以上のPRのみを「やったこと」に含める。

#### 3b. 今日レビューしたPR（レビュワーとしてrequestされたもの限定）

```bash
gh search prs --repo ${REPO_FULLNAME} --reviewed-by ${GH_USER} --updated "${TODAY}..${TODAY}" --limit 100 --json number,title,url

# 各PRについて、以下の2点を確認:

# 1. 今日のレビューが自分のものか
gh api "/repos/${REPO_FULLNAME}/pulls/{PR_NUM}/reviews" \
  --jq "[.[] | select(.submitted_at | startswith(\"${TODAY}\")) | select(.user.login == \"${GH_USER}\")] | length"

# 2. 自分がレビュワーとしてrequestされたか（コメントしただけのPRは除外）
gh api "/repos/${REPO_FULLNAME}/issues/{PR_NUM}/events" --paginate \
  --jq "[.[] | select(.event == \"review_requested\") | select(.requested_reviewer.login == \"${GH_USER}\")] | length"
```

以下のPRは「レビュー」セクションから**除外**する:
- 自分がauthorのPR（セルフレビュー）
- 自分がレビュワーとしてrequestされていないPR（コメントのみ）

#### 3c. 今日アクティビティのあったIssue（assignee限定）

自分がassigneeのIssueのみを対象とする。assigneeでないIssueにコメントしただけでは「やったこと」に**含めない**。

```bash
# 自分がassigneeのIssue（今日更新分）のみを取得
gh search issues --repo ${REPO_FULLNAME} --assignee ${GH_USER} --updated "${TODAY}..${TODAY}" --limit 100 --json number

# 各Issueについて、今日のアクティビティ（コメントまたはイベント）が自分のものか確認
gh api "/repos/${REPO_FULLNAME}/issues/{NUM}/comments?since=${TODAY}T00:00:00Z" \
  --jq "[.[] | select(.user.login == \"${GH_USER}\") | select(.created_at | startswith(\"${TODAY}\"))] | length"
```

#### 3d. 今日クローズしたIssue

```bash
gh api "/repos/${REPO_FULLNAME}/issues/{NUM}/events" \
  --jq ".[] | select(.created_at | startswith(\"${TODAY}\")) | select(.event == \"closed\") | select(.actor.login == \"${GH_USER}\")"
```

#### 3e. 今日作成したIssue

以下を他の収集ステップ（3a〜3d）と**並列で**実行する。

```bash
gh search issues --repo ${REPO_FULLNAME} --author ${GH_USER} --created "${TODAY}..${TODAY}" --limit 100 --json number,title,url
```

### 理由

従来のスキルでは、Issueへのコメント（`--commenter`）やアサイン（`--assignee`）のみを収集していたため、
ユーザーが新規作成したIssueが「やったこと」に反映されないケースがあった。

### 4. 前日の投稿を取得

Discussionの既存コメントから直前の投稿を取得し、「やったこと」と「レビュー」を「前日の振り返り」に使用する。

```bash
gh api graphql -f query='
{
  repository(owner: "${REPO_OWNER}", name: "${REPO_NAME}") {
    discussion(number: DISCUSSION_NUMBER) {
      comments(last: 1) {
        nodes {
          body
          createdAt
        }
      }
    }
  }
}' --jq '.data.repository.discussion.comments.nodes[0].body'
```

前日の投稿から以下を抽出する：
- 「✅ やったこと」または「✅ やること」セクションのリンク一覧
- 「レビュー:」セクションのリンク一覧

### 5. ユーザーに追加情報を質問

AskUserQuestionを使って以下を質問する。

**重要: AskUserQuestionの選択肢設計ルール**
- 各選択肢は「選んだらそのまま確定する値」でなければならない。「入力する」「あり」のような選択肢は、ユーザーがそれを選んでもフリーテキスト入力の機会なくsubmitされてしまうため禁止。
- フリーテキスト入力が必要な場合は、ユーザーが「Other」を選択することで入力できる。質問文に「（自由入力は『Other』を選択）」と明記すること。
- 選択肢には具体的な値のみを設定すること。

#### 質問内容

**1回のAskUserQuestionで以下4問をまとめて質問する：**

1. **困っていること**（自由入力は「Other」を選択）
   - 選択肢: 「特になし」「Other」
2. **共有事項**（自由入力は「Other」を選択）
   - 選択肢: 「特になし」「Other」
3. **勤務時間**（開始時刻、終了時刻、離席をまとめて入力。「Other」で自由入力）
   - 選択肢: 「10:00 - （終了未定、離席なし）」「10:00 - （終了未定、離席あり→Otherで入力）」「Other」
   - description で「例: 開始 10:30, 終了 19:00, 離席 12:00-13:00 / 15:00-15:30」のように入力例を示す

### 6. 下書きを作成してユーザーに提示

以下のテンプレートで下書きを作成し、マークダウンコードブロックで表示する。

```md
## {YYYY/MM/DD}

✅ やったこと
- {PR/IssueのURL一覧}

作成したIssue:
- {今日作成したIssueのURL一覧}

レビュー:
- {レビューしたPRのURL一覧}

📝 前日の振り返り
- {前日のやったこと・レビューのURL一覧}

🤿 困っていること
{ユーザーの回答、空欄なら空行}

📣 共有事項
{ユーザーの回答、空欄なら空行}

⏰ 勤務時間

- 開始: {時刻}
- 終了: {時刻 or 空欄}
- 離席:
  - {時間帯}（複数ある場合は複数行）
```

**テンプレートのルール:**
- 「作成したIssue」が0件の場合は「作成したIssue:」セクション自体を省略する
- 「レビュー」が0件の場合は「レビュー:」セクション自体を省略する
- 「離席」が無い場合は「離席:」行自体を省略する
- 「困っていること」「共有事項」が空の場合はヘッダーのみ残し内容は空行にする

### 7. ユーザーの承認後、Discussionに投稿

```bash
# Discussion Node IDを取得
DISCUSSION_ID=$(gh api graphql -f query='
{
  repository(owner: "${REPO_OWNER}", name: "${REPO_NAME}") {
    discussion(number: DISCUSSION_NUMBER) {
      id
    }
  }
}' --jq '.data.repository.discussion.id')

# コメントを投稿
gh api graphql -f query='
mutation {
  addDiscussionComment(input: {
    discussionId: "'"${DISCUSSION_ID}"'",
    body: "投稿内容"
  }) {
    comment {
      url
    }
  }
}'
```

投稿後、コメントのURLをユーザーに表示する。

## 重要な注意事項

### アクション判定の正確性

`updated` フィールドだけで検索すると、他人のアクション（ラベル変更、botの更新など）で更新されたものも含まれてしまう。
必ず以下のAPIで**自分が実際にアクションを起こしたか**を確認すること:

- コミット: `/pulls/{num}/commits` で author.login を確認
- レビュー: `/pulls/{num}/reviews` で user.login と submitted_at を確認
- コメント: `/issues/{num}/comments` で user.login と created_at を確認
- イベント: `/issues/{num}/events` で actor.login を確認

### タスク判定の厳格性

**コメントしただけでは「自分のタスク」に含めない。** 必ず以下のロール確認を行うこと:

- **Issue → やったこと**: `--assignee` で検索したIssueのみ対象。`--commenter` のみのIssueは除外する。
- **PR → レビュー**: `--reviewed-by` で検索した後、`/issues/{num}/events` で `review_requested` イベントを確認し、自分がレビュワーとしてrequestされたPRのみ対象。requestされていないPRは除外する。
- **PR → やったこと**: author または assignee であること。
- **Issue作成**: author であること。

### jq使用時の注意

Claude Code の Bash ツールでは `!=` がエスケープされてエラーになる。代わりに以下を使用：

```bash
# NG: jq 'select(.user.login != "bot")'
# OK: jq 'select(.user.login == "target_user")'
```

