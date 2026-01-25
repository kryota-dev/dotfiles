---
name: copilot-agent-task
description: This skill should be used when the user asks about "copilot agent", "Copilot coding agent", "agent-task", "agent task", "セッションログ", "session log", or discusses managing GitHub Copilot coding agent tasks. Provides operations for listing tasks, viewing session logs, and creating new tasks.
version: 1.0.0
---

# GitHub Copilot Agent Task Management Skill

GitHub Copilot coding agent のタスクとセッションログを操作するスキルです。

## 重要: プレビュー機能

`gh agent-task` コマンドはプレビュー機能であり、予告なく変更される可能性があります。

## コマンド概要

```bash
# 利用可能なサブコマンド
gh agent-task --help

# エイリアス
gh agent-tasks, gh agent, gh agents
```

## タスクの識別方法

タスクは以下の形式で指定できます：
- **PR番号**: `123`
- **セッションID**: `fd97268c-d813-4a7e-9477-d7a9016dd354`
- **URL**: `https://github.com/copilot/tasks/pull/PR_kwDOxxxxxx?session_id=SESSION_ID`

## タスク操作

### 1. タスク一覧の取得

```bash
# 最近のタスク一覧を表示
gh agent-task list
```

### 2. タスクの詳細情報を表示

```bash
# セッションIDで指定
gh agent-task view fd97268c-d813-4a7e-9477-d7a9016dd354

# PR番号で指定（カレントリポジトリ）
gh agent-task view 123

# PR番号で指定（リポジトリを明示）
gh agent-task view --repo OWNER/REPO 123

# PR参照形式で指定
gh agent-task view OWNER/REPO#123
```

### 3. セッションログの取得

```bash
# セッションログを表示
gh agent-task view SESSION_ID --log

# リポジトリを指定してセッションログを取得
gh agent-task view SESSION_ID --log -R OWNER/REPO

# ファイルに保存（大きなログの場合）
gh agent-task view SESSION_ID --log -R OWNER/REPO > session_log.txt
```

### 4. リアルタイムログのフォロー

```bash
# 実行中のタスクのログをリアルタイムで追跡
gh agent-task view SESSION_ID --follow
```

### 5. ブラウザで開く

```bash
# タスクをブラウザで開く
gh agent-task view 123 --web
```

### 6. 新規タスクの作成

```bash
# カレントリポジトリにタスクを作成
gh agent-task create "Improve the performance of the data processing pipeline"

# リポジトリを指定して作成
gh agent-task create --repo OWNER/REPO "Fix the authentication bug"
```

## 実践例

### セッションログの取得と保存

```bash
# Step 1: タスク一覧を確認
gh agent-task list

# Step 2: 特定のセッションログを取得
SESSION_ID="fd97268c-d813-4a7e-9477-d7a9016dd354"
REPO="route06/acsim"

# ログを表示
gh agent-task view $SESSION_ID --log -R $REPO

# ログをファイルに保存（大きなログの場合に有用）
gh agent-task view $SESSION_ID --log -R $REPO > /tmp/copilot_session_log.txt

# ファイルの行数を確認
wc -l /tmp/copilot_session_log.txt
```

### PRからセッションログを取得

```bash
# PR番号からタスク情報を取得
gh agent-task view --repo OWNER/REPO 8606

# 複数のセッションがある場合、セッションIDを指定
gh agent-task view SESSION_ID --log -R OWNER/REPO
```

## オプション一覧

| オプション | 説明 |
|-----------|------|
| `--log` | セッションログを表示 |
| `--follow` | ログをリアルタイムで追跡 |
| `-R, --repo` | リポジトリを指定 (`OWNER/REPO` 形式) |
| `-w, --web` | ブラウザで開く |

## 注意事項

- PR番号で指定する場合、複数のセッションが存在することがあります
- 非対話的な使用では、セッションIDでの指定を推奨
- 大きなログはファイルにリダイレクトして保存することを推奨

## 参考リンク

- [GitHub Copilot coding agent Documentation](https://docs.github.com/en/copilot/using-github-copilot/using-copilot-coding-agent)
- [gh CLI Manual](https://cli.github.com/manual)
