---
name: review-resolve-loop
description: |
  GitHub PRのレビューコメント（AI・人間）を自律的に取得・分析・対応・返信・resolveするスキル。
  未解決スレッドがなくなるまで「取得→分析→対応→返信→resolve→CI監視→再確認」ループを繰り返す。
  「review-resolve-loop」「レビュー対応ループ」「レビュー対応」「レビューに返信」「レビュー返信」
  「review対応」「レビュー指摘に対応」「ボットレビュー対応」「レビューループ」と言及された際に使用。
  PRのレビューコメントが届いた後の対応フロー全体を自動化したい場合に使用する。
argument-hint: "<pr-number-or-url> [対応指示]"
user-invocable: true
---

**ultrathink**

# Review Resolve Loop - 自律レビュー対応スキル

PR のレビューコメントを取得し、各指摘を分析して、対応が必要なものはコード変更・テスト・コミット・push まで行い、全コメントに返信して resolve する。未解決スレッドがなくなるまでループする。

**完了するまで一切の中断・停止をしてはならない。**

---

## Phase 遷移ルール

**Phase を飛ばすことは禁止。** 各 Phase の末尾に記載された遷移先に必ず従うこと。

```text
Phase 0 → Phase 1（常に）
Phase 1 → Phase 2（未解決スレッドあり）
Phase 1 → Phase 8（未解決スレッドなし ← 唯一の Phase スキップ）
Phase 2 → Phase 3（コード変更が必要なスレッドあり）
Phase 2 → Phase 4（全スレッド「対応不要」）
Phase 3 → Phase 4（常に）
Phase 4 → Phase 5（常に）
Phase 5 → Phase 5b（人間レビュアーに返信した場合）
Phase 5 → Phase 6（ボットレビューのみの場合）
Phase 5b → Phase 6（常に）
Phase 6 → Phase 7（CI 全 pass）
Phase 6 → Phase 6 内ループ（CI fail → 修正 → push → 再監視）
Phase 7 → Phase 1（新規未解決スレッドあり）
Phase 7 → Phase 8（新規未解決スレッドなし）
```

**Phase 6 は必ず実行する。** push の有無に関わらず省略不可。
push がなかった場合でも、`gh pr checks --watch` は直前の commit に対する CI 状態を返すため、
review ワークフロー（CodeRabbit, Copilot, claude[bot] 等）の完了待ちとして機能する。
`--watch` が全 check 完了で終了した時点で、ボットレビューコメントは投稿済みであることが保証される。

---

## Phase 0: 準備

### 0-1. 引数解析

`$ARGUMENTS` から PR 情報を抽出する:

- **PR URL** (`https://github.com/` を含む): URL から `owner`, `repo`, `PR番号` を抽出
- **PR 番号のみ** (`#123` や `123`): `git remote get-url origin` から `owner`/`repo` を取得
- **引数なし**: `gh pr view --json number,url --jq '.number'` で現在のブランチの PR を自動検出

追加の指示テキストがあれば記録しておく（対応方針の判断に使用）。

### 0-2. PR メタ情報取得

```bash
gh pr view {PR番号} --json title,headRefName,baseRefName,author --repo {owner}/{repo}
```

### 0-3. 認証ユーザーの取得

返信済み判定に使用する:

```bash
MY_LOGIN=$(gh api user --jq .login)
```

### 遷移
→ **Phase 1** に進む（例外なし）

---

## Phase 1: 未解決レビューコメント取得

GitHub PR のレビューには **2 種類のコメント** がある。両方を取得する必要がある:

| 種類 | 内容 | API | resolve 可否 |
|------|------|-----|-------------|
| **Review threads** | ファイルの特定行に対するインラインコメント | GraphQL `reviewThreads` | ✅ `resolveReviewThread` |
| **Review body** | レビュー全体のサマリーコメント（APPROVE/REQUEST_CHANGES/COMMENT と共に投稿） | REST `pulls/{PR}/reviews` | ❌ スレッドではないため不可 |

### 1-1. 未解決・未返信のスレッドのみを取得（review threads）

GraphQL で取得し、jq パイプで即座に絞り込む。解決済み・返信済みのデータがコンテキストに入るのを防ぐため、**取得と絞り込みは必ず 1 コマンドで行う**。結果は**一時ファイルに出力**する（GitHub API レスポンスに制御文字が含まれる場合、シェル変数経由だと jq パースエラーになるため）。

