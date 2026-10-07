# `.wtp.yml` の設定リファレンス

`wtp` はリポジトリのルートにある `.wtp.yml` からプロジェクト固有の設定を読む。雛形は `wtp init` で作れる。
このファイルで、ワークツリーを作る場所と、`wtp add` の後に自動で実行する処理を決める。

## 全体の構造

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"
hooks:
  post_create:
    - { ... }
```

## defaults

| キー | 意味 | 既定値 |
|---|---|---|
| `base_dir` | 新しいワークツリーを置くディレクトリ（プロジェクトのルートからの相対パス） | `"../worktrees"` |

既定の `base_dir` で `feature/auth` というブランチを作ると、`../worktrees/feature/auth` にできる。
`/` は入れ子のディレクトリになる。

## hook の概要

`hooks.post_create` は、ワークツリーを作った**後**、`wtp add --exec` のコマンドを実行する**前**に、上から順に
実行する手順のリスト。各手順の `type` は `copy` / `symlink` / `command` のいずれか。手作業なしで、
すぐ作業を始められる状態のワークツリーにするための仕組み。

## copy

ファイルやディレクトリを新しいワークツリーへコピーする。main のワークツリーにあるが **gitignore されている**
（そのため新しいワークツリーには無い）ファイル、たとえば `.env`・`.claude`・`.cursor/` を用意するためのもの。

```yaml
- type: copy
  from: ".env"   # main のワークツリーからの相対パス。gitignore されたファイルも可
  to: ".env"     # 新しいワークツリーからの相対パス。省略すると from と同じ
```

- `from` は常に **main** のワークツリーを基準に解決する。
- `to` は**新しい**ワークツリーを基準に解決する。省略すると `from` と同じ値になる（相対パスのときだけ）。
  `from` が絶対パスなら `to` は**必須**。
- ファイルにもディレクトリ（`from: ".cursor/"`）にも使える。

どのワークツリーから `wtp add` を実行しても、挙動は同じ。

## symlink

main のワークツリーのパスを指す symlink を、新しいワークツリーに作る。大きいディレクトリや変化する
ディレクトリ（`.bin`・`.cache`・`node_modules` など）を、コピーせずに**共有**するときに使う。

```yaml
- type: symlink
  from: ".bin"   # main のワークツリーからの相対パス（絶対パスも可）
  to: ".bin"     # 新しいワークツリーからの相対パス（絶対パスも可）
```

ワークツリーごとに独立したファイルが要るなら copy、1 つの実体を共有したいなら symlink を使う。

## command

新しいワークツリーの中でシェルコマンドを実行する。

```yaml
- type: command
  command: "npm install"
  env:                       # 任意: 追加の環境変数
    NODE_ENV: "development"
  work_dir: "."              # 任意: 作業ディレクトリ（新しいワークツリーからの相対パス）
```

- `command`: 実行するシェルコマンド。
- `env`: そのコマンドに渡す環境変数（任意）。
- `work_dir`: 作業ディレクトリ（任意。新しいワークツリーからの相対パス）。既定はワークツリーのルート。

1 つの大きなスクリプトより、1 手順ずつのコマンド（`npm ci` の後に `npm run db:setup`）を並べる方がよい。
失敗したときに、どの手順で壊れたかがすぐ分かる。タスクランナーのターゲット（`make bootstrap`）でもよい。

## パスの基準: main と新しいワークツリー

いちばん混乱しやすいところなので、次の表で覚える:

| hook の項目 | 基準 |
|---|---|
| `copy.from` | **main** のワークツリー |
| `copy.to` | **新しい**ワークツリー |
| `symlink.from` | **main** のワークツリー |
| `symlink.to` | **新しい**ワークツリー |
| `command.work_dir` | **新しい**ワークツリー |

覚え方: main のワークツリー**から**、作ったばかりのワークツリー**へ**持ってくる。`from` は元のありかを、
`to` は作ったワークツリーの中を指す。

## 全体の例

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"

hooks:
  post_create:
    # gitignore されたローカルの設定を main のワークツリーからコピーする
    - type: copy
      from: ".env"
      to: ".env"
    - type: copy
      from: ".claude"        # to を省略すると ".claude" になる

    # ディレクトリを複製せずに共有する
    - type: symlink
      from: ".bin"
      to: ".bin"

    # 依存を入れてデータベースを準備する
    - type: command
      command: "npm install"
      env:
        NODE_ENV: "development"
    - type: command
      command: "make db:setup"
      work_dir: "."
```
