# dotfiles

[chezmoi](https://www.chezmoi.io/) で管理する macOS 用の dotfiles。zsh・git・Homebrew・mise と、
コーディングエージェント（[Claude Code](https://code.claude.com/) と [Codex](https://developers.openai.com/codex)）の共通の設定を持つ。

## 新しい Mac のセットアップ

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install.sh)"
```

Xcode Command Line Tools・Homebrew・1Password を入れ、1Password CLI が使えるようになるまで待ってから
（テンプレートが描画時に秘密情報を読むため）、`chezmoi init --apply kryota-dev` を実行する。init は、秘密情報を
置いた 1Password の vault 名を尋ねる。答えは手元の `~/.config/chezmoi/chezmoi.toml` にだけ保存され、
入力し直すときは `chezmoi init --prompt` を使う。

その vault に必要なアイテム:

| アイテム | フィールド | 用途 |
|---|---|---|
| `Dotfiles - AWS Config` | `notesPlain` | `~/.aws/config` |
| `Dotfiles - Exa API` | `credential` | Exa の MCP サーバー |
| `Dotfiles - Firecrawl API` | `credential` | Firecrawl の MCP サーバー |
| `Dotfiles - Redact Patterns` | `pattern` | 自分のリポジトリでクライアント名を検出する gitleaks のルール |
| `Dotfiles - SSH Hosts` | `notesPlain` | `~/.ssh/config.d/hosts`（自宅のホスト。公開しない） |

## 日常の操作

```bash
chezmoi diff            # 差分を確認する
chezmoi apply -v        # 適用する
chezmoi edit ~/.zshrc   # 管理しているファイルをソース側で編集する
brew bundle dump --force --file=home/dot_Brewfile   # Homebrew の変更を Brewfile に反映する
```

## 開発

```bash
make lint   # shellcheck・shfmt・zsh -n・描画したスクリプトのテンプレート・actionlint
make test   # lint ＋ bats
```

全体の構成は [ARCHITECTURE.md](ARCHITECTURE.md) を参照。

## ライセンス

[MIT](LICENSE)
