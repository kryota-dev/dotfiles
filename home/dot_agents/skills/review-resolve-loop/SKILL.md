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
Phase 5 → Phase 5b（真の人間レビュアー＝非ボット・非セルフに返信した場合）
Phase 5 → Phase 6（ボット・セルフレビューのみの場合）
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

GitHub PR のレビュー由来のコメントには **3 種類** がある。すべてを取得する必要がある:

| 種類 | 内容 | API | resolve 可否 |
|------|------|-----|-------------|
| **Review threads** | ファイルの特定行に対するインラインコメント | GraphQL `reviewThreads` | ✅ `resolveReviewThread` |
| **Review body** | レビュー全体のサマリーコメント（APPROVE/REQUEST_CHANGES/COMMENT と共に投稿） | REST `pulls/{PR}/reviews` | ❌ スレッドではないため不可 |
| **CI レビューコメント** | CI ワークフロー（`.github/workflows/claude-review.yml` / `claude-self-merge-check.yml`）が marker 付きで upsert する Issue comment（`<!-- claude-code-review -->` / `<!-- claude-self-merge-check -->`、`github-actions[bot]` が投稿） | REST `issues/{PR}/comments`（marker 検索） | ❌ Issue comment のため不可 |

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
      isSelf: ((.comments.nodes[0].author.login == "'"$MY_LOGIN"'") and (([.comments.nodes[] | select(.author.login == "'"$MY_LOGIN"'")] | length) == (.comments.nodes | length))),
      hasMyReply: ([.comments.nodes[] | select(.author.login == "'"$MY_LOGIN"'")] | length > 0),
      replyDatabaseId: .comments.nodes[0].databaseId,
      comments: [.comments.nodes[] | {author: .author.login, body: .body[:200], url: .url}]
    }
  | select(.isSelf == true or .hasMyReply == false)
]' > "$TMP_THREADS"
```

**設計意図**: 解決済みスレッドや返信済みスレッドのコメント本文がコンテキストに入ると、分析の判断精度が落ちる。jq の `select` と `body[:200]` で不要データを除去し、対応が必要なスレッドのみを最小限のフィールドで取得する。結果は一時ファイル（`$TMP_THREADS`）に出力し、後続 Phase で `jq` で読み取る。

**セルフレビューの取り込み（`isSelf`）**: `multi-review` 等が自分（`$MY_LOGIN`）名義で投稿した inline レビュー（`[MUST]`/`[imo]`/`[nits]` 等）は、起点コメントが自分のため `hasMyReply` が常に `true` になり、`hasMyReply == false` だけでは取得段階で落ちてしまう。そこで **純粋セルフ**（起点が自分 **かつ** スレッド内の全コメントが自分名義 = 他者の参加がない）を `isSelf` で判定し、`select(.isSelf == true or .hasMyReply == false)` で取得対象に含める。

- **純粋セルフのみを対象とする理由**: 自分が起点でも他者（人間レビュアー等）が返信して議論が続いている thread を一律セルフ扱いで自動 resolve すると、進行中の会話を勝手にクローズしてしまう。他者が参加した自分起点 thread は `isSelf == false` となり `hasMyReply == true` のまま除外される（従来挙動を維持）。
- **完了判定の軸**: セルフ thread は `hasMyReply` が常時 `true` のため返信有無では完了判定できない。**`isResolved` を完了軸**とし、ループ内で対応・返信後に Phase 5 で resolve すれば、次ラウンドは冒頭の `select(.isResolved == false)` で自動除外される（ボットと同じ resolve ベースの完了モデル）。
- **`!=` 回避**: 「全コメントが自分名義」の判定は否定（`!=`）を使わず、自分名義コメント数とコメント総数の `length` 一致で表現する（Bash の履歴展開対策、後述のボット判定と同方針）。

100 件を超える場合は `after` カーソルでページネーションする。

**出力フィールド**:

| フィールド | 用途 |
|-----------|------|
| `id` | Phase 5 の resolve に使用 |
| `path`, `line` | Phase 2 のコード読み込み対象 |
| `isBot` | 対応方針テーブルでのレビュアー種別表示 |
| `isSelf` | 純粋セルフレビュー判定。Phase 4（返信＝ボット同等・自分宛メンション省略）／Phase 5（自動 resolve）／Phase 5b（re-request スキップ）の分岐に使用 |
| `replyDatabaseId` | Phase 4 の返信先 |
| `comments[].body[:200]` | 指摘内容の概要（詳細は Phase 2 で必要に応じて全文取得） |
| `comments[].url` | 前回回答済みの場合の参照先 |

**ボット判定**: jq の `test()` で正規表現マッチ。Claude Code の Bash では `!` が履歴展開として解釈されるため、否定には `| not` を使用する。

### 1-1b. 未返信の review body を取得（空でない body は常に取得）

review body は `reviewThreads` には含まれないため、別途 REST API で取得する。返信済み判定には Issue comment 内の hidden marker（`<!-- review-body-reply: {reviewId} -->`）を使用する。

**取得方針**: 空でない（かつ非 DISMISSED・未返信の）review body は **種別を問わず常に取得**し、コンテキストに入れて分析する。**取得と返信は別レイヤ**であり、返信するか否かは Phase 2-3b で「実質的な指摘があるか」で判定する。

review body には 2 種類あるが、**いずれも取得対象とする**:

1. **個別 thread のサマリー** （`reviews/{reviewId}/comments` に thread comments が紐づく）: 例 `"Actionable comments posted: 2"`、`"1 new potential issue"`。本体は thread 側にあるため、**多くの場合 Phase 2-3b で「返信不要」**になる（個別 thread で対応する）。ただし取得自体は行い、内容を把握する
2. **body 単独レビュー** （thread comments が紐づかない）: 例 CoderabbitのNitpick が body 内に inline コードや diff として書かれているケース。thread では返信できないため、Phase 2-3b で「返信対象」と判定されれば review body への返信が必要になる

```bash
MY_LOGIN=$(gh api user --jq .login)
TMP_REVIEWS=$(mktemp)
TMP_REPLIED=$(mktemp)

