---
name: create-pr
description: ブランチの変更をGitHub PRとして作成する。baseBranch引数でベースブランチを指定。PRタイトル・説明文を生成しghコマンドで投稿する。
argument-hint: "[base-branch]"
---

# Pull Request作成タスク

## Harness contract

`~/.agents/workflow/README.md` を優先する。承認は capability として扱い、interactive Codex では
`agent-workflow prepare-pr` と `agent-workflow create-pr` の native command approval を要求してから host runner が
下書きを private run state に保存し、PR を作成する。非対話実行は承認待ちで停止する。新規 PR の title/body source は
linked worktree に置き、`prepare-pr` が `${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow/<run-id>/` に 0600 で
コピーする。legacy
`.claude/pull-requests/` は読み取り互換だけで、新規作成・移動・削除しない。

## 概要

このタスクは、現在のブランチの変更内容を分析し、Pull Requestの下書きを自動生成してGitHubに投稿します。git diffによる差分分析、PRテンプレートの活用、GitHub CLIを使用したPR作成を行います。

## 前提条件

- GitHub CLI (`gh`) がインストールされていること
- GitHub CLIで認証済みであること (`gh auth login`)
- `git` コマンドが利用可能であること
- 現在のブランチがマージ対象のベースブランチと異なること
- pr-workflow からは linked worktree と run id が初期化済みであること

## 実行手順

### 1. ブランチ情報の取得

以下のコマンドを使用してブランチ情報を取得してください：

1. **現在のブランチ名を取得**: `git branch --show-current`
2. **ベースブランチの確認**: タスク実行時にユーザーから指定されたベースブランチを使用
   - ユーザーから指定されなかった場合は、「どのブランチをベースブランチにしますか？」と尋ねる
3. **リモートリポジトリ情報の取得**: `git remote get-url origin` からowner/repoを抽出
4. **認証ユーザーの取得**: `gh api user --jq .login` でユーザー名を取得

### 2. 差分の取得と分析

現在のブランチとベースブランチの差分を取得し、分析してください：

```bash
# ファイル一覧の取得
git diff --name-only origin/${BASE_BRANCH}..HEAD

# 詳細な差分の取得
git diff origin/${BASE_BRANCH}..HEAD

# コミット履歴の取得
git log --oneline origin/${BASE_BRANCH}..HEAD
```

### 3. 既存PR確認

PR作成前に既存のPRがないか確認してください：

```bash
gh pr list --head $(git branch --show-current) --state open --json number,title,url
```

- 現在のブランチで開いている PR を検索する
- 既に存在する場合は approval capability で user の方針（既存を使う / 中止）を得る。新規 PR を重複作成しない

### 4. PR下書きの生成

以下の情報を分析してPR下書きを作成してください：

#### 分析対象項目

- **変更ファイル一覧**: 追加、修正、削除されたファイル
- **変更内容の要約**: コードの変更パターンと目的の推定
- **コミットメッセージ**: 開発者の意図の把握
- **機能追加 or バグ修正**: 変更の性質の判断

#### PR下書きテンプレート

@.github/PULL_REQUEST_TEMPLATE.md を読み込み、差分分析結果に基づいてテンプレート内の項目を自動的に埋めてください。

### 5. 下書きファイルの準備

以下の手順で下書きファイルを保存してください：

1. **worktree 内 source**:

   title と body を linked worktree 内の一時 file に別々に保存する。Codex は workspace-write sandbox から
   XDG state に直接書き込まない。file 名に branch を埋め込まず、run id を唯一の識別子にする。

2. **private state へのコピー**:

   下書き内容を user に表示した後、interactive Codex は次の固定 host action の native command approval を要求する。

   ```bash
   agent-workflow prepare-pr <run-id> \
     --title-file <title-file-in-worktree> \
     --body-file <body-file-in-worktree>
   ```

   runner は linked worktree、recorded branch、source path containment、title の非空、出力の mode `0600` を検証して
   private run state の `title.md` / `body.md` にコピーする。source file は PR 作成後に worktree から削除する。

3. **legacy の扱い**:

   `.claude/pull-requests/` は既存下書きの参照だけに使う。新規作成、rename、削除は行わない。

### 6. ユーザー確認プロセス

下書きファイルを作成後、以下の確認を行ってください：

1. **下書き内容の表示**: 生成した PR title/body と target branch をユーザーに提示する。
2. **準備の確認**: approval capability を使う。interactive Codex は `prepare-pr` action の native command approval を
   要求する。非対話では `waiting-for-user` として停止する。`--resume` は承認を与えない。
3. **投稿の確認**: private state へのコピー後、interactive Codex は create-pr action の native command approval を
   要求する。

### 7. PR作成の実行

ユーザーが承認した場合のみ、固定 host action を実行する:

```bash
agent-workflow create-pr <run-id> \
  --title-file <title-file-in-run-state> \
  --body-file <body-file-in-run-state> \
  --base "${BASE_BRANCH}" [--draft]
```

runner は linked worktree、recorded branch、run state 内の title/body path containment、GitHub remote を検証して
PR URL を返す。agent が任意の `gh pr create` 引数を実行したり、private state の下書きを移動・削除したりしてはならない。

## 自動生成ルール

### Issue番号の推定

- **ブランチ名から推定**: `feature/issue-123` → `#123`
- **コミットメッセージから推定**: `fix: resolve #456` → `#456`
- **推定不可の場合**: `TBD`と記載

### タイトル生成ルール

1. **機能追加**: `feat: {機能名}`
2. **バグ修正**: `fix: {修正内容}`
3. **ドキュメント**: `docs: {更新内容}`
4. **リファクタリング**: `refactor: {対象範囲}`
5. **その他**: コミットメッセージの先頭を使用

### チェックリスト自動生成

変更内容に応じて以下のチェック項目を生成：

- **コード変更**: `[ ] コードレビューが完了している`
- **テスト追加**: `[ ] テストケースが追加されている`
- **UI変更**: `[ ] デザインレビューが完了している`
- **API変更**: `[ ] API仕様書が更新されている`
- **設定変更**: `[ ] 環境設定の影響を確認済み`

## 注意事項

- **ベースブランチの確認**: ユーザーから指定されたベースブランチが正しく存在することを確認
- **ファイルパスの安全性**: ブランチ名の特殊文字を適切にエスケープ
- **重複防止**: 同じブランチで既にPRが存在する場合の確認
- **下書き保存**: PR 作成に失敗しても transient state の下書きは保存された状態を維持
- **タイムスタンプの一意性**: 同じ時刻に複数実行された場合の対応
- **PRテンプレート**: `.github/PULL_REQUEST_TEMPLATE.md`を必ず読み込んで使用すること

## 出力形式

### 成功時

```markdown
✅ **PR作成完了**

- **PR番号**: #123
- **タイトル**: feat: ユーザー認証機能の追加
- **URL**: https://github.com/owner/repo/pull/123
- **下書きファイル**: `${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow/<run-id>/body.md`
- **ベースブランチ**: main
- **ヘッドブランチ**: feature/auth

PRが正常に作成されました。レビューをお待ちください。
```

### 下書きのみ保存時

```markdown
📝 **PR下書き保存完了**

- **下書きファイル**: `${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow/<run-id>/body.md`
- **ブランチ**: feature/auth
- **ベースブランチ**: main

下書きが保存されました。後でPRを作成する場合は、再度このタスクを実行してください。
```
