# 新しい vault の作成

ユーザーに頼まれたときだけ行う。vault 名（`personal` か owner）、クライアントのときは owner の別名と匿名のラベル（`c1` など。ほかの vault と重ならないもの）をユーザーに確かめてから始める。owner 名・Google アカウント・鍵の fingerprint は、公開する場所（dotfiles・PR・Issue）に書かない。

この Mac で vault を使う準備（鍵の import、pinentry-mac 用のキーチェーン項目、Drive からの復元、別名の symlink、Obsidian への登録）は、`chezmoi apply` のたびに `run_after_31-vaults.sh` が行う。ここに書くのは、vault を新しく作るときだけの手順。

## バックアップの置き場

vault は git-remote-gcrypt で暗号化し、Google Drive for desktop の同期フォルダの中の普通のディレクトリへ push する。gcrypt は、絶対パスで `HEAD` を持たないディレクトリを local バックエンドとして扱い、新しい pack のファイルだけを書くので、push の量は差分にとどまる。bare リポジトリ（`HEAD` を持つ）にすると git のバックエンドとして扱われ、push のたびに履歴全体を送るので、`git init --bare` はしない。認証は Drive アプリが担い、1Password も GitHub も通らない。Drive 上に置かれるのは暗号化したファイルだけで、Drive の版の履歴（30 日）も残る。

`<backup>` は `$HOME/Library/CloudStorage/GoogleDrive-<account>/<マイドライブ>/vault-backups/<name>`（`<account>` は 1Password の「Dotfiles - Vault」の `drive_account`。`<マイドライブ>` のフォルダ名は OS の言語で変わり、英語では空白を含む `My Drive`）。gcrypt は `/` で始まるパスだけを local バックエンドとして扱うので、`~` を使わず `$HOME` で絶対パスにし、使う箇所はすべて二重引用符で囲む。personal のバックアップは必ず `vault-backups/personal` にする（pre-commit hook がこのパスでクライアント名を検査するため）。

## 前提: vault 用の GPG 鍵（一度だけ）

1Password の vault（`chezmoi execute-template '{{ .op_vault }}'`）に、項目「Dotfiles - Vault」（`password`・`fingerprint`・`drive_account`）と、ドキュメント「Dotfiles - Vault GPG key」（秘密鍵の控え）が無ければ作る。ユーザーにコマンドを打たせず、エージェントが実行する。パスフレーズは 1Password で生成し、秘密鍵とパスフレーズはパイプでだけ受け渡して、画面とセッションのログに出さない。

```bash
V=$(chezmoi execute-template '{{ .op_vault }}'); I="Dotfiles - Vault"
op item create --category password --title "$I" --vault "$V" --generate-password='letters,digits,32' >/dev/null
pp() { op read "op://$V/$I/password"; }
gpg --batch --pinentry-mode loopback --passphrase-fd 3 --quick-generate-key "<github-user> (vault)" ed25519 sign never 3< <(pp)
FPR=$(gpg --list-secret-keys --with-colons "<github-user> (vault)" | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase-fd 3 --quick-add-key "$FPR" cv25519 encr never 3< <(pp)
gpg --batch --pinentry-mode loopback --passphrase-fd 3 --export-secret-keys --armor "$FPR" 3< <(pp) |
  op document create - --title "Dotfiles - Vault GPG key" --vault "$V" --file-name vault-gpg.asc >/dev/null
op item edit "$I" --vault "$V" "fingerprint[text]=$FPR" "drive_account[text]=<Google アカウント>" >/dev/null
chezmoi apply   # pinentry-mac 用のキーチェーン項目を作る
```

鍵をなくすと、暗号化したバックアップは復元できない。1Password の控えから一時的な `GNUPGHOME` に import し、保存したパスフレーズで署名できることを確かめておく。

## 手順

`<vault>` は `~/vaults/<name>`、`<fpr>` は vault 用の鍵の fingerprint。