# Step 1: body が空でない review を取得（種別を問わず常に取得）
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
      isSelf: (.user.login == "'"$MY_LOGIN"'"),
      state: .state,
      body: .body[:500],
      submittedAt: .submitted_at
    }
]' > "$TMP_REVIEWS"

# Step 2: 自分が返信済みの review ID を取得（hidden marker で判定）
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate --jq '
  [.[] | select(.user.login == "'"$MY_LOGIN"'") | select(.body | test("<!-- review-body-reply:")) | .body | capture("<!-- review-body-reply: (?<id>[0-9]+) -->") | .id] | unique // []
' > "$TMP_REPLIED"

# Step 3: 「未返信」の review body のみフィルタ（種別での絞り込みはしない）
jq --slurpfile replied "$TMP_REPLIED" '
  [.[]
   | select((.reviewId | tostring) as $rid | ($replied[0] | map(tostring) | index($rid)) | not)
  ]
' "$TMP_REVIEWS"

rm -f "$TMP_REVIEWS" "$TMP_REPLIED"
```

**設計意図**:
- review body は制御文字を含む場合があるため、シェル変数ではなく一時ファイル経由で処理する
- hidden marker 方式により、スキル再実行時の重複処理を防止する
- **取得は種別を問わず常に行う**: 個別 thread のサマリーであっても body をコンテキストに入れ、PR 全体の状況把握に使う。サマリーへの過剰返信は「取得段階の除外」ではなく **Phase 2-3b の返信判定（実質的な指摘があるか）** で防ぐ
- **`isSelf`**: 自分（`$MY_LOGIN`）名義の review body（`multi-review` の body サマリー等）を識別する。body は resolve できないため、返信要否は Phase 2-3b の内容判定に委ね、「返信不要」となったものは Phase 7 の台帳で再トリガーから除外する

**出力フィールド**:

| フィールド | 用途 |
|-----------|------|
| `reviewId` | Phase 4 の返信マーカーに使用 |
| `reviewer` | 対応方針テーブルでのレビュアー名表示 |
| `isBot` | ボット判定 |
| `isSelf` | セルフ body（`multi-review` のサマリー等）判定。Phase 4 のメンション省略・Phase 2-3b の返信判定に使用 |
| `body[:500]` | 指摘内容の概要 |

### 1-1c. 未返信の CI レビューコメントを取得（marker 付き Issue comment）

CI ワークフローは、レビュー結果を **marker 付きの Issue comment** として upsert する。これらは review threads にも review body にも含まれないため、別途 Issue comment を marker で検索して取得する。

| marker | ワークフロー | 内容 |
|--------|-------------|------|
| `<!-- claude-code-review -->` | `claude-review.yml` | ci-review skill の指摘サマリ（例「🔺 人間レビュー必須」、actionable な指摘を含む） |
| `<!-- claude-self-merge-check -->` | `claude-self-merge-check.yml` | セルフマージ可否判定の「PR レビューサマリー」 |

**重要 — upsert される性質**: これらのコメントは marker で **同一コメントを PATCH 更新** する（1 marker につき 1 コメント）。CI が再実行されると **同じ comment id のまま本文が書き換わる**。したがって返信済み判定は comment id 単体ではなく **`commentId@updatedAt`** をキーにする。本文が更新（= 新しい CI 実行）されれば `updatedAt` が変わり、再評価対象になる。

```bash
MY_LOGIN=$(gh api user --jq .login)
TMP_CI=$(mktemp)
TMP_CI_REPLIED=$(mktemp)

