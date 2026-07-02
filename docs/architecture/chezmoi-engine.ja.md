# chezmoi エンジン: データ、テンプレート、名前デコード

🌐 English (canonical): [chezmoi-engine.md](chezmoi-engine.md)

← [ドキュメント目次](../README.ja.md)

chezmoi エンジンは、他のすべてのサブシステムが依存するメタ層です。ソースツリーが `$HOME` にどのようにマップされるか、どのテンプレート変数が利用可能か、複数のデプロイ先にわたって設定フラグメントを共有する方法を定義します。このドキュメントでは、名前デコード、テンプレート変数インベントリ、OS 分岐、`includeTemplate`、2 つの chezmoi 設定ファイルについて説明します。

---

## ソース → `$HOME` 名前デコード

chezmoi ソースルートは `home/` です（`.chezmoiroot` で設定）。以下のパスはすべて `home/` からの相対パスです。

| ソースプレフィックス / サフィックス | デスティネーションへの効果 | 例 |
|-------------------------------------|---------------------------|-----|
| `dot_` | `.` に置換 | `dot_zshrc` → `~/.zshrc` |
| `dot_config/` | プレフィックスが再帰的に展開 | `dot_config/zsh/foo.zsh` → `~/.config/zsh/foo.zsh` |
| `private_` | デスティネーションをモード `0600` で作成 | `private_dot_aws/config` → `~/.aws/config` (0600) |
| `executable_` | デスティネーションをモード `0755` で作成 | `dot_claude/executable_statusline.sh` → `~/.claude/statusline.sh` (0755) |
| `symlink_` | シンボリックリンクを作成。ファイル内容がリンクターゲットになる | `symlink_skills.tmpl` → レンダリング結果がリンクターゲット |
| `.tmpl` サフィックス | ファイルを Go テンプレートとしてレンダリング。サフィックスはデスティネーション名から除去 | `dot_gitconfig.tmpl` → `~/.gitconfig` |
| `run_once_` プレフィックス | スクリプトのコンテンツ SHA256 をキーとして一度だけ実行 | `run_once_after_11-validate-1password.sh.tmpl` |
| `run_onchange_` プレフィックス | コンテンツハッシュまたは監視対象入力のハッシュが変わるたびに再実行 | `run_onchange_before_10-brew-bundle.sh.tmpl` |

プレフィックスとサフィックスは組み合わせ可能です。例: `home/dot_config/chezmoi/private_chezmoi.toml` → `~/.config/chezmoi/chezmoi.toml`（モード `0600`）。

---

## テンプレート変数インベントリ

すべての `.tmpl` ファイルは 2 つの変数名前空間にアクセスできます。`.chezmoidata.toml` から読み込まれる静的データと、`.chezmoi.*` 配下の chezmoi ビルトインです。

### 静的データ: `home/.chezmoidata.toml`

このファイルは chezmoi が自動ロードします（ソースツリー内の `.chezmoidata.*` という名前のファイルはすべてテンプレートデータ辞書にマージされます）。マシンごとの設定は不要です。

| 変数 | 型 | 値 / 目的 |
|------|-----|-----------|
| `.email` | string | コミット作者およびgit設定のメールアドレス |
| `.name` | string | コミット作者名（`kryota-dev`） |
| `.signingkey` | string | git コミット署名に使用する SSH 公開鍵のパス（`~/.ssh/ssh-key.pub`） |
| `.ghq_user` | string | デフォルトの `ghq` ユーザー名前空間（`kryota-dev`） |
| `.versions.moralerspace_font` | string | Moralerspace フォントのリリースバージョン。external アーカイブ URL で使用（Renovate がバンプ） |
| `.skills.anthropic_commit` | string | 取得する `anthropics/skills` コミットの SHA。Renovate がバンプする |
| `.ecc.version` | string | ECC リリースバージョン。`github-tags` customManager の **Renovate** 追跡 anchor。chezmoi テンプレートからは未参照（chezmoi が使うのは `.ecc.commit`）。ECC リリースごとに `.ecc.commit` と共にバンプされる |
| `.ecc.commit` | string | ピン固定された ECC リリースのイミュータブルなコミット SHA。すべての ECC external URL で使用 |
| `.ecc.skills` | string 配列 | 採用済み ECC スキル名の <!-- FACT:ecc-skill-count -->126<!-- /FACT --> エントリリスト。`.chezmoiexternal.toml` でレンジされ、スキルごとに 1 つの external エントリを生成 |

トップレベルキーはベアで参照します: `{{ .name }}`、`{{ .email }}`。ネストしたテーブルはドット区切りで参照します: `{{ .ecc.commit }}`、`{{ .versions.moralerspace_font }}`。

### chezmoi ビルトイン

| 変数 | 型 | 主な用途 |
|------|-----|---------|
| `.chezmoi.os` | string | macOS では `"darwin"`、Linux では `"linux"`。OS 分岐のキー |
| `.chezmoi.homeDir` | string | `$HOME` への絶対パス。フックパスや設定ファイルで使用 |

---

## OS 分岐

標準的な OS 分岐イディオムは以下の通りです。

```
{{ if eq .chezmoi.os "darwin" }}
# macOS のみのブロック
{{ else if eq .chezmoi.os "linux" }}
# Linux ブロック
{{ end }}
```

除外形式の否定形も使用されます。

```
{{ if ne .chezmoi.os "darwin" }}
# 非 macOS ブロック（例: Linux では Library/ を無視）
{{ end }}
```

このガードは以下の箇所に現れます。

- `.chezmoiignore` — Darwin 以外では `Library/` を無視。
- `.chezmoiexternal.toml` — Moralerspace フォントエントリをラップ（macOS のみ）。
- ほとんどの `run_*` ライフサイクルスクリプト — macOS 固有コマンドをガード。

