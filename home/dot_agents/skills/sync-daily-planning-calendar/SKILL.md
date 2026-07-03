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
| 複数日列挙（カンマ区切り） | `2026-03-10,2026-03-15,2026-03-22` | 連続しない複数日を一括指定 |
| 複数日列挙（スペース区切り） | `2026-03-10 2026-03-15 2026-03-22` | 同上（スペース区切り） |

`M` or `MM` 形式の場合、現在の年を自動的に補完する。
複数日列挙は `M/D` 短縮形（例: `4/3,4/27`）も許容する。
内部的には対象日を `[d1, d2, ...]` の集合で保持し、Step 3 以降は集合として扱う。

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
| `4/3,4/27`, `4/3 4/27` | 複数日（カンマ／スペース区切り、連続しない複数日） |
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

native の `gh discussion view --comments` で取得する（Discussion Node ID の解決は不要）。`DISCUSSION_NUMBER` は手順 2 で特定した番号を入れる。

**注意: `gh discussion` は preview 機能であり、フラグや出力構造が予告なく変わりうる。** 破壊的変更で動作しなくなった場合は、下の Fallback（`gh api graphql`）へ切り替える。

```bash
# native: 全コメントを古い順で取得（--limit はコメント件数に応じて調整）
gh discussion view DISCUSSION_NUMBER --repo "${REPO_FULLNAME}" \
  --comments --order oldest --limit 100 \
  --json comments --jq '.comments.nodes[] | {createdAt, body}'
```

**Fallback（`gh discussion` が preview 変更等で使えない場合）:**

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

##### 翌日に跨ぐ時刻の扱い（重要）

勤務時間や離席が **0:00 を跨ぐ場合**（例: `開始 10:24 / 終了 00:40` のような深夜終業ケース）、
時刻の数値比較だけでは `終了 < 開始` となり、後段の差分計算で実装スロットが破綻する。

このため、解析時に以下の補正を行うこと:

- `終了 (H, M)` が `開始 (H, M)` より早い場合 → 終了を **当日 +1 日** として `datetime` で保持する
- 離席 `(start, end)` も同様に `end < start` なら `end` を翌日扱い
- データ構造は `(start: datetime, end: datetime)` として保持し、`hour:minute` 単独では持たない

```python
# Python 実装例
ws = datetime(d.year, d.month, d.day, s_h, s_m)
if (e_h, e_m) < (s_h, s_m):
    we = datetime(d.year, d.month, d.day, e_h, e_m) + timedelta(days=1)
else:
    we = datetime(d.year, d.month, d.day, e_h, e_m)
```

Google Calendar 側も `startTime=2026-04-23T20:50:00`, `endTime=2026-04-24T00:40:00`
のように日付を跨いだ予定として作成可能なので、そのまま渡せばよい。

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
- **無視するイベント**: 終日イベント（`allDay: true` や `eventType: "workingLocation"` など）、および**自分が `declined` した予定**（後述）

##### 自分が `declined` したMTGの扱い（重要）

カレンダー API の各イベントには `attendees[]` 配列があり、各 attendee に `responseStatus`
（`accepted` / `declined` / `needsAction` / `tentative`）が付く。
自分の attendee（`self: true` を持つもの）の `responseStatus` が `"declined"` の場合、
そのMTGには **不参加** なので、実装時間から除外してはいけない（休憩・離席ではない）。

判定ロジック:

```python
def is_declined_by_self(event):
    for a in event.get("attendees", []):
        if a.get("self") and a.get("responseStatus") == "declined":
            return True
    return False
```

`is_declined_by_self(event) == True` のMTGは「無視するイベント」として扱い、
除外区間には含めないこと。

過去事例: 4/29 (祝日・昭和の日) は Daily Standup と teamBeta DS が定例として
カレンダーに残っていたが、ユーザーは祝日のため両方 `declined` に設定していた。
スキルが declined を考慮せず除外したため、本来の実装時間が過小に切り出される事故が発生した。

### Step 4: 差分計算

**対象日の集合を先に確定する（重要）。** ここでいう「各日」は DP 記録のある日だけではない。
range 内の次の **和集合** を対象日とする:

- **DP 記録のある日**（Step 3a で抽出）
- **既存の対象イベント（`event-title`）がカレンダーに存在する日**（Step 3b で抽出）

DP 日だけをループすると、DP がなく既存イベントだけが残る「**削除のみ**」候補日（例: 休暇・休日で
DP 未投稿だが初期テンプレートの繰り返し予定が残っている日）を取りこぼす。取りこぼした日は
プレビュー（Step 5）にも整合性チェック（Step 8）にも現れず、ユーザーが手動で気付いて
確認するまで放置される（過去事例: 6/23・6/26 をユーザーが指摘するまで「削除のみ」候補として
surface できなかった）。**必ず両者の和集合をループ対象にすること。**

実装メモ: スクリプトで処理する場合、`dp_days = set(DP.keys())` と
`target_days = set(target_by_day.keys())` を作り、`sorted(dp_days | target_days)` を
range で絞ってループする。DP 日だけを `for d in DP:` で回さない。