# Step 1: marker 付き Issue comment を取得
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate --jq '
[
  .[]
  | select(.body | test("<!-- claude-code-review -->|<!-- claude-self-merge-check -->"))
  | {
      type: "ci_review_comment",
      commentId: .id,
      reviewer: .user.login,
      isBot: true,
      marker: (if (.body | test("<!-- claude-self-merge-check -->")) then "claude-self-merge-check" else "claude-code-review" end),
      updatedAt: .updated_at,
      body: .body[:1000],
      url: .html_url
    }
]' > "$TMP_CI"

# Step 2: 自分が返信済みの CI コメント（commentId@updatedAt）を取得
gh api repos/{owner}/{repo}/issues/{PR番号}/comments --paginate --jq '
  [.[] | select(.user.login == "'"$MY_LOGIN"'") | select(.body | test("<!-- ci-review-reply:")) | .body | capture("<!-- ci-review-reply: (?<key>[^ ]+) -->") | .key] | unique // []
' > "$TMP_CI_REPLIED"

# Step 3: 未返信（commentId@updatedAt が一致しない）のみフィルタ
jq --slurpfile replied "$TMP_CI_REPLIED" '
  [.[] | select((((.commentId|tostring) + "@" + .updatedAt)) as $key | ($replied[0] | index($key)) | not)]
' "$TMP_CI"

