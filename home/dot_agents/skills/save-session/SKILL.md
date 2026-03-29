---
name: save-session
description: Claude Codeのセッションファイル（JSONL）を取得し、サブエージェントでMarkdownに変換して保存する。セッションログのアーカイブや振り返りに使用
argument-hint: "[label] - 出力ファイル名のプレフィックス（デフォルト: session、例: review, debug, refactor）"
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/*), Agent
---

# セッション内容をMarkdownで保存

## 手順

### 1. セッションファイル取得スクリプトの実行

```bash
RAW_FILE=$(bash ${CLAUDE_SKILL_DIR}/scripts/capture.sh "${CLAUDE_SESSION_ID}" "$ARGUMENTS")
```

スクリプトが以下を自動処理:

- `${CLAUDE_SESSION_ID}`（スキル変数展開）でセッションを正確に特定
- `~/.claude/projects/` 配下から対応するJSONLファイルを取得
- git情報（owner-repo, branch）からパスを組み立て
- 出力先にJSONLファイルをコピー

出力先: `$HOME/Documents/session-logs/<owner>-<repo>/YYYY-MM-DD-<branch>/sessions/<label>-<session-id>.jsonl`

### 2. サブエージェントでMarkdown変換

**メインのコンテキストを圧迫しないよう、必ずAgentツール（subagent）に変換を委譲すること。**

サブエージェントへの指示:

1. JSONLファイル `$RAW_FILE` を読み込む
2. 各行をJSONとしてパースし、`type` フィールドで分類する:
   - `user`（`.message.content`）: ユーザーの入力 → `>` 引用ブロック
   - `assistant`（`.message.content[]`）:
     - `type: "text"` → 通常テキスト
     - `type: "tool_use"` → コマンド実行はコードブロック（```bash 等）で表示
     - `type: "thinking"` → 省略する
   - `progress` / `file-history-snapshot` / `system` → 省略する
3. 変換ルール:
   - ツール呼び出し結果は `<details>` タグで折りたたむ
   - エラーは ❌、成功は ✅ でマーク
   - セッションの概要・学び・次のステップを生成
4. 変換結果を `<RAW_FILEから.jsonlを除いた部分>_formatted.md` に書き出す

### 3. 結果報告

サブエージェント完了後、以下のフォーマットで報告:

```
セッション保存完了。

- JSONL: {label}-{session-id}.jsonl ({size})
- Markdown: {label}-{session-id}_formatted.md ({size})
- 保存先: ~/Documents/session-logs/{owner-repo}/{date}-{branch}/sessions/
- 概要: {セッション内容の1行要約}
```