各対象日について以下を計算する。

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
| **変更あり** | 既存の対象イベントと計算結果の時間帯が不一致、計算結果 ≥ 1 件 | 削除→再作成 |
| **新規追加** | 既存の対象イベントなし、Daily Planning あり、計算結果 ≥ 1 件 | 新規作成 |
| **削除のみ** | 既存の対象イベントあり、Daily Planning なし | ユーザーに日ごと個別確認 |
| **要確認** | 既存の対象イベントあり、Daily Planning あり、計算結果 0 件 | **必ずユーザー確認**（自動で削除しない） |

「一致」の判定は、イベント数が同じかつ各イベントの開始・終了時刻が完全に一致する場合とする。

##### `要確認` 状態の安全装置（重要）

DP がある日でも、勤務時間がほぼ全てMTGや離席で埋まり、5分未満スロットしか残らないと
**計算結果が 0 件**になる。この場合、自動で「変更あり」として処理すると既存イベントが
削除されるだけで実装記録が失われる事故になる。

そのため、`計算結果が空 (0 件) かつ既存対象イベントが存在する` 場合は **`要確認`** として分類し、
プレビューで明示してユーザーに以下のいずれかを選んでもらう:

- 既存イベントを削除する（DP 通り、実装時間 0 を確定）
- 既存イベントを残す（DP の入力誤り疑いがある場合）
- 同期を中止して DP を見直す

過去事例: 4/23 のように DP の終了が翌日 (00:40) で、翌日跨ぎ未対応のため計算結果が 0 件になり、
既存3件が黙って削除されるバグが発生した。翌日跨ぎ対応 + `要確認` 状態の二重防御で再発を防ぐ。

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

「削除のみ」の日がある場合、カレンダー更新前に `AskUserQuestion` で確認する。
**休暇／休日と「記録忘れ」を区別する必要があるため、3択を提示する**。

##### 該当日数が 1〜3 日の場合（日ごと個別確認）

`AskUserQuestion` の `questions` 配列に1問ずつ並べ、最大3問で日ごとに確認する:

```
質問: 「03/16 のカレンダー予定（Daily Planning 記録なし）をどうしますか？」
選択肢:
  - 「削除する（休暇・休日のため）」
  - 「そのまま残す（後で DP 投稿予定）」
  - 「Daily Planning 作成スキルを呼び出す（記録忘れ）」
```

「Daily Planning 作成スキルを呼び出す」が選択された日は、**その日の処理を中断**し、
「`/daily-planning` を実行して当該日の DP を投稿してから、再度 `range="YYYY-MM-DD"` で
同期してください」とユーザーに案内する。

##### 該当日数が 4 日以上の場合（multiSelect で一括選別）

最大4問の制約があるため、日ごと個別確認はできない。代わりに以下の流れで処理する:

1. 「削除のみ」候補日をリストで提示
2. `AskUserQuestion` で `multiSelect: true` を指定し、**削除対象日**を複数選択させる
3. 選ばれなかった日はそのまま残す（記録忘れの可能性があるため、別途 `/daily-planning` を案内）

```
質問: 「以下の Daily Planning 記録なしの日のうち、カレンダー予定を削除するものを選んでください
       （未選択の日は『記録忘れの可能性あり』として残します）」
選択肢:
  - 「03/16 の予定（10:00-19:00 等 3件）」
  - 「03/20 の予定（10:00-19:00 等 3件）」
  - ...
multiSelect: true
```

##### `要確認` 状態の日（DP あり、計算結果 0 件）

`要確認` 状態の日がある場合、別途 `AskUserQuestion` で日ごとに確認する:

```
質問: 「04/23 は DP がありますが計算結果が0件です。どうしますか？」
選択肢:
  - 「既存イベントを削除する（実装時間 0 を確定）」
  - 「既存イベントを残す（DP の入力を見直す）」
  - 「同期を中止する」
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

- **一時的エラー（502/503/504/Cloudflare bad gateway 等）**:
  自動リトライする。**60 秒の指数バックオフで最大 2 回**（合計 3 回試行）。
  Cloudflare からの `retry_after` ヘッダがあれば優先的にそれに従う。
- **作成失敗時（リトライしても回復しない場合）**:
  失敗した日とエラー内容を記録し、残りの日の処理を続行する
- **処理完了後**: 失敗した日がある場合、一覧を表示し、該当日のみの再実行を案内する
- データソース（Daily Planning）は常に保持されるため、失敗した日は `range` で日付指定して再実行することで復旧可能

##### 過去事例

2026-04-30 の同期セッションで `mcp__claude_ai_Google_Calendar__create_event` が
`Error 502: Bad gateway`（Cloudflare 由来）を返したことがある。
このときは手動でリトライして回復したが、本スキルでは自動リトライで瞬断起因の取りこぼしを抑える。

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

### Step 8: 整合性チェック（必須）

同期処理完了後（`dry-run` の場合も含む）、**必ず最終整合性チェックを実行**する。
P1（翌日跨ぎ）/ P2（空スロット）/ P6（リトライ失敗）に起因する取りこぼしを最終防衛として検出する。

#### チェック手順

1. Daily Planning と Google カレンダーを **再取得**（同期後の状態を反映）
2. **Step 4 と同じ対象日集合（DP 日 ∪ 既存対象イベント日）** をループし、各日について以下を比較:
   - 期待値: DP のある日は `(DP 勤務時間範囲) - 離席 - 当日MTG` を `subtract` した結果。
     DP がなく削除した「削除のみ」日は期待値 `[]`（0件）
   - 実測値: カレンダーの対象イベント `event-title` の (start, end) リスト
3. 一致判定: イベント数が同じ、かつ各 `(start, end)` が完全一致
   （「削除のみ」で削除した日は実測値が `[]` になっていれば一致）

#### 出力フォーマット

```
=== 整合性チェック ===

