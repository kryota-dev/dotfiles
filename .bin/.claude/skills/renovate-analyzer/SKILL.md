---
name: renovate-analyzer
description: Renovate PRを分析し、アップデート可否と修正方針を提示する。PR番号またはURLを引数で指定する。
argument-hint: "[pr-number-or-url]"
disable-model-invocation: true
---

# Renovate PR 分析コマンド

PR番号またはURL: $ARGUMENTS

## コンテキスト

- リポジトリ: !`git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "unknown"`

## タスク

`renovate-analyzer` サブエージェントを使用して、指定されたRenovate PRを分析してください。

### 引数の解釈

1. **URL形式** (`https://github.com/owner/repo/pull/123`): URLからrepoとPR番号を抽出
2. **pr=数字形式** (`pr=123`): 現在のリポジトリのPR番号として解釈
3. **数字のみ** (`123`): 現在のリポジトリのPR番号として解釈

### 実行

Taskツールで `renovate-analyzer` サブエージェントを起動し、特定したリポジトリとPR番号を渡してください。
