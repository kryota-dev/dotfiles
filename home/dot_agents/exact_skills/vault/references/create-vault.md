# 新しい vault の作成

GitHub に private リポジトリを作る外向きの操作なので、ユーザーに頼まれたときだけ行う。vault 名（`personal` か owner）、GitHub のリポジトリ名、使う GPG 鍵をユーザーに確かめてから始める。リポジトリ名と鍵 ID は、公開する場所（dotfiles・PR・Issue）に書かない。

## 前提: vault 用の GPG 鍵

最初の vault を作る前に一度だけ用意する。鍵を作る操作とパスフレーズの入力はユーザーが行う。

1. `gpg --quick-generate-key "<名前> (vault)" ed25519 sign never` で署名用の主鍵を作り、`gpg --quick-add-key <fingerprint> cv25519 encr never` で暗号化用の副鍵を足す。パスフレーズを設定する。
2. 秘密鍵の控え（`gpg --export-secret-keys --armor <fingerprint>`）とパスフレーズを 1Password に保管する。控えのファイルをディスクに残さない。
3. `gpgconf --kill gpg-agent` で gpg-agent を再起動し、`~/.gnupg/gpg-agent.conf` の pinentry-mac を読ませる。最初に鍵を使うとき、pinentry-mac の「Save in Keychain」を選ぶと、以後は無人で使える。

鍵をなくすと、GitHub 上の暗号化したバックアップは復元できない。

## 手順

`<vault>` は `~/vaults/<name>`、`<fpr>` は vault 用の鍵の fingerprint。

1. 骨組みを作る。

   ```
   _index.md
   daily/  decisions/  meetings/  notes/  attachments/
   ```

   personal ではさらに `knowledge/`・`projects/`・`_inbox/rule-proposals.md`・`owners.md` を作る。`owners.md` には owner と vault の対応表を書く（自分の owner は `personal`）。

2. `.obsidian/` の雛形を用意する。personal があれば、その `.obsidian/` から次だけをコピーする: `app.json`・`core-plugins.json`・`community-plugins.json`・`plugins/obsidian-git/`。`workspace*.json` はコピーしない（Obsidian が開くたびに書き換える）。personal を作るときは、ユーザーに Obsidian で vault を開いてもらい、Obsidian Git を入れて設定してもらう。

3. git を初期化する。vault は公開しないので、dotfiles の SSH 署名（1Password の承認）を vault では使わない。改ざんの検出は gcrypt の GPG 署名が担う。グローバルの gitignore は `.obsidian/` を無視するので、vault では打ち消して設定を履歴に残す。

   ```bash
   git -C <vault> init
   git -C <vault> config commit.gpgsign false
   printf '%s\n' '!.obsidian/' '.obsidian/workspace*.json' '.trash/' > <vault>/.gitignore
   git -C <vault> add -A && git -C <vault> commit -m "chore: vault を作成"
   ```

4. GitHub に空の private リポジトリを作り、gcrypt の remote を足す。gcrypt は `user.signingkey` を GPG の鍵として読むが、dotfiles はそこに SSH 鍵を設定しているので、vault 用の鍵を remote ごとに指定する。

   ```bash
   gh repo create <repo> --private
   git -C <vault> remote add origin "gcrypt::git@github.com:<github-user>/<repo>.git"
   git -C <vault> config remote.origin.gcrypt-participants <fpr>
   git -C <vault> config remote.origin.gcrypt-signingkey <fpr>
   git -C <vault> push -u origin main
   ```

5. 復元できることを確かめる。作業ツリーの外の一時ディレクトリに clone し、中身が一致したら一時ディレクトリを消す。GitHub の Web 画面で、ファイル名と中身が読めないことも確かめる。

   ```bash
   git clone "gcrypt::git@github.com:<github-user>/<repo>.git" <tmp>/restore
   diff -r --exclude=.git <vault> <tmp>/restore
   ```

6. ユーザーに Obsidian で「Open folder as vault」から `<vault>` を開いてもらう。Obsidian Git が commit と push をすることを確かめる。

## Obsidian Git の設定（personal で一度決め、雛形として配る）

- 自動の commit と push の間隔を設定する。
- Dock から起動した Obsidian は PATH が最小限なので、Obsidian Git の設定で PATH に `/opt/homebrew/bin` を足す（`git-remote-gcrypt` と `gpg` を見つけさせるため）。
