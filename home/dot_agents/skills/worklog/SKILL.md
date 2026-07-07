---
name: worklog
description: |
  期間指定で週報/稼働報告/月次報告のドラフトを生成する skill。gh 横断検索（merged/opened PR・
  レビュー・Issue）+ ローカル git log + session-summary + daily-planning 投稿を集約し、
  請求根拠・実績アピール・振り返りに使える Markdown（+CSV）を .kryota-dev/worklog/ に出力する。
  トリガー: "worklog", "週報", "稼働報告", "月次報告", "今週のまとめ", "先週何やったっけ"
  使用場面: 週次/月次の報告ドラフト作成、請求前の稼働根拠整理、振り返りの素材出し。
argument-hint: "[--period=this-week|last-week|this-month|last-month|YYYY-MM|<start>..<end>] [--scope=owner[/repo],...] [--csv] [--out=<dir>]"
user-invocable: true
---

# worklog

「先週（先月）何をやったか」を掘り返すコストをゼロにする。収集は**完全 read-only**、
出力はローカルの gitignore 領域のみ。稼働**時間**は推定せず、活動の事実だけを集める。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--period` | `this-week` | 集計期間（JST）。`this-week`=今週月曜〜実行時点、`last-week`=先週月〜日、`this-month` / `last-month` / `YYYY-MM`、`<start>..<end>`（`YYYY-MM-DD..YYYY-MM-DD`） |
| `--scope` | all | `owner` または `owner/repo` のカンマ区切りで絞り込み（例: `--scope=kryota-dev,kryota-dev/dotfiles`） |
| `--csv` | off | Markdown に加えて同名の .csv も出力する |
| `--out` | `~/dotfiles/.kryota-dev/worklog/` | 出力先ディレクトリ。git 追跡領域なら警告して確認する。判定は**最も近い実在の祖先ディレクトリ**に対して `git rev-parse --is-inside-work-tree` と `git check-ignore -q -- <出力先>` で行う（未作成ディレクトリで判定を素通りさせない）。既定以外を指定した場合は、出力が内部資料である旨を再掲して確認する |

## 安全原則

- 収集は read-only（`gh search` / `gh pr view` / `git log` / ローカル Read のみ）。**GitHub への書き込み・外部送信は一切しない**。
- 稼働時間は推定しない。活動量（PR・コミット・レビュー数）のみ提示し、時間数の記入は人間が行う。
- 出力はクライアント固有名を含む**内部資料**。既定の出力先はグローバル gitignore 済み領域（`~/.gitignore_global` の `.kryota-dev`）であり、冒頭に転記警告コメントを必ず含める。

## Phase 1: 期間算出（JST）

daily-planning skill の Step 1 と同じ考え方で、JST 基準の期間・UTC 境界・gh search 用の検索レンジを算出する:

```bash
# 例: this-week（月曜起点）
TODAY_JST=$(TZ=Asia/Tokyo date +%Y-%m-%d)
DOW=$(TZ=Asia/Tokyo date +%u)                          # 1=月曜
START_DATE=$(TZ=Asia/Tokyo date -v-$((DOW - 1))d +%Y-%m-%d)
END_DATE=$TODAY_JST
LABEL=$(TZ=Asia/Tokyo date +%G-W%V)                    # ISO 週。ファイル名に使う

# gh search は UTC 解釈のため、検索は ±1 日広げ、採否は UTC 境界で後段フィルタする
SEARCH_START=$(TZ=Asia/Tokyo date -j -v-1d -f %Y-%m-%d "$START_DATE" +%Y-%m-%d)
SEARCH_END=$(TZ=Asia/Tokyo date -j -v+1d -f %Y-%m-%d "$END_DATE" +%Y-%m-%d)
START_UTC="${SEARCH_START}T15:00:00Z"        # JST 初日 00:00 = UTC 前日 15:00
END_EXCLUSIVE_UTC="${END_DATE}T15:00:00Z"    # JST 最終日 24:00 = UTC 当日 15:00
```

- 採否判定は `closedAt` / `createdAt` / `submitted_at` を `START_UTC ≤ t < END_EXCLUSIVE_UTC` で行う（`${START_DATE}..${END_DATE}` を検索にそのまま使うと JST 初日 00:00–08:59 の活動を落とす）。
- `date -v` / `-j -f` は BSD date（macOS）構文。GNU date（Linux）では `date -d` に読み替える。
- `last-week`: 先週月曜〜日曜（LABEL は先週の `%G-W%V`）。`this-month`/`last-month`/`YYYY-MM`: 月初〜月末（未来日は実行時点まで、LABEL は `YYYY-MM`）。`<start>..<end>`: LABEL は `YYYYMMDD-YYYYMMDD`。

## Phase 2: 並列収集

以下を**並列の Bash 呼び出し**で取得する（`@me` は gh が解決。`--scope` 指定時は `--owner` や `repo:` 修飾を付ける）:

```bash
# 1. 期間内にマージされた自分の PR（成果の中心）
gh search prs --author=@me --merged-at "${SEARCH_START}..${SEARCH_END}" --limit 100 \
  --json repository,number,title,url,closedAt

# 2. 期間内に作成した PR（進行中の仕事）
gh search prs --author=@me --created "${SEARCH_START}..${SEARCH_END}" --limit 100 \
  --json repository,number,title,url,createdAt,state,isDraft

