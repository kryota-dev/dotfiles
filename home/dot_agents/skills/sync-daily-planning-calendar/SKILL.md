---
name: sync-daily-planning-calendar
description: "Daily Planning（GitHub Discussion）の勤務時間をGoogleカレンダーの指定イベントに同期する。「カレンダー同期」「Daily Planning同期」「勤務時間をカレンダーに反映」「アプリケーション実装の予定を更新」「カレンダーの工数修正」などと言及された際に使用。Daily Planningの勤務時間（開始・終了・離席）を元に、カレンダーの対象イベントを実際の作業時間帯に合わせて再作成する。"
argument-hint: "range=\"3\" event-title=\"イベントタイトル\" [dry-run] [force]"
---

# Daily Planning → Googleカレンダー同期スキル

## 概要

Daily Planning（GitHub Discussion）に記録された勤務時間（開始・終了・離席）を元に、Googleカレンダーの指定タイトルのイベントを実際の作業時間帯に合わせて削除・再作成する。
勤務時間から離席時間とMTG（対象イベント以外のカレンダー予定）を除外した時間帯を算出し、対象イベントとして登録する。

## 引数

### 必須引数

| 引数 | 説明 |
|------|------|
| `range` | 同期対象の範囲（下記参照） |
| `event-title` | 同期対象のカレンダーイベントタイトル |

#### `range` の形式

| 形式 | 例 | 説明 |
|------|---|------|
| `today` | `today` | 本日のみ |
| `M` or `MM` | `3`, `03` | 当年の指定月 |
| `YYYY-MM` | `2026-03` | 年月指定 |
| `YYYY-MM-DD` | `2026-03-10` | 特定の日 |
| `YYYY-MM-DD..YYYY-MM-DD` | `2026-03-10..2026-03-15` | 範囲指定 |

`M` or `MM` 形式の場合、現在の年を自動的に補完する。

### オプション引数

| 引数 | 説明 |
|------|------|
| `dry-run` | 変更内容をプレビューのみ表示し、カレンダーは変更しない |
| `force` | 既にカスタマイズ済みの日（既存予定が計算結果と一致する日）も上書きする |

## 前提条件

- Google Calendar MCP Server が有効であること
- `gh` コマンドが使用可能であること
- カレントディレクトリがDaily Planningを投稿しているリポジトリであること

## 実行手順

### Step 1: Googleアカウント確認

カレンダー操作を行う前に、連携中のGoogleアカウントが正しいか確認する。

1. `gcal_list_events` を軽量に呼び出して、レスポンスの `summary` フィールドからアカウント情報（メールアドレス）を取得する:

```
gcal_list_events(
  timeMin="今日の日付T00:00:00",
  timeMax="今日の日付T00:01:00",
  timeZone="Asia/Tokyo",
  maxResults=1
)
```

2. 取得したアカウント情報をユーザーに表示し、`AskUserQuestion` ツールで確認する:

```
質問: 「現在連携中のGoogleアカウントは {email} です。このアカウントで同期を進めてよいですか？」
選択肢:
  - 「はい、このアカウントで進める」
  - 「いいえ、アカウントを切り替えたい」
```

ユーザーが「いいえ」を選択した場合、Claude.aiの Settings → Integrations からGoogle Calendarの接続を切り替えるよう案内し、切り替え後に再度確認する。

### Step 2: 引数の解析

`range` 引数を柔軟に解釈し、対象期間の開始日・終了日を決定する。
ユーザーの入力が正確なパターンに沿っていなくても、意図を推測して適切な期間に変換する。

#### 代表的な解釈例

| 入力 | 解釈 |
|------|------|
| `today`, `きょう` | 本日の日付 |
| `3`, `03`, `3月` | `{現在の年}-03-01` 〜 `{現在の年}-03-31` |
| `2026-03`, `2026/03` | `2026-03-01` 〜 `2026-03-31` |
| `2026-03-10`, `3/10` | その日のみ |
| `2026-03-10..2026-03-15`, `3/10-3/15` | 範囲指定 |
| `先月`, `前月` | 前月1日〜末日 |

どうしても意図が推測できない場合のみ、ユーザーに確認する。

### Step 3: データ収集（並列実行）

