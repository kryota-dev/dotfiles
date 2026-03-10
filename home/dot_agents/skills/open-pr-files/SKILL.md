---
name: open-pr-files
description: "PRの変更ファイル一覧を取得しVSCodeで開く。引数省略時は現在のブランチのPRを自動検出。"
argument-hint: "[pr-number-or-url（省略可）]"
disable-model-invocation: true
---

# PR 変更ファイルを VSCode で開くタスク

## 概要

指定された Pull Request の変更ファイル一覧を取得し、すべてのファイルを VSCode で開きます。

## 引数

$ARGUMENTS（省略可）

- PR番号（例: `9676`）
- またはPR URL（例: `https://github.com/<OWNER>/<REPO>/pull/9676`）
- 省略時: 現在のブランチに紐づくPRを自動検出

## 実行手順

### 1. PR特定子の決定

引数からPR特定子を決定してください：

- **PR URLの場合**: URLからPR番号を抽出（例: `https://github.com/<OWNER>/<REPO>/pull/9676` → `9676`）
- **PR番号のみの場合**: そのまま使用
- **引数が空の場合**: 現在のブランチに紐づくPRを自動検出するため、以下のコマンドでPR番号を取得

```bash
gh pr view --json number --jq '.number'
```

上記コマンドが失敗した場合（現在のブランチにPRが存在しない場合）、ユーザーにPR番号の入力を求めて終了してください。

### 2. 変更ファイルの取得と VSCode で開く

以下のコマンドを実行してください。`{PR番号}` をステップ1で決定した値に置き換えること。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/files --jq '.[] | select(.status == "removed" | not) | .filename' | while IFS= read -r file; do code "$file" & done
```

### 3. 結果の報告

変更ファイル（削除以外）の一覧を番号付きリストで報告してください。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/files --jq '.[] | select(.status == "removed" | not) | .filename' | cat -n
```

削除されたファイルがある場合は、別途「削除されたファイル」として一覧を報告してください。

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/files --jq '.[] | select(.status == "removed") | .filename' | cat -n
```
