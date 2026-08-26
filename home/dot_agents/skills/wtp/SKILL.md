---
name: wtp
description: "satococoa 製の `wtp`（Worktree Plus）CLI の総合ガイド。Git ワークツリーを `wtp` で作成・一覧・削除・移動したいとき、`wtp add`/`wtp cd`/`wtp list`/`wtp remove`/`wtp exec` に言及されたとき、ブランチ名からの自動ワークツリーパス導出、`.wtp.yml` の post-create フック（copy/symlink/command）、ワークツリーのブランチ追跡、シェル統合（`wtp shell-init`, `wtp hook`, タブ補完, auto-cd）について尋ねられたときに使用する。ユーザーが `wtp` と明示せずワークフローを説明しただけの場合（例:「この feature ブランチ用にワークツリーを立ち上げて」「auth のワークツリーに移動して」「ワークツリーとそのブランチを片付けて」）でも、`wtp` が利用可能なツールである限りこの skill を起動する。"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# wtp (Worktree Plus)

## Harness contract

`pr-workflow` から呼ばれた場合、harness にかかわらず linked worktree を必須とする。branch 名は
`feat/`、`fix/`、`refactor/` など task の意味を表す prefix を使い、harness 名を prefix にしない。
Codex の workspace-write child は作成済み linked worktree にだけ入れ、main worktree へは書き込まない。
Codex main session での**新規作成**は sandbox 内の `wtp add` ではなく、Codex native command approval を伴う
`agent-workflow worktree-init <run-id> --branch <branch> --base main` を使う。この action は clean な main branch から
`git worktree add` と run state 初期化を一体で行い、`wtp` / `.wtp.yml` の hook / `direnv allow` は実行しない。user は
terminal command を入力しない。既存 worktree の一覧・移動・削除に本 skill の
`wtp` 手順を使える。

`wtp` は `git worktree` の面倒な部分を取り除く Git ワークツリーマネージャーである。
ブランチ名から適切なパスを自動導出し、リモートブランチを自動追跡し、作成時に
プロジェクト固有のセットアップフックを実行し、ワークツリー間を即座に `cd` で
移動できるようにする。

この skill では日常的なコマンドに加え、設定とシェル統合を扱う。`.wtp.yml` フック
の完全なリファレンス（copy/symlink/command フック、パス解決ルール）は
`references/configuration.md` を参照すること。

## メンタルモデル

- **ワークツリーはリポジトリの外に存在する。** デフォルトでは `../worktrees/<branch-name>`
  配下に作られるため、`feature/auth` は `../worktrees/feature/auth` になる。ブランチ名の
  スラッシュはディレクトリになり、種類ごとに整理された状態を保つ。
- **メインのワークツリーは `@` である。** `wtp cd` / `wtp exec` では `@` と指定するか、
  名前を省略すると「ホームへ戻る」（素の `cd` と同様）意味になる。
- **フックは `wtp add` 実行時に走る。** ワークツリー作成後に手動で行っていたこと
  （`.env` のコピー、キャッシュのシンボリックリンク、依存関係のインストール等）は
  `.wtp.yml` に書いておく。

挙動がおかしいと感じたら、必ず `wtp --version` でインストール済みバージョンを確認
すること — 本 skill は **v2.10.x** を前提に書かれている。

## ワークツリーの作成 — `wtp add`

```bash
wtp add <existing-branch>          # 既存のローカル/リモートブランチからワークツリーを作成
wtp add -b <new-branch> [<commit>] # 新規ブランチ + ワークツリーを作成
```

主な挙動:

- **自動追跡**: `<branch>` がローカルに存在せず、リモートにちょうど1つだけ存在する場合、
  `wtp` は自動的にローカル追跡ブランチを作成する。リモートにも無ければ明確なエラーになる。
- **base 指定での新規ブランチ**: `wtp add -b hotfix/urgent main` は `main` から分岐する。
  base にはコミット（`abc1234`）やリモート ref（`origin/main`）も指定できる。
- **作成後にセットアップを実行**: `--exec "<cmd>"` はフック完了 *後* に新しいワークツリー内で
  コマンドを実行する（TTY が存在すればインタラクティブなコマンドにも対応）。
- **スクリプトフレンドリー**: `--quiet` / `-q` を付けると作成された絶対パスのみを出力するため、
  `dir=$(wtp add -b feature/x --quiet)` のように捕捉できる。

例:

```bash
wtp add feature/auth                      # 既存ブランチ（必要ならリモートを追跡）
wtp add -b feature/new-feature            # 全く新しいブランチ
wtp add -b hotfix/urgent main             # main を base にした新規ブランチ
wtp add -b feature/test origin/main       # origin/main を追跡する新規ブランチ
wtp add -b feature/x --exec "npm test"    # 作成 → フック実行 → npm test
```

**同名ブランチが複数のリモートに存在する場合**は設計上あいまいなため、`wtp` は推測しない。
自分でローカルブランチを作成してから再実行すること:

```bash
git branch --track feature/shared upstream/feature/shared
wtp add feature/shared
```

## ワークツリーの一覧 — `wtp list`（エイリアス `ls`）

```bash
wtp list                 # 表形式: PATH, BRANCH, HEAD; メインワークツリーは @ ... * で表示
wtp list --quiet         # パスのみ（1行ずつ）— スクリプト/パイプ処理向け
wtp list --compact       # 幅の狭い/リダイレクト出力向けに列幅を最小化
wtp list --max-path-width 80
```