以下の2つのデータを並列で取得する。

#### 3a. Daily Planning の取得

**重要: macOSでは`USERNAME`がシステム環境変数として予約されているため、変数名は`GH_USER`を使うこと。**

1. GitHubユーザー名とリポジトリ情報を取得:

```bash
GH_USER=$(gh api user --jq '.login')
REPO_FULLNAME=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
REPO_OWNER=$(echo "${REPO_FULLNAME}" | cut -d'/' -f1)
REPO_NAME=$(echo "${REPO_FULLNAME}" | cut -d'/' -f2)
```

2. 対象月のDaily Planning Discussionを検索:

対象期間に含まれる全ての年月について、それぞれDiscussionを検索する。
（範囲が月をまたぐ場合、複数のDiscussionを取得する必要がある）

```bash
YEAR_MONTH="YYYY-MM"
SEARCH_QUERY="repo:${REPO_FULLNAME} ${GH_USER} ${YEAR_MONTH} in:title"

gh api graphql \
  -f query='
    query($q: String!) {
      search(query: $q, type: DISCUSSION, first: 5) {
        nodes {
          ... on Discussion {
            number
            title
            category { name }
          }
        }
      }
    }
  ' \
  -f q="${SEARCH_QUERY}" \
  --jq '.data.search.nodes[] | select(.category.name == "Daily planning")'
```

GraphQLの変数バインディング（`-f q=`）を使用することで、検索クエリの文字列補間を安全に行う。

3. Discussionのコメントを全取得:

```bash
gh api graphql -f query="
{
  repository(owner: \"${REPO_OWNER}\", name: \"${REPO_NAME}\") {
    discussion(number: DISCUSSION_NUMBER) {
      comments(first: 100) {
        nodes {
          body
          createdAt
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}" --jq '.data.repository.discussion.comments.nodes[] | {createdAt, body}'
```

4. 各コメントから勤務時間を解析:

コメント本文から以下の情報を抽出する:
- 日付: `## YYYY/MM/DD` パターン
- 開始時刻: `- 開始: HH:MM` パターン
- 終了時刻: `- 終了: HH:MM` パターン
- 離席: `- HH:MM - HH:MM` パターン（`離席:` セクション配下、複数行対応）

対象期間外の日付はスキップする。

#### 3b. Googleカレンダー予定の取得

`gcal_list_events` で対象期間の全予定を取得する。

```
gcal_list_events(
  timeMin="YYYY-MM-DDT00:00:00",
  timeMax="YYYY-MM-DDT23:59:59",
  timeZone="Asia/Tokyo",
  maxResults=250
)
```

結果が大きくファイルに保存された場合は、Bashでファイルを読み込んで解析する。

取得したイベントを以下の3カテゴリに分類する:
- **対象イベント**: `event-title` 引数の文字列を含む予定 → 削除・再作成の対象
- **MTGイベント**: 対象イベント以外の時間指定予定 → 除外区間として使用
- **無視するイベント**: 終日イベント（`allDay: true` や `eventType: "workingLocation"` など）

### Step 4: 差分計算

各日について以下を計算する。

#### 4a. 実装時間帯の算出

1. Daily Planningから勤務時間帯 `[開始, 終了]` を構築
2. 除外区間をリストアップ:
   - Daily Planningの離席時間
   - カレンダーのMTGイベント
3. 除外区間のうち、勤務時間外のものを除去:
   - 勤務開始前に終了するMTG → 除去
   - 勤務終了後に開始するMTG → 除去
4. 勤務開始がMTG中の場合 → 勤務開始をMTG終了時刻に調整
5. 除外区間をソートし、重複する区間を統合
6. 勤務時間帯から除外区間を差し引き、残りの区間を実装時間帯とする
7. 5分未満の短い実装スロットは除外する（ノイズ回避）

#### 4b. 既存予定との比較

各日の状態を判定する:

| 状態 | 条件 | アクション |
|------|------|-----------|
| **変更なし** | 既存の対象イベントと計算結果の時間帯が一致 | スキップ（`force` でない場合） |
| **変更あり** | 既存の対象イベントと計算結果の時間帯が不一致 | 削除→再作成 |
| **新規追加** | 既存の対象イベントなし、Daily Planningあり | 新規作成 |
| **削除のみ** | 既存の対象イベントあり、Daily Planningなし | ユーザーに確認後、削除 |