```bash
MY_LOGIN=$(gh api user --jq .login)
TMP_THREADS=$(mktemp)

gh api graphql -f query='{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {PR番号}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 20) {
            nodes {
              databaseId
              author { login }
              body
              url
            }
          }
        }
      }
    }
  }
}' --jq '
[
  .data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved == false)
  | {
      type: "review_thread",
      id,
      path,
      line,
      isOutdated,
      reviewer: .comments.nodes[0].author.login,
      isBot: (.comments.nodes[0].author.login | test("^(coderabbitai|claude|devin-ai-integration|copilot|github-actions|dependabot)")),
      hasMyReply: ([.comments.nodes[] | select(.author.login == "'"$MY_LOGIN"'")] | length > 0),
      replyDatabaseId: .comments.nodes[0].databaseId,
      comments: [.comments.nodes[] | {author: .author.login, body: .body[:200], url: .url}]
    }
  | select(.hasMyReply == false)
]' > "$TMP_THREADS"
```

**設計意図**: 解決済みスレッドや返信済みスレッドのコメント本文がコンテキストに入ると、分析の判断精度が落ちる。jq の `select` と `body[:200]` で不要データを除去し、対応が必要なスレッドのみを最小限のフィールドで取得する。結果は一時ファイル（`$TMP_THREADS`）に出力し、後続 Phase で `jq` で読み取る。

100 件を超える場合は `after` カーソルでページネーションする。

**出力フィールド**:

| フィールド | 用途 |
|-----------|------|
| `id` | Phase 5 の resolve に使用 |
| `path`, `line` | Phase 2 のコード読み込み対象 |
| `isBot` | 対応方針テーブルでのレビュアー種別表示 |
| `replyDatabaseId` | Phase 4 の返信先 |
| `comments[].body[:200]` | 指摘内容の概要（詳細は Phase 2 で必要に応じて全文取得） |
| `comments[].url` | 前回回答済みの場合の参照先 |

**ボット判定**: jq の `test()` で正規表現マッチ。Claude Code の Bash では `!` が履歴展開として解釈されるため、否定には `| not` を使用する。

### 1-1b. 未返信の review body を取得

review body は `reviewThreads` には含まれないため、別途 REST API で取得する。返信済み判定には Issue comment 内の hidden marker（`<!-- review-body-reply: {reviewId} -->`）を使用する。

```bash
MY_LOGIN=$(gh api user --jq .login)
TMP_REVIEWS=$(mktemp)
TMP_REPLIED=$(mktemp)

# Step 1: body が空でない review を取得
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --paginate --jq '
[
  .[]
  | select(.body | length > 0)
  | select(.state != "DISMISSED")
  | {
      type: "review_body",
      reviewId: .id,
      reviewer: .user.login,
      isBot: (.user.login | test("^(coderabbitai|claude|devin-ai-integration|copilot|github-actions|dependabot)")),
      state: .state,
      body: .body[:500],
      submittedAt: .submitted_at
    }
]' > "$TMP_REVIEWS"

# Step 2: 自分が返信済みの review ID を取得（hidden marker で判定）
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate --jq '
  [.[] | select(.user.login == "'"$MY_LOGIN"'") | select(.body | test("<!-- review-body-reply:")) | .body | capture("<!-- review-body-reply: (?<id>[0-9]+) -->") | .id] | unique // []
' > "$TMP_REPLIED"

# Step 3: 未返信の review body のみフィルタ
jq --slurpfile replied "$TMP_REPLIED" '
  [.[] | select((.reviewId | tostring) as $rid | ($replied[0] | map(tostring) | index($rid)) | not)]
' "$TMP_REVIEWS"

rm -f "$TMP_REVIEWS" "$TMP_REPLIED"
```

**設計意図**: review body は制御文字を含む場合があるため、シェル変数ではなく一時ファイル経由で処理する。hidden marker 方式により、スキル再実行時の重複処理を防止する。

**出力フィールド**:

| フィールド | 用途 |
|-----------|------|
| `reviewId` | Phase 4 の返信マーカーに使用 |
| `reviewer` | 対応方針テーブルでのレビュアー名表示 |
| `isBot` | ボット判定 |
| `body[:500]` | 指摘内容の概要 |

### 1-2. 処理対象がなければ完了

Phase 1-1 と Phase 1-1b の両方の出力が空配列 `[]` なら Phase 8（完了報告）へ直行する。

### 1-3. 詳細コメント本文の取得（必要な場合）

Phase 1-1 で取得した `body[:200]` では指摘内容が切り詰められている場合、Phase 2 の分析時に個別コメントの全文を取得する:

```bash
# review thread のコメント全文
gh api repos/{owner}/{repo}/pulls/comments/{databaseId} --jq '.body'

# review body の全文
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews/{reviewId} --jq '.body'
```

