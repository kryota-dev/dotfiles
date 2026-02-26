---
name: claude-code-subagents
description: Claude Codeのサブエージェント（Subagents / Task tool）機能に関するリファレンス。サブエージェントの種類、カスタムエージェントの作成方法、権限モード、ツール制限などの知識を提供する。「サブエージェント」「subagent」「Task tool」「カスタムエージェント」「.claude/agents」と言及された際に使用。
user-invocable: false
---

# Claude Code サブエージェント リファレンス

## 概要

サブエージェントは、独立したコンテキストウィンドウで実行される専門エージェント。
メインセッションのコンテキストを保護しつつ、特定タスクを委譲する。

## サブエージェント vs エージェントチーム

- **サブエージェント**: 単一セッション内で実行、結果をメイン会話に返す
- **エージェントチーム**: 複数セッションで並列実行、相互通信可能

## 組み込みサブエージェントタイプ

| タイプ | モデル | ツール | 用途 |
|--------|--------|--------|------|
| Explore | Haiku | 読み取り専用（Write/Edit不可） | ファイル発見、コード検索、コードベース探索 |
| Plan | 継承 | 読み取り専用（Write/Edit不可） | 計画作成前の現地調査 |
| general-purpose | 継承 | すべて | 複雑な多ステップタスク |
| Bash | 継承 | Bash | ターミナルコマンド実行 |
| statusline-setup | Sonnet | Read, Edit | ステータスライン設定 |
| claude-code-guide | Haiku | Read, Grep, Glob, WebFetch, WebSearch | Claude Code機能の質問応答 |

### Explore の thoroughness レベル

- `quick`: ターゲット検索
- `medium`: バランスの取れた探索
- `very thorough`: 包括的な分析

## Task ツールのパラメータ

| パラメータ | 説明 |
|-----------|------|
| prompt | タスクの指示（必須） |
| subagent_type | エージェントタイプ（必須） |
| description | 3-5語の概要 |
| model | 使用モデル（sonnet/opus/haiku） |
| mode | 権限モード |
| run_in_background | 背景実行（true/false） |
| resume | 前回のエージェントIDで再開 |
| name | エージェント名 |
| team_name | チーム名（チーム使用時） |
| max_turns | 最大ターン数 |

## カスタムエージェントの作成

### 配置場所

| スコープ | パス |
|---------|------|
| プロジェクト | .claude/agents/<name>.md |
| ユーザー | ~/.claude/agents/<name>.md |
| プラグイン | <plugin>/agents/<name>.md |

### 優先順位（高→低）

1. `--agents` CLIフラグ（セッション限定）
2. `.claude/agents/`（プロジェクト）
3. `~/.claude/agents/`（ユーザー全体）
4. プラグイン `agents/` ディレクトリ

### ファイルフォーマット

```markdown
---
name: my-agent
description: エージェントの説明（自動委譲の判断に使用）
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit
model: sonnet
permissionMode: acceptEdits
maxTurns: 50
skills:
  - skill-name
memory: user
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
---

エージェントのシステムプロンプト。
役割、専門性、動作指針を記述。
```

### frontmatter フィールド一覧

| フィールド | 必須 | 説明 |
|-----------|------|------|
| name | はい | 小文字とハイフンのみの識別子 |
| description | はい | 説明（自動委譲判断に使用） |
| tools | いいえ | 許可ツール（ホワイトリスト） |
| disallowedTools | いいえ | 拒否ツール（ブラックリスト） |
| model | いいえ | sonnet/opus/haiku/inherit（デフォルト: inherit） |
| permissionMode | いいえ | 権限モード |
| maxTurns | いいえ | 最大ターン数 |
| skills | いいえ | 起動時にロードするスキル |
| mcpServers | いいえ | 利用可能なMCPサーバー |
| hooks | いいえ | ライフサイクルフック |
| memory | いいえ | 永続メモリスコープ（user/project/local） |

### CLIによる動的定義

```bash
claude --agents '{
  "code-reviewer": {
    "description": "Expert code reviewer",
    "prompt": "You are a senior code reviewer...",
    "tools": ["Read", "Grep", "Glob"],
    "model": "sonnet"
  }
}'
```

## 権限モード

| モード | 動作 |
|--------|------|
| default | 標準的な権限チェック |
| acceptEdits | ファイル編集の自動承認 |
| dontAsk | 権限プロンプトの自動拒否（許可ルール適用） |
| bypassPermissions | 全権限チェックスキップ（サンドボックスのみ） |
| plan | 読み取り専用（計画モード） |

## ツール制限

### ホワイトリスト方式

```yaml
tools: Read, Grep, Glob, Bash
```

### ブラックリスト方式

```yaml
disallowedTools: Write, Edit
```

### Task ツールの制限

```yaml
tools: Task(worker, researcher), Read, Bash
```

→ `worker` と `researcher` エージェントのみ呼び出し可能

## 前景・背景実行

- **前景**: ブロッキング、完了まで待機、権限プロンプトがユーザーに表示
- **背景**: 非同期・並行実行、`Ctrl+B` で背景化可能
  - 背景実行時はMCPツール利用不可
  - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` で無効化可能

## Hook による制御

### エージェント固有フック（frontmatter内）

```yaml
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate-command.sh"
```

### プロジェクトレベルフック（settings.json）

```json
{
  "hooks": {
    "SubagentStart": [
      { "matcher": "db-agent", "hooks": [...] }
    ],
    "SubagentStop": [
      { "hooks": [...] }
    ]
  }
}
```

## 具体例

### コードレビューエージェント

```markdown
---
name: code-reviewer
description: Expert code review. Use proactively after code changes.
tools: Read, Grep, Glob, Bash
model: inherit
---

You are a senior code reviewer.
Review checklist:
- Code clarity and readability
- Error handling
- Security concerns
- Test coverage
- Performance
```

### 読み取り専用DBクエリエージェント

```markdown
---
name: db-reader
description: Execute read-only database queries.
tools: Bash
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate-readonly-query.sh"
---

You are a database analyst with read-only access.
Execute SELECT queries only.
```

## ベストプラクティス

1. **単一責任**: 各エージェントは1つの特定タスクに特化
2. **詳細な description**: 自動委譲の判断材料。「use proactively」で積極的委譲を促進
3. **必要最小限のツール許可**: セキュリティと焦点の確保
4. **スキル活用**: `skills:` で必要なドメイン知識を事前ロード
5. **永続メモリ**: `memory: user` でプロジェクト全体の学習蓄積
6. **モデル選択**: Haiku=探索、Sonnet=汎用、Opus=複雑な推論
7. **管理**: `/agents` でインタラクティブに管理

## 権限制御

```json
{
  "permissions": {
    "deny": ["Task(Explore)", "Task(custom-agent)"]
  }
}
```
