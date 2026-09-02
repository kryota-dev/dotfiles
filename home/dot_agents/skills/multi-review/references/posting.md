# multi-review: PR コメント投稿手順

Phase 5 で選ばれた投稿方法を実行する手順。**投稿本文のプレフィクス（`[MUST]` / `[SHOULD]` /
`[NITS]` / `[GOOD]`）とプロジェクト独自 prefix の扱いは `SKILL.md` の finding schema 節が SSOT**。

## PR コメント投稿手順

### 安全原則（絶対遵守）

- **`event` は `COMMENT` または省略（Pending Review）のみ**。`APPROVE` / `REQUEST_CHANGES` を投稿しない。承認/変更要求は user の明示操作に委ねる（AI が他人 PR を自動承認して merge 事故を起こす経路を構造的に絶つ）。
- **投稿先の owner/repo は Phase 1 で確定した `$OWNER`/`$REPO` のみ**を使う。Phase 5 で書き換えない（cross-repo で誤対象へ投稿する事故を防ぐ）。
- **AI ツールのクレジット・署名**（`Co-Authored-By` / `Generated with ...` 等）を body / インライン / reply に付与しない（`~/AGENTS.md` の global ルール準拠）。

以下の全 `gh api` 呼び出しは Phase 1 で確定した `$OWNER` / `$REPO` / `$PR_NUMBER` を明示的に差し込む（`{owner}`/`{repo}` の字面プレースホルダは gh が cwd に解決してしまうため使わない）。

### 投稿方法の対応（Phase 5 の回答に対応）

| Phase 5 の選択 | 投稿方法 | submit |
|---------------|---------|--------|
| サマリーを body に含めて投稿 | 下記「A. サマリー付きで submit」。`event: "COMMENT"` + `body`（統合サマリー）+ `comments`（インライン） | 即時 submit（body が即表示される） |
| body なしで投稿 | 下記「B. Pending Review 作成」または「A」で `body` を空にする。デフォルトは Pending（`event` 省略）でユーザーに submit を委ねる | Pending（ユーザーが GitHub UI で submit） |

> Note: `(Recommended)` は表示専用の suffix。Phase 5 の選択肢との literal 照合時は strip 済みの label で比較する（e.g. `${selection%% (Recommended)}`）。

### A. サマリー付きで submit（body にサマリー + インライン）

`event: "COMMENT"` を指定すると即座に submit される（`body` とインラインが即表示）。`body` には Phase 3〜4 の統合サマリーを記載する。

```bash
cat <<'PAYLOAD' | gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --method POST --input -
{
  "event": "COMMENT",
  "body": "## Multi-Review 統合レビュー結果\n\n（セキュリティ評価・事実検証で棄却した指摘・GOOD・既存レビュー重複チェック等のサマリー）",
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[SHOULD] コメント本文"
    }
  ]
}
PAYLOAD
```

- `body` にも AI クレジット・署名（`Co-Authored-By` 等）は付けない。
- インラインコメントは差分行（diff hunk 内）にしか付けられない。差分外ファイルへの指摘は body サマリーに記載するか、関連する差分内ファイルの行に紐付ける。

### B. Pending Review 作成（body なし・インラインのみ・ユーザーが submit）

### 1. 既存の Pending Review を確認

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
  --jq '.[] | select(.state == "PENDING") | {id, state, user: .user.login}'
```

### 2. Pending Review がない場合: 新規作成

`event` フィールドを **省略** すると pending 状態になる（`event: "PENDING"` を明示的に指定すると `422` エラー）。

```bash
cat <<'PAYLOAD' | gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --method POST --input -
{
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[SHOULD] コメント本文"
    }
  ]
}
PAYLOAD
```

### 3. Pending Review が既にある場合: GraphQL でコメント追加

REST API では既存の pending review にコメントを追加できないため、GraphQL API を使用する。

#### 3.1. Node ID を取得

```bash
gh api graphql \
  -f query='query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviews(states: PENDING, first: 5) {
          nodes {
            id
            state
            author { login }
          }
        }
      }
    }
  }' \
  -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER"
```

#### 3.2. コメントを追加

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
      "body": "[SHOULD] コメント本文"
    }
  }
}
GQL
```

### コメント対象の選定（Phase 4 の重複除外後）

- **[MUST]** と **[SHOULD]**（重複除外後の新規指摘のみ）をインラインコメントとして投稿する
- **[GOOD]**（既存レビュアーが未言及のもののみ）は称賛コメントとして投稿する（数が多い場合は代表的なものに絞る）
- **[NITS]** は投稿するかどうかをユーザー判断に委ねる
- 既存指摘と同じファイル:行番号で **異なる視点** のときは、Phase 4 の「異なる視点のコメント本文テンプレート」を適用して投稿する
- submit はユーザーに委ねる（Pending 状態のまま）
