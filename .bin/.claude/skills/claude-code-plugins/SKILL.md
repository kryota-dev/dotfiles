---
name: claude-code-plugins
description: Claude Codeのプラグイン（Plugins）機能に関するリファレンス。プラグインの構造、作成方法、インストール、マーケットプレイス、配布方法などの知識を提供する。「プラグイン」「plugin」「マーケットプレイス」「marketplace」と言及された際に使用。
user-invocable: false
---

# Claude Code プラグイン リファレンス

## 概要

プラグインは、スキル・エージェント・フック・MCPサーバー・LSPサーバーをまとめてパッケージ化し、
チームやコミュニティと共有できる自己完結型の拡張単位。
ネームスペース付き（`/plugin-name:skill-name`）で名前衝突を回避。

## ディレクトリ構造

```
my-plugin/
├── .claude-plugin/              # メタデータ（オプション）
│   └── plugin.json              # マニフェスト
├── skills/                      # スキル（<name>/SKILL.md 構造）
├── agents/                      # エージェント定義
├── commands/                    # スラッシュコマンド（レガシー）
├── hooks/                       # フック
│   └── hooks.json
├── .mcp.json                    # MCPサーバー定義
├── .lsp.json                    # LSPサーバー定義
├── scripts/                     # フック用スクリプト
├── LICENSE
└── README.md
```

注意: `.claude-plugin/` には `plugin.json` のみ配置。
skills/, agents/, hooks/ 等はすべてプラグインルートに配置。

## plugin.json マニフェスト

```json
{
  "name": "plugin-name",
  "version": "1.0.0",
  "description": "プラグインの説明",
  "author": { "name": "Author Name" },
  "homepage": "https://docs.example.com",
  "repository": "https://github.com/user/plugin",
  "license": "MIT",
  "keywords": ["keyword1", "keyword2"],
  "commands": ["./custom/commands/"],
  "agents": "./custom/agents/",
  "skills": "./custom/skills/",
  "hooks": "./config/hooks.json",
  "mcpServers": "./mcp-config.json",
  "lspServers": "./.lsp.json"
}
```

### 必須フィールド

- `name`: ユニーク識別子（kebab-case）

### 環境変数

- `${CLAUDE_PLUGIN_ROOT}`: プラグインディレクトリの絶対パス

## プラグインの作成手順

### 1. ディレクトリ作成

```bash
mkdir -p my-plugin/.claude-plugin
mkdir -p my-plugin/skills/hello
```

### 2. マニフェスト作成

`my-plugin/.claude-plugin/plugin.json`

### 3. スキル追加

`my-plugin/skills/hello/SKILL.md`

### 4. ローカルテスト

```bash
claude --plugin-dir ./my-plugin
```

呼び出し: `/my-plugin:hello` または `/my-plugin:hello arguments`

## インストール方法

### インストールスコープ

| スコープ | 設定ファイル | 用途 |
|---------|-----------|------|
| user | ~/.claude/settings.json | 個人用、全プロジェクト |
| project | .claude/settings.json | チーム共有、git管理下 |
| local | .claude/settings.local.json | 個人用、gitignore |
| managed | managed-settings.json | 組織全体 |

### インストール方法

```bash
# インタラクティブUI
/plugin

# コマンド
/plugin install plugin-name@marketplace-name
/plugin install plugin-name@marketplace-name --scope project
```

### settings.json での自動設定

```json
{
  "enabledPlugins": {
    "code-formatter@company-tools": true
  },
  "extraKnownMarketplaces": {
    "company-tools": {
      "source": {
        "source": "github",
        "repo": "your-org/claude-plugins"
      }
    }
  }
}
```

## 管理コマンド

```bash
/plugin enable plugin-name@marketplace-name
/plugin disable plugin-name@marketplace-name
/plugin uninstall plugin-name@marketplace-name
/plugin update plugin-name@marketplace-name
/plugin marketplace add owner/repo
/plugin marketplace list
/plugin marketplace remove marketplace-name
```

## マーケットプレイス配布

### marketplace.json

```json
{
  "name": "my-plugins",
  "owner": { "name": "Your Name" },
  "plugins": [
    {
      "name": "review-plugin",
      "source": "./plugins/review-plugin",
      "description": "コードレビュースキル",
      "version": "1.0.0"
    }
  ]
}
```

### プラグインソースの種類

| ソース | 例 |
|--------|-----|
| 相対パス | `"source": "./plugins/my-plugin"` |
| GitHub | `{ "source": "github", "repo": "owner/repo", "ref": "v2.0" }` |
| Git URL | `{ "source": "url", "url": "https://gitlab.com/..." }` |
| npm | `{ "source": "npm", "package": "@company/plugin", "version": "2.0" }` |

### マーケットプレイスの追加

```bash
/plugin marketplace add owner/repo                              # GitHub
/plugin marketplace add https://gitlab.com/company/plugins.git  # GitLab
/plugin marketplace add ./my-marketplace                        # ローカル
```

## 含められるコンポーネント

| コンポーネント | ファイル | 説明 |
|-------------|---------|------|
| スキル | skills/<name>/SKILL.md | カスタム機能 |
| エージェント | agents/<name>.md | 専門サブエージェント |
| フック | hooks/hooks.json | イベントハンドラー |
| MCPサーバー | .mcp.json | 外部ツール連携 |
| LSPサーバー | .lsp.json | コード知能（補完、診断等） |
| コマンド | commands/<name>.md | スラッシュコマンド |

## 公式プラグイン例

| プラグイン | 機能 |
|-----------|------|
| commit-commands | Git自動化（commit, commit-push-pr, clean_gone） |
| pr-review-toolkit | PRレビュー（6専門エージェント並列実行） |
| code-review | 自動コードレビュー（5並列Sonnetエージェント） |
| security-guidance | セキュリティフック（9パターン監視） |
| plugin-dev | プラグイン開発ウィザード |
| hookify | カスタムフック作成ツール |

## ベストプラクティス

1. **単一責任**: 1プラグイン1目的
2. **ローカルテストから始める**: `claude --plugin-dir` でテスト
3. **セマンティックバージョニング**: MAJOR.MINOR.PATCH
4. **メタデータを完全に記入**: description, keywords, license
5. **セキュリティ**: `${CLAUDE_PLUGIN_ROOT}` でパスを参照、パストラバーサル防止
6. **ドキュメント**: README.md, CHANGELOG.md