rm -f "$TMP_CI" "$TMP_CI_REPLIED"
```

**設計意図**:
- review body 同様、CI コメントは制御文字を含み得るため一時ファイル経由で処理する
- `commentId@updatedAt` の hidden marker（`<!-- ci-review-reply: {commentId}@{updatedAt} -->`）で「この内容に対しては返信済み」を表現し、CI 再実行で本文が更新されたら再評価する
- `marker` フィールドで `claude-code-review`（actionable な指摘を含む）か `claude-self-merge-check`（サマリ中心）かを区別し、Phase 2-3c の対応方針判定に使う

**出力フィールド**:

| フィールド | 用途 |
|-----------|------|
| `commentId` / `updatedAt` | Phase 4 の返信マーカー（`commentId@updatedAt`）に使用 |
| `marker` | Phase 2-3c の対応方針判定 |
| `body[:1000]` | 指摘内容の概要（詳細は Phase 1-3 で全文取得） |
| `url` | 参照先 |

CI コメントの全文取得が必要な場合:

```bash
gh api repos/{owner}/{repo}/issues/comments/{commentId} --jq '.body'
```

### 1-2. 処理対象がなければ完了

Phase 1-1 / Phase 1-1b / Phase 1-1c の **すべての出力が空配列 `[]`** なら Phase 8（完了報告）へ直行する。

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
- 処理対象（review thread / review body / CI レビューコメントのいずれか）あり → **Phase 2** に進む
- 処理対象なし → **Phase 8** に進む（これが唯一の Phase スキップ）

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

**セルフ inline thread（`isSelf == true`）の扱い**: `multi-review` 等が自分名義で投稿したセルフレビューも、上記と同じく「対応する／対応不要」を判定する。ただし返信・resolve の挙動が一部異なるため、以下の 3 分類で考える:

| 分類 | 例 | 返信 | resolve |
|------|----|------|---------|
| **actionable な指摘（対応する）** | `[MUST]`/`[SHOULD]`/`[imo]` のバグ・規約違反・修正提案 | する（Phase 4、対応済み SHA 付き） | する（Phase 5） |
| **指摘ありだが対応不要** | 退行なし・スコープ外と判断したセルフ指摘 | する（Phase 4、根拠付き） | する（Phase 5） |
| **`[GOOD]`/非 actionable（称賛・指摘なし）** | `[GOOD]` の称賛コメント等、対応も返信も不要なもの | **しない**（自分の称賛への対応不要返信はノイズ） | する（Phase 5、**silent resolve**） |

**ポイント**: セルフ thread はボット同等に「対応したかどうか」を返信するが、`[GOOD]`/非 actionable なものだけは **返信せず resolve のみ**（silent resolve）とする。いずれの分類でも Phase 5 で必ず resolve するため、未解決のまま次ラウンドに残らない。

### 2-3b. review body の対応方針判定

Phase 1-1b で取得した review body（種別を問わず全件取得済み）の本文を読んで、以下のいずれかに分類:

| パターン | 例 | 対応方針 |
|---|---|---|
| **body 自体が実質的な指摘** | CoderabbitのNitpickコメントが body 内に inline コードや diff として書かれているケース（thread に紐づかない body 単独レビュー） | **返信対象**（thread では返信できないため、Phase 4 で Issue comment として返信） |
| **個別 thread のサマリー** | `"Actionable comments posted: 2"` 等、本体が個別 thread 側にある要約 | **返信不要**（個別 thread で対応するため。body への返信は重複） |
| **No Issues / 内容なしの ack** | devin "No Issues Found"、人間の "見ました！！" | **返信不要**（指摘なし、ノイズ回避。ボット・人間問わず適用） |

**判定基準**: body 内に「修正提案」「具体的な懸念」「コード差分」等の実質的な指摘があり、**かつ その指摘が個別 thread 側に存在しない**（body でしか返信できない）かどうか。挨拶・要約・「No Issues」・個別 thread のサマリーのみなら返信不要。**返信不要としたものは Phase 7 の台帳で再トリガーから除外する**（body は resolve できないため）。

### 2-3c. CI レビューコメントの対応方針判定

Phase 1-1c で取得した CI レビューコメント（marker 付き Issue comment）の全文を読んで、以下のいずれかに分類する。判定軸は review body（2-3b）と同じく「実質的な指摘があるか」だが、CI コメント特有の観点を加える:

| marker / 内容 | 例 | 対応方針 |
|---|---|---|
| **actionable な指摘を含む** | `claude-code-review` が具体的なバグ・規約違反・修正提案を列挙 | **対応する**（Phase 3 でコード対応 → Phase 4 で返信） |
| **人間レビュー必須・マージブロックの通知** | `claude-code-review` の「🔺 人間レビュー必須」、`claude-self-merge-check` の「セルフマージ不可」判定 | **返信対象**（コード対応は不要だが、認識した旨と対応方針を Phase 4 で返信。ユーザーに状況を共有） |
| **サマリ / セルフマージ可 / 指摘なし** | `claude-self-merge-check` の「PR レビューサマリー」「セルフマージ可」、指摘のない概要 | **返信不要**（ノイズ回避） |

**注意**: `claude-self-merge-check` は多くの場合サマリで `返信不要`。`claude-code-review` は actionable な指摘を含むことがあるため必ず全文を読んで判定する。コード対応が必要な指摘は review thread と同様に Phase 3 で対応する。

### 2-4. 対応方針のユーザー承認

全スレッドの分析が完了したら、考察結果を一覧表にまとめて `AskUserQuestion` でユーザーに提示し、最終判断を委ねる。**ボットレビュー・人間レビューの区別なく、必ずユーザー承認を経る。**

提示形式:

```markdown
## レビュー対応方針

