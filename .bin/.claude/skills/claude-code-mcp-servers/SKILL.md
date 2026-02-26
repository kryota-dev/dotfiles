---
name: claude-code-mcp-servers
description: Claude CodeのMCPサーバー（Model Context Protocol）設定に関するリファレンス。MCPサーバーの設定方法、トランスポート、スコープ、権限設定、管理コマンドなどの知識を提供する。「MCPサーバー」「MCP」「Model Context Protocol」「外部ツール連携」と言及された際に使用。
user-invocable: false
---

# Claude Code MCPサーバー リファレンス

## 概要

MCP（Model Context Protocol）は、Claude Codeを外部ツールやデータソースに接続するオープンスタンダード。
GitHub, Sentry, Notion, Figma, PostgreSQL, Stripe 等と連携可能。

## トランスポート方式

| 方式 | 対象 | 推奨度 | コマンド |
|------|------|--------|---------|
| HTTP | クラウドサービス | 推奨 | `claude mcp add --transport http` |
| SSE | リモートサーバー | 非推奨（廃止予定） | `claude mcp add --transport sse` |
| Stdio | ローカルプロセス | 場合による | `claude mcp add --transport stdio` |

## 設定方法

### CLI コマンド

```bash
# HTTP サーバー
claude mcp add --transport http notion https://mcp.notion.com/mcp

# HTTP（Bearer認証付き）
claude mcp add --transport http secure-api https://api.example.com/mcp \
  --header "Authorization: Bearer your-token"

# Stdio サーバー（環境変数付き）
claude mcp add --transport stdio --env AIRTABLE_API_KEY=YOUR_KEY airtable \
  -- npx -y airtable-mcp-server

# JSON設定から追加
claude mcp add-json my-server '{"type":"http","url":"https://..."}'

# Claude Desktopから設定インポート
claude mcp add-from-claude-desktop
```

### .mcp.json（プロジェクトスコープ）

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/"
    },
    "database": {
      "type": "stdio",
      "command": "/usr/local/bin/db-server",
      "args": ["--config", "${CONFIG_DIR}/db.json"],
      "env": {
        "DB_URL": "${DATABASE_URL:-localhost:5432}"
      }
    }
  }
}
```

## スコープ

| スコープ | 保存位置 | コマンド | 用途 |
|---------|---------|---------|------|
| local | ~/.claude.json | デフォルト | 個人用、機密情報含む |
| project | .mcp.json | `--scope project` | チーム共有、git管理 |
| user | ~/.claude.json | `--scope user` | 複数プロジェクト共通 |

### 優先順位（高→低）

1. Local scope
2. Project scope
3. User scope

## 管理コマンド

```bash
claude mcp list                      # 一覧表示
claude mcp get github                # 詳細確認
claude mcp remove github             # 削除
claude mcp reset-project-choices     # プロジェクトスコープの承認リセット
claude mcp serve                     # Claude Code自体をMCPサーバーとして実行
```

### セッション内

```bash
/mcp                                 # MCPサーバーの状態確認・認証
```

## 権限設定

### settings.json でのMCP権限

```json
{
  "permissions": {
    "allow": [
      "MCP(github)",
      "MCP(memory)",
      "mcp__puppeteer__puppeteer_navigate"
    ],
    "deny": [
      "MCP(filesystem)"
    ]
  }
}
```

### プロジェクトMCPサーバーの自動承認

```json
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["memory", "github"],
  "disabledMcpjsonServers": ["filesystem"]
}
```

### マネージド設定での制限

```json
{
  "allowedMcpServers": [
    { "serverName": "github" },
    { "serverCommand": ["npx", "-y", "approved-package"] },
    { "serverUrl": "https://mcp.company.com/*" }
  ],
  "deniedMcpServers": [
    { "serverName": "dangerous-server" }
  ]
}
```

## 環境変数

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| MAX_MCP_OUTPUT_TOKENS | 出力トークン上限 | 25000 |
| MCP_TIMEOUT | サーバー起動タイムアウト（ms） | - |
| ENABLE_TOOL_SEARCH | ツール検索有効化 | auto |

## MCP Tool Search

ツール定義がコンテキストの10%超で自動有効化:

```bash
export ENABLE_TOOL_SEARCH=true        # 強制有効化
export ENABLE_TOOL_SEARCH=auto:5      # 5%で有効化
export ENABLE_TOOL_SEARCH=false       # 無効化
```

## MCPプロンプトの実行

```bash
/mcp__github__list_prs               # MCPプロンプトをコマンドとして実行
/mcp__github__pr_review 456          # 引数付き
```

## トラブルシューティング

| 問題 | 原因 | 解決策 |
|------|------|--------|
| Connection closed | Windows: cmd /c ラッパー未使用 | `cmd /c npx ...` を使用 |
| Server not found | スコープの不一致 | `claude mcp list` で確認 |
| 認証エラー | OAuth失敗 | `/mcp` で再認証 |
| 出力が大きすぎる | デフォルト上限 | `MAX_MCP_OUTPUT_TOKENS=50000` |

### 診断コマンド

```bash
claude doctor     # 設定の診断
claude --verbose  # 詳細デバッグ
```

## ベストプラクティス

1. **環境変数で機密情報管理**: `.mcp.json` に直接トークンを記述しない
2. **プロジェクトMCPはgit管理**: `.mcp.json` をコミットしてチーム共有
3. **権限の最小化**: 必要最小限のMCP権限のみ付与
4. **信頼できるサーバーのみ使用**: サードパーティサーバーはセキュリティリスク
5. **プロンプトインジェクション対策**: 未検証コンテンツを取得するMCPサーバーは慎重に
6. **HTTP推奨**: SSEは非推奨・廃止予定
