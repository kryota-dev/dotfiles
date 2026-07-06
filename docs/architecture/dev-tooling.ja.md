# 開発ツールチェーン: mise、Brewfile、git

🌐 English (canonical): [dev-tooling.md](dev-tooling.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントは非 AI 系の開発ツールレイヤーを扱います。ランタイムと CLI ツールのバージョン SSOT としての mise、Brewfile + `.brewfile-linux-exclude` パターン、1Password SSH コミット署名を使った git 設定、グローバル gitleaks pre-commit フック、Ghostty ターミナル設定を説明します。

---

## mise: バージョン SSOT

`home/dot_config/mise/config.toml` は `~/.config/mise/config.toml` へそのまま展開されます（`.tmpl` ではありません — マシン固有のレンダリングは不要です）。これが全ピン済みツールバージョンの単一の情報源です。

### `[tools]` ブロック

`home/dot_config/mise/config.toml` の `[tools]` ブロックが、全ピン済みランタイムと CLI バージョンの SSOT です。Renovate が各ピンを自動バンプし、変更があると次回の `chezmoi apply` で `run_onchange_after_12-setup-mise` が再トリガーされます。**権威ある最新のバージョン一覧はそのファイルを参照してください。**

ブロックには以下の3カテゴリのエントリがあります（例示のみ; 権威ある最新一覧は `config.toml` を参照）:

- **ランタイム言語** — 正確なバージョンにピン（例: `node`、`python`、`ruby`、`go`、`deno`、`rust`）
- **レジストリ解決可能な CLI ツール** — ベアキーを使用（例: `gh`、`gitleaks`、`shellcheck`、`starship`、`tmux`）
- **npm バックの CLI** — mise レジストリにエントリがなく、`"npm:<pkg>"` キー形式を使用（例: `"npm:agent-browser"`、`"npm:happy"`）

### `[settings]` ブロック

既知の初回インストール失敗を防ぐための2つのデフォルト外設定:

```toml
[settings]
python.precompiled_flavor = "install_only"
ruby.compile = false
```

**`python.precompiled_flavor = "install_only"`**: この設定がないと、mise は `freethreaded+install_only_stripped` フレーバーを選択します。このフレーバーは `lib/` ディレクトリを省略し、初回インストール時に `"Python installation is missing a 'lib' directory"` エラーで失敗します（issues #121、#104）。`install_only` フレーバーは完全な `lib/` を含みます。

**`ruby.compile = false`**: ソースビルドによるデッドロックを防ぎます。ruby をソースからコンパイルする場合、`ruby-build` の configure プローブが処理中のバージョンの mise シムに再侵入し、インストールロックでブロックします（issue #122）。プリコンパイル済みバイナリを使用することでこれを完全に回避します。

### ツールの追加方法

- **mise を優先**: 正確なバージョンを指定して `[tools]` にツールを追加する。レジストリで解決可能なツールはベアキー、npm のみのツールは `"npm:<pkg>"` を使用。
- **GUI アプリとカスクには Brewfile**: macOS の `.app` バンドルや App Store アプリは `dot_Brewfile` に追加する（mise ではなく）。
- **ピンは意図的にバンプする**: mise はバージョン範囲を使用しない。`home/dot_config/mise/config.toml` をバンプすると次回の `chezmoi apply` で `run_onchange_after_12-setup-mise.sh.tmpl` が再トリガーされ、`mise install` が再実行される。

---

## Brewfile と `.brewfile-linux-exclude`

### `dot_Brewfile`

`home/dot_Brewfile` は標準の Homebrew バンドルファイルです: tap、formula、cask、mas（App Store）、vscode 拡張、go エントリを含みます。これは**プレーンテキスト — `.tmpl` ファイルではありません**。これは意図的なものです: `make dump-brewfile` は `brew bundle dump` を実行してファイルを上書き再生成します。テンプレートにすると上書きされるか再生成できなくなります。

制約:
- Brewfile に `brew "chezmoi"` を追加しないでください。chezmoi 自体はスタンドアロンの `curl get.chezmoi.io` ブートストラップでインストールされます（PR #22）。Brewfile に追加すると mise 管理バージョンと競合します。
- Brewfile の変更は `run_onchange_before_10-brew-bundle.sh.tmpl` の埋め込み sha256 を通じて次回の `chezmoi apply` で自動適用されます。

### `.brewfile-linux-exclude`

`/.brewfile-linux-exclude`（chezmoi ソースディレクトリ `home/` の外、**リポジトリルート**にあります）は `grep -E` パターンのリストです。これらのパターンにマッチする Brewfile 行は Linux で除外されます。

このファイルは2つの独立したコンシューマーが共有する SSOT です:

1. **ライフサイクルスクリプト**（`run_onchange_before_10-brew-bundle.sh.tmpl`）— Linux 上:
   ```bash
   grep -E '^(tap |brew )' "$BREWFILE" | grep -v -E -f "$EXCLUDE" > "$TMPFILE"
   brew bundle --no-upgrade --file="$TMPFILE"
   ```
   スクリプトは `{{ .chezmoi.sourceDir }}/../.brewfile-linux-exclude` 経由で `.brewfile-linux-exclude` にアクセスします（`home/` ソースディレクトリの1階層上）。

2. **CI**（`.github/workflows/setup-validation.yml`）— Ubuntu ランナーで `brew bundle` を実行する前に、同一の `grep` パイプラインで一時ファイルを生成します。

Linux 非互換の Brewfile エントリを追加する際は、2箇所に分岐ロジックを書くのではなく、`.brewfile-linux-exclude` にマッチパターンを追加してください。

---

## git 設定

`home/dot_gitconfig.tmpl` は `~/.gitconfig` にレンダリングされます。ID フィールドは chezmoi データ（`.chezmoidata.toml`）から取得します:

```ini
[user]
    name = {{ .name }}
    email = {{ .email }}
    signingkey = {{ .signingkey }}
```

その他の注目すべき設定:

| 設定 | 値 | 目的 |
|------|-----|------|
| `core.excludesfile` | `~/.gitignore_global` | グローバル gitignore（macOS/Linux/node パターン + カスタム） |
| `core.editor` | `nvim` | デフォルトエディタ |
| `core.hooksPath` | `~/.config/git/hooks` | グローバル pre-commit フック（後述） |
| `commit.gpgsign` | `true` | 全コミットに署名 |
| `gpg.format` | `ssh` | SSH キーで署名 |
| `init.defaultBranch` | `main` | |
| `extensions.worktreeConfig` | `true` | ワークツリー別 gitconfig サポート |
| `ghq.root` | `~/ghq` | ghq クローンルート |
| `ghq.user` | `{{ .ghq_user }}` | `ghq get` のデフォルト GitHub ユーザー名 |

### 1Password SSH コミット署名

`[gpg "ssh"]` ブロックは apply 時に `op-ssh-sign` の存在をプローブすることで**条件付きでレンダリング**されます:

```
{{- if stat "/Applications/1Password.app/Contents/MacOS/op-ssh-sign" }}
[gpg "ssh"]
    program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
{{- else if stat "/opt/1Password/op-ssh-sign" }}
[gpg "ssh"]
    program = "/opt/1Password/op-ssh-sign"
{{- end }}
```

apply 時にどちらのパスも存在しない場合、ブロックは完全に省略されます。`commit.gpgsign = true` は設定されたままなので、1Password がインストールされていないマシンではコミット署名が失敗します。解決策は 1Password をインストールして `chezmoi apply` を再実行することです。

署名キー（`user.signingkey`）は `.chezmoidata.toml` に格納された SSH 公開キーのフィンガープリントです。1Password の `op-ssh-sign` バイナリが署名呼び出しをインターセプトし、1Password エージェントから秘密鍵を取得します。

---

## グローバル gitleaks pre-commit フック

### ワイヤリング

`dot_gitconfig.tmpl` は `core.hooksPath = ~/.config/git/hooks` を設定します。これにより、マシン上のすべてのリポジトリで `.git/hooks` が置き換えられ、グローバル pre-commit がハーネス（人間、Claude Code、Codex）に関わらず**全コミット**で実行されます。

`home/dot_config/git/hooks/executable_pre-commit` は `~/.config/git/hooks/pre-commit` として 0755 モードで展開されます（`executable_` プレフィックス）。

### フックの動作

1. **gitleaks の解決**: PATH バイナリ（mise シム）を優先し、`mise exec -- gitleaks` にフォールバックし、gitleaks が存在しない場合は警告付きのフェイルオープン（スキャンスキップ）— `mise install` 実行前のマシンでコミットがブロックされないよう。

2. **設定の選択**: リポジトリローカルの `.gitleaks.toml`（gitleaks が自動検出）を優先し、`~/.config/git/gitleaks.toml`（グローバル設定）にフォールバック。`--config` を常に渡すとリポジトリ固有の allowlist を隠してしまいます。

3. **スキャン実行**: `gitleaks git --staged --redact --no-banner`。検出時は exit 1 と修正手順を表示。

4. **リポジトリ自身の pre-commit をチェーン**: `git rev-parse --path-format=absolute --git-common-dir` で解決し、`/hooks/pre-commit` を追加。`--git-path hooks/pre-commit` ではなく `--git-common-dir` を使用します — 前者は `core.hooksPath` を尊重し、このグローバルフック自身に解決されて無限 exec ループを引き起こすためです（PR #3d2b844 の修正）。`-ef` による自己参照ガードが二重防護として機能します。

### グローバル gitleaks 設定

`home/dot_config/git/private_gitleaks.toml.tmpl` はデフォルトルールセットを拡張し、2つの allowlist 正規表現を追加します:

```toml
[extend]
useDefault = true

[allowlist]
regexTarget = "line"
regexes = [
  '''op://\S.*''',
  '''onepasswordRead''',
]
```

`op://` URI は 1Password 参照であり、シークレットではありません。`onepasswordRead` はそれらを読み込む chezmoi テンプレート関数です。どちらもソースツリーにシークレット値を埋め込みません。

**`paths` allowlist は定義されていません。** このコンフィグは `core.hooksPath` 経由でグローバルにロードされるため、`paths` エントリを設定すると_すべての_リポジトリでそのパスをスキャナーが見えなくなります。ステージングに到達すべきでないファイル（`.kryota-dev/` 計画メモなど）は代わりに `~/.gitignore_global` で除外されています。

### クライアント識別子ルール（自分名義リポジトリのみ、1Password から注入）

2 つ目の設定ファイル `private_gitleaks-own.toml.tmpl`（`~/.config/git/gitleaks-own.toml` へモード 0600 で展開）は、base 設定をミラーした上で `client-identifiers` ルールを追加します。この正規表現自体はこの public リポジトリに絶対に含めてはなりません:

```toml
[[rules]]
id = "client-identifiers"
regex = '''(?i)({{ onepasswordRead "op://kryota.dev/Dotfiles - Redact Patterns/pattern" | trim }})'''
```

**owner-scoped な設定選択。** pre-commit フックはリポジトリの `origin` remote で設定を出し分けます: メンテナー自身の GitHub namespace（`kryota-dev`、`ryota-k0827`）配下のリポジトリ — および remote 未設定のリポジトリ（後で public に push されうるため fail-safe 側に倒す）— には `gitleaks-own.toml` を、クライアント/業務リポジトリ（自身の識別子が正当に頻出する）には base の `gitleaks.toml` を適用します。このためクライアントリポジトリの commit がこのルールでブロックされることはありません。`gitleaks-own.toml` が未展開の場合（1Password アイテム作成前のフレッシュマシン）は base 設定にフォールバックします。

`chezmoi apply` 実行時、パターンは 1Password のアイテム `Dotfiles - Redact Patterns`（ボールト `kryota.dev`、フィールド `pattern`）から読み込まれます。このアイテムは `name1|name2|…` 形式の単一アルタネーション（必要に応じて regex エスケープ済み、`'''` と改行は禁止）を保持します。`run_once_after_11-validate-1password.sh.tmpl` は apply 時にこのアイテムを再検証します: 存在・非空・`'''` 不在・regex としてコンパイル可能であること。なおフレッシュマシンではファイルテンプレートの展開がこのスクリプトより先に走るため、アイテム欠落時はまず chezmoi/op の生エラーが表面化します — スクリプトは gate ではなく診断レイヤーです。アイテム自体の作成はメンテナーが手動で行う out-of-band な手順であり、その値がこのリポジトリに書き込まれることはありません。

**このルールの唯一の強制ポイントはローカル pre-commit フックです。** サーバーサイドのバックストップは存在しません: パターンは CI で再現できず（1Password 非接続）、GitHub secret scanning はカスタム識別子 regex を対象外とします。`git commit --no-verify` で完全にバイパスできます。

誤検知が発生した場合は、他の gitleaks 検出と同じエスケープハッチを使用します: `git commit --no-verify`。

### 注意事項

- `git commit --no-verify` はフックをバイパスします。これはハーネスごとのポリシーとして意図的です。CI/サーバーサイドの gitleaks がバックストップとなります。
- 独自の `core.hooksPath` を設定するリポジトリ（例: husky）はグローバルフックに到達しません。
- フックがチェーンするのは `pre-commit` のみです。`.git/hooks` の他のフックタイプ（`commit-msg`、`post-commit` など）はチェーンされません。それらに依存するリポジトリは `core.hooksPath` を設定するフックマネージャーを使用する必要があります。

---

## Ghostty ターミナル

`home/dot_config/ghostty/config` は `~/.config/ghostty/config` へそのまま展開されます。テンプレートではありません。

主な設定:

| 設定 | 値 |
|------|-----|
| `font-family` | `Moralerspace Neon` |
| `font-size` | `14` |
| `shell-integration` | `zsh` |
| `term` | `xterm-256color` |
| `copy-on-select` | `clipboard` |
| `cursor-style` | `block` |
| `cursor-style-blink` | `true` |
| `macos-option-as-alt` | `true` |
| `macos-titlebar-style` | `tabs` |

**フォントの前提条件**: Ghostty は `Moralerspace Neon` フォントファミリーがインストールされている必要があります。Moralerspace Neon は apply 時に chezmoi エンジンが `.chezmoiexternal.toml` の `["Library/Fonts"]` external 経由でデプロイします（macOS のみ）。Nerd Font シンボルのみカスク（`font-symbols-only-nerd-font`）は Brewfile でインストールされます。

---

## 関連ドキュメント

- [ライフサイクルスクリプト: 実行順序とトリガーモデル](lifecycle-scripts.ja.md) — `run_onchange_before_10`（brew bundle）と `run_onchange_after_12`（mise install）はそれぞれ `dot_Brewfile` と `mise/config.toml` のハッシュによってトリガーされる
- [zsh スタートアップ、プロンプト、シェルモジュール](shell-environment.ja.md) — `.zshrc` が mise、direnv、starship、zoxide を activate する
- [CI アーキテクチャとテストスイート](../contributing/ci-and-tests.ja.md) — CI が `.brewfile-linux-exclude` フィルタを複製し、`config.toml` ハッシュで mise インストールをキャッシュする
- [1Password シークレットのオンボーディング](../getting-started/secrets-1password.ja.md) — SSH コミット署名を有効にする 1Password セットアップ
- [アカウント分離: エイリアス、env](../agents/account-isolation.ja.md) — AI エージェントサブシステムに橋渡しする gateguard Codex ゲート
