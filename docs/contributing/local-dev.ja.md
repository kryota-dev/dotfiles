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
| `test` | `lint`、`lint-node`、`lint-console`、`test-node`、`test-bats` の順 |
| `test-bats` | `bats tests/*.bats` |
| `lint-node` | frontier-harness module/test に対する `node --check` |
| `lint-console` | `home/` と `tests/` 配下の全 JS/TS ソースに対し、`no-console` だけを有効にした `deno lint`（後述） |
| `test-node` | live provider credential を使わない `node --test tests/frontier_harness.test.mjs` |
| `benchmark` | `scripts/benchmark.sh`（コールドスタート + 10 回平均） |
| `sync-ghq-completion` | mise でピンした ghq バージョンに対応する `_ghq` をアップストリームから取得してベンダリング |
| `lint-deno` | ntfy dashboard（kryota-dev/dotfiles#371）に対する `deno check` + `deno lint` + `deno fmt --check`。best-effort で `deno` が無ければスキップ。`lint`/CI には含まれない |
| `test-deno` | ntfy dashboard に対する `deno test`。`lint-deno` と同じ best-effort/opt-in スコープ |

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

## console ガード

`make lint-console` は「debug 出力を残さない」というハウスルールを機械的に担保するチェックです。
#520 で退役した `stop:check-console-log` hook の移送先であり、その除去によってルールを強制する
仕組みが失われていました（#522）。

```
deno lint --no-config --rules-tags= --rules-include=no-console
```

- **検査対象**: `home/` と `tests/` 配下の、任意の深さにある `.mjs`・`.cjs`・`.js`・`.mts`・
  `.cts`・`.ts`・`.jsx`・`.tsx` すべて。glob が深さ 1 段で `.js` を含まない `lint-node` より
  意図的に広く取っています。
- **`grep` ではなく `deno lint` である理由**: ルールが AST ベースのため、文字列リテラルや
  コメント中に書かれた `console.log` を違反として報告しません。
  `tests/agent_improvement.test.mjs` は実行可能なソースを文字列として埋め込んでおり、
  テキスト走査ではこれを誤検出します。
- **1 ルールだけにしている理由**: `--rules-tags=` がタグ由来の既定ルールをすべて落とすため、
  ポリシーとして強制されるのは `no-console` だけになります。対象の多くは deno が本来所有しない
  Node モジュールであり、推奨ルールセットの残りはそれらに対して発火してしまいます。なお deno は
  `ban-unused-ignore` も報告します（**有効なルール**に属する ignore ディレクティブを評価するため）。
  これが、除外マーカーがそれを正当化した呼び出しより長生きするのを防いでいます。`--no-config` は、
  チェックアウトより上位にある `deno.json` が強制内容を変えるのを防ぎます。
- **deno 不在を致命的にしている理由**: `lint-deno` と異なり、このターゲットはツールが無いときに
  自分をスキップしません（`mise install deno`）。ツールが無いと自らを無効化するガードは、
  そもそもこの検査が失われた経緯そのものです。検査対象が 0 件の場合も同じ理由で失敗させます —
  何にもマッチしない glob が「違反なし」と読めてはなりません。

### 行単位で除外する

意図的な出力（CLI の利用者向け出力、サーバー側ログなど）は、`--` の後ろに理由を書いて
行単位で除外します。

```js
// deno-lint-ignore no-console -- user-facing CLI output, not a debug leftover
console.log(banner);
```

除外が行スコープなのは意図的で、同じファイル内の 2 つ目の `console.*` 呼び出しは依然として
失敗します。呼び出しを消したらコメントも消してください — 何も抑止しなくなったディレクティブは
`ban-unused-ignore` として報告されます。

ファイル単位の除外は「非推奨」ではなく**拒否**します。deno は
`// deno-lint-ignore-file no-console`（および全ルールを無効化する裸の
`// deno-lint-ignore-file`）を honor するため、どちらもファイル全体を黙って除外できてしまいます。
そこでターゲットは lint の前にこの 2 形式を走査して失敗させます。

```
lint-console: file-level opt-out is not allowed; use a per-line '// deno-lint-ignore no-console -- <reason>' instead:
home/dot_local/lib/example/cli.mjs:1:// deno-lint-ignore-file no-console
```

他のルールだけを指定したファイル単位ディレクティブ（`// deno-lint-ignore-file no-explicit-any`）は
そのまま通します — このガードを弱めることはなく、その下にある console 呼び出しは依然として
報告されるためです。

ツリーの大半はそもそも除外を必要としません。`home/dot_local/lib/` 配下の CLI モジュールは
既に `process.stdout.write` / `process.stderr.write` 経由で出力しています。ガードを有効化した
時点でリポジトリに存在した除外は、ntfy dashboard のサーバー側エラーログ 1 件のみでした。

`tests/console_lint.bats` は、テキストへのアサーションではなく、上書き可能な
`CONSOLE_LINT_ROOTS` を使って fixture ツリーに対してターゲットを実行します。存在はするが
何も検出しなくなったガードは、テキスト的なアサーションをすべて通過してしまうためです。

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
