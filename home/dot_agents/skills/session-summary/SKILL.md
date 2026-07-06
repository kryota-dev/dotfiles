---
name: session-summary
description: 'セッション終了時に作業サマリーをmarkdownで出力する。「セッションサマリー」「作業サマリー」「session summary」「サマリーを出力」「今日の作業をまとめて」と言及された際に使用。セッションで行った全作業を構造化して記録し、次回セッションへの引き継ぎ資料とする。'
argument-hint: "[--archive [label]] - 深掘りモード起動フラグ（省略時は通常モード）"
---

# セッションサマリー生成

現在のセッションで行った作業を構造化されたmarkdownファイルとして出力する。

## 出力先

`.kryota-dev/claude/session-summary/` 配下（プロジェクトルート相対）

## ファイル命名規則

`<timestamp>_<session-id>.md`

- タイムスタンプ: `date '+%Y%m%d%H%M%S'` で取得
- セッションID: `~/.claude/projects/` 配下の現プロジェクトディレクトリ内で最新の `.jsonl` ファイル名（拡張子除去）から取得

```bash
# セッションID取得例
CLAUDE_PROJECT_DIR="$HOME/.claude/projects"
# プロジェクトパスはCWDから導出（/ を - に置換）
PROJECT_KEY=$(pwd | sed 's|/|-|g')
SESSION_ID=$(ls -t "$CLAUDE_PROJECT_DIR/$PROJECT_KEY/"*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)
TIMESTAMP=$(date '+%Y%m%d%H%M%S')
FILENAME="${TIMESTAMP}_${SESSION_ID}.md"
```

## サマリーの構成

会話履歴を振り返り、以下の構造でサマリーを作成する。セッション内容に応じてセクションを取捨選択し、該当しないセクションは省略する。

```markdown
# セッションサマリー: {セッションの主題を簡潔に}

| Field      | Value                       |
| ---------- | --------------------------- |
| **Date**   | {YYYY-MM-DD}                |
| **Branch** | `{ブランチ名}`              |
| **PR**     | {PRリンク（あれば）}        |
| **Issue**  | {関連Issueリンク（あれば）} |

---

## 実施内容

{セッションで行った作業を論理的なグループに分けて記述}
{各グループ内で具体的な変更・決定事項を箇条書き}

## コミット履歴

{セッション中に作成されたコミットを `git log --oneline` 形式で列挙}

## 未着手・残課題

{着手できなかったタスク、次回セッションで対応すべき事項}

## 設計判断・議論

{ユーザーとの議論で下された設計判断があれば記録}
{判断の根拠・代替案・却下理由を含める}

## 学び・改善点

{セッション中に得られた教訓、次回以降に活かすべき改善点}
```

## 作成手順

1. `date '+%Y%m%d%H%M%S'` でタイムスタンプを取得
2. `~/.claude/projects/` からセッションIDを取得
3. 出力ディレクトリ `.kryota-dev/claude/session-summary/` を作成（`mkdir -p`）
4. 会話履歴を振り返り、上記テンプレートに沿ってサマリーを作成
5. ファイルを書き出す

## 深掘りモード（`--archive [label]` 起動）

引数の先頭が `--archive` の場合は、通常の会話履歴ベースのサマリー生成ではなく、**セッション JSONL の物理アーカイブ + サブエージェントによる深掘りサマリー生成**モードで動作する。`~/Documents/session-logs/` 配下に永続保管したい・数か月後に監査したい・レビュー用に配布したい場面で使う（通常モードよりコストが高い）。

**model 経由の起動には反応させない**。description は `--archive` を意図的に載せておらず、通常モード用のトリガー語彙のみ含む。深掘りモードは slash 起動（`/session-summary --archive ...`）でのみ発火させ、`AskUserQuestion` で明示確認したうえで進めることを推奨する。

### 1. 引数の解釈と JSONL のアーカイブ

`$ARGUMENTS` の先頭が `--archive` であれば、その後の空白区切りの残りをそのまま `LABEL` として使う（省略時は `session`）:

```bash
# $ARGUMENTS 例: "--archive review" / "--archive" / ""
REST="${ARGUMENTS#--archive}"        # "--archive review" → " review"
LABEL="${REST# }"                    # 先頭スペースを除去 → "review"
LABEL="${LABEL:-session}"            # 空なら "session"

RAW_FILE=$(bash "${CLAUDE_SKILL_DIR}/scripts/capture.sh" "${CLAUDE_SESSION_ID}" "$LABEL")
```

`capture.sh` の探索順:

1. `$CLAUDE_CONFIG_DIR/projects/`（環境変数が設定されていれば最優先）
2. `$HOME/.claude*/projects/`（標準 `~/.claude` と派生環境 `~/.claude-r06` 等を一括カバー）

`label` に `/` を含めても、ファイル名は安全化される（`/` → `-`）。出力先は `~/Documents/session-logs/<owner-repo>/<date>-<branch>/sessions/<label>-<session-id>.jsonl`。

### 2. サブエージェントで深掘りサマリー生成

**メインのコンテキストを圧迫しないよう、必ず Agent ツール（general-purpose）に委譲**する。渡す指示テンプレート本体は本 skill の [`references/archive-mode.md`](references/archive-mode.md) にあるため、深掘りモード起動時に Read でその全文を読み、`<RAW_FILE>` を capture.sh の戻り値で置換した上で subagent の prompt として渡す（jq クエリ・除外条件・出力フォーマット・品質基準まで含む完全版）。

### 3. 結果報告

サブエージェント完了後、以下のフォーマットで報告:

```
セッション保存完了。
- JSONL: <label>-<session-id>.jsonl (<size>)
- サマリー: <label>-<session-id>_formatted.md (<size>)
- 保存先: ~/Documents/session-logs/<owner-repo>/<date>-<branch>/sessions/
- 概要: <セッション内容の 1 行要約>
```

## 注意事項

- メタデータテーブルの各フィールドは、セッション中に該当する情報がない場合は行ごと省略する
- 「実施内容」は最も重要なセクション。作業の時系列ではなく、論理的なまとまりで構成する
- コミット履歴はセッション開始時点のHEADからの差分を `git log` で取得する
- 残課題は具体的に記述し、次回セッションですぐに着手できるレベルの粒度にする
- **深掘りモードは `--archive` 明示時のみ起動する**。通常のサマリー要求（`セッションサマリーを出力して`等）では従来どおり会話履歴ベースの軽量モードで動作する