| # | 対象 | レビュアー | 指摘概要 | 判断 | 根拠 |
|---|------|-----------|---------|------|------|
| 1 | {path}:{line}（thread） | {reviewer} | {指摘の要約} | 対応する | {根拠} |
| 2 | review body | {reviewer} | {指摘の要約} | 対応不要 | {根拠} |
| 3 | CI: {marker} | github-actions[bot] | {指摘の要約} | 対応する | {根拠} |
| 4 | {path}:{line}（self thread） | kryota-dev (self) | {セルフ指摘の要約} | 対応する | {根拠} |
| 5 | {path}:{line}（self thread） | kryota-dev (self) | [GOOD] 称賛 | 返信不要・resolve のみ | 非 actionable |
```

セルフレビュー（`isSelf == true`）は、レビュアー列に `{login} (self)` と明記して人間・ボットと区別する。

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

**review body への返信**:

review body はスレッドではないため、Issue comment として投稿する。返信済み判定用の hidden marker を必ず含める。

**ただし、Phase 2-3b で「返信対象」と判定した review body に対してのみ実施する**。個別 thread のサマリー review body や No Issues / ack には返信しない（重複応答とノイズを回避）。セルフ body（`isSelf == true`）への返信ではメンション（`@{自分のlogin}`）を付けない（4-2 参照）。

```bash
gh api repos/{owner}/{repo}/issues/{PR番号}/comments \
  --method POST \
  -f body="{返信内容}

<!-- review-body-reply: {reviewId} -->"
```

**CI レビューコメントへの返信**（Phase 1-1c の marker 付き Issue comment）:

CI レビューコメントもスレッドではないため、Issue comment として投稿する。返信済み判定用の hidden marker は **`commentId@updatedAt`** をキーにする（upsert で本文が更新されたら再評価するため）。**Phase 2-3c で「対応する」「返信対象」と判定したものにのみ返信**する（サマリ / セルフマージ可 / 指摘なしには返信しない）。

```bash
# CI コメント（github-actions）へは @ メンションを付けない（4-2 参照）。本文に他の @ が含まれ得るため一時ファイル経由で投稿する（4-3 参照）
gh api repos/{owner}/{repo}/issues/{PR番号}/comments \
  --method POST \
  -F body=@/tmp/ci-reply.txt
# /tmp/ci-reply.txt の末尾に必ず次の marker を含める:
#   <!-- ci-review-reply: {commentId}@{updatedAt} -->
```

### 4-1b. 人間レビュアーへの返信内容のユーザー承認

**真の人間レビュアー（`isBot == false` かつ `isSelf == false`）への返信は、投稿前に必ず `AskUserQuestion` でユーザーに返信内容を提示し承認を得る。** ボットレビューおよびセルフレビュー（`isSelf == true`）への返信は定型文のため承認不要（セルフはボット同等に扱う。Phase 2-4 の方針一括承認でカバー済み）。

提示形式:

```markdown
## 返信内容の確認

**スレッド**: {path}:{line} ({reviewer})

> {返信内容案}

