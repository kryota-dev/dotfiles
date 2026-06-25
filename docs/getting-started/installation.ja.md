# インストールとブートストラップ

> 🌐 English (canonical): [installation.md](installation.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントでは、dotfiles をブートストラップする 2 つのエントリポイント、それぞれが内部で何を行うか、そして再実行時の冪等性について説明します。

ルートの `README.md` にはハッピーパスのワンライナーが記載されています。このページでは、Xcode CLI ツールの欠如、Debian 系以外の Linux、ネットワークリトライ、chezmoi ダウンロード後の処理といったエッジケースを解説します。

---

## 前提条件

| プラットフォーム | ブートストラップ前に必要なもの |
|-----------------|-------------------------------|
| macOS (Apple Silicon) | `curl`、`bash`（どちらも macOS 標準搭載） |
| Ubuntu / Debian | `curl`、`bash`、`sudo` |
| その他の Linux | 非サポート — スクリプトはエラーで終了 |

**1Password**（CLI 統合が有効になったデスクトップアプリと、PATH に通った CLI `op`）は、`chezmoi apply` がシークレットバックのテンプレートをレンダリングするために必要です。まったく新しいマシンでは、`install.sh` が dotfiles をダウンロードして適用した後、1Password ゲート（`run_once_after_11`）がシークレットを検証します。必要な Vault アイテムについては [1Password シークレットのオンボーディング](secrets-1password.ja.md) を参照してください。

---

## エントリポイント A — 新しいマシン（推奨）

```bash
# 実行前にスクリプトを確認: https://github.com/kryota-dev/dotfiles/blob/main/install/install.sh
bash <(curl -fsLS https://raw.githubusercontent.com/kryota-dev/dotfiles/main/install/install.sh)
```

`install.sh` は意図的に短く書かれています。その処理内容:

### 1. OS 検出

スクリプトは `uname` で分岐します:

```
Darwin   → macOS パス
Linux    → Linux パス（apt-get が必要）
その他   → exit 1（非サポート）
```

### 2. macOS: Xcode CLI ツール

```bash
if ! xcode-select -p &>/dev/null; then
  xcode-select --install
  echo "Please re-run this script after installation completes."
  exit 0
fi
```

Xcode CLI ツールが存在しない場合、スクリプトはグラフィカルインストーラーダイアログを起動し、**exit 0** で終了します（エラーではありません）。スクリプトはダイアログの完了を待ちません。ツールのインストールが完了したら、ブートストラップコマンドを再実行してください。ツールがすでに存在する場合、このチェックは no-op です。

### 3. Linux: apt-get による前提条件インストール

```bash
sudo apt-get update
sudo apt-get install -y build-essential curl file git
```

`sudo` と `apt-get` の両方が利用可能でなければなりません。どちらかが存在しない場合、スクリプトは即座に exit 1 します。yum、dnf、pacman、その他のパッケージマネージャーはサポートしていません。

### 4. chezmoi ダウンロード — 3 回リトライ（バックオフ付き）

```bash
for attempt in 1 2 3; do
  if installer=$(curl -fsLS https://get.chezmoi.io) && [ -n "$installer" ]; then
    break
  elif [ "$attempt" -lt 3 ]; then
    sleep $((attempt * 5))   # 5 秒、次に 10 秒
  else
    exit 1
  fi
done
```

インストーラーシェルスクリプトは `get.chezmoi.io` からダウンロードされます。ダウンロードが失敗した場合（ネットワークエラー、空のボディ）、スクリプトは増加する遅延（2 回目の前に 5 秒、3 回目の前に 10 秒）で最大 3 回リトライします。継続的な失敗時は exit 1 します。

### 5. chezmoi init --apply

```bash
sh -c "$installer" -- init --apply kryota-dev
```

`get.chezmoi.io` インストーラーは `chezmoi` バイナリを `~/.local/bin/` に配置し、直ちに以下を実行します:

```
chezmoi init --apply kryota-dev
```

これにより `github.com/kryota-dev/dotfiles` が chezmoi ソースディレクトリにクローンされ、`.chezmoiroot`（`home/`）が読み込まれ、ライフサイクルスクリプトを含む完全な apply が起動します。

---

## エントリポイント B — chezmoi インストール済みの場合

```bash
chezmoi init --apply kryota-dev
```

chezmoi がすでに PATH にある場合（前回のインストール、mise や brew 経由のインストールなど）に使用します。エントリポイント A のステップ 5 以降と同じ結果になります。

---

## `chezmoi init --apply` 後の処理

chezmoi は固定された二フェーズの順序で適用します。番号付きライフサイクルスクリプトが apply の一部として実行されます:

```
BEFORE フェーズ（ファイル書き込み前）
  00-install-prerequisites   run_once    Xcode CLI ツール + Homebrew / Linuxbrew
  10-brew-bundle             run_onchange  brew bundle --no-upgrade

chezmoi がすべての管理ファイルを $HOME に書き込む

AFTER フェーズ（ファイル書き込み後）
  11-validate-1password      run_once    1Password ゲート（macOS のみ）— アイテム欠落時 exit 1
  12-setup-mise              run_onchange  mise install（3 回リトライ）
  13-setup-mcp               run_onchange  Claude Code MCP サーバーを登録
  14-enable-clv2-observer    run_onchange  CLV2 継続学習オブザーバーを有効化
  16-migrate-claude-binary   run_once    ~/.local/bin/claude → mise install へのシンリンク
  18-setup-agent-browser     run_onchange  agent-browser 用 Chromium をダウンロード
  20-macos-defaults          run_onchange  macOS システム環境設定（macOS のみ）
  40-setup-sheldon           run_onchange  sheldon lock
  50-set-login-shell         run_once    chsh -s zsh（Linux のみ）
  90-other-apps              run_once    インタラクティブなオプショナルアプリ（macOS のみ）
```

注: フォント（Moralerspace Neon）はライフサイクルスクリプトではなく、`home/.chezmoiexternal.toml` に宣言された `["Library/Fonts"]` external を通じて chezmoi エンジンが apply 時に直接フェッチします（macOS のみ）。Nerd Font シンボル専用 cask は Brewfile でインストールされます。

完全なセマンティクスは [ライフサイクルスクリプト: 順序とトリガーモデル](../architecture/lifecycle-scripts.ja.md) を参照してください。

---

## 冪等性と安全な再実行

`chezmoi apply -v`（またはブートストラップの再実行）は安全です:

- `run_once_` スクリプトはレンダリングされたコンテンツの SHA256 を追跡します。スクリプト本体が変わらない限り再実行されません。
- `run_onchange_` スクリプトは追跡するファイル（例: `dot_Brewfile`、`mise/config.toml`）のハッシュを埋め込みます。そのハッシュが変化した時だけ再実行されます。
- ファイル書き込みは設計上冪等です — chezmoi はコンテンツが異なる場合のみファイルを書き込みます。

**例外:** `run_once_after_11-validate-1password` が前回の実行で完了済みの場合、新しい Vault アイテムを追加しても chezmoi は再実行しません。強制的に再実行するには、記録済みの状態を削除します:

```bash
chezmoi state delete-bucket --bucket=scriptState
```

その後 `chezmoi apply` を再実行します。

---

## ソースツリーからの変更適用

ブートストラップ後の更新適用:

```bash
chezmoi apply -v        # 変更ファイルを表示しながら適用
chezmoi diff            # 適用せずに変更プレビュー
```

意図的に `make apply` ターゲットは存在しません。詳細は [ローカル開発と make の契約](../contributing/local-dev.ja.md) を参照してください。

---

## 次のステップ

1. [1Password シークレットのオンボーディング](secrets-1password.ja.md) を完了する — `chezmoi apply` がシークレットバックのテンプレートをレンダリングするために必要です。
2. [確認チェックリスト](verification.ja.md) を実行してマシンが収束したことを確認する。