「一致」の判定は、イベント数が同じかつ各イベントの開始・終了時刻が完全に一致する場合とする。

### Step 5: プレビュー表示とユーザー確認

変更内容を以下の形式で表示する:

```
=== 同期プレビュー ===

【変更あり】03/10
  削除: 10:00-10:30, 11:00-12:00, 13:00-19:00 (3件)
  作成: 11:00-11:47, 14:14-19:01 (2件)

【変更なし】03/11 (既にカスタマイズ済み)

【削除のみ】03/16 (Daily Planning記録なし)
  削除: 10:00-10:30, 11:00-12:00, 13:00-19:00 (3件)

合計: 削除 XX件, 作成 XX件
```

#### ユーザー確認

プレビュー表示後、`AskUserQuestion` ツールで確認する:

- **`dry-run` の場合**: 確認不要。プレビューと工数サマリー（Step 7）を表示して終了
- **`dry-run` でない場合**: 以下の確認を行う:

```
質問: 「上記の内容でカレンダーを更新します。よろしいですか？（削除 XX件, 作成 XX件）」
選択肢:
  - 「はい、実行する」
  - 「いいえ、キャンセルする」
```

ユーザーが「いいえ」を選択した場合、処理を中止し工数サマリーのみ表示する。

#### Daily Planning記録なしの日の確認

「削除のみ」の日がある場合、カレンダー更新前に `AskUserQuestion` で追加確認する:

```
質問: 「Daily Planning記録がない日（03/16, 03/20 等）のカレンダー予定を削除しますか？」
選択肢:
  - 「削除する」
  - 「そのまま残す」
```

### Step 6: カレンダー更新

ユーザーの確認後、以下を実行する:

1. **既存イベントの削除**: `gcal_delete_event` で対象イベントを削除
   - 繰り返し予定の場合、個別インスタンスのID（`recurringEventId_YYYYMMDDTHHMMSSZ` 形式）で削除する
   - シリーズ全体を削除しないよう注意
2. **新規イベントの作成**: `gcal_create_event` で実装時間帯を作成
   - `sendUpdates: "none"` を指定し、通知を送信しない
   - タイトルは `event-title` 引数の値をそのまま使用
   - タイムゾーンは `Asia/Tokyo` を指定
3. 進捗を日単位で報告する

#### エラーハンドリング

各日の処理（削除→作成）を独立した単位として扱い、障害時のデータ消失リスクを最小化する:

- **作成失敗時**: 失敗した日とエラー内容を記録し、残りの日の処理を続行する
- **処理完了後**: 失敗した日がある場合、一覧を表示し、該当日のみの再実行を案内する
- データソース（Daily Planning）は常に保持されるため、失敗した日は `range` で日付指定して再実行することで復旧可能

### Step 7: 工数サマリー表示

同期完了後（`dry-run` の場合も含む）、必ず工数サマリーを表示する。
計算結果の実装時間帯と、Daily Planningの勤務時間（離席のみ除外）の両方を算出する。

```
=== 工数サマリー ===
| 日付 | 工数（実装） | 工数（MTG含む） |
|------|------------|----------------|
| 03/02 | 5h46m | 5h46m |
| 03/03 | 8h46m | 9h45m |
| ...  | ...   | ...   |
| 合計 | 123h41m | 132h19m |
```

- **工数（実装）**: 対象イベント（`event-title`）の合計時間
- **工数（MTG含む）**: 勤務時間 - 離席時間の合計（MTGも含む実働時間）

## エッジケース

- **Daily Planning Discussionが見つからない場合**: エラーメッセージを表示して終了
- **対象期間にDaily Planningコメントが0件**: 警告を表示して終了
- **Googleカレンダー MCPが利用不可**: ユーザーにMCPの有効化を促す
- **gcal_list_events の結果がファイルに保存された場合**: Bashでファイルを読み込んでPythonで解析する
- **jq使用時**: `!=` はClaude CodeのBashツールでエスケープエラーになるため、`select(.field == "value")` の形式を使う