この内容で返信してよいですか？
```

### 4-2. 返信テンプレート

**返信冒頭の `@{reviewer}` メンション**: 原則として冒頭に `@{reviewer}` メンションを付ける。`coderabbitai[bot]` のように `[bot]` サフィックスを持つレビュアーは、メンションから `[bot]` を除いた `@coderabbitai` 形式にする（`coderabbitai` 等は `@` 言及で再レビュー等に反応する）。

**ただし、以下のレビュアーへはメンションを付けない**（通知効果がない／自分宛で無意味なため、ノイズを避ける）:

- **セルフレビュー（`isSelf == true`、`@{自分のlogin}`）**: 自分宛メンションは自分への通知を生むだけで意味がない
- **`github-actions`（CI レビューコメント）**: `@github-actions` は通知効果を持たない

これらの場合は、テンプレート冒頭の `@{reviewer}` を省き、本文（`**対応しました（ {COMMIT_SHA} ）**` 等）から直接始める。

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

> **Note**: 人間・ボット（`coderabbitai` 等）への返信には `@{reviewer}` メンションを付け、`[bot]` サフィックスはメンションから除く（`coderabbitai[bot]` → `@coderabbitai`）。**セルフレビュー（`@{自分のlogin}`）と `github-actions` へはメンションを付けない**（自分宛は無意味、`@github-actions` は通知効果なし）。

### 4-3. 返信時の注意事項

- **`@` を含む body の投稿**: `gh api` の `-F` フラグでは `@` で始まる値がファイル参照として解釈される。返信内容に `@` メンションを含む場合は、一時ファイルに書き出してから `-F body=@/tmp/reply.txt` で渡すこと
- **ローカルのみのドキュメントを根拠にしない**: `.spec-workflow/`, `.claude/` 等のパスは PR コメントの根拠として不適切。GitHub 上で閲覧可能なファイルのみ参照する
- **コードの実際の挙動を根拠にする**: `api-error-handle.ts:44` のように具体的なファイルと行番号で根拠を示す
- **前回回答済みの場合**: 前回の返信 URL を引用して重複を避ける

### 遷移
→ **Phase 5** に進む（例外なし）

---

## Phase 5: スレッド Resolve（ボット・セルフ）

**ボットレビュー（`isBot == true`）およびセルフレビュー（`isSelf == true`）のスレッドを** 自動 resolve する。**真の人間レビュー（`isBot == false` かつ `isSelf == false`）のスレッドは resolve しない** — レビュアー本人が確認して resolve する。

- **セルフレビューを resolve する理由**: 自分がレビュアー本人であり、対応／対応不要の判断も自分で下せる。また完了判定が `isResolved` 軸（Phase 1-1）のため、resolve しないと未解決のまま毎ラウンド再取得され無限ループになる。`[GOOD]`/非 actionable で返信を省いたセルフ thread（Phase 2-3）も、resolve は必ず行う（silent resolve）。

```bash
# ボットレビュー・セルフレビューのスレッドを resolve（isBot == true または isSelf == true）
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_id}" }) {
    thread { isResolved }
  }
}'
```

**注意**:
- review body はスレッドではないため `resolveReviewThread` の対象外。Phase 4 で Issue comment として返信し、hidden marker を含めることで「対応済み」を表現する（セルフ body も同様）。
- outdated スレッドであっても、真の人間レビューの場合は resolve しない。

### 遷移
- 真の人間レビュアー（`isBot == false` かつ `isSelf == false`）に返信した場合 → **Phase 5b** に進む
- ボット・セルフレビューのみの場合 → **Phase 6** に進む

---

## Phase 5b: 人間レビュアーへの Re-request review

真の人間レビュアー（`isBot == false` かつ `isSelf == false`）に返信した場合、返信完了後に Re-request review を行う。ボットレビューおよびセルフレビューには不要（セルフは自分自身に re-request できないため）。

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

`--watch` 完了後、**必ず別コマンドで** fail 件数を数値として取得する。

**重要 — チェック名による誤検知を避ける**: `gh pr checks` の出力はタブ区切りで、第 1 列が **チェック名**、第 2 列が **ステータス**（`pass` / `fail` / `skipping` / `pending` 等）。`grep -ic "fail"` は **チェック名に "fail" を含む行**（例: `notify-on-schedule-failure`、`check-failure-handler`）も数えてしまい、ステータスが `skipping`/`pass` でも fail と誤判定する。**必ず第 2 列（ステータス列）が厳密に `fail` の行のみ**を数えること:

```bash
# 第 2 列（ステータス）が厳密に "fail" の行のみを数える（チェック名の "fail" は無視）
FAIL_COUNT=$(gh pr checks {PR番号} --repo {owner}/{repo} | awk -F'\t' '$2=="fail"' | grep -c .)
echo "Failed checks: $FAIL_COUNT"

