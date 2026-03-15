# chezmoi Externals Reference

## Overview

`.chezmoiexternal.$FORMAT` files (with optional `.tmpl` extension) define external files and archives to include as if they were part of the source state. They are always interpreted as templates.

Multiple `.chezmoiexternal.$FORMAT` files can exist anywhere in the source state. Entries are indexed by target name relative to the file's directory.

## Entry Fields

| Field                        | Type     | Default      | Description                                            |
|------------------------------|----------|--------------|--------------------------------------------------------|
| `type`                       | string   | required     | `file`, `archive`, `archive-file`, or `git-repo`      |
| `url`                        | string   | required     | https://, http://, or file:// URL                      |
| `urls`                       | []string | none         | Fallback URLs tried in order                           |
| `refreshPeriod`              | duration | `0` (never)  | How often to re-download (`24h`, `168h`, `672h`)       |
| `executable`                 | bool     | false        | Set executable permissions                             |
| `private`                    | bool     | false        | Set private permissions                                |
| `readonly`                   | bool     | false        | Set readonly permissions                               |
| `encrypted`                  | bool     | false        | External is encrypted                                  |
| `decompress`                 | string   | none         | `bzip2`, `gzip`, `xz`, or `zstd`                      |
| `exact`                      | bool     | false        | Treat directories as exact (remove unmanaged entries)  |
| `stripComponents`            | int      | 0            | Strip leading path components from archive             |
| `format`                     | string   | autodetect   | Archive format: tar, tar.gz, tgz, zip, etc.           |
| `path`                       | string   | none         | Path to file within archive (for `archive-file`)       |
| `include`                    | []string | none         | Patterns to include from archive                       |
| `exclude`                    | []string | none         | Patterns to exclude from archive                       |
| `checksum.sha256`            | string   | none         | Expected SHA256 checksum                               |
| `checksum.sha384`            | string   | none         | Expected SHA384 checksum                               |
| `checksum.sha512`            | string   | none         | Expected SHA512 checksum                               |
| `checksum.size`              | int      | none         | Expected size in bytes                                 |
| `clone.args`                 | []string | none         | Extra args to `git clone`                              |
| `pull.args`                  | []string | none         | Extra args to `git pull`                               |
| `filter.command`             | string   | none         | Filter command for content                             |
| `filter.args`                | []string | none         | Args for filter command                                |
| `archive.extractAppleDouble` | bool     | false        | Extract AppleDouble files                              |
| `targetPath`                 | string   | none         | Override target path (allows multiple entries to one dir) |

## Include/Exclude Algorithm

1. If name matches any `exclude` pattern -> excluded (and all children if directory)
2. If name matches any `include` pattern -> included
3. If only `include` specified -> excluded
4. If only `exclude` specified -> included
5. Otherwise -> included

## Type: `file`

Single file from URL.

```toml
[".vim/autoload/plug.vim"]
    type = "file"
    url = "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"
    refreshPeriod = "168h"
```

## Type: `archive`

Directory from archive URL.

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

Single file extracted from archive. Requires `path` field.

```toml
{{ $ageVersion := "1.1.1" -}}
[".local/bin/age"]
    type = "archive-file"
    url = "https://github.com/FiloSottile/age/releases/download/v{{ $ageVersion }}/age-v{{ $ageVersion }}-{{ .chezmoi.os }}-{{ .chezmoi.arch }}.tar.gz"
    path = "age/age"
    executable = true
```

Note: Check archive paths carefully. Some archives use `./` prefix, others don't.

## Type: `git-repo`

Clone/pull a git repository. Uses `git clone` if target doesn't exist, `git pull` if it does.

```toml
[".vim/pack/alker0/chezmoi.vim"]
    type = "git-repo"
    url = "https://github.com/alker0/chezmoi.vim.git"
    refreshPeriod = "168h"
    [".vim/pack/alker0/chezmoi.vim".pull]
        args = ["--ff-only"]
```

Limitations:
- Requires `git` in `$PATH`
- Delegates management to git (not shown in `chezmoi diff` or `chezmoi dump`)
- Listed by `chezmoi unmanaged`
- Cannot manage extra files in the directory

## Using `targetPath` for Multiple Sources to One Directory

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

## Using Filters

```toml
[".Software/anki"]
    type = "archive"
    url = "https://example.com/anki.tar.zst"
    filter.command = "zstd"
    filter.args = ["-d"]
    format = "tar"
```

## Private Git Repos

Use `stat` to conditionally include:

```toml
{{ if stat (joinPath .chezmoi.homeDir ".ssh" "id_rsa") }}
[".path/to/repo"]
    type = "git-repo"
    url = "git@private.com:org/repo.git"
{{ end }}
```

## Refreshing

- Default refresh period is `0` (never auto-refresh)
- Force refresh: `chezmoi apply -R` or `chezmoi apply --refresh-externals`
- Typical periods: `24h` (daily), `168h` (weekly), `672h` (4 weeks)
- For tagged/versioned URLs, no refresh period needed (bump version manually)

## `.chezmoiexternals/` Directory

Files in `.chezmoiexternals/` directories are treated as `.chezmoiexternal.$FORMAT` files relative to the source directory. Does not support externals for subdirectories within the directory itself.
