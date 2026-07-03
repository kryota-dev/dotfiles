# GitHub Sub-issues & Issue Types Management Skill

GitHub の Sub-issue 機能および Issue Types 機能を、gh CLI 2.94.0+ の native コマンド
（`gh issue create/edit/view`）で操作するエージェントスキルです。

## 概要

このスキルは以下のキーワードで自動的にアクティベートされます：
- "sub-issues", "sub-issue", "サブイシュー", "子イシュー"
- "issue type", "Issue Type"
- "parent issue", "親issue"
- GitHub Issues の階層管理に関する質問

## 提供する機能

### Sub-issue 操作
- Parent Issue の Sub-issues 一覧取得（`gh issue view --json subIssues,subIssuesSummary`）
- 既存 Issue を Sub-issue として追加（`gh issue edit --add-sub-issue` / `--parent`）
- Sub-issue を親から削除（`gh issue edit --remove-sub-issue` / `--remove-parent`）
- Issue の Parent Issue 取得（`gh issue view --json parent`）

### Issue Types 操作
- Issue の現在の Issue Type 取得（`gh issue view --json issueType`）
- Issue の Issue Type 設定・変更（`gh issue edit --type <name>` / `--remove-type`）
- Organization の Issue Types 一覧取得（native 未対応のため GraphQL を併用）

## 重要な注意点

native フラグは gh 2.94.0+ かつ GitHub.com / GHES 3.17+（relationships は 3.19+）で利用可能です。
それ未満の環境では、SKILL.md 末尾の「Fallback: GraphQL API」に記載した `gh api graphql`
（`GraphQL-Features: sub_issues` / `issue_types` ヘッダー付き）へフォールバックします。

## ファイル構成

```
github-sub-issues/
├── SKILL.md   # スキル定義（native gh コマンド + GraphQL fallback）
└── README.md  # このファイル
```

## 参考リンク

- [GitHub Sub-issues Documentation](https://github.blog/engineering/architecture-optimization/introducing-sub-issues-enhancing-issue-management-on-github/)
- [GitHub Issue Types Discussion](https://github.com/orgs/community/discussions/139933)
