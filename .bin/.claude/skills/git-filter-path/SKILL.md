---
name: git-filter-path
description: "指定パスをgitコミット履歴から完全に除去する（ローカルファイルは保持）。"
argument-hint: "<path>"
user-invocable: true
allowed-tools: Bash, AskUserQuestion
---

# Git コミット履歴からの指定パス除去

## 概要

`git filter-repo` を使用して、指定パスを全コミット履歴から除去します。
ローカルファイルは退避・復元により保持されます。push はユーザーに委任します。

## 実行手順

### 1. 事前検証

#### 1-1. 引数の確認

引数 `$ARGUMENTS` で対象パスを受け取ります。引数が空の場合はエラーを表示して終了します。

#### 1-2. git リポジトリの確認

```bash
git rev-parse --is-inside-work-tree
```

git リポジトリ内でない場合はエラーを表示して終了します。

#### 1-3. git filter-repo の存在確認

```bash
which git-filter-repo
```

見つからない場合は `brew install git-filter-repo` を案内して終了します。

#### 1-4. 対象パスの履歴確認

```bash
git log --oneline --all -- <path>
```

履歴にパスが含まれない場合はエラーを表示して終了します。
該当コミット数を記録します。

#### 1-5. ローカルファイルの存在確認

```bash
ls -la <path>
```

ワーキングツリーにファイルが存在するか確認します。
存在しない場合は退避・復元が不要であることを記録します。

#### 1-6. リモート URL の記録

```bash
git remote -v
```

リモート URL を記録します（`git filter-repo` 実行後にリモートが削除されるため）。

#### 1-7. 現在のブランチ名の記録

```bash
git branch --show-current
```

### 2. ユーザー確認

`AskUserQuestion` ツールを使用して、以下の情報を提示し実行可否を確認します。

**提示する情報:**
- 対象パス
- 該当コミット数
- ローカルファイルの有無（退避の要否）
- リモート URL

**警告事項:**
- 全コミットのハッシュが変わる
- 署名済みコミットは未署名になる（署名はコミット内容に対して行われるため、内容が変わると無効になり除去される。これは再署名では回復できない）
- 実行後に `git push --force` が必要
- `git filter-repo` 実行時にリモートが一時的に削除される

**選択肢:**
- 「実行する」: 履歴書き換えを実行
- 「キャンセル」: 処理を中止

ユーザーがキャンセルした場合は処理を終了します。

### 3. ファイル退避

ワーキングツリーにファイルが存在する場合のみ実行します。

タイムスタンプを生成します:

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
```

退避先ディレクトリを作成してファイルをコピーします:

```bash
BACKUP_DIR="/tmp/git-filter-path-${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"
cp -r <path> "$BACKUP_DIR/"
```

退避が完了したことを報告します。

### 4. 履歴書き換え

```bash
git filter-repo --path <path> --invert-paths --force
```

### 5. ファイル復元

退避を行った場合のみ実行します。

必要に応じて親ディレクトリを作成し、退避先からワーキングツリーへ復元します:

```bash
mkdir -p <path の親ディレクトリ>
cp -r "$BACKUP_DIR/<basename>" <path>
```

復元後、退避元と復元先のファイル数が一致することを確認します。

### 6. リモート再追加

ステップ 1-6 で記録したリモート URL を再追加します:

```bash
git remote add origin <記録した URL>
```

### 7. 結果報告

以下を報告します:

- 履歴からの除去が完了したこと
- ローカルファイルが復元されたこと（退避した場合）
- 退避先ディレクトリのパス（念のため）

ユーザーへの push 指示:

```
git push --force origin <ブランチ名>
```
