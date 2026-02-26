---
name: claude-code-settings
description: Claude Codeの設定（Settings / settings.json）に関するリファレンス。設定ファイルの場所と優先順位、全設定項目、パーミッション、環境変数、モデル設定、CLAUDE.mdなどの知識を提供する。「settings.json」「設定」「パーミッション」「permissions」「CLAUDE.md」「defaultMode」と言及された際に使用。
user-invocable: false
---

# Claude Code 設定 リファレンス

## 設定ファイルの場所と優先順位（高→低）

| 優先度 | スコープ | 場所 | 共有 |
|--------|---------|------|------|
| 1 | マネージド | macOS: /Library/Application Support/ClaudeCode/managed-settings.json | 組織全体 |
| 2 | CLI引数 | コマンドラインフラグ | セッション限定 |
| 3 | ローカル | .claude/settings.local.json | なし（gitignore） |
| 4 | プロジェクト | .claude/settings.json | あり（git管理） |
| 5 | ユーザー | ~/.claude/settings.json | なし |

### その他の設定ファイル

```
~/.claude.json              # プライベート設定（OAuth、MCP、キャッシュ）
.mcp.json                   # プロジェクトMCPサーバー設定
.claude/CLAUDE.md           # プロジェクト記憶（チーム共有）
CLAUDE.md                   # プロジェクト記憶（ルート）
CLAUDE.local.md             # ローカル記憶（gitignore）
~/.claude/CLAUDE.md         # グローバル記憶
.claude/rules/*.md          # モジュール化ルール
~/.claude/rules/*.md        # グローバルルール
```

## パーミッション設定

### 基本構造

```json
{
  "permissions": {
    "allow": ["Bash(npm run *)"],
    "ask": ["Bash(git push *)"],
    "deny": ["Bash(curl *)", "Read(.env)"],
    "defaultMode": "acceptEdits",
    "additionalDirectories": ["../docs/"]
  }
}
```

### defaultMode の値

| モード | 説明 |
|--------|------|
| default | 初回使用時に許可が必要 |
| acceptEdits | ファイル編集の自動承認 |
| plan | Plan Mode: 読み取り専用 |
| dontAsk | 事前承認なし以外は自動拒否 |
| bypassPermissions | 全許可スキップ（危険） |

### ルール構文

```json
{
  "permissions": {
    "allow": [
      "Bash(npm run lint)",        // 正確なコマンド
      "Bash(npm run *)",           // ワイルドカード
      "Bash(git * main)",          // 中間ワイルドカード
      "Read",                      // ツール全体
      "MCP(github)",               // MCPサーバー全体
      "mcp__github__list_prs",     // 特定MCPツール
      "WebFetch(domain:github.com)" // ドメイン指定
    ],
    "deny": [
      "Read(.env)",                // 相対パス（CWDから）
      "Read(~/.ssh/id_rsa)",       // ホームディレクトリ
      "Read(//etc/passwd)",        // 絶対パス
      "Read(/src/**/*.ts)",        // 相対パス（settings.jsonから）
      "Task(Explore)",             // サブエージェント
      "mcp__github__*"             // MCPツール（ワイルドカード）
    ]
  }
}
```

### 評価順序

**deny → ask → allow**（最初にマッチしたルールが適用。denyが常に優先）

## 環境変数設定

```json
{
  "env": {
    "ANTHROPIC_API_KEY": "sk-xxx",
    "ANTHROPIC_MODEL": "claude-opus-4-6",
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000",
    "MAX_THINKING_TOKENS": "31999",
    "MAX_MCP_OUTPUT_TOKENS": "50000",
    "MCP_TIMEOUT": "10000",
    "ENABLE_TOOL_SEARCH": "auto",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

## モデル設定

```json
{
  "model": "opus",
  "availableModels": ["sonnet", "haiku"],
  "alwaysThinkingEnabled": true
}
```

### モデルエイリアス

| エイリアス | 説明 |
|----------|------|
| default | アカウント種別に応じた推奨モデル |
| sonnet | 最新 Sonnet（Sonnet 4.6） |
| opus | 最新 Opus（Opus 4.6） |
| haiku | 高速・効率的 Haiku |
| sonnet[1m] | Sonnet 1M トークンコンテキスト |
| opusplan | Plan=Opus、実行=Sonnet |

## フック設定

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "npx prettier --write"
          }
        ]
      }
    ]
  }
}
```

## MCPサーバー設定

```json
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["github", "sentry"],
  "disabledMcpjsonServers": ["filesystem"]
}
```

## プラグイン設定

```json
{
  "enabledPlugins": {
    "code-formatter@company-tools": true
  },
  "extraKnownMarketplaces": {
    "company-tools": {
      "source": { "source": "github", "repo": "org/plugins" }
    }
  }
}
```

## サンドボックス設定

```json
{
  "sandbox": {
    "enabled": true,
    "mode": "auto-allow"
  }
}
```

## ステータスライン設定

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  }
}
```

## CLAUDE.md

### ファイル場所と階層

| ファイル | スコープ | 共有 |
|---------|---------|------|
| ~/.claude/CLAUDE.md | グローバル | なし |
| ./CLAUDE.md | プロジェクト | あり（git） |
| ./.claude/CLAUDE.md | プロジェクト（代替） | あり（git） |
| ./CLAUDE.local.md | ローカル | なし（gitignore） |
| ./.claude/rules/*.md | モジュール化ルール | あり（git） |

### パス固有ルール（.claude/rules/）

```markdown
---
paths:
  - "src/api/**/*.ts"
---

# API Development Rules

- All API endpoints must include input validation
- Use standard error response format
```

### CLAUDE.md ベストプラクティス

- 500行以下を目安
- 実装に影響するもののみ記述
- `@README.md` で他ファイルを参照可能

## 管理コマンド

```bash
/config         # 設定UI
/permissions    # パーミッション管理
/hooks          # Hook管理
/memory         # メモリファイル管理
/mcp            # MCPサーバー管理
/model          # モデル切り替え
/sandbox        # Sandbox設定
/statusline     # ステータスライン設定
/vim            # Vimモード切り替え
/cost           # コスト・トークン使用量
/context        # 詳細なコンテキスト分析
```

## マネージド設定（エンタープライズ限定）

```json
{
  "allowManagedHooksOnly": true,
  "allowManagedPermissionRulesOnly": true,
  "disableBypassPermissionsMode": "disable",
  "availableModels": ["sonnet", "haiku"],
  "strictKnownMarketplaces": [...],
  "allowedMcpServers": [...]
}
```

## 設定シナリオ例

### セキュリティ重視

```json
{
  "permissions": {
    "defaultMode": "plan",
    "deny": ["Read(.env*)", "Read(**/*secret*)", "Bash(curl *)", "Bash(wget *)"],
    "allow": ["Bash(npm run lint)", "Bash(npm test)", "Read"]
  },
  "sandbox": { "enabled": true }
}
```

### パフォーマンス重視

```json
{
  "model": "opusplan",
  "alwaysThinkingEnabled": true,
  "env": { "MAX_THINKING_TOKENS": "31999", "ENABLE_TOOL_SEARCH": "auto:5" },
  "permissions": { "defaultMode": "acceptEdits" }
}
```

### チーム開発

```json
{
  "permissions": {
    "deny": ["Read(.env)", "Bash(git push)"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "./hooks/validate-command.sh" }]
      }
    ]
  }
}
```

## JSON Schema

設定ファイルの先頭にスキーマを指定可能:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json"
}
```