review body に画像（`<img>` タグや `![image](url)`）が含まれている場合は、`gh-asset` や認証付き curl で画像をダウンロードし、Read ツールで内容を確認する。**画像のダウンロードに失敗した場合は、ユーザーに画像 URL を報告し手動ダウンロードを依頼する。「テキスト部分で十分判断できる」等の独断は禁止** — 画像が判断に必要かどうかの判断自体をユーザーに委ねること。

### 遷移
- 未解決スレッドあり → **Phase 2** に進む
- 未解決スレッドなし → **Phase 8** に進む（これが唯一の Phase スキップ）

---

## Phase 2: 各スレッドの分析

未解決・未返信のスレッドを 1 件ずつ分析する。

### 2-1. コメント内容の読解

スレッド内の全コメントを時系列で読み、指摘の本質を理解する。ボットによってフォーマットが異なる:

- **coderabbitai**: `_⚠️ Potential issue_ | _🟠 Major_` で重要度表示。`🤖 Prompt for AI Agents` に修正指示あり
- **Copilot**: `[must]`/`[ask]` プレフィックスで分類。`suggestion` コードブロックで修正案提示
- **devin-ai-integration**: `🔴`/`🟡` で重要度表示
- **claude[bot]**: 自由形式だがガイドライン引用を含むことが多い

### 2-2. 関連コードの実際の読み込み

**重要: 憶測ではなく、コード・ドキュメントを実際に読んで判断する。**

- `path` と `line` から対象ファイルの該当箇所を Read ツールで読む
- 指摘が参照している他のファイル（テスト、ドキュメント、設定ファイル等）も読む
- プロジェクトの規約ドキュメント（AGENTS.md, docs/coding/ 等）で指摘の妥当性を検証する

### 2-3. 対応方針の考察

各スレッドに対して、コードとドキュメントを実際に読んだ上で、以下のいずれかに分類する:

| 判断 | 条件例 |
|------|-------|
| **対応する** | バグ修正、規約違反の修正、テストパターンの統一、ドキュメント整合性修正 |
| **対応不要** | 退行なし（変更前から同じ挙動）、スコープ外、前回回答済みと同一指摘、他ボットの矛盾する指摘に既に対応済み |

**退行（regression）の確認**: 指摘された箇所が変更前から同じ挙動であれば「退行なし」として対応不要と判断できる。`git diff {base}...HEAD` で変更範囲を確認する。

### 2-4. 対応方針のユーザー承認

全スレッドの分析が完了したら、考察結果を一覧表にまとめて `AskUserQuestion` でユーザーに提示し、最終判断を委ねる。**ボットレビュー・人間レビューの区別なく、必ずユーザー承認を経る。**

提示形式:

```markdown
## レビュー対応方針

| # | スレッド | レビュアー | 指摘概要 | 判断 | 根拠 |
|---|---------|-----------|---------|------|------|
| 1 | {path}:{line} | {reviewer} | {指摘の要約} | 対応する | {根拠} |
| 2 | {path}:{line} | {reviewer} | {指摘の要約} | 対応不要 | {根拠} |
```

ユーザーの選択肢:
- 「この方針で進める」→ Phase 3 へ（対応するもの）/ Phase 4 へ（対応不要のもの）
- 「修正がある」→ ユーザーの指示に従い方針を調整して再提示

### 遷移
- 「対応する」スレッドあり → **Phase 3** に進む
- 全スレッド「対応不要」 → **Phase 4** に進む

---

## Phase 3: コード変更の実施

対応が必要と判断したスレッドのコード変更を行う。同一コミットにまとめられる変更はまとめる。

### 3-1. 変更の実施

- ファイルの修正（Edit ツール使用）
- 関連テストの修正・追加（必要な場合）

### 3-2. 品質チェック

プロジェクトの品質チェックコマンドを実行する。`package.json` の `scripts` から判断:

```bash
# 例（プロジェクトに応じて変更）
pnpm format && pnpm check
pnpm -F @apps/api test {関連テストファイル}
```

### 3-3. コミット & push

```bash
git add {変更ファイル}
git commit -m "{type}({scope}): レビュー指摘対応 — {変更内容の要約}"
git push
```

push が `protected branch hook declined` で失敗した場合は、merge queue 実行中の可能性がある。`notify` でユーザーに通知し、解消後にリトライする。

### 3-4. コミット SHA の記録

```bash
COMMIT_SHA=$(git rev-parse HEAD)
```

### 遷移
→ **Phase 4** に進む（例外なし）

---

## Phase 4: レビューコメントへの返信

### 4-1. 返信の投稿

**review thread への返信**（インラインコメント）:

各スレッドの最初のコメントの `databaseId` に対して返信する。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments/{databaseId}/replies \
  --method POST \
  -f body="{返信内容}"
```

**review body への返信**（レビュー全体のサマリーコメント）:

review body はスレッドではないため、Issue comment として投稿する。返信済み判定用の hidden marker を必ず含める。

```bash
gh api repos/{owner}/{repo}/issues/{PR番号}/comments \
  --method POST \
  -f body="{返信内容}

<!-- review-body-reply: {reviewId} -->"
```

### 4-1b. 人間レビュアーへの返信内容のユーザー承認

**人間レビュアー（`isBot == false`）への返信は、投稿前に必ず `AskUserQuestion` でユーザーに返信内容を提示し承認を得る。** ボットレビューへの返信は定型文のため承認不要。

提示形式:

```markdown
## 返信内容の確認

**スレッド**: {path}:{line} ({reviewer})

> {返信内容案}

この内容で返信してよいですか？
```

### 4-2. 返信テンプレート

**人間レビュアーへの返信**: 冒頭に `@{reviewer}` メンションを付ける。ボットへの返信にはメンション不要。

**対応済み（コード変更あり）:**

```markdown
@{reviewer} **対応しました（ {COMMIT_SHA} ）**

{変更内容の簡潔な説明}

---
*Co-Authored-By: {モデル名} <noreply@anthropic.com>*
```

コミット SHA の前後には**半角スペースが必須**。スペースがないと GitHub がリンクとして認識しない。

**対応不要（根拠付き）:**

```markdown
@{reviewer} **対応不要と判断しました**

{根拠の説明。以下のパターンから適切なものを選択:}
- 変更前から同じ挙動であり、本PRによる退行ではありません
- 本PRのスコープ外のため、別途対応を検討します
- 前回の {URL} レビューで回答済みです
- {コードパス}:{行番号} の実装を確認した結果、{具体的根拠}

---
*Co-Authored-By: {モデル名} <noreply@anthropic.com>*
```

**review body への返信（Issue comment として投稿）:**

review body への返信は Issue comment として投稿する。hidden marker を必ず末尾に含める（Phase 1-1b の返信済み判定に使用）:

```markdown
@{reviewer} > {review body の指摘を引用}

{返信内容}

<!-- review-body-reply: {reviewId} -->
---
*Co-Authored-By: {モデル名} <noreply@anthropic.com>*
```

> **Note**: ボットレビューへの返信では `@{reviewer}` メンションを省略する。

### 4-3. 返信時の注意事項

- **`@` を含む body の投稿**: `gh api` の `-F` フラグでは `@` で始まる値がファイル参照として解釈される。返信内容に `@` メンションを含む場合は、一時ファイルに書き出してから `-F body=@/tmp/reply.txt` で渡すこと
- **ローカルのみのドキュメントを根拠にしない**: `.spec-workflow/`, `.claude/` 等のパスは PR コメントの根拠として不適切。GitHub 上で閲覧可能なファイルのみ参照する
- **コードの実際の挙動を根拠にする**: `api-error-handle.ts:44` のように具体的なファイルと行番号で根拠を示す
- **前回回答済みの場合**: 前回の返信 URL を引用して重複を避ける

### 遷移
→ **Phase 5** に進む（例外なし）

---

## Phase 5: スレッド Resolve（ボットのみ）

**ボットレビュー（`isBot == true`）のスレッドのみ** 自動 resolve する。**人間レビュー（`isBot == false`）のスレッドは resolve しない** — レビュアー本人が確認して resolve する。

```bash
# ボットレビューのスレッドのみ resolve
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_id}" }) {
    thread { isResolved }
  }
}'
```

**注意**:
- review body はスレッドではないため `resolveReviewThread` の対象外。Phase 4 で Issue comment として返信し、hidden marker を含めることで「対応済み」を表現する。
- outdated スレッドであっても、人間レビューの場合は resolve しない。

### 遷移
- 人間レビュアーに返信した場合 → **Phase 5b** に進む
- ボットレビューのみの場合 → **Phase 6** に進む

---

## Phase 5b: 人間レビュアーへの Re-request review

人間レビュアーに返信した場合、返信完了後に Re-request review を行う。ボットレビューには不要。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/requested_reviewers \
  --method POST \
  -f 'reviewers[]={reviewer}'
```

これにより、レビュアーに「返信があったので再確認してほしい」という通知が届く。

### 遷移
→ **Phase 6** に進む（例外なし）

---

## Phase 6: CI 監視

**このPhaseは必ず実行する。省略禁止。**

