# 新しい vault の作成

ユーザーに頼まれたときだけ行う。vault 名（`personal` か owner）、匿名のラベル（クライアントのとき）、使う GPG 鍵をユーザーに確かめてから始める。owner 名・Google アカウント・鍵 ID は、公開する場所（dotfiles・PR・Issue）に書かない。

## バックアップの置き場

vault は git-remote-gcrypt で暗号化し、Google Drive for desktop の同期フォルダの中の普通のディレクトリへ push する。gcrypt は、絶対パスで `HEAD` を持たないディレクトリを local バックエンドとして扱い、新しい pack のファイルだけを書くので、push の量は差分にとどまる。bare リポジトリ（`HEAD` を持つ）にすると git のバックエンドとして扱われ、push のたびに履歴全体を送るので、`git init --bare` はしない。認証は Drive アプリが担い、1Password も GitHub も通らない。Drive 上に置かれるのは暗号化したファイルだけで、Drive の版の履歴（30 日）も残る。

`<backup>` は `~/Library/CloudStorage/GoogleDrive-<account>/<マイドライブ>/vault-backups/<name>`（`<マイドライブ>` のフォルダ名は OS の言語で変わる）。クライアントの業務用の Google アカウントではなく、自分のアカウントを使う。

## 前提: vault 用の GPG 鍵

最初の vault を作る前に一度だけ用意する。この節の手順はすべて、ユーザーが自分のターミナルで行う。エージェントは実行しない（秘密鍵やパスフレーズがセッションのログに残るため）。

1. `gpg --quick-generate-key "<名前> (vault)" ed25519 sign never` で署名用の主鍵を作り、`gpg --quick-add-key <fingerprint> cv25519 encr never` で暗号化用の副鍵を足す。パスフレーズを設定する。
2. 秘密鍵の控え（`gpg --export-secret-keys --armor <fingerprint>` の出力）とパスフレーズを 1Password に保管する。控えのファイルをディスクに残さない。
3. `gpgconf --kill gpg-agent` で gpg-agent を再起動し、`~/.gnupg/gpg-agent.conf` の pinentry-mac を読ませる。最初に鍵を使うとき、pinentry-mac の「Save in Keychain」を選ぶと、以後は無人で使える。

鍵をなくすと、暗号化したバックアップは復元できない。

## 手順

`<vault>` は `~/vaults/<name>`、`<fpr>` は vault 用の鍵の fingerprint。

1. 骨組みを作る。

   ```
   _index.md
   daily/  decisions/  meetings/  notes/  attachments/
   ```

   personal ではさらに `knowledge/_index.md`・`projects/`・`_inbox/rule-proposals.md`・`owners.md` を作る。`owners.md` には owner・vault・匿名のラベル（`c1` など）の対応表を書く（自分の owner は `personal`）。クライアントの vault を作るときは、personal の `owners.md` に 1 行足す。

2. `.obsidian/` の雛形を用意する。personal があれば、その `.obsidian/` から次だけをコピーする: `app.json`・`core-plugins.json`・`community-plugins.json`・`plugins/obsidian-git/`。`workspace*.json` はコピーしない（Obsidian が開くたびに書き換える）。personal を作るときは、ユーザーに Obsidian で vault を開いてもらい、Obsidian Git を入れて設定してもらう。

3. git を初期化し、バックアップのディレクトリと gcrypt の remote を用意する。vault は公開しないので、dotfiles の SSH 署名（1Password の承認）を vault では使わない。改ざんの検出は gcrypt の GPG 署名が担う。gcrypt は `user.signingkey` を GPG の鍵として読むが、dotfiles はそこに SSH 鍵を設定しているので、vault 用の鍵を remote ごとに指定する。remote は最初の commit の前に足す。グローバルの pre-commit hook は、remote が無いリポジトリでクライアント名を検査し、`gcrypt::` の remote では検査しないため。

   ```bash
   git -C <vault> init
   git -C <vault> config commit.gpgsign false
   mkdir -p <backup>
   git -C <vault> remote add origin "gcrypt::<backup>"
   git -C <vault> config remote.origin.gcrypt-participants <fpr>
   git -C <vault> config remote.origin.gcrypt-signingkey <fpr>
   ```

4. 最初の commit をして push する。グローバルの gitignore は `.obsidian/` を無視するので、vault では打ち消して設定を履歴に残す。大きな添付はバックアップを重くするので、動画とアーカイブは git に入れない。

   ```bash
   printf '%s\n' '!.obsidian/' '.obsidian/workspace*.json' '.trash/' 'attachments/**/*.mp4' 'attachments/**/*.mov' 'attachments/**/*.zip' > <vault>/.gitignore
   git -C <vault> add -A && git -C <vault> commit -m "chore: vault を作成"
   git -C <vault> push -u origin main
   ```

5. 復元できることを確かめる。作業ツリーの外の一時ディレクトリに clone し、HEAD の commit が一致したら一時ディレクトリを消す（git は空のディレクトリと無視したファイルを保存しないので、ディレクトリ全体は比べない）。participants を指定しない clone は、どの有効な署名も受け入れるので、指定する。

   ```bash
   git clone -c remote.origin.gcrypt-participants=<fpr> "gcrypt::<backup>" <tmp>/restore
   test "$(git -C <vault> rev-parse HEAD)" = "$(git -C <tmp>/restore rev-parse HEAD)"
   ```

6. ユーザーに Obsidian で「Open folder as vault」から `<vault>` を開いてもらい、Obsidian Git の設定で PATH に `$(brew --prefix)/bin` を足してもらう。PATH の設定は Obsidian の localStorage に保存され、`.obsidian/` の雛形では伝わらないので、vault ごとに要る（`git-remote-gcrypt` と `gpg` を見つけさせるため）。手入力の変更が Obsidian Git から push されることを確かめるまでを、作成の完了とする。

## 別の Mac での復元

必ず clone から始める。gcrypt の push は実質的に常に force になるので、`git init` した新しいリポジトリから push すると、バックアップの履歴を上書きする。

```bash
git clone -c remote.origin.gcrypt-participants=<fpr> "gcrypt::<backup>" ~/vaults/<name>
git -C ~/vaults/<name> config remote.origin.gcrypt-signingkey <fpr>
git -C ~/vaults/<name> config commit.gpgsign false
```

## Obsidian Git の設定（personal で一度決め、雛形として配る）

- 自動の commit と push の間隔を設定する。
- PATH は雛形で伝わらないので、手順 6 で vault ごとに設定する。
