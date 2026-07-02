# インストールの確認

> 🌐 English (canonical): [verification.md](verification.md)

← [ドキュメント目次](../README.ja.md)

このチェックリストは `.github/workflows/setup-validation.yml` が CI でアサートする内容を反映しています。`chezmoi apply` 後にマシンが収束したことを確認するため、各ステップをローカルで実行してください。

---

## 1. コアファイルのデプロイ確認

```bash
for f in \
  ~/.zshrc \
  ~/.zprofile \
  ~/.gitconfig \
  ~/.ssh/config \
  ~/.config/starship.toml \
  ~/.config/sheldon/plugins.toml \
  ~/.config/ghostty/config \
  ~/.config/mise/config.toml; do
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
```

8 つのパスすべてが `OK` と表示される必要があります。ファイルが欠けている場合は `chezmoi apply` が不完全です。

## 2. zsh モジュールのデプロイ確認

```bash
for mod in aliases git docker claude functions completions wtp ghq; do
  f=~/.config/zsh/${mod}.zsh
  [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
```

これらのモジュールは zsh 起動時に sheldon によって読み込まれます。モジュールが欠けると起動エラーやエイリアスの欠落が発生します。

## 3. mise 管理ツールの解決確認

```bash
eval "$(mise activate bash)"
for tool in node python go; do
  path=$(which "$tool")
  echo "$tool: $path"
  echo "$path" | grep -q ".local/share/mise" || echo "WARNING: $tool が mise で管理されていません"
done
node --version
python3 --version
go version
```

各バイナリパスに `.local/share/mise` が含まれる必要があります。システムインストール済みのツールが mise バージョンを上書きしている場合、シムが有効になっていません。

## 4. ghq 設定の確認

```bash
ghq_root=$(git config --type path --global --get ghq.root || true)
ghq_user=$(git config --global --get ghq.user || true)
[ "$ghq_root" = "$HOME/ghq" ] && echo "OK: ghq.root" || echo "MISMATCH: ghq.root=$ghq_root"
[ "$ghq_user" = "kryota-dev" ]  && echo "OK: ghq.user" || echo "MISMATCH: ghq.user=$ghq_user"
[ -f ~/.config/zsh/completions/_ghq ] && echo "OK: _ghq 補完" || echo "MISSING: _ghq 補完"
```

## 5. クリーンな非インタラクティブ zsh 起動

```bash
zsh_stderr=$(zsh -i -c exit 2>&1 >/dev/null) || true
if echo "$zsh_stderr" | grep -qE 'command not found|parse error|not found'; then
  echo "ERROR: zsh 起動エラー:"
  echo "$zsh_stderr"
else
  echo "OK: zsh がクリーンに起動します"
fi
```

これは `setup-validation.yml` が使用する完全に同一のチェックです。stderr に `command not found` や `parse error` があればシェルモジュールが壊れています。

## 6. コミット署名の確認（macOS）

```bash
git config --global --get gpg.format          # 期待値: ssh
git config --global --get gpg.ssh.program     # 期待値: 1Password SSH エージェントバイナリのパス
git config --global --get commit.gpgsign      # 期待値: true
```

次に、一時的なコミットでエンドツーエンドの 1Password SSH エージェント署名を確認します:

```bash
cd "$(mktemp -d)" && git init && git commit --allow-empty -m "signing test"
```

1Password ダイアログが表示されてコミットが成功すれば、署名が正しく設定されています。

## 7. エージェントランチャーエイリアスの確認（zsh）

新しいインタラクティブ zsh セッション（または `exec zsh`）を開始して確認します:

```bash
type cld       # 関数またはエイリアスに解決されるはず
type cld-r06   # 同様
type cdx       # Codex デフォルトアカウントランチャー
type cdx-r06   # Codex r06 アカウントランチャー
```

これらのエイリアスは `~/.config/zsh/claude.zsh` で定義され、sheldon によって読み込まれます。欠落している場合は、zsh モジュールがデプロイされているか（ステップ 2）、sheldon が正常に実行されたかを確認してください。

---

## トラブルシューティングクイックリファレンス

| 症状 | 考えられる原因 | 対処法 |
|------|--------------|--------|
| `MISSING: ~/.zshrc` | `chezmoi apply` が完了していない | `chezmoi apply -v` を再実行してエラーを確認 |
| ツールが `.local/share/mise` 配下にない | mise シムが有効でない | `mise activate bash` を実行するか新しいターミナルを開く |
| zsh stderr に `command not found` | 依存関係の欠落または sheldon ロック未実行 | `sheldon lock` を実行してから `exec zsh` |
| `ghq.root` の不一致 | `~/.gitconfig` が完全に適用されていない | `chezmoi apply -v` を実行して `dot_gitconfig.tmpl` を確認 |
| 署名テストで 1Password エラー | SSH エージェントが未起動またはロック済み | 1Password デスクトップを開いてアンロックし、再試行 |
| `cld` / `cdx` エイリアスが欠落 | sheldon が `claude.zsh` を読み込んでいない | `~/.config/zsh/claude.zsh` の存在を確認し `sheldon lock` を実行 |

---

## CI との関係

`.github/workflows/setup-validation.yml` は、クリーンルームの `chezmoi apply` 後に macOS と Ubuntu の両方でステップ 1〜5 を実行します。ステップ 6 と 7 は macOS 専用で 1Password が必要なため CI から除外されています。このチェックリストをローカルで実行することで、CI がカバーできない部分まで完全に確認できます。
