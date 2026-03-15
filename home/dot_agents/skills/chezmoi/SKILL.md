---
name: chezmoi
description: "chezmoi dotfiles管理の包括的スキル。chezmoiのsource directory、template（.tmplファイル）、source state attributes（dot_、private_、run_once_等）、.chezmoiexternal、.chezmoiignore、chezmoi設定ファイル、またはchezmoiで管理されるdotfilesを扱う際に使用する。chezmoiコマンド（chezmoi add、apply、diff、edit、init、update）、template関数（onepasswordRead、lookPath、output、include等）、複数マシン間でのdotfiles管理について言及された際にもトリガーする。ファイル命名規則、template、script、externals、暗号化、1Password連携を含むchezmoiワークフロー全体をカバーする。"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# chezmoi dotfiles管理

## Core Concepts

chezmoiは **source state** から **target state** を計算し、**destination directory**（ホームディレクトリ）に適用することでdotfilesを管理する。

- **Source directory**: chezmoiがsource stateを保存する場所（default: `~/.local/share/chezmoi`、`.chezmoiroot`で変更可能）
- **Config file**: マシン固有のデータ（`~/.config/chezmoi/chezmoi.toml`）
- **Target state**: source state + config + destination stateから計算される目標状態
- **Working tree**: gitのworking tree（通常はsource directoryと同じだが、`.chezmoiroot`使用時は親ディレクトリになる場合がある）

## Source State Attributes（ファイル命名規則）

source stateのファイル名・ディレクトリ名はprefixとsuffixで属性をencodeする。prefixの順序は重要。

### Prefix

| Prefix        | 効果                                                         |
|---------------|--------------------------------------------------------------|
| `after_`      | destination更新後にscriptを実行                               |
| `before_`     | destination更新前にscriptを実行                               |
| `create_`     | ファイルが存在しない場合のみ作成                               |
| `dot_`        | 先頭にdotを付与（例: `dot_zshrc` → `.zshrc`）                |
| `empty_`      | 空でもファイルを保持                                          |
| `encrypted_`  | source stateで暗号化されたファイル                             |
| `exact_`      | chezmoiが管理していないentryを削除（directory用）              |
| `executable_` | 実行権限を設定                                                |
| `external_`   | 子entryの属性を無視（git submodule用）                        |
| `literal_`    | prefix属性のparseを停止                                      |
| `modify_`     | 既存ファイルを変更するscript（stdinで受け取りstdoutに出力）    |
| `once_`       | 内容が一度もrun成功していない場合のみscriptを実行              |
| `onchange_`   | 前回のrun成功から内容が変更された場合のみscriptを実行          |
| `private_`    | group・otherのpermissionを削除（0700/0600）                   |
| `readonly_`   | write permissionを削除                                       |
| `remove_`     | target entryを削除                                           |
| `run_`        | scriptとして実行                                              |
| `symlink_`    | symlinkを作成（ファイル内容 = link先）                        |

### Suffix

| Suffix     | 効果                              |
|------------|-----------------------------------|
| `.tmpl`    | Go text/templateとして解釈        |
| `.literal` | suffix属性のparseを停止           |
| `.age`     | age暗号化使用時に除去される        |

### Target Type Reference

