# chezmoi Command Reference

## 目次
1. [Core Workflow](#core-workflow)
2. [編集と管理](#編集と管理)
3. [検査とDebug](#検査とdebug)
4. [State管理](#state管理)
5. [Git連携](#git連携)
6. [暗号化](#暗号化)

---

## Core Workflow

### `chezmoi init [repo]`
chezmoiを初期化する。`repo` が指定された場合、source directoryとしてcloneする。
- `--apply` - init後にapply
- `--one-shot` - init、apply後にchezmoiのdataを削除（ephemeral環境用）
- `.chezmoi.$FORMAT.tmpl` が存在する場合、configを生成する

### `chezmoi add [flags] targets...`
Targetをsource stateに追加する。
- `--template` - templateとして追加
- `--encrypt` - fileを暗号化
- `--exact` - directoryをexactとして追加
- `--follow` - symlinkをfollow

### `chezmoi apply [targets...]`
Destinationをtarget stateに合わせて更新する。
- `-v` / `--verbose` - 変更内容を表示
- `--dry-run` / `-n` - 変更を実行しない
- `-R` / `--refresh-externals` - externalを強制再download

### `chezmoi update`
最新の変更をpullしてapplyする。`git pull --autostash --rebase` を実行後、`chezmoi apply` を実行。

### `chezmoi diff [targets...]`
Target stateとdestinationの差分を表示する。
- `--reverse` - diffの方向を反転
- `--pager` / `--no-pager` - pagerの制御

## 編集と管理

### `chezmoi edit [targets...]`
Source fileを編集する。引数なしの場合、source directoryを開く。
- `--apply` - editor終了後に変更をapply
- `--watch` - 保存のたびにapply
- 暗号化/復号化を透過的に処理
- 正しいsyntax highlightのためtargetに似たfile名でtemp fileを作成

### `chezmoi re-add [targets...]`
変更されたtarget fileをsource stateに再追加する。Templateでは動作しない。

### `chezmoi chattr attributes targets...`
Source fileのattributeを変更する。
- `+template` / `-template` - template attributeの追加/削除
- `+executable` / `-executable`
- `+private` / `-private`
- `+readonly` / `-readonly`
- `+empty` / `-empty`
- `+exact` / `-exact`
- `+encrypted` / `-encrypted`

### `chezmoi forget targets...`
Targetをsource stateから削除する（destinationからは削除しない）。

### `chezmoi destroy targets...`
Source stateとdestinationの両方から削除する。

### `chezmoi manage targets...`
`add` のalias。

### `chezmoi unmanage targets...`
`forget` のalias。

### `chezmoi merge targets...`
Source、target、destination state間の三方向merge。

### `chezmoi merge-all`
Sourceとdestination間で異なる全fileをmerge。

## 検査とDebug

### `chezmoi cat targets...`
Fileのtarget state（applyされる内容）を出力する。

### `chezmoi diff`
次回 `apply` で変更される内容を表示する。

### `chezmoi status [targets...]`
Targetのstatusを表示する。Status code:
- `A` - Added
- `D` - Deleted
- `M` - Modified
- `R` - Script to Run

### `chezmoi data [--format json|toml|yaml]`
Template dataを出力する。Default formatはJSON。

### `chezmoi managed [--path-style absolute|relative|source-absolute|source-relative]`
全managed entryをlist表示する。

### `chezmoi unmanaged`
chezmoiが管理していないdestination内のentryをlist表示する。

### `chezmoi ignored`
`.chezmoiignore` で無視されているentryをlist表示する。

### `chezmoi source-path [targets...]`
Targetのsource pathを表示する。

### `chezmoi target-path [sources...]`
Source fileのtarget pathを表示する。

### `chezmoi execute-template [templates...]`
Template stringを実行し結果を表示する。引数なしの場合、stdinから読み取る。
- `--init` - init-time関数を有効化
- `--promptString key=value` - test用にprompt responseを事前設定
- `--promptBool key=value`
- `--promptInt key=value`
- `--promptChoice key=value`

### `chezmoi doctor`
潜在的な問題をcheckする。各項目について `ok`、`warning`、または `error` を報告。

### `chezmoi dump [targets...]`
Target stateをJSONでdumpする。

### `chezmoi dump-config`
Parse済みconfigをdumpする。

### `chezmoi cat-config`
Config fileの内容を表示する。

### `chezmoi verify`
Destinationがtarget stateと一致するかverifyする。一致の場合はexit code 0、不一致の場合は1。

## State管理

### `chezmoi state`
chezmoiのpersistent state databaseを管理する。
- `chezmoi state delete-bucket --bucket=scriptState` - run_once_のstateをclear
- `chezmoi state delete-bucket --bucket=entryState` - run_onchange_のstateをclear
- `chezmoi state dump` - 全stateをdump

## Git連携

### `chezmoi cd`
Source directoryでshellを開く。Shellを終了すると元に戻る。

### `chezmoi git -- args...`
Source directoryでgit commandを実行する。chezmoiのflagとgitのflagを分離するために `--` を使用。
```
chezmoi git -- add .
chezmoi git -- commit -m "Update dotfiles"
chezmoi git -- push
```

### Auto commit/push
Chezmoi configで設定:
```toml
[git]
    autoCommit = true
    autoPush = true
    commitMessageTemplate = "{{ promptString \"Commit message\" }}"
```

## 暗号化

### `chezmoi encrypt file`
Fileを暗号化する。

### `chezmoi decrypt file`
Fileを復号化する。

### age暗号化設定
```toml
encryption = "age"
[age]
    identity = "~/.config/chezmoi/key.txt"
    recipient = "age1..."
```

Keyの生成: `chezmoi age-keygen --output ~/.config/chezmoi/key.txt`

## その他のCommand

### `chezmoi import archive`
Archiveをsource stateにimportする。
- `--strip-components N` - 先頭path componentを除去
- `--destination path` - destination prefix

### `chezmoi archive [--format tar|zip]`
Target stateのarchiveを作成する。

### `chezmoi completion shell`
Shell completion scriptを生成する。

### `chezmoi generate git-commit-message`
変更からcommit messageを生成する。

### `chezmoi secret`
Secret managerと連携する。Subcommandはmanagerにより異なる。
