# GitHub Copilot Agent Task Management Skill

GitHub Copilot coding agent のタスクとセッションログを `gh agent-task` コマンドで操作するスキルです。

## 概要

このスキルは以下のキーワードで自動的にアクティベートされます：
- "copilot agent", "Copilot coding agent"
- "agent-task", "agent task"
- "セッションログ", "session log"
- Copilot agent のタスク管理に関する質問

## 提供する機能

### タスク操作
- タスク一覧の取得
- タスクの詳細情報表示
- セッションログの取得
- 新規タスクの作成
- リアルタイムログのフォロー

## 重要な注意点

`gh agent-task` コマンドはプレビュー機能であり、予告なく変更される可能性があります。

### タスクの識別方法

タスクは以下の形式で指定できます：
- PR番号: `123`
- セッションID: `12345abc-12345-12345-12345-12345abc`
- URL: `https://github.com/OWNER/REPO/pull/123/agent-sessions/SESSION_ID`

## ファイル構成

```
copilot-agent-task/
├── metadata.json  # スキルメタデータ
├── README.md      # このファイル
└── SKILL.md       # スキル定義（コマンド使用方法）
```

## 参考リンク

- [GitHub Copilot coding agent Documentation](https://docs.github.com/en/copilot/using-github-copilot/using-copilot-coding-agent)
