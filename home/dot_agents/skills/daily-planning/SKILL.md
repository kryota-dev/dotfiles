---
name: daily-planning
description: "GitHub DiscussionにDaily Planningを投稿する。「daily planning」「日報」「デイリー」などと言及された際に使用。"
argument-hint: ""
---

# Daily Planning 投稿スキル

## 概要

GitHub Discussionの「Daily planning」カテゴリにある、今月分のdiscussionを特定し、今日の行動履歴をもとにDaily Planningエントリを作成・投稿する。

## 実行手順

### 1. 基本情報・タイムゾーン範囲の取得

GitHubユーザー名・リポジトリ情報に加えて、**JST「今日」の範囲を UTC で算出**して以降のフィルタに使う。
GitHub API の `created_at` / `submitted_at` は UTC のため、`startswith("YYYY-MM-DD")` で比較すると JST の早朝アクション（UTC では前日扱い）を取りこぼす。

```bash
GH_USER=$(gh api user --jq '.login')
REPO_FULLNAME=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
REPO_OWNER=$(echo "${REPO_FULLNAME}" | cut -d'/' -f1)
REPO_NAME=$(echo "${REPO_FULLNAME}" | cut -d'/' -f2)

# JST 基準の日付
TODAY_JST=$(TZ=Asia/Tokyo date +%Y-%m-%d)
YESTERDAY_JST=$(TZ=Asia/Tokyo date -v-1d +%Y-%m-%d)

# JST 今日の範囲を UTC で表現
#   JST 今日 00:00 = UTC 前日 15:00
#   JST 今日 24:00 = UTC 当日 15:00
START_UTC="${YESTERDAY_JST}T15:00:00Z"
END_UTC="${TODAY_JST}T15:00:00Z"

# `gh search` 系は UTC 基準で日付フィルタを行うため、JST 今日に対応する UTC 期間（昨日〜今日の2日間）で検索する
SEARCH_START="${YESTERDAY_JST}"
SEARCH_END="${TODAY_JST}"

# GH_USER — GitHubユーザー名
# REPO_FULLNAME — "owner/repo" 形式（カレントディレクトリのリポジトリから自動取得）
# REPO_OWNER / REPO_NAME — GraphQL クエリの repository(owner:, name:) で使用
# START_UTC / END_UTC — `/repos/.../{commits,reviews,comments,events}` の created_at/submitted_at フィルタに使う
# SEARCH_START / SEARCH_END — `gh search prs/issues --updated/--created` のレンジに使う
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

JST 今日の範囲（`START_UTC` 〜 `END_UTC`）を使って、以下の情報を**並列で**収集する。

**重要: `updated` ではなく、実際にユーザーがアクションを起こしたものだけを抽出すること。**

**「やったこと」に含めるアクション:**
- 自分の**コミット push**（PR）
- 自分の**マージ操作**（PR）
- 自分の**Issue close**
- 自分が**assignee の Issue で今日コメント**したもの
- 自分が**作成した Issue**

**「レビュー」に含めるアクション:**
- 自分が**レビュワーとして request** されており、かつ JST 今日に**レビュー submit** または**レビューコメント（インライン）**を残したもの

**含めない:**
- 自分が author でない Issue にコメントしただけのもの
- レビュワー request されていない PR にコメントしただけのもの
- 自分が author の PR への自己レビュー

#### 3a. 今日コミット / マージしたPR

自分がauthorまたはassigneeのPRのうち、JST 今日にコミット push、または自分でマージしたものを特定する。

```bash
# まず候補となるPRを取得（author + assignee、JST 今日に対応する2日間レンジで更新されたもの）
gh search prs --repo "${REPO_FULLNAME}" --author "${GH_USER}" --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 --json number,title,url
gh search prs --repo "${REPO_FULLNAME}" --assignee "${GH_USER}" --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 --json number,title,url

# 各PRについて、JST 今日の自分のコミット数を確認
gh api "/repos/${REPO_FULLNAME}/pulls/${PR_NUM}/commits" --paginate \
  --jq ".[] | select(.author.login == \"${GH_USER}\") | select(.commit.author.date >= \"${START_UTC}\" and .commit.author.date < \"${END_UTC}\") | .sha" | wc -l | tr -d ' '

# 各PRについて、JST 今日に自分がマージしたかを確認
gh api "/repos/${REPO_FULLNAME}/issues/${PR_NUM}/events" --paginate \
  --jq ".[] | select(.actor.login == \"${GH_USER}\") | select(.event == \"merged\") | select(.created_at >= \"${START_UTC}\" and .created_at < \"${END_UTC}\") | .id" | wc -l | tr -d ' '
