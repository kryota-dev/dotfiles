# chezmoi External Reference

## 概要

`.chezmoiexternal.$FORMAT` file（optional `.tmpl` extension付き）は、source stateの一部として外部fileやarchiveをincludeする定義を行う。常にtemplateとして解釈される。

複数の `.chezmoiexternal.$FORMAT` fileがsource state内の任意の場所に存在可能。Entryはfileのdirectoryからの相対target nameでindexされる。

## Entry Field

| Field                        | Type     | Default      | 説明                                                  |
|------------------------------|----------|--------------|------------------------------------------------------|
| `type`                       | string   | required     | `file`、`archive`、`archive-file`、または `git-repo`   |
| `url`                        | string   | required     | https://、http://、または file:// URL                  |
| `urls`                       | []string | none         | 順番に試行されるfallback URL                           |
| `refreshPeriod`              | duration | `0`（none）   | 再download間隔（`24h`、`168h`、`672h`）                |
| `executable`                 | bool     | false        | 実行権限を設定                                         |
| `private`                    | bool     | false        | private permissionを設定                               |
| `readonly`                   | bool     | false        | readonly permissionを設定                              |
| `encrypted`                  | bool     | false        | externalが暗号化されている                              |
| `decompress`                 | string   | none         | `bzip2`、`gzip`、`xz`、または `zstd`                  |
| `exact`                      | bool     | false        | directoryをexactとして扱う（管理外entryを削除）         |
| `stripComponents`            | int      | 0            | archiveから先頭path componentを除去                    |
| `format`                     | string   | autodetect   | archive format: tar、tar.gz、tgz、zip等               |
| `path`                       | string   | none         | archive内のfile path（`archive-file` 用）              |
| `include`                    | []string | none         | archiveからincludeするpattern                         |
| `exclude`                    | []string | none         | archiveから除外するpattern                            |
| `checksum.sha256`            | string   | none         | 期待されるSHA256 checksum                              |
| `checksum.sha384`            | string   | none         | 期待されるSHA384 checksum                              |
| `checksum.sha512`            | string   | none         | 期待されるSHA512 checksum                              |
| `checksum.size`              | int      | none         | 期待されるsize（byte）                                 |
| `clone.args`                 | []string | none         | `git clone` への追加args                               |
| `pull.args`                  | []string | none         | `git pull` への追加args                                |
| `filter.command`             | string   | none         | contentのfilter command                               |
| `filter.args`                | []string | none         | filter commandのargs                                  |
| `archive.extractAppleDouble` | bool     | false        | AppleDouble fileを抽出                                |
| `targetPath`                 | string   | none         | target pathをoverride（複数entryから1つのdirectoryへ）  |

## Include/Exclude Algorithm

1. 名前が `exclude` patternにmatch → 除外（directoryの場合は全子要素も除外）
2. 名前が `include` patternにmatch → include
3. `include` のみ指定されている場合 → 除外
4. `exclude` のみ指定されている場合 → include
5. それ以外 → include

## Type: `file`

URLからの単一file。

```toml
[".vim/autoload/plug.vim"]
    type = "file"
    url = "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"
    refreshPeriod = "168h"
```

## Type: `archive`

Archive URLからのdirectory。

```toml
[".oh-my-zsh"]
    type = "archive"
    url = "https://github.com/ohmyzsh/ohmyzsh/archive/master.tar.gz"
    exact = true
    stripComponents = 1
    refreshPeriod = "168h"

[".oh-my-zsh/custom/plugins/zsh-syntax-highlighting"]
    type = "archive"
    url = "https://github.com/zsh-users/zsh-syntax-highlighting/archive/master.tar.gz"
    exact = true
    stripComponents = 1
    refreshPeriod = "168h"
    include = ["*/*.zsh", "*/.version", "*/.revision-hash", "*/highlighters/**"]
```

## Type: `archive-file`

Archiveから抽出した単一file。`path` fieldが必要。

```toml
{{ $ageVersion := "1.1.1" -}}
[".local/bin/age"]
    type = "archive-file"
    url = "https://github.com/FiloSottile/age/releases/download/v{{ $ageVersion }}/age-v{{ $ageVersion }}-{{ .chezmoi.os }}-{{ .chezmoi.arch }}.tar.gz"
    path = "age/age"
    executable = true
```

注意: archive内のpathを慎重に確認すること。`./` prefixがあるものとないものがある。

## Type: `git-repo`

Git repositoryのclone/pull。Targetが存在しない場合は `git clone`、存在する場合は `git pull` を使用。

```toml
[".vim/pack/alker0/chezmoi.vim"]
    type = "git-repo"
    url = "https://github.com/alker0/chezmoi.vim.git"
    refreshPeriod = "168h"
    [".vim/pack/alker0/chezmoi.vim".pull]
        args = ["--ff-only"]
```

制限事項:
- `$PATH` に `git` が必要
- 管理をgitに委譲（`chezmoi diff` や `chezmoi dump` に表示されない）
- `chezmoi unmanaged` でlist表示される
- directory内の追加fileを管理できない

## `targetPath` で複数sourceから1つのdirectoryへ

```toml
[p10k_fonts]
    type = "archive"
    url = "https://github.com/romkatv/powerlevel10k-media/archive/master.tar.gz"
    stripComponents = 1
    include = ["*/*.ttf"]
    targetPath = "Library/Fonts"
[source_code_pro]
    type = "archive"
    url = "https://github.com/adobe-fonts/source-code-pro/archive/master.tar.gz"
    stripComponents = 2
    include = ["**/*.ttf"]
    targetPath = "Library/Fonts"
```

## Filterの使用

```toml
[".Software/anki"]
    type = "archive"
    url = "https://example.com/anki.tar.zst"
    filter.command = "zstd"
    filter.args = ["-d"]
    format = "tar"
```

## Private Git Repository

`stat` を使って条件付きでinclude:

```toml
{{ if stat (joinPath .chezmoi.homeDir ".ssh" "id_rsa") }}
[".path/to/repo"]
    type = "git-repo"
    url = "git@private.com:org/repo.git"
{{ end }}
```

## Refresh

- Default refresh periodは `0`（auto refreshなし）
- 強制refresh: `chezmoi apply -R` または `chezmoi apply --refresh-externals`
- 一般的なperiod: `24h`（daily）、`168h`（weekly）、`672h`（4 weeks）
- Tag付き/version付きURLにはrefresh period不要（versionを手動で更新）

## `.chezmoiexternals/` Directory

`.chezmoiexternals/` directory内のfileは、source directoryからの相対pathで `.chezmoiexternal.$FORMAT` fileとして扱われる。directory自体のsubdirectoryに対するexternalはsupportされていない。
