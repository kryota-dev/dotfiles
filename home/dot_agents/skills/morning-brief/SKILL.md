---
name: morning-brief
description: |
  朝イチの状況把握を 1 コマンドに統合する skill。repo-radar（GitHub 横断）・gmail-triage
  （受信箱）・Google Calendar（今日の予定）・前日の session-summary（作業コンテキスト）を
  並列収集し、「今日どこから手を付けるか」を 1 枚のブリーフィングにまとめる。全収集 read-only。
  トリガー: "morning-brief", "朝ブリーフィング", "おはよう", "今日の状況", "モーニングブリーフ"
  使用場面: 始業時のキャッチアップ、Daily Standup 前の準備、休暇明けの状況復帰。
argument-hint: "[--days=N] [--skip=mail|repo|calendar|context] [--post]"
user-invocable: true
---

# morning-brief

「今日は何から始めるか」を決めるための材料を、始業前に 1 枚へ集約する。
個別の深掘りは各 skill（repo-radar / gmail-triage）へハンドオフし、本 skill は統合と
優先判断の提示に徹する。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--days` | 3 | メール・コンテキストの遡り日数（休暇明けは大きくする） |
| `--skip` | なし | 指定セクションの収集を省略する（例: `--skip=mail`） |
| `--post` | off | ブリーフィングを daily-planning の Discussion にコメント投稿する（投稿前に承認必須） |

## 安全原則

- 収集はすべて read-only（GitHub 検索・Gmail 検索・Calendar 参照・ローカル markdown の Read）。
- `--post` 時のみ書き込みが発生し、投稿本文を提示して user 承認を得てからコメントする。
- 会社カレンダーの予定詳細（参加者・会議 URL）は、`--post` する本文には含めない（時刻と件名のみ）。

## Phase 1: 並列収集

以下の 4 系統を**並列で**収集する。1 系統が失敗しても中断せず、そのセクションに
「取得失敗（理由）」と明記して続行する:

1. **GitHub**: `repo-radar` の Phase 1〜2（収集・優先度付け）を read-only で実行する。
2. **受信箱**: `gmail-triage` の Phase 1〜3 を report-only で実行する（`--days` を引き継ぐ）。
3. **今日の予定**: Google Calendar MCP `list_events` で今日 0:00〜24:00（JST）を取得し、
   時刻順に並べる。空き時間帯（連続 60 分以上）も算出する。
4. **前日コンテキスト**: 直近の session-summary（`.kryota-dev/claude/session-summary/` 等、
   各リポジトリの既存出力先）と、アクティブリポジトリの `git log --since` から
   「昨日どこまでやったか・中断中の作業」を要約する。

## Phase 2: ブリーフィング出力

```markdown
# Morning Brief — <日付 JST>

## 今日の予定
| 時刻 | 件名 |
（空き時間帯: <例: 09:00-10:00, 15:00-16:30>）

## 今すぐ対応（P1）
（repo-radar P1 + gmail-triage A/C 区分から抽出。なければ「なし ✅」）

## 昨日の続き
（中断中の作業・未 push の変更・未完了タスクを 3 行以内で）

## 今日中に見るもの
（repo-radar P2〜P3、受信箱 B 区分、締切が近いイベント）

## 推奨ネクストアクション（3 つまで）
1. <空き時間帯と突き合わせた、最もレバレッジの高い具体的な 1 手>
```

**推奨ネクストアクション**は「何を」だけでなく「いつ」（どの空き時間帯で）まで踏み込む。
該当があれば各 skill へのハンドオフを具体的に示す（`renovate-sweep --all` /
`issue-fleet <番号列>` / `review-resolve-loop` / `gmail-triage --apply` など）。

## Phase 3: 投稿（`--post` 時のみ）

`daily-planning` skill の手順で今月分の Daily planning Discussion を特定し、
ブリーフィングをコメント投稿する。**投稿本文を提示して user 承認を得てから実行する**。

## 運用メモ

- 平日朝の定時実行（cron / routine）に載せる場合は read-only 部分のみを対象とし、
  その設定は課金を伴うため **user の明示依頼で**行う（kryota-dev/dotfiles#257 と統合予定）。
- 収集 4 系統のうち MCP 依存（Gmail / Calendar）は headless 実行時に認証切れの可能性がある。
  その場合もエラーで止めず、GitHub + ローカルコンテキストのみで縮退出力する。
