# GitHub Projects Management Skill

## 概要

このスキルは、GitHub Projects (ProjectV2) の操作を自動化するためのエージェントスキルです。

## 主な機能

1. **プロジェクト情報の取得**
   - 組織のプロジェクト一覧
   - プロジェクトのフィールド情報（Status、Priority等）

2. **issueとプロジェクトの連携**
   - issueが属するプロジェクトの特定
   - Project Item IDの取得

3. **ステータス管理**
   - 単一issueのステータス更新
   - 複数issueの一括ステータス更新

## 使い方

### Claude Codeでの使用

このスキルは `~/.claude/skills/github-projects/` に配置されています。Claude Codeがこのディレクトリを読み込むことで、自動的にスキルとして利用可能になります。

### 実行例

**ユーザーの質問:**
> "issue #100, #101, #102のProjectsステータスを'In Progress'に変更してください"

**Claudeの応答:**
> github-projectsスキルを使用して、各issueのステータスを更新します...

Claude Codeは自動的にスキル内のコードやガイドラインを参照して、適切なコマンドを実行します。

## ファイル構成

```
~/.claude/skills/github-projects/
├── README.md          # このファイル
├── metadata.json      # スキルのメタデータ
└── skill.md          # スキルの詳細な説明とコード例
```

## 前提条件

### 必要なツール

- **GitHub CLI (`gh`)**: インストール済みであること
  ```bash
  brew install gh
  ```

### 必要な権限

GitHub CLIのトークンに以下のスコープが必要です：

- `project`: プロジェクトの読み書き
- `repo`: リポジトリアクセス
- `read:org`: 組織の読み取り

権限の追加：
```bash
gh auth refresh -s project
```

## よくある使用シナリオ

### シナリオ1: 複数issueを一括で"In Progress"に移動

```
ユーザー: "issue #100から#110までを'In Progress'にしてください"
```

Claude Codeが自動的に：
1. プロジェクトIDを取得
2. Statusフィールドの"In Progress"オプションIDを取得
3. 各issueのProject Item IDを取得
4. 各issueのステータスを更新

### シナリオ2: プロジェクトのステータス選択肢を確認

```
ユーザー: "Product Backlogプロジェクトで使用できるステータスを教えてください"
```

Claude Codeが自動的に：
1. プロジェクトIDを取得
2. Statusフィールドの情報を取得
3. 利用可能なステータス一覧を表示

### シナリオ3: issueの現在のステータスを確認

```
ユーザー: "issue #100の現在のプロジェクトステータスは？"
```

Claude Codeが自動的に：
1. issueのProject Items情報を取得
2. 現在のステータスを表示

## トラブルシューティング

### エラー: "INSUFFICIENT_SCOPES"

**原因:** GitHubトークンに`project`スコープが不足

**解決策:**
```bash
gh auth refresh -s project
```

### issueがプロジェクトに見つからない

**原因:** issueがまだプロジェクトに追加されていない

**解決策:**
GitHub Web UIからissueをプロジェクトに追加するか、以下のコマンドで追加：
```bash
gh project item-add <project-number> --owner <org> --url <issue-url>
```

## 学習リソース

- [GitHub Projects V2 API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub GraphQL API](https://docs.github.com/en/graphql)
- [Claude Code Skills Documentation](https://code.claude.com/docs/ja/skills)

## バージョン履歴

### v1.0.0 (2026-01-06)
- 初回リリース
- 基本的なプロジェクト操作機能を実装
