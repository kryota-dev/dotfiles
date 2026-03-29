---
name: save-session
description: Ghosttyターミナルのバッファを取得し、サブエージェントでMarkdownに変換して保存する。セッションログのアーカイブや振り返りに使用
argument-hint: [label]
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/*), Agent
---

# セッション内容をMarkdownで保存

## 手順

### 1. バッファ取得スクリプトの実行

```bash
RAW_FILE=$(bash ${CLAUDE_SKILL_DIR}/scripts/capture.sh "$ARGUMENTS")
```

スクリプトが以下を自動処理:

- Ghostty環境の確認（`GHOSTTY_RESOURCES_DIR`）
- git情報（owner-repo, branch）からパスを組み立て
- `mktemp` でアトミックにファイル生成（`.txt` 拡張子）
- クリップボードを退避・復元
- AppleScriptで `select_all` → `copy_to_clipboard` でペインバッファを取得
- 取得後に選択を解除
- stdout に生成ファイルパスを出力

出力先: `$HOME/Documents/session-logs/<owner>-<repo>/YYYY-MM-DD-<branch>/sessions/<label>-<XXXXXX>.txt`

### 2. サブエージェントでMarkdown変換

**メインのコンテキストを圧迫しないよう、必ずAgentツール（subagent）に変換を委譲すること。**

サブエージェントへの指示:

1. 生テキストファイル `$RAW_FILE`（`.txt`）を読み込む
2. 以下のルールに従ってMarkdownに変換する:
   - ユーザーの入力は `>` 引用ブロックで表現
   - Claudeの応答は通常テキストで記述
   - コマンド実行とその出力は適切なコードブロック（```bash, ```json 等）で囲む
   - ツール呼び出し結果は `<details>` タグで折りたたむ
   - エラーは ❌、成功は ✅ でマーク
   - セッションの概要・学び・次のステップを生成
3. 変換結果を `<RAW_FILEから.txtを除いた部分>_formatted.md` に書き出す

### 3. 結果報告

サブエージェント完了後、以下を簡潔に報告:

- 保存先パス（.txt / _formatted.md の両方）
- 各ファイルサイズ
- セッション概要（1行）
