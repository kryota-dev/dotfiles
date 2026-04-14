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

---

## Phase 1: 未解決レビュースレッド取得

### 1-1. 未解決・未返信のスレッドのみを取得

GraphQL で取得し、jq パイプで即座に絞り込む。解決済み・返信済みのデータがコンテキストに入るのを防ぐため、**取得と絞り込みは必ず 1 コマンドで行う**。

```bash
MY_LOGIN=$(gh api user --jq .login)

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
]'
```

**設計意図**: 解決済みスレッドや返信済みスレッドのコメント本文がコンテキストに入ると、分析の判断精度が落ちる。jq の `select` と `body[:200]` で不要データを除去し、対応が必要なスレッドのみを最小限のフィールドで取得する。

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

### 1-2. 処理対象がなければ完了

出力が空配列 `[]` なら Phase 8（完了報告）へ直行する。

### 1-3. 詳細コメント本文の取得（必要な場合）

Phase 1-1 で取得した `body[:200]` では指摘内容が切り詰められている場合、Phase 2 の分析時に個別コメントの全文を取得する:

```bash
gh api repos/{owner}/{repo}/pulls/comments/{databaseId} --jq '.body'
```

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
pnpm -F @acsim/api test {関連テストファイル}
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

---

## Phase 4: レビューコメントへの返信

各スレッドの最初のコメントの `databaseId` に対して返信する。

### 4-1. 返信の投稿

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/comments/{databaseId}/replies \
  --method POST \
  -f body="{返信内容}"
```

### 4-2. 返信テンプレート

**対応済み（コード変更あり）:**

```markdown
**対応しました（ {COMMIT_SHA} ）**

{変更内容の簡潔な説明}

---
*Co-Authored-By: {モデル名} <noreply@anthropic.com>*
```

コミット SHA の前後には**半角スペースが必須**。スペースがないと GitHub がリンクとして認識しない。

**対応不要（根拠付き）:**

```markdown
**対応不要と判断しました**

{根拠の説明。以下のパターンから適切なものを選択:}
- 変更前から同じ挙動であり、本PRによる退行ではありません
- 本PRのスコープ外のため、別途対応を検討します
- 前回の {URL} レビューで回答済みです
- {コードパス}:{行番号} の実装を確認した結果、{具体的根拠}

---
*Co-Authored-By: {モデル名} <noreply@anthropic.com>*
```

### 4-3. 返信時の注意事項

- **ローカルのみのドキュメントを根拠にしない**: `.spec-workflow/`, `.claude/` 等のパスは PR コメントの根拠として不適切。GitHub 上で閲覧可能なファイルのみ参照する
- **コードの実際の挙動を根拠にする**: `api-error-handle.ts:44` のように具体的なファイルと行番号で根拠を示す
- **前回回答済みの場合**: 前回の返信 URL を引用して重複を避ける

---

## Phase 5: スレッド Resolve

返信済みの全スレッドを一括 resolve する:

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_id}" }) {
    thread { isResolved }
  }
}'
```

---

## Phase 6: CI 監視

push した変更がある場合のみ実行する。

```bash
gh pr checks {PR番号} --repo {owner}/{repo} --watch
```

CI 失敗時:
1. `gh run view {run_id} --repo {owner}/{repo} --log-failed` でログを取得
2. 失敗原因を分析
3. 修正してコミット・push
4. 再度 CI を監視

---

## Phase 7: 新規レビュー確認（ループ）

CI 通過後（または push がなかった場合は Phase 5 の後）、Phase 1 の GraphQL クエリを再実行して新規の未解決スレッドを確認する。

- **新規スレッドあり** → Phase 1 に戻る
- **新規スレッドなし** → Phase 8 へ

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
