# 1Password シークレットのオンボーディング

> 🌐 English (canonical): [secrets-1password.md](secrets-1password.md)

← [ドキュメント目次](../README.ja.md)

`chezmoi apply` は apply 時に 1Password からシークレットバックのテンプレートを直接レンダリングします。このページでは、必要な Vault アイテム、それぞれの用途、そしてアイテムが欠落またはリネームされた場合に何が壊れるかを説明します。

render-at-apply パターンの設計思想については [シークレットとアカウント分離の設計](../explanation/secrets-and-isolation.ja.md) を参照してください。

---

## ハードゲート: `run_once_after_11-validate-1password`

macOS では、`chezmoi apply` はすべての管理ファイルを書き込んだ直後に `run_once_after_11-validate-1password.sh.tmpl` を実行します。このスクリプトは:

1. `op`（1Password CLI）がインストールされているか確認 — 存在しない場合 exit 1
2. `op account list` が成功するか確認 — 認証されていない場合 exit 1
3. 必要な各アイテム参照に対して `op read` を呼び出す — 最初の欠落アイテムで exit 1

```
exit 1  →  chezmoi apply が失敗
         →  後続のライフサイクルスクリプトが実行されない
         →  MCP サーバー、CLV2 オブザーバー、mise ツール: セットアップされない
```

これは意図的なフェイルファースト動作です。欠落アイテムは、壊れた環境をサイレントに生成するのではなく、直ちに表面化されます。

このスクリプトは `run_once_` です: 一度成功すると chezmoi はその完了を記録し、スクリプトの内容が変わらない限り再実行しません。成功した apply の後に Vault アイテムをリネームしたり、新しいアイテムを追加したり、アイテムを別の Vault に移動した場合は、強制的に再実行する必要があります:

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

**Linux のみ:** スクリプト本体全体は `{{ if ne .chezmoi.os "darwin" }}` でガードされています — Linux では "Skipping: not macOS" と表示して exit 0 します。Linux CI は 1Password なしで apply します。

---

## 前提条件

macOS で `chezmoi apply` を実行する前に:

1. **1Password デスクトップアプリ**がインストールされ、サインイン済みであること。
2. **CLI 統合が有効**: 1Password → 設定 → デベロッパー → "1Password CLI と統合"。
3. **1Password CLI（`op`）**がインストール済み: `brew install --cask 1password-cli`。
4. 以下に示す <!-- FACT:onepassword-vault-item-count -->4<!-- /FACT --> つの Vault アイテムすべてが `kryota.dev` Vault に存在すること。

---

## 必要な Vault アイテム

すべてのアイテムは **`kryota.dev`** Vault に存在します。アイテムタイトルとフィールド参照は正確に一致する必要があります — どちらかをリネームすると `op read` が失敗し `chezmoi apply` が exit 1 します。

### 1. `Dotfiles - AWS Config`

| 属性 | 値 |
|-----|---|
| Vault | `kryota.dev` |
| アイテムタイトル | `Dotfiles - AWS Config` |
| フィールド参照 | `notesPlain` |
| op:// URI | `op://kryota.dev/Dotfiles - AWS Config/notesPlain` |
| レンダリング先 | `~/.aws/config`（`private_dot_aws/config.tmpl`） |
| ファイルモード | `0600`（`private_` プレフィックスによる） |

`~/.aws/config` の INI コンテンツ全体をセキュアノートの本文として保存します。chezmoi は apply 時にそのまま `~/.aws/config` にレンダリングします。

### 2. `Dotfiles - Exa API`

| 属性 | 値 |
|-----|---|
| Vault | `kryota.dev` |
| アイテムタイトル | `Dotfiles - Exa API` |
| フィールド参照 | `credential` |
| op:// URI | `op://kryota.dev/Dotfiles - Exa API/credential` |
| レンダリング先 | `~/.config/zsh/claude-secrets.zsh`（`private_claude-secrets.zsh.tmpl`） |
| ファイルモード | `0600` |

`exa` ユーザースコープ Claude Code MCP サーバーが使用します。レンダリングされたファイルは `EXA_API_KEY` をシェル変数として設定します（export なし）。`claude.zsh` はこれを claude サブプロセスのみにスコープして再エクスポートします。

### 3. `Dotfiles - Firecrawl API`

| 属性 | 値 |
|-----|---|
| Vault | `kryota.dev` |
| アイテムタイトル | `Dotfiles - Firecrawl API` |
| フィールド参照 | `credential` |
| op:// URI | `op://kryota.dev/Dotfiles - Firecrawl API/credential` |
| レンダリング先 | `~/.config/zsh/claude-secrets.zsh`（Exa と同じファイル） |
| ファイルモード | `0600` |

`firecrawl` ユーザースコープ Claude Code MCP サーバーが使用します。同じファイルに `FIRECRAWL_API_KEY` を設定します。

### 4. `Dotfiles - Redact Patterns`

