---
name: pr-draft-summary
description: >-
  コード変更完了後にPR準備ブロックを生成する。ブランチ名提案・PRタイトル・PR説明文ドラフトを
  固定フォーマットで出力する。ランタイムコード・テスト・ビルド設定・動作に影響するドキュメント変更が
  完了しレビュー準備に入る際に使用。
user-invocable: true
allowed-tools: Bash, Read
---

# PR Draft Summary

コード変更完了後にPR準備ブロックを生成します。

## 実行手順

### 1. 情報収集

以下のコマンドを並列で実行して情報を収集します:

```bash
# 現在のブランチ名
git branch --show-current

# ワーキングツリーの状態
git status --short

# 変更統計
git diff --stat

# ステージ済みの変更統計
git diff --cached --stat

# 直近のコミット履歴
git log --oneline -10

# ベースブランチとの差分統計（main or master）
git diff main...HEAD --stat 2>/dev/null || git diff master...HEAD --stat 2>/dev/null
```

PRテンプレートの有無を確認:

```bash
# PRテンプレートがあれば読み込む
cat .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null
```

### 2. 変更分析

収集した情報を分析し、以下を判断:

- 変更の性質（feat, fix, docs, chore, refactor, test 等）
- 影響範囲（変更されたモジュール・コンポーネント）
- ブランチ名の適切性（mainにいる場合はブランチ名を提案）

### 3. 出力生成

以下の固定フォーマットで出力します:

```markdown
# Pull Request Draft

## Branch name suggestion

git checkout -b {type}/{description}

## Title

{type}: {簡潔な説明}

## Description

### Summary
- {変更点1}
- {変更点2}
- {変更点3}

### Test plan
- [ ] {テスト項目1}
- [ ] {テスト項目2}
```

## 注意事項

- このスキルはテキスト出力のみを行います。PR作成やgit操作は実行しません
- PRタイトルは70文字以内に収めてください
- PRテンプレートが存在する場合は、テンプレートの構造に従って説明文を生成してください
- 既存の`$create-pr`スキルと役割を分離しています（`create-pr`は実際のPR作成を担当）
