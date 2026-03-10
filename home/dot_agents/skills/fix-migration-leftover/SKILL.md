---
name: fix-migration-leftover
description: "DBマイグレーション失敗時に、別ブランチの残骸（既存のビューやテーブル等）を特定してドロップし、マイグレーションを再実行する。「migration failed」「already exists」「マイグレーションエラー」などと言及された際に使用。"
user-invocable: true
allowed-tools: Bash, Read, Grep, AskUserQuestion
---

# DBマイグレーション残骸の修復

## 概要

別ブランチで作成されたDBオブジェクト（ビュー、テーブル等）がローカルDBに残っている場合、マイグレーションが `already exists` エラーで失敗する。
このスキルは、残骸を特定・ドロップしてマイグレーションを再実行する。

## 対象エラー

- `relation "xxx" already exists`（ビュー、テーブル）
- `type "xxx" already exists`（ENUM型）
- `index "xxx" already exists`（インデックス）
- `constraint "xxx" already exists`（制約）

## 手順

### Step 1: エラーメッセージの解析

マイグレーションエラー出力から以下を特定する：

- **オブジェクト名**: エラーメッセージ中の `"xxx" already exists` の `xxx`
- **オブジェクト種別**: エラーの前のSQL文から判定（`CREATE VIEW` / `CREATE TABLE` / `CREATE TYPE` 等）
- **マイグレーションファイル**: `Failed query` に含まれるSQL文

### Step 2: Dockerコンテナの特定

```bash
docker ps --format "{{.Names}} {{.Image}}" | grep -i postgres
```

### Step 3: DB名の特定

```bash
docker exec <コンテナ名> psql -U postgres -c "\l"
```

開発用DB（`spec_tracker_development` 等）を使用する。

### Step 4: 残骸の確認

オブジェクト種別に応じたクエリで存在を確認する：

```bash
# ビューの場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "SELECT viewname FROM pg_views WHERE viewname = '<オブジェクト名>';"

# テーブルの場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "SELECT tablename FROM pg_tables WHERE tablename = '<オブジェクト名>';"

# ENUM型の場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "SELECT typname FROM pg_type WHERE typname = '<オブジェクト名>';"

# インデックスの場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "SELECT indexname FROM pg_indexes WHERE indexname = '<オブジェクト名>';"
```

### Step 5: ユーザー確認

`AskUserQuestion` ツールを使用し、以下を報告した上でドロップの許可を求める：

- 残骸のオブジェクト名と種別
- 別ブランチの残骸である可能性が高い旨
- 実行予定のDROP文

### Step 6: 残骸のドロップ

ユーザーが承認した場合のみ実行する：

```bash
# ビューの場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "DROP VIEW IF EXISTS <オブジェクト名>;"

# テーブルの場合（依存関係に注意）
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "DROP TABLE IF EXISTS <オブジェクト名>;"

# ENUM型の場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "DROP TYPE IF EXISTS <オブジェクト名>;"

# インデックスの場合
docker exec <コンテナ名> psql -U postgres -d <DB名> -c \
  "DROP INDEX IF EXISTS <オブジェクト名>;"
```

### Step 7: マイグレーション再実行

```bash
pnpm -F @acsim/api db:migrate
```

### Step 8: 結果の確認

- マイグレーションが成功したことを確認する
- 失敗した場合は、Step 1 に戻って次のエラーを解析する（複数の残骸がある場合）

## 注意事項

- **テスト用DBにも同様の残骸がある可能性がある**。テスト実行時にエラーが出た場合は `spec_tracker_test_worker_*` DBも確認する
- テーブルのドロップは依存関係（FK制約等）によって失敗する場合がある。その場合は `CASCADE` オプションの使用をユーザーに確認する
- このスキルはローカル開発環境専用。本番・ステージング環境では使用しない