```

コミットまたはマージのいずれかが1以上なら「やったこと」に含める。

#### 3b. 今日レビューしたPR（レビュワーとしてrequestされたもの限定）

レビュー submit せずに review comment（インラインコメント）だけを残すケースもあるため、`/reviews` と `/comments` の両方を確認する。

```bash
# 候補PR（reviewed-by、JST 今日に対応する2日間レンジ）
gh search prs --repo "${REPO_FULLNAME}" --reviewed-by "${GH_USER}" --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 --json number,title,url

# 各PRについて、以下の3点を確認:

# 1. JST 今日の自分のレビュー submit 数
gh api "/repos/${REPO_FULLNAME}/pulls/${PR_NUM}/reviews" \
  --jq "[.[] | select(.user.login == \"${GH_USER}\") | select(.submitted_at >= \"${START_UTC}\" and .submitted_at < \"${END_UTC}\")] | length"

# 2. JST 今日の自分のレビューコメント（インライン）数
gh api "/repos/${REPO_FULLNAME}/pulls/${PR_NUM}/comments" --paginate \
  --jq ".[] | select(.user.login == \"${GH_USER}\") | select(.created_at >= \"${START_UTC}\" and .created_at < \"${END_UTC}\") | .id" | wc -l | tr -d ' '

# 3. 自分がレビュワーとしてrequestされたか（コメントしただけのPRは除外）
gh api "/repos/${REPO_FULLNAME}/issues/${PR_NUM}/events" --paginate \
  --jq ".[] | select(.event == \"review_requested\") | select(.requested_reviewer.login == \"${GH_USER}\") | .id" | wc -l | tr -d ' '
```

「1または2が1以上」かつ「3が1以上」のPRを「レビュー」に含める。

以下のPRは「レビュー」セクションから**除外**する:
- 自分がauthorのPR（セルフレビュー）
- 自分がレビュワーとしてrequestされていないPR

#### 3c. 今日コメント / クローズしたIssue（assignee限定）

自分がassigneeのIssueのみを対象とする。

```bash
# 自分がassigneeのIssue（JST 今日に対応する2日間レンジで更新分）
gh search issues --repo "${REPO_FULLNAME}" --assignee "${GH_USER}" --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 --json number,title,url

# 各Issueについて、JST 今日の自分のコメント数を確認
gh api "/repos/${REPO_FULLNAME}/issues/${NUM}/comments" --paginate \
  --jq ".[] | select(.user.login == \"${GH_USER}\") | select(.created_at >= \"${START_UTC}\" and .created_at < \"${END_UTC}\") | .id" | wc -l | tr -d ' '

# 各Issueについて、JST 今日に自分が close したかを確認
gh api "/repos/${REPO_FULLNAME}/issues/${NUM}/events" --paginate \
  --jq ".[] | select(.actor.login == \"${GH_USER}\") | select(.event == \"closed\") | select(.created_at >= \"${START_UTC}\" and .created_at < \"${END_UTC}\") | .id" | wc -l | tr -d ' '