# 参考: ステータス別の内訳を確認する
gh pr checks {PR番号} --repo {owner}/{repo} | awk -F'\t' '{print $2}' | sort | uniq -c
```

### 6-2b. 禁止事項

以下の操作は明示的に禁止する:

- `gh pr checks` の出力を `tail`, `head`, `sed -n` 等で **行を間引いて** 一部の check を見ないこと（全 check を確認する）
- 一部の check のみを確認して「全 pass」と判断すること
- `--watch` なしで `gh pr checks` を実行し、pending の check を無視すること
- Phase 6 自体をスキップすること（push の有無に関わらず）
- **`grep -ic "fail"` のように行全体（チェック名を含む）で fail を数えること**（チェック名の "fail" を誤検知する。6-2 のとおりステータス列で判定する）

なお、`awk -F'\t' '$2=="fail"'` のような **ステータス列の抽出・判定** は禁止に当たらない（出力を間引くのではなく、全行を対象に列で判定しているため）。

### 6-3. fail 時の対応

```bash
# 失敗した check の一覧（ステータス列が fail の行のみ。チェック名の "fail" は拾わない）
gh pr checks {PR番号} --repo {owner}/{repo} | awk -F'\t' '$2=="fail"'

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

### セッショントリアージ台帳（無限ループ防止）

**重要**: Phase 2 で一度トリアージした項目のうち、**こちらの追加アクションでは状態が変わらないもの**（下記）は、Phase 7 で再取得しても **再度ループバックさせてはならない**。これらをループ継続条件に含めると、永遠に同じ項目を再提示し続ける無限ループになる。

セッション中、トリアージした項目の識別子と判断を台帳として保持する（識別子: review thread = `thread id` / review body = `reviewId` / CI コメント = `commentId@updatedAt`）。次の項目は「処理済み（state-stable）」として **Phase 7 の再トリガー判定から除外**する:

- **人間スレッドで「返信不要」と決定したもの**: 真の人間スレッド（`isBot == false` かつ `isSelf == false`）は自動 resolve しない（Phase 5）ため、返信もしないと未解決・未返信のまま残るが、これは想定どおり。レビュアー本人の resolve に委ねる。
- **Phase 2-3b で「返信不要」と判定した review body すべて**（ack/approve・No Issues・👍 等に限らず、**個別 thread のサマリー review body も含む**）。review body は `resolveReviewThread` の対象外（resolve できない）ため、返信不要としたものを台帳除外しないと毎ラウンド再取得され無限ループになる。1-1b で body を常に取得するようになったぶん、ここで確実に除外する。
- **`commentId@updatedAt` が変化していない CI レビューコメント**（内容が更新されておらず、既にトリアージ済み）。
- **（補足）セルフ inline thread / セルフ review body**: セルフ inline thread は Phase 5 で必ず resolve される（`[GOOD]` の silent resolve 含む）ため、次ラウンドは冒頭の `select(.isResolved == false)` で自動除外され、**台帳に依存しない**。セルフ review body は上記「返信不要 review body」のルールで台帳除外する。

### 7-1. 未解決スレッドの再取得

Phase 1-1 と同じ GraphQL クエリを再実行し、未解決・未返信 review threads を取得する。**台帳に載っている（トリアージ済みで state-stable な）スレッドは除外**し、新規スレッドのみを対象とする。

### 7-2. 未返信 review body の再取得

Phase 1-1b と同じ REST API クエリを再実行する。**台帳に載っている reviewId は除外**し、新規の未返信 review body のみを対象とする。

### 7-2b. 未返信 CI レビューコメントの再取得

