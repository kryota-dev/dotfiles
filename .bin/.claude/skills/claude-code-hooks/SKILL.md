---
name: claude-code-hooks
description: Claude Codeのフック（Hooks）機能に関するリファレンス。フックの種類、設定方法、入出力形式、マッチャー、具体的な実装例を提供する。「フック」「hooks」「PreToolUse」「PostToolUse」「自動フォーマット」「ファイル保護」と言及された際に使用。
user-invocable: false
---

# Claude Code フック リファレンス

## 概要

フックは、Claude Codeのライフサイクル内の特定時点で自動実行されるユーザー定義のシェルコマンドまたはLLMプロンプト。
決定論的な制御を提供し、プロジェクトルールの実装や繰り返しタスクの自動化に使用。

## フックの種類（イベント）

| イベント | 発火時期 | マッチ対象 |
|---------|--------|-----------|
| SessionStart | セッション開始・再開時 | 開始方法（startup/resume/clear/compact） |
| UserPromptSubmit | ユーザープロンプト送信時 | なし（全て発火） |
| PreToolUse | ツール実行前 | ツール名 |
| PermissionRequest | 権限ダイアログ表示時 | ツール名 |
| PostToolUse | ツール実行後（成功） | ツール名 |
| PostToolUseFailure | ツール実行失敗後 | ツール名 |
| Notification | 通知送信時 | 通知タイプ |
| SubagentStart | サブエージェント起動時 | エージェント種類 |
| SubagentStop | サブエージェント終了時 | エージェント種類 |
| Stop | Claude応答終了時 | なし |
| TeammateIdle | チームメイト待機時 | なし |
| TaskCompleted | タスク完了マーク時 | なし |
| PreCompact | コンテキスト圧縮前 | 圧縮理由（manual/auto） |
| SessionEnd | セッション終了時 | 終了理由 |

## 設定方法

### settings.json での記述

```json
{
  "hooks": {
    "イベント名": [
      {
        "matcher": "正規表現パターン",
        "hooks": [
          {
            "type": "command",
            "command": "実行するコマンド",
            "timeout": 600
          }
        ]
      }
    ]
  }
}
```

### 設定ファイルの場所と優先度（高→低）

1. Managed settings（管理者制御）
2. SDK hooks（エージェント定義内）
3. Plugin hooks（プラグインの hooks/hooks.json）
4. Project hooks（.claude/settings.json）
5. Project local hooks（.claude/settings.local.json）
6. User hooks（~/.claude/settings.json）

## フックの型

| 型 | 説明 |
|----|------|
| command | シェルコマンド実行 |
| prompt | LLMプロンプト評価 |
| agent | エージェントベースの検証 |

## 入力データ（stdin JSON）

### 共通フィールド

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/Users/user/my-project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse"
}
```

### PreToolUse 固有フィールド

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test",
    "description": "Run test suite",
    "timeout": 120000
  }
}
```

### Stop 固有フィールド

```json
{
  "stop_hook_active": true,
  "last_assistant_message": "I've completed..."
}
```

## 出力形式（stdout JSON）

### 終了コード

| コード | 意味 | 動作 |
|-------|------|------|
| 0 | 成功 | 実行許可。JSON出力を処理 |
| 2 | ブロック | 実行ブロック。stderrが返却 |
| その他 | エラー | 実行継続。stderrはverboseモード表示 |

### 汎用出力フィールド

```json
{
  "continue": true,
  "stopReason": "Build failed",
  "suppressOutput": false,
  "systemMessage": "警告メッセージ"
}
```

### PreToolUse の決定制御

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow|deny|ask",
    "permissionDecisionReason": "理由",
    "updatedInput": { "field": "new_value" },
    "additionalContext": "Claudeへのコンテキスト"
  }
}
```

## マッチャーの例

```json
{ "matcher": "Edit|Write" }           // 複数ツール
{ "matcher": "mcp__github__.*" }      // MCPツール
{ "matcher": "Bash" }                 // 単一ツール
{ "matcher": "" }                     // すべてで発火
```

## 実行方式

- マッチしたすべてのフックが**並列実行**
- 同一コマンドは自動重複排除（1回のみ実行）

## 具体的な実装例

### 例1: 自動フォーマット（PostToolUse）

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write"
          }
        ]
      }
    ]
  }
}
```

### 例2: 保護ファイルのブロック（PreToolUse）

```bash
#!/bin/bash
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

PROTECTED_PATTERNS=(".env" "package-lock.json" ".git/")
for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "Blocked: $FILE_PATH matches protected pattern '$pattern'" >&2
    exit 2
  fi
done
exit 0
```

### 例3: デスクトップ通知（Notification - macOS）

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "osascript -e 'display notification \"Claude Code needs attention\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

### 例4: コンテキスト注入（SessionStart - compact時）

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Reminder: use Bun, not npm. Run bun test before committing.'"
          }
        ]
      }
    ]
  }
}
```

### 例5: 危険なコマンドのブロック（PreToolUse）

```bash
#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')
if echo "$COMMAND" | grep -q "drop table\|rm -rf"; then
  echo "Blocked: potentially destructive command" >&2
  exit 2
fi
exit 0
```

### 例6: 環境変数の永続化（SessionStart）

```bash
#!/bin/bash
if [ -n "$CLAUDE_ENV_FILE" ]; then
  echo 'export NODE_ENV=production' >> "$CLAUDE_ENV_FILE"
fi
exit 0
```

### 例7: 非同期フック（背景実行）

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/run-tests-async.sh",
            "async": true,
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

## ベストプラクティス

1. **シェル変数を引用符で囲む**: `"$FILE_PATH"` とする
2. **パストラバーサル検査**: `".."` を含むパスを拒否
3. **SessionStartは高速に**: 毎セッション実行されるため
4. **プロジェクトディレクトリ参照**: `"$CLAUDE_PROJECT_DIR"/.claude/hooks/script.sh`
5. **Stopフックの無限ループ防止**: `stop_hook_active` をチェック
6. **デバッグ**: `echo "Debug info" >&2` でverbose出力、`claude --debug` で確認
7. **管理コマンド**: `/hooks` でインタラクティブに管理
