---
name: delete-merged-branches
description: "ベースブランチにマージ済みのローカルgitブランチを検出して一括削除する。「マージ済みブランチを削除」「merged branches」「ブランチの掃除」などと言及された際に使用。"
user-invocable: true
allowed-tools: Bash, AskUserQuestion
---

# マージ済みブランチの一括削除

## 概要

ベースブランチ（デフォルト: `main`）にマージ済みのローカルブランチを検出し、ユーザー確認の上で一括削除します。

## 実行手順

### 1. ベースブランチの特定

デフォルトブランチ（`main` または `master`）を特定します。

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

取得できない場合は `main` をデフォルトとして使用します。

### 2. マージ済みブランチの一覧取得

```bash
git branch --merged <ベースブランチ>
```

出力からベースブランチ自体（`main` / `master`）と現在チェックアウト中のブランチ（`*` 付き）を除外します。

### 3. ワークツリーで使用中のブランチの特定

```bash
git worktree list --porcelain | grep 'branch' | sed 's@branch refs/heads/@@'
```

ステップ2で取得したブランチのうち、ワークツリーで使用中のものを特定します。

### 4. 結果の報告

マージ済みブランチをテーブル形式で一覧表示します。

| ブランチ名 | 状態 |
|---|---|
| `feat/example-1` | 削除対象 |
| `feat/example-2` | ワークツリー使用中（`/wtp-cleanup` で対応） |

- ワークツリー使用中のブランチがある場合は、`/wtp-cleanup` スキルで対応するようユーザーに案内してください。
- マージ済みブランチが存在しない場合は、その旨を報告して終了します。

### 5. 削除の実行

`AskUserQuestion` ツールを使用して、削除対象ブランチの一括削除を実行してよいかユーザーに確認してください。

ユーザーが承認した場合のみ、`git branch -d` で一括削除を実行します。

```bash
git branch --merged <ベースブランチ> | grep -v '^\* ' | grep -v '^  <ベースブランチ>$' | xargs git branch -d
```

### 6. 削除失敗時の対応

`git branch -d` はリモートブランチとの差分がある場合などに失敗することがあります（`not fully merged` エラー）。

削除に失敗したブランチがある場合：

1. 失敗したブランチ名とエラー理由を一覧表示します。
2. `AskUserQuestion` ツールを使用して、`git branch -D`（強制削除）を実行してよいかユーザーに確認してください。
3. ユーザーが承認した場合のみ、対象ブランチを `git branch -D` で強制削除します。

```bash
git branch -D <BRANCH_1> <BRANCH_2> ...
```

### 7. 削除後の確認

```bash
git branch
```

残っているブランチの一覧を表示し、削除結果を報告してください。