1. 骨組みを作る。空のディレクトリには `.gitkeep` を置く（git は空のディレクトリを保存しないので、復元したときに消える）。

   ```
   _index.md
   daily/  decisions/  meetings/  notes/  attachments/
   ```

   personal ではさらに `knowledge/_index.md`・`projects/`・`_inbox/rule-proposals.md`・`owners.md` を作る。`owners.md` には自分の GitHub の owner だけを 1 行ずつ書き、クライアントの情報は書かない。

   クライアントの vault ではさらに `_vault.md` を作る。`run_after_31-vaults.sh` は `owners:` の行を読み、vault 名と異なる owner ごとに `~/vaults/<owner>` の symlink を作る。

   ```yaml
   ---
   owners: [<owner>, <別名の owner>]
   label: c1
   ---
   ```

   vault 名と owner には英数字・`.`・`_`・`-` だけを使う（それ以外はスクリプトが扱わない）。

2. Obsidian Git を入れる。personal があれば、その `.obsidian/` から `community-plugins.json` と `plugins/obsidian-git/` をコピーする。無ければ、GitHub のリリースから入れて設定を書く。`<tag>` は `gh release view --repo Vinzent03/obsidian-git --json tagName` の最新を使い、入れた tag を vault の `_index.md` の直近の決定に記録する（`main.js` は Obsidian の中で実行され、vault ごとほかの Mac にも配られるため、何を入れたかを残す）。手入力の commit に `human:` を付け、エージェントの `agent(...)` と区別する。

   ```bash
   P=<vault>/.obsidian/plugins/obsidian-git; mkdir -p "$P"
   for f in main.js manifest.json styles.css; do gh release download <tag> --repo Vinzent03/obsidian-git --pattern "$f" --dir "$P"; done
   printf '%s\n' '["obsidian-git"]' > <vault>/.obsidian/community-plugins.json
   printf '%s\n' '{"autoSaveInterval": 10, "commitMessage": "human: vault backup {{date}}", "autoCommitMessage": "human: vault backup {{date}}"}' > "$P/data.json"
   ```

   Obsidian Git が `git-remote-gcrypt` と `gpg` を見つけられるのは、`run_onchange_after_20-macos-defaults.sh` が GUI アプリの PATH に Homebrew を入れているから（反映には再起動が要る）。

3. git を初期化し、バックアップのディレクトリと gcrypt の remote を用意する。vault は公開しないので、dotfiles の SSH 署名（1Password の承認）を vault では使わない。改ざんの検出は gcrypt の GPG 署名が担う。gcrypt は `user.signingkey` を GPG の鍵として読むが、dotfiles はそこに SSH 鍵を設定しているので、vault 用の鍵を remote ごとに指定する。remote は最初の commit の前に足す。グローバルの pre-commit hook は、remote が無いリポジトリでクライアント名を検査し、クライアントの vault の `gcrypt::` の remote では検査しないため。

   ```bash
   git -C <vault> init
   git -C <vault> config commit.gpgsign false
   mkdir -p "<backup>"
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

5. 復元できることを確かめる。作業ツリーの外の一時ディレクトリに clone し、HEAD の commit が一致したら一時ディレクトリを消す（ディレクトリ全体は比べない。git は無視したファイルを保存しない）。participants を指定しない clone は、どの有効な署名も受け入れるので、指定する。

   ```bash
   git clone -c remote.origin.gcrypt-participants=<fpr> "gcrypt::<backup>" <tmp>/restore
   test "$(git -C <vault> rev-parse HEAD)" = "$(git -C <tmp>/restore rev-parse HEAD)"
   ```

6. `chezmoi apply` を実行する。Obsidian が起動していなければ、vault を Obsidian の一覧に登録し、クライアントの vault の別名の symlink を作る。ユーザーには、Obsidian で vault を開き、初回に出るコミュニティプラグインの有効化を承認してもらう。

## 別の Mac での復元

`install.sh`（または `chezmoi apply`）が、1Password と Google Drive のサインイン後に自動で行う。サインインの前は何もせず、次の apply でやり直す。手で復元するときも、必ず clone から始める（gcrypt の push は実質的に常に force になるので、`git init` した新しいリポジトリから push すると、バックアップの履歴を上書きする）。
