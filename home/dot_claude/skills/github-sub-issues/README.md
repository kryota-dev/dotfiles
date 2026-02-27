# GitHub Sub-issues & Issue Types Management Skill

GitHub の Sub-issue 機能および Issue Types 機能を GraphQL API で操作するエージェントスキルです。

## 概要

このスキルは以下のキーワードで自動的にアクティベートされます：
- "sub-issues", "sub-issue", "サブイシュー", "子イシュー"
- "issue type", "Issue Type"
- "parent issue", "親issue"
- GitHub Issues の階層管理に関する質問

## 提供する機能

### Sub-issue 操作
- Parent Issue の Sub-issues 一覧取得
- 既存 Issue を Sub-issue として追加
- Sub-issue を親から削除
- Issue の Parent Issue 取得

### Issue Types 操作
- Organization の Issue Types 一覧取得
- Issue の現在の Issue Type 取得
- Issue の Issue Type 設定・変更

## 重要な注意点

GraphQL API で Sub-issues / Issue Types 機能を使用するには、特別なヘッダーが必須です：

```bash
# Sub-issues 操作時
-H "GraphQL-Features: sub_issues"

# Issue Types 操作時
-H "GraphQL-Features: issue_types"
```

このヘッダーがないと API は正しく動作しません。

## ファイル構成

```
github-sub-issues/
├── SKILL.md   # スキル定義（GraphQL API の使用方法）
└── README.md  # このファイル
```

## 参考リンク

- [GitHub Sub-issues Documentation](https://github.blog/engineering/architecture-optimization/introducing-sub-issues-enhancing-issue-management-on-github/)
- [GitHub Issue Types Discussion](https://github.com/orgs/community/discussions/139933)