push がなかった場合でも、`gh pr checks --watch` は直前の commit に対する CI 状態を返す。
review ワークフロー（CodeRabbit, Copilot, claude[bot]）は GitHub Actions として実行されるため、
`--watch` が全 check 完了で終了した時点で、ボットレビューコメントは投稿済みであることが保証される。

### 6-1. 全 check の完了を待つ

```bash
gh pr checks {PR番号} --repo {owner}/{repo} --watch
```

### 6-2. fail 判定

**`gh pr checks` の出力を `tail` / `head` 等で切り詰めることは禁止。** 全行を確認すること。

`--watch` 完了後、**必ず別コマンドで** fail 件数を数値として取得する:

```bash
FAIL_COUNT=$(gh pr checks {PR番号} --repo {owner}/{repo} | grep -ic "fail")
echo "Failed checks: $FAIL_COUNT"
```

### 6-2b. 禁止事項

以下の操作は明示的に禁止する:

- `gh pr checks` の出力を `tail`, `head`, `sed`, `awk` 等で切り詰めること
- 一部の check のみを確認して「全 pass」と判断すること
- `--watch` なしで `gh pr checks` を実行し、pending の check を無視すること
- Phase 6 自体をスキップすること（push の有無に関わらず）

### 6-3. fail 時の対応

```bash
# 失敗した check の一覧
gh pr checks {PR番号} --repo {owner}/{repo} | grep -i "fail"

# 失敗した run のログ
gh run view {run_id} --repo {owner}/{repo} --log-failed
```

1. 失敗原因を分析
2. コード修正 → コミット → push
3. **6-1 に戻り**再度 `--watch` で全 check 完了を待つ
4. 2 回連続同一原因で失敗: `notify` でユーザーに報告

### 遷移
- `FAIL_COUNT == 0` → **Phase 7** に進む
- `FAIL_COUNT > 0` → 修正後 **Phase 6-1** に戻る

---

## Phase 7: 新規レビュー確認（ループ）

Phase 6 完了後に実行する。Phase 6 の `--watch` が全 check 完了を待っているため、
review ワークフロー（ボットレビュー）も完了済みであることが保証されている。

### 7-1. 未解決スレッドの再取得

Phase 1-1 と同じ GraphQL クエリを再実行し、新規の未解決・未返信 review threads を確認する。

### 7-2. 未返信 review body の再取得

Phase 1-1b と同じ REST API クエリを再実行し、新規の未返信 review body を確認する。

### 7-3. 判定

- **7-1 または 7-2 で 1 件以上あり** → **Phase 1** に戻る（新ラウンド開始）
- **両方とも 0 件** → **Phase 8** に進む

### 遷移
- 新規未解決スレッド or 未返信 review body あり → **Phase 1** に戻る
- 両方なし → **Phase 8** に進む

---

## Phase 8: 完了報告

```bash
notify
```

処理結果のサマリーを表示:

```markdown
## review-resolve-loop 完了

### PR: {owner}/{repo}#{PR番号}

| # | スレッド | レビュアー | 判断 | コミット |
|---|---------|-----------|------|---------|
| 1 | {path}:{line} | {author} | 対応済み | {SHA} |
| 2 | {path}:{line} | {author} | 対応不要 | — |

- 処理ラウンド数: {N}
- 対応済み: {N}件 / 対応不要: {N}件
- 未解決スレッド: 0件
```

---

## エッジケース対処

| ケース | 対処 |
|-------|------|
| スレッド 100 件超 | GraphQL の `after` カーソルでページネーション |
| 同一ファイル・同一行に複数スレッド | 各スレッドを独立に処理。コード変更は 1 コミットにまとめ、各スレッドに同一 SHA で返信 |
| outdated スレッド | `isOutdated == true` かつ未解決の場合、コードを確認して対応済みなら resolve |
| 矛盾するボット指摘（A が X を、B が Y を提案） | ユーザーに確認を求める |
| push 認証エラー（1Password 等） | `notify` でユーザーに通知し、リトライを待つ |
| CI flaky 失敗 | 1 回のみ自動リトライ。2 回目も失敗なら報告 |
| 自分が起点のスレッド | スキップ（他者の指摘ではない） |
| author が null（deleted ユーザー） | ボット扱いで自律対応 |
| 画像添付あり | **ユーザーに報告し手動ダウンロードを依頼**（独断で「テキストで十分」と判断しない） |
| review body の API レスポンスに制御文字 | シェル変数ではなく一時ファイル経由で jq 処理（Phase 1-1b 参照） |
| Phase 6 で push なしの場合 | `gh pr checks --watch` を実行し review ワークフロー完了を待つ。push なしでも直前 commit の CI 状態が返される。ボットレビュー投稿の保証に必要 |
