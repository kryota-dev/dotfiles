# ローカル開発

🌐 English (canonical): [local-dev.md](local-dev.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントでは、dotfiles リポジトリのコントリビューターワークフローとして、`make` ターゲットの契約、lint パイプラインの内部実装、そしてベンダリングした `_ghq` 補完の生成ファイルワークフローを説明します。

---

## `make` の契約

`Makefile` は全ローカル開発コマンドの単一情報源 (SSOT) です。デフォルトターゲットは `help` であり、素の `make` を実行するとターゲット一覧を表示して終了します — `$HOME` には一切触れません。

| ターゲット | 実行内容 |
|---|---|
| `help`（デフォルト） | `## ` ドキュメントコメント行を `awk` でパースしてターゲット一覧を表示 |
| `lint` | shellcheck + shfmt diff チェック + `zsh -n` 構文チェック（後述） |
| `fmt` | `.sh` ファイルを `shfmt -w -i 2 -ci` でインプレース整形；`.sh.tmpl` は差分表示のみ |
| `test` | `lint` の後に `test-bats` |
| `test-bats` | `bats tests/*.bats` |
| `benchmark` | `scripts/benchmark.sh`（コールドスタート + 10 回平均） |
| `dump-brewfile` | `rm home/dot_Brewfile && brew bundle dump --file home/dot_Brewfile` |
| `sync-ghq-completion` | mise でピンした ghq バージョンに対応する `_ghq` をアップストリームから取得してベンダリング |

### `make apply` が存在しない理由

dotfiles の適用は `$HOME` を変更します。その変更をデフォルトの `make` ターゲット（またはそもそも利用可能なターゲット）にすると、筋肉記憶や CI のタイプミスによる意図しない実行が起こりえます。代わりに、apply と diff は直接実行します。

```bash
chezmoi apply -v    # 詳細出力付きで適用
chezmoi diff        # 変更内容を表示
```

`all` ターゲットは `help` にエイリアスされており、`$HOME` への誤った変更を防いでいます。

---

## lint パイプライン

`make lint` は 3 つのツールを順番に実行します。いずれも `home/**/*.sh` と `home/**/*.sh.tmpl` を対象とし、`symlink_*` にマッチするファイルは除外します。

### 1. shellcheck

```
shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329
```

除外コードとその理由：

| コード | 理由 |
|---|---|
| SC1091 | ソースするファイルが lint 環境に存在しない |
| SC2034 | サブシェルや chezmoi テンプレートでのみ使われる変数が未使用と報告される |
| SC2086 | 特定の変数に対する単語分割は意図的 |
| SC2317 | chezmoi テンプレートの条件ブロックで到達不能コードの誤検知が起きる |
| SC2329 | テンプレート主導の構造でループ変数の警告が出る |

### 2. shfmt

```
shfmt -d -i 2 -ci
```

フラグ：2 スペースインデント（`-i 2`）、case インデント（`-ci`）、差分モード（`-d`）。`fmt` ターゲットでは `.sh` ファイルに対して `-d` の代わりに `-w` を使用してインプレース書き込みを行います。

### 3. zsh 構文チェック

`zsh -n` は以下を対象に実行されます：

- `home/dot_config/zsh/*.zsh` ファイル（すべて直接）
- `home/dot_config/zsh/*.zsh.tmpl` ファイル（テンプレート行を除去した後）
- `home/dot_config/zsh/completions/_ghq`

---

## テンプレート行の除去

chezmoi テンプレートはシェルコードのインラインに Go の `{{ }}` ディレクティブを埋め込みます。シェル lint ツールは Go テンプレート構文を解釈できないため、`Makefile` は `{{` を含むすべての行を除去した上でコンテンツを shellcheck、shfmt、`zsh -n` に渡します：

```bash
sed '/{{/d' "$f" | shellcheck --shell=bash --exclude=... -
sed '/{{/d' "$f" | shfmt -d -i 2 -ci
sed '/{{/d' "$f" | zsh -n
```

### バックスラッシュ継続の危険性

この除去は行単位で行われます：`{{` がその行のどこかに現れると、その行全体を削除します。複数行にまたがる `\` 継続構文は、`{{` が独立した行にある場合にのみ安全です。`\` で継続する行が除去された場合、次の行が宙ぶらりんの継続対象になり、lint がシンタックスエラーを検出します。

**問題のあるパターン：**

```sh
# .sh.tmpl でこのような書き方は避けること
some_command \
  {{ if .someFlag }}"--flag"{{ end }} \   # <- この行が削除される
  last_arg                                 # <- 宙ぶらりん、パースエラー
```

**安全な代替案：** テンプレートディレクティブを独立した行に置くか、`{{` を含む行に依存する `\` 継続を避ける。

---

## `sync-ghq-completion` 生成ファイルワークフロー

`home/dot_config/zsh/completions/_ghq` は `ghq` の zsh 補完をアップストリームからベンダリングしたコピーです。手動編集は行わず、生成によって管理します。

### 仕組み

1. `scripts/ghq-version.sh` が `home/dot_config/mise/config.toml` から mise でピンした ghq バージョン（例：`0.6.2`）を読み取る。
2. ターゲットが `https://raw.githubusercontent.com/x-motemen/ghq/v<version>/misc/zsh/_ghq` を取得する。
3. 検証：取得したファイルが空でなく、`#compdef ghq` で始まることを確認。
4. ベンダリングヘッダーを先頭に追加：
   ```
   #compdef ghq
   # vendored: x-motemen/ghq@v<version> misc/zsh/_ghq
   # Run 'make sync-ghq-completion' to refresh.
   ```
5. 出力に対して `zsh -n` を実行。
6. `mv` でアトミックに配置。

### 実行タイミング

- `home/dot_config/mise/config.toml` の `ghq` バージョンを上げる際は、コミット前に `make sync-ghq-completion` を実行する。
- プルリクエスト上では、CI が `sync-ghq-completion` ジョブを自動実行し、変更があれば更新した `_ghq` を自動コミットする。

CI ジョブは同一リポジトリ PR のみを対象とします。フォーク PR は読み取り専用の `GITHUB_TOKEN` を受け取るため、ジョブはスキップされます。

`_ghq` を手動編集することはしないこと — 次の同期で上書きされます。

---

## 関連ドキュメント

- `make lint` と `make test-bats` を反映した CI ワークフロー：[ci-and-tests.ja.md](ci-and-tests.ja.md)
- ワークツリーと環境のセットアップ：[worktrees-and-env.ja.md](worktrees-and-env.ja.md)
- chezmoi の apply とソース構造：[../architecture/chezmoi-engine.ja.md](../architecture/chezmoi-engine.ja.md)