✅ 04/01 (Wed) 一致 (3件 / 7h56m)
✅ 04/02 (Thu) 一致 (2件 / 7h46m)
❌ 04/23 (Thu) 不一致
   期待: [('10:24', '10:30'), ('11:00', '13:09'), ('14:36', '19:37'), ('20:50', '(+1)00:40')]
   実際: []
✅ ...

==================================================
問題: 1件
  - 04/23 (Thu): 期待4件 vs 実際0件
```

#### 不一致が見つかった場合

- 不一致日を一覧表示し、再同期コマンド `range="YYYY-MM-DD"` を案内
- ユーザーの判断で再同期 or 手動修正を選んでもらう

#### 検証ロジックのテンプレート（Python）

整合性チェックは以下のような Python スクリプトで実装する。
翌日跨ぎ対応した `subtract` / `merge` ヘルパーをそのまま使う:

```python
from datetime import datetime, timedelta

def merge(ivs):
    """重複・隣接区間を統合してソート済みリストを返す"""
    if not ivs:
        return []
    ivs = sorted(ivs)
    out = [list(ivs[0])]
    for s, e in ivs[1:]:
        if s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [tuple(x) for x in out]

def subtract(work, excludes):
    """勤務時間帯から除外区間を引いた残りの区間を返す（5分未満は除外）"""
    ws, we = work
    valid = []
    for s, e in excludes:
        if e <= ws or s >= we:
            continue
        valid.append((max(s, ws), min(e, we)))
    valid = merge(valid)
    cur = ws
    for s, e in valid:
        if s <= cur:
            cur = max(cur, e)
        else:
            break
    out = []
    c = cur
    for s, e in valid:
        if e <= c:
            continue
        if s > c:
            out.append((c, s))
            c = e
        else:
            c = max(c, e)
    if c < we:
        out.append((c, we))
    return [(s, e) for s, e in out if (e - s) >= timedelta(minutes=5)]
```

各日の比較ロジック例:

```python
expected = subtract((ws, we), breaks + mtgs)  # ws, we, breaks は DP 由来 / mtgs はカレンダー由来
actual = sorted([(ev.start, ev.end) for ev in calendar_target_events_on(d)])
same = (len(expected) == len(actual)) and all(
    es == as_ and ee == ae for (es, ee), (as_, ae) in zip(expected, actual)
)
```

## エッジケース

- **Daily Planning Discussionが見つからない場合**: エラーメッセージを表示して終了
- **対象期間にDaily Planningコメントが0件**: 警告を表示して終了
- **Googleカレンダー MCPが利用不可**: ユーザーにMCPの有効化を促す
- **gcal_list_events の結果がファイルに保存された場合**: Bashでファイルを読み込んでPythonで解析する
- **jq使用時**: `!=` はClaude CodeのBashツールでエスケープエラーになるため、`select(.field == "value")` の形式を使う
- **DP の終了時刻が翌日に跨ぐ場合**: Step 3a「翌日に跨ぐ時刻の扱い」を参照（`終了 < 開始` なら翌日扱い）。離席も同様
- **計算結果が空 (0 件) なのに既存対象イベントがある日**: `要確認` 状態として `AskUserQuestion` で確認（Step 4b 参照）
- **DP がない日に既存の対象イベントが残っている場合**: Step 4 の対象日集合（DP 日 ∪ 既存対象イベント日）に必ず含め、「削除のみ」状態として Step 5 で日ごと確認する。DP 日だけを走査して取りこぼさないこと（過去事例: 6/23・6/26 をユーザー指摘まで surface できなかった）
- **MCP の 502/503/504 エラー**: Step 6「エラーハンドリング」を参照（指数バックオフで最大2回リトライ）
- **同期後の最終確認**: Step 8「整合性チェック」を必ず実行（`dry-run` 含む）
- **祝日・休日に declined したMTG**: Step 3b「自分が `declined` したMTGの扱い」を参照。除外区間に含めないこと。整合性チェック（Step 8）の `mtgs` 構築時にも同じフィルタを適用すること