| 属性 | 値 |
|-----|---|
| Vault | `kryota.dev` |
| アイテムタイトル | `Dotfiles - Redact Patterns` |
| フィールド参照 | `pattern` |
| op:// URI | `op://kryota.dev/Dotfiles - Redact Patterns/pattern` |
| レンダリング先 | `~/.config/git/gitleaks-own.toml`（`dot_config/git/private_gitleaks-own.toml.tmpl`） |
| ファイルモード | `0600`（`private_` プレフィックスによる） |

クライアント/勤務先の識別子パターンを `name1|name2|...` の交替形式で保存します（必要に応じて regex エスケープ済み; `'''` と改行は不可）。chezmoi は apply 時にこれを自社名前空間リポジトリ用の gitleaks 設定にレンダリングします。`run_once_after_11` スクリプトはさらにこの値をスモークテストします——パターンが非空であること、TOML 生文字列リテラルを破壊する `'''` を含まないこと、有効な正規表現としてコンパイルできることを検証します。破損したパターンは自社名前空間リポジトリのすべてのコミットでクライアント識別子ルールをサイレントに無効化してしまいます。

---

## アイテムが欠落またはリネームされた場合の影響

| 欠落アイテム | 即時の失敗 | 下流への影響 |
|------------|-----------|------------|
| `Dotfiles - AWS Config` | 検証ゲートで `chezmoi apply` が exit 1 | `~/.aws/config` が書き込まれない、AWS CLI が使用不可 |
| `Dotfiles - Exa API` | 検証ゲートで `chezmoi apply` が exit 1 | `claude-secrets.zsh` がレンダリングされない、exa MCP サーバーが認証失敗 |
| `Dotfiles - Firecrawl API` | 検証ゲートで `chezmoi apply` が exit 1 | `claude-secrets.zsh` がレンダリングされない、firecrawl MCP サーバーが認証失敗 |
| `Dotfiles - Redact Patterns` | 検証ゲートで `chezmoi apply` が exit 1 | `gitleaks-own.toml` がレンダリングされない、自社名前空間リポジトリでクライアント識別子 gitleaks ルールが無効化 |

ゲートはすべての 4 アイテムを成功前にチェックするため、1 つのアイテムが欠落するだけでライフサイクルスクリプトの after フェーズ全体がブロックされます。

---

## 値のレンダリング方法

テンプレートは chezmoi の `onepasswordRead` 関数を使用します:

```
# private_dot_aws/config.tmpl
{{- onepasswordRead "op://kryota.dev/Dotfiles - AWS Config/notesPlain" }}

# private_claude-secrets.zsh.tmpl
EXA_API_KEY={{ onepasswordRead "op://kryota.dev/Dotfiles - Exa API/credential" | squote }}
FIRECRAWL_API_KEY={{ onepasswordRead "op://kryota.dev/Dotfiles - Firecrawl API/credential" | squote }}

# dot_config/git/private_gitleaks-own.toml.tmpl
regex = '''(?i)({{ onepasswordRead "op://kryota.dev/Dotfiles - Redact Patterns/pattern" | trim }})'''
```

重要なポイント:
- 値は `chezmoi apply` 時のみレンダリングされます — リポジトリには保存されません。
- `private_` chezmoi プレフィックスにより、すべてのレンダリング済みファイルがモード `0600` で書き込まれます。
- API キーは `squote`（シングルクォート）でラップされているため、`$` やバッククォートを含むキーがファイルを source したときにシェル展開やコマンド置換をトリガーできません。
- レンダリングされた `.zsh` ファイルは未エクスポートの変数（`export` なし）を使用するため、インタラクティブシェルのすべての子プロセスに値がリークしません。`claude.zsh` のランチャー関数がそれぞれのサブプロセスのみにスコープして再エクスポートします。

---

## CI での除外

`setup-validation.yml` は CI で `chezmoi apply` を実行する前に 1Password 依存のファイルをすべて除外します。以下の 6 ファイルは **両方のジョブ**（macOS および Ubuntu）で `/tmp/chezmoi-excluded/` に移動されます:

```
home/private_dot_aws/config.tmpl
home/dot_config/zsh/private_claude-secrets.zsh.tmpl
home/run_once_before_00-install-prerequisites.sh.tmpl
home/run_onchange_before_10-brew-bundle.sh.tmpl
home/run_once_after_11-validate-1password.sh.tmpl
home/dot_config/git/private_gitleaks-own.toml.tmpl
```

**macOS ジョブ**はさらに `home/run_once_after_90-other-apps.sh.tmpl` を除外します（および `home/run_once_after_30-setup-fonts.sh.tmpl` への古い参照も含みますが、そのスクリプトはもう存在しないため `if [ -f ]` ガードにより無視されます）。

CI は 1Password に一切触れず、レンダリング済みシークレットファイルは CI ランナーに存在しません。

---

## 参考ドキュメント

- [シークレットとアカウント分離の設計](../explanation/secrets-and-isolation.ja.md) — シークレットが sourced-not-exported である理由、0600 レンダリングパターン、アカウント分離との合成。
- [インストールとブートストラップ](installation.ja.md) — 完全な apply シーケンスと検証ゲートが実行されるタイミング。