Phase 1-1c と同じクエリを再実行し、`commentId@updatedAt` が **新規または変化した** CI レビューコメントのみを対象とする（変化なし = 台帳済みは除外）。Phase 6 の `--watch` で `claude-review` / `claude-self-merge-check` ワークフローの完了を待っているため、この時点で最新の CI コメントが投稿済みであることが保証される。

### 7-3. 判定

台帳除外後に残った項目で判定する:

- **7-1 / 7-2 / 7-2b のいずれかに「台帳に未登録の新規・変化した項目」が 1 件以上あり** → **Phase 1** に戻る（新ラウンド開始）
- **新規・変化した項目が 0 件**（残りはすべて台帳済みの state-stable 項目のみ） → **Phase 8** に進む

### 遷移
- 台帳未登録の新規 / 変化した項目あり → **Phase 1** に戻る
- なし（残りは state-stable のみ） → **Phase 8** に進む

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
| 自分が起点のスレッド（純粋セルフ＝他者参加なし） | セルフレビューとして処理（`isSelf == true`）。ボット同等に返信（`[GOOD]`/非 actionable は返信なし）し、必ず resolve する（Phase 1-1 / 2-3 / 4 / 5） |
| 自分が起点だが他者が参加したスレッド | `isSelf == false` かつ `hasMyReply == true` のため取得対象外（従来挙動を維持。進行中の議論を勝手に resolve しない） |
| author が null（deleted ユーザー） | ボット扱いで自律対応 |
| 画像添付あり | **ユーザーに報告し手動ダウンロードを依頼**（独断で「テキストで十分」と判断しない） |
| review body の API レスポンスに制御文字 | シェル変数ではなく一時ファイル経由で jq 処理（Phase 1-1b 参照） |
| Phase 6 で push なしの場合 | `gh pr checks --watch` を実行し review ワークフロー完了を待つ。push なしでも直前 commit の CI 状態が返される。ボットレビュー投稿の保証に必要 |
| 個別 thread のサマリー review body | Phase 1-1b で **常に取得**する（取得段階では除外しない）。返信要否は Phase 2-3b で判定し、多くは「返信不要」（個別 thread で対応）。返信不要としたものは Phase 7 台帳で再トリガーから除外 |
| No Issues / ack のみの review body | Phase 2-3b で「返信不要」分類。重複応答とノイズ回避のため返信しない（ボット・人間問わず適用） |
| CI レビューコメントが再実行で更新された | upsert で同一 comment id のまま本文が変わる。返信済み判定は `commentId@updatedAt` をキーにし、`updatedAt` が変われば再評価する（Phase 1-1c） |
| `claude-self-merge-check` のサマリのみ | Phase 2-3c で「返信不要」分類。actionable な指摘がなければ返信しない |
| `github-actions[bot]` へのメンション | `@github-actions` は通知効果を持たないため付与しない（Phase 4-2） |
| セルフレビューへの返信メンション | 自分宛 `@{自分のlogin}` は自分への通知を生むだけで無意味なため付与しない（Phase 4-2） |
| `gh pr checks` の fail 誤検知 | `grep -ic "fail"` はチェック名（`notify-on-schedule-failure` 等）にも一致する。ステータス列で `awk -F'\t' '$2=="fail"'` と判定する（Phase 6-2） |
| 真の人間スレッドを「返信不要」と決定 | 真の人間スレッド（`isBot == false` かつ `isSelf == false`）は自動 resolve しないため未解決のまま残る。セッショントリアージ台帳に記録し Phase 7 の再トリガーから除外する（無限ループ防止、Phase 7）。レビュアー本人の resolve に委ねる |
| 返信不要とした review body（サマリー含む）・更新されない CI コメント | review body は resolve できないため、返信不要としたものは台帳に記録し Phase 7 で除外。新規・変化した項目のみでループ継続を判定する（Phase 7） |
| セルフレビューの完了 | セルフ thread は Phase 5 で必ず resolve されるため `isResolved` で次ラウンド自動除外（台帳に依存しない）。セルフ review body は「返信不要 review body」のルールで台帳除外（Phase 7） |