```

コメントまたは close のいずれかが1以上なら「やったこと」に含める。

#### 3d. 今日作成したIssue

以下を他の収集ステップ（3a〜3c）と**並列で**実行する。

```bash
gh search issues --repo "${REPO_FULLNAME}" --author "${GH_USER}" --created "${SEARCH_START}..${SEARCH_END}" --limit 100 --json number,title,url
```

検出された Issue のうち、`created_at` が JST 今日範囲（`START_UTC` 以上 `END_UTC` 未満）に入るもののみを採用する。

### 履歴・補足

- 旧版で `--commenter` のみだったため、新規作成 Issue が漏れたのを `--author --created` の併用で解消（2025年下半期）
- 2026-04 の見直し:
  - フィルタを `startswith("${TODAY}")` から JST 範囲（`START_UTC..END_UTC`）に変更（タイムゾーン取りこぼし解消）
  - レビューを `/reviews` だけでなく `/pulls/{num}/comments`（インラインコメント）まで対象化
  - PR マージ・Issue close も明示的に「やったこと」へ統合

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
- フリーテキスト入力が必要な場合は、ユーザーは自動付与される **`Other`** を選択する。`options` に `Other` を**明示書きしない**こと（公式仕様で `Other` は自動付与）。質問文に「（自由入力は『Other』を選択）」と明記する。
- `options` は **`minItems: 2`**。選択肢が実質1つしかない質問は、ダミー選択肢（例: 「同上（ダミー、選ばない）」）を加えてバリデーションを満たす。
- 選択肢には具体的な値のみを設定すること。

#### 質問内容

**1回のAskUserQuestionで以下3問をまとめて質問する：**

1. **困っていること**（自由入力は「Other」を選択）
   - 選択肢: 「特になし」「同上（ダミー、選ばない）」
2. **共有事項**（自由入力は「Other」を選択）
   - 選択肢: 「特になし」「同上（ダミー、選ばない）」
3. **勤務時間**（開始時刻、終了時刻、離席をまとめて入力。「Other」で自由入力）
   - 選択肢: 「10:00 - （終了未定、離席なし）」「10:00 - （終了未定、離席あり→Otherで入力）」
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
- 「やったこと」は **3a（コミット / マージしたPR）** + **3c（コメント / クローズしたIssue）** をまとめて1つのリストとして列挙する
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

### タイムゾーン取り扱い

GitHub API の `created_at` / `submitted_at` / `commit.author.date` は **UTC** で記録される。
`gh search` の `--updated` / `--created` レンジも UTC 基準で日付判定される。

そのため、**JST の今日**と一致させたい場合は `startswith("YYYY-MM-DD")` のような UTC 日付文字列比較を使ってはいけない（JST 早朝のアクションは UTC では前日になり、取りこぼす）。
代わりに、JST 今日に対応する UTC 期間（前日 15:00Z 〜 当日 15:00Z）を `START_UTC` / `END_UTC` として算出し、`>=` / `<` で範囲比較する。

`gh search` 系も UTC 基準のため、JST 今日に対応する2日間（昨日と今日）を `--updated` / `--created` レンジに指定して候補を広めに取得し、その後 API レスポンスを `START_UTC`/`END_UTC` で再フィルタする。

### アクション判定の正確性

`updated` フィールドだけで検索すると、他人のアクション（ラベル変更、botの更新など）で更新されたものも含まれてしまう。
必ず以下のAPIで**自分が実際にアクションを起こしたか**を確認すること:

- コミット: `/pulls/{num}/commits` で `author.login` と `commit.author.date` を確認
- マージ: `/issues/{num}/events` で `event == "merged"` と `actor.login` を確認
- レビュー submit: `/pulls/{num}/reviews` で `user.login` と `submitted_at` を確認
- レビューコメント（インライン）: `/pulls/{num}/comments` で `user.login` と `created_at` を確認
- Issue/PR コメント: `/issues/{num}/comments` で `user.login` と `created_at` を確認
- Issue close 等のイベント: `/issues/{num}/events` で `actor.login` と `created_at` を確認

### タスク判定の厳格性

**コメントしただけでは「自分のタスク」に含めない。** 必ず以下のロール確認を行うこと:

- **Issue → やったこと**: `--assignee` で検索したIssueのみ対象。`--commenter` のみのIssueは除外する。
- **PR → レビュー**: `--reviewed-by` で検索した後、`/issues/{num}/events` で `review_requested` イベントを確認し、自分がレビュワーとしてrequestされたPRのみ対象。requestされていないPRは除外する。`/reviews` だけでなく `/pulls/{num}/comments`（インライン）も確認し、いずれか1以上なら採用。
- **PR → やったこと**: author または assignee であり、JST 今日にコミット push またはマージしたもの。
- **Issue作成**: author であること。

### `gh api --paginate --jq length` の落とし穴

`--paginate` は内部で複数回 API 呼び出しを行い、**ページ毎に `--jq` が適用される**。そのため `length` を取るとページ毎に出力されてしまい、合計値にならない。

```bash
# NG: ページごとに length が別々の行で出力される
gh api "/path" --paginate --jq "[.[] | select(...)] | length"
# 出力例:
# 0
# 1

# OK: 要素 ID 等を出力して wc -l で合算
gh api "/path" --paginate --jq ".[] | select(...) | .id" | wc -l | tr -d ' '
```

### zsh の word splitting

このスキルは **zsh で実行される前提**（macOS デフォルトシェル）。bash 風の `for X in $LIST` は zsh では空白で分割されず、リスト全体が1要素として扱われる。

```bash
# NG (zsh): 1要素として扱われ、ループが1回しか回らない
PRS="12389 11911"
for PR in $PRS; do ...; done

# OK: 配列を使う
PRS=(12389 11911)
for PR in "${PRS[@]}"; do ...; done
```

### jq使用時の注意

Claude Code の Bash ツールでは `!=` がエスケープされてエラーになる。代わりに以下を使用：

```bash
# NG: jq 'select(.user.login != "bot")'
# OK: jq 'select(.user.login == "target_user")'
```

