# ワークツリーと環境

🌐 English (canonical): [worktrees-and-env.md](worktrees-and-env.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントでは、ワークツリーの自動化（`wtp` + `.wtp.yml`）、`direnv` ベースの環境ロード（`.envrc` / `.env`）、プロジェクトスコープの MCP サーバー（`.mcp.json`）を説明します。

---

## wtp によるワークツリーの自動化

[wtp](https://github.com/kryota-dev/wtp)（Worktree Plus）は post-create フックを持つ git ワークツリー管理ツールです。リポジトリの `.wtp.yml` では、ワークツリーの作成先と作成後の処理を設定しています。

### `.wtp.yml`

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees/dotfiles"

hooks:
  post_create:
    - type: symlink
      from: ".env"
      to: ".env"

    - type: symlink
      from: ".spec-workflow"
      to: ".spec-workflow"

    - type: command
      command: "direnv allow"
```

ポイント：

- **`base_dir`** はメインチェックアウトからの相対パスです。`wtp add` で作成した新しいワークツリーは `../worktrees/dotfiles/<branch-name>` に配置され、メインリポジトリディレクトリの兄弟ディレクトリになります。
- **post-create フック 1**：メインチェックアウトの `.env` を新しいワークツリーへシンボリックリンクします。これによりワークツリーが `OP_ACCOUNT`（および将来追加される変数）を手動コピーなしに継承します。
- **post-create フック 2**：メインチェックアウトの `.spec-workflow` をシンボリックリンクします。`.env` と `.spec-workflow` はどちらも gitignore 対象です；シンボリックリンクによりメインチェックアウトとすべてのワークツリー間でこれらの状態を共有します。
- **post-create フック 3**：`direnv allow` を実行し、新しいワークツリーの `.envrc` が最初の `cd` で即座に有効になります。

**前提条件**：`wtp add` を実行する前に、`.env` と `.spec-workflow` がメインチェックアウトに存在していなければなりません。`.spec-workflow` ディレクトリは spec-workflow MCP サーバーが初回使用時に作成します。`.env` は `.env.template` からブートストラップする必要があります（後述）。

---

## direnv と `.env`

リポジトリはプロジェクトごとの環境変数を読み込むために [direnv](https://direnv.net/) を使用しています。`.envrc` の内容は 1 行のみです：

```sh
dotenv
```

これにより、リポジトリ（またはワークツリー）に `cd` するたびに direnv が `.env` をシェルに読み込みます。最初の `direnv allow` の後（新しいワークツリーでは wtp の post-create フックが自動実行）、`.env` 内の変数がシェルにエクスポートされます。

### `.env.template`

コミットされたテンプレートは必要な変数を示しています：

```sh
OP_ACCOUNT=my.1password.com
```

`OP_ACCOUNT` は `chezmoi apply` 時に `op` と chezmoi の `onepasswordRead` が使用する 1Password アカウントを選択します。`my.1password.com` は 1Password.com の個人アカウントに対する正しい値です；アカウントが別のドメインにある場合は調整してください。

### `.env` のブートストラップ

`.env` は gitignore 対象です。最初の `chezmoi apply` の前にテンプレートから作成してください：

```bash
cp .env.template .env
# OP_ACCOUNT のドメインが異なる場合は .env を編集する
direnv allow
```

`direnv allow` 後、リポジトリディレクトリ内にいる間は常に `OP_ACCOUNT` がシェルで利用可能です。`wtp add` で作成した新しいワークツリーは、シンボリックリンクフックによって同じ `.env` を継承し、`direnv allow` が自動実行されます。

### サンドボックス読み取りの注意点

一部の環境（特に Claude Code のエージェントサンドボックス）では、`.env` と `.envrc` が Read ツールや Bash ツールの呼び出しでパーミッションブロックされることがあります。パーミッションエラーを回避してこれらのファイルを確認するには、`git show` を使用してください：

```bash
git show HEAD:.env.template   # コミットされたテンプレートを確認
git show HEAD:.envrc           # envrc を確認（1 行：dotenv）
```

`.env` 自体は gitignore 対象なので `git show` では読めません；ファイルシステムへのアクセスがある場合はワーキングコピーを直接読み取るか、`.env.template` から内容を推測してください。

---

## プロジェクトスコープの MCP サーバー

`.mcp.json` は Claude Code や Codex がこのリポジトリで作業する際にアクティブになる MCP サーバーを宣言しています：

```json
{
  "mcpServers": {
    "spec-workflow": {
      "command": "npx",
      "args": ["-y", "@pimzino/spec-workflow-mcp@latest", "."]
    }
  }
}
```

`spec-workflow` は仕様駆動開発ワークフローのツール（`/spec-workflow`、`/approvals` など）を提供します。プロジェクトスコープのため、エージェントの作業ディレクトリがこのリポジトリである場合にのみ有効になります。

注意：`context7` と `deepwiki` はかつて `.mcp.json` で宣言されていましたが、ユーザースコープに移動されました（`run_onchange_after_13-setup-mcp.sh.tmpl` でインストール）。プロジェクトの `.mcp.json` にはプロジェクト固有の `spec-workflow` サーバーのみが残っています。

MCP サーバーが作成する `.spec-workflow/` ディレクトリは gitignore 対象です。wtp のシンボリックリンクフックによりワークツリー間で共有されるため、作業中のワークツリーに関わらず spec の状態にアクセスできます。

---

## 関連ドキュメント

- Makefile ターゲットと lint：[local-dev.ja.md](local-dev.ja.md)
- CI とテスト：[ci-and-tests.ja.md](ci-and-tests.ja.md)
- 1Password シークレットと `onepasswordRead`：[../getting-started/secrets-1password.ja.md](../getting-started/secrets-1password.ja.md)
- chezmoi の apply とソース構造：[../architecture/chezmoi-engine.ja.md](../architecture/chezmoi-engine.ja.md)