補足: `wtp list` はブランチ名を省略表示することがある。**完全な** ブランチ名が
必要な場合（マージ状況の確認等）は、以下と組み合わせること:
`git worktree list --porcelain | grep '^branch '`

## ワークツリーの削除 — `wtp remove`（エイリアス `rm`）

```bash
wtp remove <worktree-name>                    # ワークツリーのみ削除
wtp remove --force <name>                      # dirty な状態でも強制削除
wtp remove --with-branch <name>                # ブランチも削除（マージ済みの場合のみ）
wtp remove --with-branch --force-branch <name> # 未マージでもブランチを削除
```

`--with-branch` はこの目玉機能で、ワークツリーと**そのブランチ**を1ステップで
アトミックに削除し、孤立したブランチを残さない。ブランチは `--force-branch` を
付けない限りマージ済みの場合のみ削除される。対象はワークツリーの**ディレクトリ名**
であり、ブランチパスではない（`wtp list` の出力を参照）。

## 移動 — `wtp cd`

`wtp cd` はワークツリーの絶対パスを出力する。使い方は2通り:

```bash
cd "$(wtp cd feature/auth)"   # 直接: コマンド置換。どのシェルでも動く
cd "$(wtp cd)"                # メインワークツリー（素の cd = 「ホームへ戻る」）
```

シェルフックがインストールされていれば（シェル統合を参照）、`wtp cd` は
サブシェル無しで直接ディレクトリを変更する:

```bash
wtp cd feature/auth   # そこへジャンプ
wtp cd @              # メインワークツリー（明示指定）
wtp cd                # メインワークツリー
wtp cd <TAB>          # ワークツリー名のタブ補完
```

## ワークツリー内でのコマンド実行 — `wtp exec`

```bash
wtp exec <worktree> -- <command> [args...]
```

`cd` せずに別のワークツリー内でコマンドを実行する。ターゲットの解決方法は
`wtp cd` と同じ（`@` はメインワークツリー）:

```bash
wtp exec feature/auth -- go test ./...
wtp exec @ -- pwd
```

## 設定 — `.wtp.yml`

```bash
wtp init   # サンプルフック付きの .wtp.yml をリポジトリルートに雛形生成
```

最小構成:

```yaml
version: "1.0"
defaults:
  base_dir: "../worktrees"   # ワークツリーの作成先（プロジェクトルートからの相対パス）
hooks:
  post_create:
    - type: copy
      from: ".env"            # 'from' はメインワークツリーからの相対パス（gitignore 済みでも可）
      to: ".env"              # 'to' は新しいワークツリーからの相対パス（既定は 'from' と同じ）
    - type: symlink
      from: ".bin"
      to: ".bin"
    - type: command
      command: "npm ci"
```

3種類のフック（`copy`, `symlink`, `command`）、正確なパス解決ルール、`env`/`work_dir`
オプションの詳細は `references/configuration.md` に記載されている — `from`/`to` の
「メイン vs 新規ワークツリー」の区別が最もよくある間違いの元なので、`.wtp.yml` を
編集・生成する前に読むこと。

## シェル統合

タブ補完 **と** ディレクトリ変更する `wtp cd` / インタラクティブな `wtp add` での
auto-cd を有効にする。

- **Homebrew でインストールした場合**（このマシン）: 遅延ロードされる。`wtp` と
  入力後に最初に `TAB` を押すと、そのセッションで `wtp shell-init <shell>` が
  評価される — rc の編集は不要。現在のシェルで即座に反映したい場合は
  `wtp shell-init <shell>` を手動実行すること。
- **`go install` でインストールした場合**: シェルの rc に1行追加する:

  ```bash
  eval "$(wtp shell-init zsh)"     # zsh  (~/.zshrc)
  eval "$(wtp shell-init bash)"    # bash (~/.bashrc); bash-completion v2 が必要
  wtp shell-init fish | source     # fish (~/.config/fish/config.fish)
  ```

`shell-init` は補完 + cd フックをまとめて有効化する。補完なしで cd フックだけ
欲しい場合は、代わりに `wtp hook <shell>` を使うこと（`bash`/`zsh`/`fish` サブコマンド）。

標準出力が TTY でない場合（コマンド置換、パイプ）、`wtp add` はプレーンな CLI 挙動を
保ち、ディレクトリの自動切り替えは**行わない**（スクリプトの動作が予測可能なままになる）。

## トラブルシューティング

`wtp` は実用的なエラーメッセージを目指している。よくあるもの:

- `branch '<x>' not found in local or remote branches` — タイプミス、もしくは
  リモートが fetch されていない。`git fetch` してから再試行すること。
- `branch '<x>' exists in multiple remotes: origin, upstream` — あいまい。
  先にローカル追跡ブランチを作成してから（`git branch --track <x> origin/<x>`）、
  `wtp add <x>` すること。
- `failed to create worktree: exit status 128` — 大抵はワークツリーのパスが
  既に存在している。`wtp list` で確認すること。
- `Cannot remove worktree with uncommitted changes. Use --force to override` —
  commit/stash するか、破棄してよいなら `wtp remove --force <name>` を使うこと。

## 関連 skill

マージ済みワークツリーの一括整理については `wtp-cleanup` skill を参照。
`main` にマージ済みのブランチを持つワークツリーを検出し、確認の上で削除する。