macOS がプライマリターゲットです。Linux サポートは CI をグリーンに保つためだけに存在し、フォントや macOS デフォルト設定などの機能は Linux では単純に存在しません。

---

## 共有テンプレート: `includeTemplate`

`home/.chezmoitemplates/` 配下のファイルは直接デプロイされません。他の `.tmpl` ファイルから以下の構文で取り込まれる名前付きフラグメントです。

```
{{ includeTemplate "<フラグメント名>" . }}
```

末尾の `.` は現在のデータコンテキスト（すべてのテンプレート変数）をフラグメントに渡します。解決順序は `.chezmoitemplates/` を先に検索し、次にソースディレクトリを検索します。

| フラグメント | インクルード元 | 目的 |
|-------------|--------------|------|
| `coding-standards.md` | `AGENTS.md.tmpl` | ハウスコーディング標準（日本語）。一度作成し `~/AGENTS.md` に埋め込む。`~/.claude/CLAUDE.md` は `@~/AGENTS.md` インポート（chezmoi の `includeTemplate` ではなく Claude Code のファイル参照機能）経由で間接的に取り込む |
| `codex-hooks.json` | `dot_codex/hooks.json.tmpl`、`dot_codex-r06/hooks.json.tmpl` | 実際の Codex `PreToolUse` フック本体。`{{ .chezmoi.homeDir }}` を参照 |
| `codex-shared-config.toml` | `dot_codex/private_shared.config.toml.tmpl`、`dot_codex-r06/private_shared.config.toml.tmpl` | 共有 Codex プロファイル設定。personality、model、推論努力度、`multi_agent` フラグ |

`dot_codex/` と `dot_codex-r06/` ディレクトリは構造的に同一の薄いラッパーで、`includeTemplate` 呼び出しのみを含みます。実際の設定本体は `.chezmoitemplates/` に存在するため、2 つのアカウントが乖離することはありません。

---

## 2 つの chezmoi 設定ファイル

`home/` 配下に chezmoi に関連する TOML ファイルが 2 つありますが、役割が異なります。

### `home/.chezmoidata.toml` — テンプレートデータ

自動ロード。`.tmpl` ファイルが読み取る**値**を含みます。メールアドレス、キーパス、バージョンピン、テンプレートが必要とするその他の変数をここに書きます。`$HOME` にはデプロイされず、テンプレートエンジンにデータを提供するためだけにソースツリーに存在します。

### `home/dot_config/chezmoi/private_chezmoi.toml` — chezmoi ビヘイビア設定

`~/.config/chezmoi/chezmoi.toml` にモード `0600` でデプロイされます（`private_` プレフィックスによる）。テンプレートデータではなく、**chezmoi 自身の設定**を含みます。現在の内容:

```toml
[diff]
  exclude = ["scripts"]
```

`exclude = ["scripts"]` 設定により、`chezmoi diff` はデフォルトで `run_*` ライフサイクルスクリプトの変更を非表示にします。スクリプトの編集が diff 出力でサイレントに適用されることがあります。フィルターを上書きするには `--exclude=` を渡してください。これは意図的な設定です。ライフサイクルスクリプトの diff はノイズが多く、コンテンツハッシュ（`run_once_`/`run_onchange_`）が意味のあるシグナルです。

この 2 つのファイルを混同しやすいですが、どちらも chezmoi に関連する TOML ファイルです。ルール: テンプレート用データ → `.chezmoidata.toml`、chezmoi 自身のビヘイビア → `dot_config/chezmoi/private_chezmoi.toml`。

---

## `.chezmoiignore` と `.chezmoiremove`

### `.chezmoiignore`

chezmoi が作成も管理もしない**デスティネーション**パスのグロブパターンです。これらのパターンにマッチする既存ファイルを削除しません。単に無視するだけです。このファイル自体がテンプレートなので、パターンを OS 条件付きにできます。

このリポジトリでの用途:
- ハーネスのランタイム状態: `~/.claude/history.jsonl`、`~/.codex/sessions/`、ECC データベースなど。
- AWS CLI および SSO キャッシュ。
- 非 Darwin（Linux）での `Library/`。

パターンはデスティネーションパスのグロブ（`$HOME` 相対）であり、ソースグロブではありません。

### `.chezmoiremove`

`chezmoi apply` のたびに chezmoi が**アクティブに削除**するデスティネーションパスです。以前にデプロイされたファイルを廃棄するための仕組みです。

chezmoi ソースツリーからファイルを削除しても、`$HOME` にすでにデプロイされたコピーは**削除されません**。デプロイ済みファイルを削除したい場合は:

1. ソースファイルを `git rm`（またはエクスターナルリストから削除）、**かつ**
2. デスティネーションパスを `.chezmoiremove` に追加する

が必要です。

現在のエントリ: 廃棄された `sdd-*` エージェントファイル 4 件と、`agent-browser` の専用スキル（`electron`、`slack`、`dogfood`）3 件。これらのデプロイ済みコピーは強制削除されます（CLI が実行時にサービスするため）。

---

## lint との関係

テンプレートファイル（`.tmpl`）には、シェルや TOML 構文に Go テンプレートディレクティブが混在しています。lint パイプラインは shellcheck、shfmt、`zsh -n` を実行する前に `sed '/{{/d'` で `{{` を含む行を除去します。これは以下を意味します。

- `{{ … }}` ディレクティブと同じ行にあるシェル文は lint 中に失われます。
- 除去されたテンプレート行の直後にある行でバックスラッシュ行継続（`\`）を使用すると、残ったシェル文が壊れます。

テンプレートディレクティブは独立した行に記述してください。lint パイプライン全体については [contributing/local-dev.ja.md](../contributing/local-dev.ja.md) を参照してください。
