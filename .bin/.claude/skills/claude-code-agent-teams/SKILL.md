---
name: claude-code-agent-teams
description: Claude Codeのエージェントチーム（Agent Teams / Swarm）機能に関するリファレンス。チームの作成・管理、タスク割り当て、メッセージング、シャットダウンなどの知識を提供する。「エージェントチーム」「チーム」「swarm」「並列エージェント」「TeamCreate」と言及された際に使用。
user-invocable: false
---

# Claude Code エージェントチーム リファレンス

## 概要

エージェントチームは、複数のClaudeインスタンスが並行して協調する実験的機能。
サブエージェントと異なり、チームメイト同士が直接通信可能。

## 有効化

環境変数が必要（デフォルト無効）:

```json
// settings.json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

または: `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`

## チーム構成要素

| 要素 | 説明 |
|------|------|
| チームリーダー | メインセッション。チーム統括、メンバー生成、タスク管理 |
| チームメイト | 独立したClaudeインスタンス。独自コンテキストウィンドウで自律動作 |
| 共有タスクリスト | チーム全体で見える作業リスト。依存関係の自動追跡 |
| メールボックス | メンバー間の直接通信システム |

## ファイルシステム

```
~/.claude/teams/{team-name}/config.json   # チーム設定
~/.claude/tasks/{team-name}/              # タスクリスト
```

## チーム作成

自然言語でリーダーに指示:

```
Create an agent team to review PR #142. Spawn three reviewers:
- One focused on security implications
- One checking performance impact
- One validating test coverage
```

## タスク管理プリミティブ

| ツール | 説明 |
|--------|------|
| TeamCreate | チーム初期化 |
| TaskCreate | タスク作成（subject, description, activeForm） |
| TaskUpdate | 状態遷移（pending → in_progress → completed / deleted） |
| TaskList | 全タスク一覧（ID順で処理推奨） |
| TaskGet | タスク詳細取得 |
| Task(team_name) | チームメンバー生成 |
| SendMessage | エージェント間通信 |
| TeamDelete | クリーンアップ |

### TaskCreate のフィールド

- **subject**: 命令形のタイトル（例: "Fix authentication bug"）
- **description**: 詳細な説明と受け入れ基準
- **activeForm**: 進行中のスピナー表示（例: "Fixing authentication bug"）

### TaskUpdate のフィールド

- **status**: `pending` / `in_progress` / `completed` / `deleted`
- **owner**: 割り当て先のエージェント名
- **addBlocks/addBlockedBy**: タスク依存関係

## メッセージング

### SendMessage（1対1通信）

```json
{
  "type": "message",
  "recipient": "researcher",
  "content": "メッセージ内容",
  "summary": "5-10語の要約"
}
```

### Broadcast（全体通知 - コスト高、慎重に使用）

```json
{
  "type": "broadcast",
  "content": "全員への通知",
  "summary": "要約"
}
```

### シャットダウン要求

```json
{
  "type": "shutdown_request",
  "recipient": "researcher",
  "content": "Task complete"
}
```

## メンバーのエージェントタイプ

| タイプ | 説明 |
|--------|------|
| Explore | 読み取り専用リサーチ |
| Plan | アーキテクチャ設計 |
| Bash / general-purpose | 全ツール利用可能 |
| カスタム | .claude/agents/ で定義 |

## UIインタラクション

- `Shift+Down`: チームメイト切り替え（In-processモード）
- `Ctrl+T`: タスクリスト表示/非表示

## シャットダウン手順

1. 全チームメイトに `shutdown_request` 送信
2. 各メイトが `shutdown_response` で承認
3. 全メンバー停止後、`TeamDelete` でクリーンアップ

## ベストプラクティス

1. **計画先行**: Plan Modeで計画作成 → 承認後にチーム展開（トークン節約）
2. **十分なコンテキスト**: スポーンプロンプトに詳細を含める（会話履歴は継承されない）
3. **適切なタスクサイズ**: 5-6個/メンバー目安。自己完結した成果物
4. **ファイル競合回避**: 各メンバーが異なるファイルセットを担当
5. **モデル選択**: リーダー=Opus、メンバー=Sonnet（コスト最適化）
6. **リーダーは管理に専念**: 自分でタスク実装せず、メンバー完了を待つ
7. **監視と操舵**: チェックインで進捗確認、問題を早期検出

## コストと制限

- トークン消費: 約7倍（各メイトが独立コンテキストウィンドウ）
- 1セッション1チーム
- ネストチーム不可（メンバーは子チーム作成不可）
- リーダー固定（移譲不可）
- セッション再開時、In-processメンバーは復元されない

## ユースケース例

- 並列コードレビュー（セキュリティ、パフォーマンス、テストカバレッジ）
- 競合仮説による調査（複数理論を並行検証）
- クロスレイヤー機能実装（フロント、バック、DB、テスト）
- QAスワーム（URL検証、リンクチェック、SEO、アクセシビリティ）