| Target type    | 許可されるprefix（順序通り）                                              | Suffix   |
|----------------|---------------------------------------------------------------------------|----------|
| Directory      | `remove_`, `external_`, `exact_`, `private_`, `readonly_`, `dot_`        | なし     |
| Regular file   | `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_`   | `.tmpl`  |
| Create file    | `create_`, `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Modify file    | `modify_`, `encrypted_`, `private_`, `readonly_`, `executable_`, `dot_`  | `.tmpl`  |
| Remove         | `remove_`, `dot_`                                                         | なし     |
| Script         | `run_`, `once_` or `onchange_`, `before_` or `after_`                    | `.tmpl`  |
| Symlink        | `symlink_`, `dot_`                                                        | `.tmpl`  |

## Application Order

1. Source stateを読み込む
2. Destination stateを読み込む
3. Target stateを計算する
4. `run_before_` scriptをalphabetical orderで実行
5. Entry（file、directory、external、script、symlink）をtarget nameのalphabetical orderで更新。Directoryはその中身より先に更新される。
6. `run_after_` scriptをalphabetical orderで実行

Target nameは全attributeを除去した後に判定される。例: `modify_dot_beta` のtargetは `.beta` で、`create_alpha` の `alpha` より前にsortされる。

## Template

chezmoiはGoの `text/template` 構文を[sprig関数](http://masterminds.github.io/sprig/)で拡張して使用する。

ファイルがtemplateとして扱われる条件:
- `.tmpl` suffixを持つ、または
- `.chezmoitemplates` directory内にある

### 主要Template変数

| Variable               | 説明                              |
|------------------------|-----------------------------------|
| `.chezmoi.os`          | OS: `darwin`, `linux`, `windows`  |
| `.chezmoi.arch`        | Architecture: `amd64`, `arm64`    |
| `.chezmoi.hostname`    | hostname（最初の `.` まで）        |
| `.chezmoi.fqdnHostname`| FQDN                             |
| `.chezmoi.username`    | 現在のuser名                      |
| `.chezmoi.homeDir`     | home directory path               |
| `.chezmoi.sourceDir`   | source directory path             |
| `.chezmoi.sourceFile`  | 現在のtemplateの相対path          |
| `.chezmoi.targetFile`  | target fileの絶対path             |
| `.chezmoi.kernel`      | kernel情報（Linux専用、WSL検出用） |
| `.chezmoi.osRelease`   | `/etc/os-release` data（Linux専用）|

custom変数はconfig fileの `[data]` sectionまたは `.chezmoidata.$FORMAT` fileで定義する。

### 主要Template関数

完全なreferenceは `references/template-functions.md` を参照。

**Data access:**
- `output "cmd" "arg"...` - commandを実行しstdoutを返す（template実行ごとにcache）
- `include "file"` - ファイル内容をそのまま返す（source directoryからの相対path）
- `includeTemplate "file" data` - templateを実行し結果を返す
- `fromJson`, `fromToml`, `fromYaml`, `fromIni` - data formatをparse
- `toPrettyJson`, `toToml`, `toYaml`, `toIni` - data formatにserialize
- `jq "query" input` - dataに対してjq queryを実行

**File system:**
- `lookPath "cmd"` - PATHからexecutableを検索（見つからない場合は空文字列）
- `findExecutable "cmd" (list "bin" ".local/bin")` - 特定directoryからexecutableを検索
- `stat path` - file情報を取得（存在しない場合はfalse）
- `joinPath .chezmoi.homeDir ".config"` - path要素を結合
- `glob "pattern"` - destination directoryでfileをmatch

**Text処理:**
- `comment "# " text` - 各行にcomment markerをprefix
- `warnf "format" args...` - stderrに警告を出力

**1Password連携:**
- `onepasswordRead "op://vault/item/field"` - `op read` 経由でsecretを読み取る
- `onepassword "UUID"` - itemを構造化dataとして取得
- `onepasswordDocument "UUID"` - documentの内容を取得
- `onepasswordDetailsFields "UUID"` - labelでindexされたfieldを取得
- `onepasswordItemFields "UUID"` - labelでindexされたitem fieldを取得

**Init-time関数（`chezmoi init` 実行時のみ）:**
- `promptString "prompt" [default]` - 文字列入力を要求
- `promptStringOnce . "key" "prompt" [default]` - 未設定の場合のみ入力を要求
- `promptBool "prompt" [default]` - boolean値を要求
- `promptChoice "prompt" choices [default]` - listから選択
- `promptChoiceOnce . "key" "prompt" choices [default]` - 未設定の場合のみ選択
- `stdinIsATTY` - 対話式terminalかcheck
- `writeToStdout "text"` - init中にstdoutに出力

### Template Directives

file固有のtemplate optionをcommentで設定:

```
chezmoi:template:left-delimiter="<<" right-delimiter=">>"
chezmoi:template:missing-key=zero
chezmoi:template:line-endings=native
```

### よく使うTemplate Pattern

**OS条件分岐:**
```
{{ if eq .chezmoi.os "darwin" -}}
# macOS設定
{{ else if eq .chezmoi.os "linux" -}}
# Linux設定
{{ end -}}
```

**commandの存在check:**
```
{{ if lookPath "mise" -}}
eval "$(mise activate zsh)"
{{ end -}}
```

**Whitespace制御:** `{{-` と `-}}` で前後のwhitespaceを除去する。

**Template内でliteral `{{` を記述:**
```
{{ "{{" }} and {{ "}}" }}
```

## Script

Scriptは `run_` prefixを持ち、`chezmoi apply` 時に実行される。

- `run_` - 毎回実行
- `run_once_` - 内容がrun成功したことがない場合のみ実行（SHA256で追跡）
- `run_onchange_` - 内容が変更された場合に実行（別ファイル名で同内容がrun済みでも再実行）
- `run_before_` / `run_after_` - file更新に対する実行timingを制御

Scriptには `#!` shebang行が必要。sourceでexecutable bitを設定する必要はない。

**ファイル変更時にscriptを実行:**
```bash
#!/bin/bash
# hash: {{ include "Brewfile" | sha256sum }}
brew bundle --file={{ joinPath .chezmoi.sourceDir "Brewfile" | quote }}
```

**Scriptを条件付きで無効化:** `.tmpl` scriptが空/whitespaceのみにrenderされると実行されない。

**環境変数:** chezmoiは `CHEZMOI=1`、`CHEZMOI_OS`、`CHEZMOI_ARCH` 等を設定する。追加の変数はconfigの `[scriptEnv]` で設定可能。

## Special Files / Directories

### File
- **`.chezmoiroot`** - subdirectoryをsource rootとして指定（1行、相対path）
- **`.chezmoiignore`** - 無視するpattern（template対応、`!` による除外）
- **`.chezmoiremove`** - 削除対象のpattern
- **`.chezmoiexternal.$FORMAT`** - 外部file/archiveのinclude
- **`.chezmoidata.$FORMAT`** - 静的template data（json/jsonc/toml/yaml、template非対応）
- **`.chezmoiversion`** - 必要最低chezmoiバージョン
- **`.chezmoi.$FORMAT.tmpl`** - config file template（`chezmoi init` 時に実行）

### Directory
- **`.chezmoitemplates/`** - 共有template（`{{ template "name" . }}` で利用可能）
- **`.chezmoidata/`** - data fileのdirectory（mergeされる、subdirectory対応）
- **`.chezmoiscripts/`** - target directoryを作成しないscript
- **`.chezmoiexternals/`** - external定義のdirectory

## Externals（`.chezmoiexternal.$FORMAT`）

URLからfileをsource stateの一部としてincludeする。Type:
- `file` - URLからの単一file
- `archive` - archive URLからのdirectory（tar、tar.gz、zip等）
- `archive-file` - archiveから抽出した単一file
- `git-repo` - git repositoryのclone/pull

主要field: `type`、`url`、`refreshPeriod`、`stripComponents`、`exact`、`include`、`exclude`、`executable`、`path`（archive-file用）、`checksum.sha256`。

詳細なexternal設定は `references/externals.md` を参照。

## Modify Template

`modify_` prefixを持ち `chezmoi:modify-template` を含むfileはmodify templateとして扱われる。既存fileの内容は `.chezmoi.stdin` で利用可能:

```
{{- /* chezmoi:modify-template */ -}}
{{ fromJson .chezmoi.stdin | setValueAtPath "key" "value" | toPrettyJson }}
```

Modify templateには `.tmpl` extensionを付けてはならない。

## Config File

場所: `~/.config/chezmoi/chezmoi.$FORMAT`。主要section:

```toml
sourceDir = "~/.dotfiles"     # source directoryをoverride
[data]                        # template変数
    email = "user@example.com"
[git]
    autoCommit = true         # 変更時にauto commit
    autoPush = true           # 変更時にauto push
[diff]
    exclude = ["scripts"]     # diff出力からscriptを除外
[scriptEnv]
    MY_VAR = "value"          # script用環境変数
[hooks.apply.post]
    command = "echo"          # hook command
    args = ["applied"]
```

## 主要Command

| Command | 説明 |
|---------|------|
| `chezmoi add [--template] FILE` | fileをsource stateに追加 |
| `chezmoi apply [-v]` | target stateをdestinationに適用 |
| `chezmoi diff` | targetとdestinationの差分を表示 |
| `chezmoi edit [--apply] FILE` | source fileを編集 |
| `chezmoi edit --watch FILE` | 保存時にauto applyで編集 |
| `chezmoi cd` | source directoryでshellを開く |
| `chezmoi init [--apply] REPO` | repositoryから初期化 |
| `chezmoi update` | 変更をpullしてapply |
| `chezmoi data` | template dataを表示 |
| `chezmoi managed` | 管理中のfileを一覧表示 |
| `chezmoi unmanaged` | 管理外のfileを一覧表示 |
| `chezmoi re-add` | 変更されたtargetをsourceに再追加 |
| `chezmoi chattr +template FILE` | file attributeを変更 |
| `chezmoi execute-template 'TPL'` | template式をtest |
| `chezmoi doctor` | 問題をcheck |
| `chezmoi forget FILE` | source stateから削除 |
| `chezmoi merge FILE` | 三方向merge |
| `chezmoi cat FILE` | fileのtarget stateを表示 |
| `chezmoi status` | targetのstatusを表示 |
| `chezmoi state delete-bucket --bucket=scriptState` | run_onceのstateをclear |
| `chezmoi state delete-bucket --bucket=entryState` | run_onchangeのstateをclear |

## Troubleshooting

- **Template scriptで `exec format error`**: `#!` の前の改行を `{{- }}` で除去する（minus記号でwhitespaceをtrim）
- **Script実行時に `permission denied`**: `/tmp` が `noexec` の場合、configで `scriptTempDir` を指定
- **`timeout` error**: 別のchezmoi instanceが `chezmoistate.boltdb` のlockを保持している
- **diffの色が壊れる**: `LESS=-R` を設定するか、configで `pager = "less -R"` を指定
- **`chezmoi edit` で空buffer**: editorをforegroundで動作するよう設定（`vim -f`、`code --wait`）
- **追加時に `no such file or directory`**: source stateで親directoryを手動作成し `.keep` を配置
- **Nix/Termuxで `/bin/bash` が見つからない**: template scriptで `#!{{ lookPath "bash" }}` を使用
- **SSH configがgroup writable**: chezmoi configで `umask = 0o022` を指定

Template関数、external、commandの完全なreferenceは `references/` 内のfileを参照。

## このスキルの更新

chezmoiがupdateされ公式ドキュメントが変更された場合、`references/update-procedure.md` に記載された更新手順を実行してこのスキルの内容を更新する。手順では `twpayne/chezmoi` から `gh api` 経由で最新ドキュメントをdownloadし、全skill fileを再生成する。