# 3. 自分がレビューした可能性のある PR（候補集合。期間帰属は Phase 3 で検証）
#    ※ --updated は「PR の最終更新日」での近似であり、レビュー実施日そのものではない
gh search prs --reviewed-by=@me --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 \
  --json repository,number,title,url,author

# 4. 期間内に自分が関わった Issue（期間内更新ベースの近似）
gh search issues --involves=@me --updated "${SEARCH_START}..${SEARCH_END}" --limit 100 \
  --json repository,number,title,url,state,updatedAt
```

ローカルソース:

- **session-summary**: 次の 2 経路を走査し、ファイル名先頭 timestamp（`YYYYMMDDHHMMSS`）が期間内のものを Read する:
  1. `ghq list -p` の各 repo の `<repo>/.kryota-dev/claude/session-summary/*.md`
  2. wtp ワークツリーの `~/worktrees/*/*/.kryota-dev/claude/session-summary/*.md`（ghq 経路では発見できない。パスの `<repo>` 部分で親 repo へ集約する）
- **daily-planning 投稿**: daily-planning skill の Step 1〜2 のレシピで対象月の Discussion を特定し、期間内の自分のコメント本文を抽出する。
- **git log 補強**: 1〜4 で活動が観測された repo のうちローカル clone がある repo に限り実行する（100+ の全 repo 走査はしない）。repo ごとに author の identity が異なるため、必ずその repo の設定値を使う:

```bash
git -C <path> log --author="$(git -C <path> config user.email)" \
  --since="${START_DATE} 00:00 +0900" --until="${END_DATE} 23:59 +0900" --oneline
```

**縮退動作（morning-brief と同原則）**: いずれかのソースが失敗（未認証・レート制限・スコープ不足・ファイル不在）しても中断せず、該当セクションに「取得失敗（理由）」と明記して続行する。

## Phase 3: 整形

- **UTC 境界フィルタ**: 検索結果 1・2 は `closedAt` / `createdAt` を `START_UTC ≤ t < END_EXCLUSIVE_UTC` で絞り込んでから採用する。
- **Reviewed の期間帰属を検証**: 検索 3 は候補集合に過ぎない。author が自分の PR を除外した上で、各候補に `gh api repos/<owner>/<repo>/pulls/<番号>/reviews --jq '[.[] | select(.user.login == "<自分の login>")]'` を実行し、`submitted_at` が UTC 境界内にあるものだけを「今期レビューした PR」として採用する。
- **Issues は近似のまま採用**し、レポートに「期間内更新ベースの近似」であることを明記する（正確な帰属が必要な場合のみ個別にコメント/クローズ日時を確認する）。
- リポジトリ単位にグルーピングし、Merged → Opened → Reviewed → Issues の順に並べる。
- ハイライトは「外から見える成果」（マージ済み PR・クローズ Issue・公開物）から 3〜5 行選ぶ。
- 活動ゼロの期間は「活動なし」と明記した骨組みを出力する（空ファイルやエラーにしない）。

## Phase 4: 出力

`--out`（既定 `~/dotfiles/.kryota-dev/worklog/`）に `<LABEL>.md` を書き出す（ディレクトリがなければ `mkdir -p` で作成。作成前に引数表の追跡領域判定を必ず通す）。同名ファイルが既にある場合は差分を提示して上書き確認する。

```markdown
<!-- INTERNAL: 内部資料。クライアント固有名を含む。公開物へ転記する前に
     redact パターン（gitleaks-own.toml の client-identifiers）での検査を必ず行うこと -->
# Worklog <LABEL>（<START_DATE> 〜 <END_DATE> JST）

## ハイライト
- （外から見える成果を 3〜5 行）

## リポジトリ別詳細
### <owner/repo>
- ✅ Merged: #123 タイトル（URL）
- 🚧 Opened: #124 タイトル（URL、draft なら明記）
- 👀 Reviewed: #125 タイトル（author、submitted_at 検証済み）
- 🎯 Issues: #45 タイトル（state）

## 活動メトリクス
| 指標 | 値 |
|------|----|
| Merged PR | N |
| Opened PR | N |
| レビューした PR（submitted_at 検証済み） | N |
| 関与 Issue（期間内更新の近似） | N |
| コミット（ローカル観測分） | N |
| アクティブ repo | N |

（稼働時間はここに人間が記入: ___ h — 本 skill は時間を推定しない）

## 翌週へ持ち越し
- （open PR / assigned issue の一覧）

## 所感（人間記入）
-
```

`--csv` 時は同名 `.csv` も出力する。ヘッダ: `date,repo,type,ref,title,url`（`type` は `pr-merged|pr-opened|review|issue|commit|session`、`date` は JST の `YYYY-MM-DD`）。フィールドは **RFC 4180 準拠でダブルクォート**する（タイトル中のカンマ・引用符対策）。

## 運用メモ

- 推奨リズム: 毎週月曜朝に `/worklog --period=last-week`（morning-brief と同じ朝ルーチンに載る）。月次請求前に `/worklog --period=last-month --csv`。
- 検索 limit 100 を超えて溢れた場合は、溢れた旨をレポート末尾に必ず明記する（silent truncation 禁止）。
- 出力はあくまで**ドラフト**。所感・時間数の記入と、提出・送信・転記は人間が行う。
