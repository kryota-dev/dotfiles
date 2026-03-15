---
name: chezmoi
description: "Comprehensive chezmoi dotfiles management skill. Use when working with chezmoi source directories, templates (.tmpl files), source state attributes (dot_, private_, run_once_, etc.), .chezmoiexternal, .chezmoiignore, chezmoi config files, or any dotfiles managed by chezmoi. Also trigger when the user mentions chezmoi commands (chezmoi add, apply, diff, edit, init, update), template functions (onepasswordRead, lookPath, output, include, etc.), or asks about managing dotfiles across multiple machines. This skill covers the full chezmoi workflow: file naming conventions, templates, scripts, externals, encryption, and 1Password integration."
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# chezmoi Dotfiles Management

## Core Concepts

chezmoi manages dotfiles by computing a **target state** from a **source state** and applying it to the **destination directory** (your home directory).

- **Source directory**: Where chezmoi stores the source state (`~/.local/share/chezmoi` by default, can be overridden with `.chezmoiroot`)
- **Config file**: Machine-specific data (`~/.config/chezmoi/chezmoi.toml`)
- **Target state**: Desired state computed from source state + config + destination state
- **Working tree**: The git working tree (normally same as source directory, but can be a parent when using `.chezmoiroot`)

## Source State Attributes (File Naming Conventions)

File and directory names in the source state encode attributes via prefixes and suffixes. The order of prefixes matters.

### Prefixes

| Prefix        | Effect                                                       |
|---------------|--------------------------------------------------------------|
| `after_`      | Run script after updating destination                        |
| `before_`     | Run script before updating destination                       |
| `create_`     | Create file only if it doesn't exist                         |
| `dot_`        | Rename to leading dot (e.g. `dot_zshrc` -> `.zshrc`)        |
| `empty_`      | Keep file even if empty                                      |
| `encrypted_`  | File is encrypted in source state                            |
| `exact_`      | Remove anything not managed by chezmoi (directories)         |
| `executable_` | Set executable permissions                                   |
| `external_`   | Ignore attributes in child entries (for git submodules)      |
| `literal_`    | Stop parsing prefix attributes                               |
| `modify_`     | Script that modifies existing file (receives stdin, writes stdout) |
| `once_`       | Run script only if contents never ran successfully before    |
| `onchange_`   | Run script only if contents changed since last successful run |
| `private_`    | Remove group and world permissions (0700/0600)               |
| `readonly_`   | Remove write permissions                                     |
| `remove_`     | Remove the target entry                                      |
| `run_`        | Execute as script                                            |
| `symlink_`    | Create symlink (file contents = link target)                 |

### Suffixes

| Suffix     | Effect                            |
|------------|-----------------------------------|
| `.tmpl`    | Interpret as Go text/template     |
| `.literal` | Stop parsing suffix attributes    |
| `.age`     | Stripped when age encryption used |

### Target Type Reference

| Target type   | Allowed prefixes (in order)                                               | Suffixes |
|---------------|---------------------------------------------------------------------------|----------|
| Directory     | `remove_`, `external_`, `exact_`, `private_`, `readonly_`, `dot_`        | none     |
| Regular file  | `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_`   | `.tmpl`  |
| Create file   | `create_`, `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Modify file   | `modify_`, `encrypted_`, `private_`, `readonly_`, `executable_`, `dot_`  | `.tmpl`  |
| Remove        | `remove_`, `dot_`                                                         | none     |
| Script        | `run_`, `once_` or `onchange_`, `before_` or `after_`                    | `.tmpl`  |
| Symlink       | `symlink_`, `dot_`                                                        | `.tmpl`  |

## Application Order

1. Read source state
2. Read destination state
3. Compute target state
4. Run `run_before_` scripts in alphabetical order
5. Update entries (files, directories, externals, scripts, symlinks) in alphabetical order of target name. Directories are updated before their contents.
6. Run `run_after_` scripts in alphabetical order

Target names are considered after all attributes are stripped. For example, `modify_dot_beta` targets `.beta`, which sorts before `alpha` from `create_alpha`.

## Templates

chezmoi uses Go's `text/template` syntax extended with [sprig functions](http://masterminds.github.io/sprig/).

A file is treated as a template when:
- It has a `.tmpl` suffix, OR
- It is in the `.chezmoitemplates` directory

### Key Template Variables

| Variable               | Description                              |
|------------------------|------------------------------------------|
| `.chezmoi.os`          | OS: `darwin`, `linux`, `windows`         |
| `.chezmoi.arch`        | Architecture: `amd64`, `arm64`           |
| `.chezmoi.hostname`    | Hostname (up to first `.`)               |
| `.chezmoi.fqdnHostname`| Fully qualified domain name              |
| `.chezmoi.username`    | Current username                         |
| `.chezmoi.homeDir`     | Home directory path                      |
| `.chezmoi.sourceDir`   | Source directory path                    |
| `.chezmoi.sourceFile`  | Relative path of current template        |
| `.chezmoi.targetFile`  | Absolute path of target file             |
| `.chezmoi.kernel`      | Kernel info (Linux only, useful for WSL) |
| `.chezmoi.osRelease`   | `/etc/os-release` data (Linux only)      |

Custom variables are defined in the config file under `[data]` or in `.chezmoidata.$FORMAT` files.

### Essential Template Functions

For complete reference, see `references/template-functions.md`.

**Data access:**
- `output "cmd" "arg"...` - Execute command, return stdout (cached per template execution)
- `include "file"` - Return literal file contents (relative to source dir)
- `includeTemplate "file" data` - Execute template and return result
- `fromJson`, `fromToml`, `fromYaml`, `fromIni` - Parse data formats
- `toPrettyJson`, `toToml`, `toYaml`, `toIni` - Serialize data formats
- `jq "query" input` - Run jq query against data

**File system:**
- `lookPath "cmd"` - Find executable in PATH (empty string if not found)
- `findExecutable "cmd" (list "bin" ".local/bin")` - Find executable in specific dirs
- `stat path` - Get file info (returns false if not exists)
- `joinPath .chezmoi.homeDir ".config"` - Join path elements
- `glob "pattern"` - Match files in destination dir

**Text processing:**
- `comment "# " text` - Prefix each line with comment marker
- `warnf "format" args...` - Print warning to stderr

**1Password integration:**
- `onepasswordRead "op://vault/item/field"` - Read secret via `op read`
- `onepassword "UUID"` - Get item as structured data
- `onepasswordDocument "UUID"` - Get document contents
- `onepasswordDetailsFields "UUID"` - Get fields indexed by label
- `onepasswordItemFields "UUID"` - Get item fields indexed by label

**Init-time functions (only during `chezmoi init`):**
- `promptString "prompt" [default]` - Ask for string input
- `promptStringOnce . "key" "prompt" [default]` - Ask only if not already set
- `promptBool "prompt" [default]` - Ask for boolean
- `promptChoice "prompt" choices [default]` - Ask to choose from list
- `promptChoiceOnce . "key" "prompt" choices [default]` - Choose only if not set
- `stdinIsATTY` - Check if interactive terminal
- `writeToStdout "text"` - Write to stdout during init

### Template Directives

Set per-file template options with comments like:

```
chezmoi:template:left-delimiter="<<" right-delimiter=">>"
chezmoi:template:missing-key=zero
chezmoi:template:line-endings=native
```

### Common Template Patterns

**OS-conditional content:**
```
{{ if eq .chezmoi.os "darwin" -}}
# macOS config
{{ else if eq .chezmoi.os "linux" -}}
# Linux config
{{ end -}}
```

**Check if command exists:**
```
{{ if lookPath "mise" -}}
eval "$(mise activate zsh)"
{{ end -}}
```

**Whitespace control:** Use `{{-` and `-}}` to trim surrounding whitespace.

**Literal `{{` in templates:**
```
{{ "{{" }} and {{ "}}" }}
```

## Scripts

Scripts have the `run_` prefix and are executed during `chezmoi apply`.

- `run_` - Run every time
- `run_once_` - Run only if contents haven't run successfully before (tracks SHA256)
- `run_onchange_` - Run when contents change (even if same content ran before under different name)
- `run_before_` / `run_after_` - Control execution timing relative to file updates

Scripts must include a `#!` shebang line. They don't need the executable bit set in source.

**Trigger script on file change:**
```bash
#!/bin/bash
# hash: {{ include "Brewfile" | sha256sum }}
brew bundle --file={{ joinPath .chezmoi.sourceDir "Brewfile" | quote }}
```

**Disable script conditionally:** If a `.tmpl` script renders to empty/whitespace, it won't execute.

**Environment variables:** chezmoi sets `CHEZMOI=1`, `CHEZMOI_OS`, `CHEZMOI_ARCH`, etc. Extra vars can be set in `[scriptEnv]` config.

## Special Files and Directories

### Files
- **`.chezmoiroot`** - Specifies subdirectory as source root (single line, relative path)
- **`.chezmoiignore`** - Patterns to ignore (supports templates, `!` exclusions)
- **`.chezmoiremove`** - Patterns of targets to remove
- **`.chezmoiexternal.$FORMAT`** - External files/archives to include
- **`.chezmoidata.$FORMAT`** - Static template data (json/jsonc/toml/yaml, NOT templates)
- **`.chezmoiversion`** - Minimum chezmoi version required
- **`.chezmoi.$FORMAT.tmpl`** - Config file template (executed during `chezmoi init`)

### Directories
- **`.chezmoitemplates/`** - Shared templates (available via `{{ template "name" . }}`)
- **`.chezmoidata/`** - Directory of data files (merged, supports subdirs)
- **`.chezmoiscripts/`** - Scripts that don't create target directories
- **`.chezmoiexternals/`** - Directory of external definitions

## Externals (`.chezmoiexternal.$FORMAT`)

Include files from URLs as if part of source state. Types:
- `file` - Single file from URL
- `archive` - Directory from archive URL (tar, tar.gz, zip, etc.)
- `archive-file` - Single file extracted from archive
- `git-repo` - Clone/pull a git repository

Key fields: `type`, `url`, `refreshPeriod`, `stripComponents`, `exact`, `include`, `exclude`, `executable`, `path` (for archive-file), `checksum.sha256`.

For detailed external configuration, see `references/externals.md`.

## Modify Templates

Files with `modify_` prefix containing `chezmoi:modify-template` are treated as modify templates. The existing file content is available as `.chezmoi.stdin`:

```
{{- /* chezmoi:modify-template */ -}}
{{ fromJson .chezmoi.stdin | setValueAtPath "key" "value" | toPrettyJson }}
```

Modify templates must NOT have a `.tmpl` extension.

## Configuration File

Located at `~/.config/chezmoi/chezmoi.$FORMAT`. Key sections:

```toml
sourceDir = "~/.dotfiles"     # Override source directory
[data]                        # Template variables
    email = "user@example.com"
[git]
    autoCommit = true         # Auto-commit on changes
    autoPush = true           # Auto-push on changes
[diff]
    exclude = ["scripts"]     # Exclude scripts from diff output
[scriptEnv]
    MY_VAR = "value"          # Environment variables for scripts
[hooks.apply.post]
    command = "echo"          # Hook commands
    args = ["applied"]
```

## Common Commands

| Command | Description |
|---------|-------------|
| `chezmoi add [--template] FILE` | Add file to source state |
| `chezmoi apply [-v]` | Apply target state to destination |
| `chezmoi diff` | Show differences between target and destination |
| `chezmoi edit [--apply] FILE` | Edit source file |
| `chezmoi edit --watch FILE` | Edit with auto-apply on save |
| `chezmoi cd` | Open shell in source directory |
| `chezmoi init [--apply] REPO` | Initialize from repo |
| `chezmoi update` | Pull and apply changes |
| `chezmoi data` | Show template data |
| `chezmoi managed` | List managed files |
| `chezmoi unmanaged` | List unmanaged files |
| `chezmoi re-add` | Re-add modified targets to source |
| `chezmoi chattr +template FILE` | Change file attributes |
| `chezmoi execute-template 'TPL'` | Test template expressions |
| `chezmoi doctor` | Check for problems |
| `chezmoi forget FILE` | Remove from source state |
| `chezmoi merge FILE` | Three-way merge |
| `chezmoi cat FILE` | Show target state of file |
| `chezmoi status` | Show status of targets |
| `chezmoi state delete-bucket --bucket=scriptState` | Clear run_once state |
| `chezmoi state delete-bucket --bucket=entryState` | Clear run_onchange state |

## Troubleshooting

- **`exec format error` in template scripts**: Remove newline before `#!` by using `{{- }}` (minus sign for whitespace trimming)
- **`permission denied` executing scripts**: Set `scriptTempDir` in config if `/tmp` has `noexec`
- **`timeout` errors**: Another chezmoi instance holds the lock on `chezmoistate.boltdb`
- **Broken diff colors**: Set `LESS=-R` or configure `pager = "less -R"` in config
- **Blank buffer in `chezmoi edit`**: Configure editor to stay in foreground (`vim -f`, `code --wait`)
- **`no such file or directory` when adding**: Create parent directory manually in source state with `.keep`
- **`/bin/bash` not found on Nix/Termux**: Use `#!{{ lookPath "bash" }}` in template scripts
- **Group-writable SSH config**: Set `umask = 0o022` in chezmoi config

For complete reference documentation on template functions, externals, and commands, see the files in `references/`.

## Updating This Skill

When chezmoi is updated and the official documentation changes, run the update procedure described in `references/update-procedure.md` to refresh this skill's content. The procedure downloads the latest documentation from `twpayne/chezmoi` via `gh api` and regenerates all skill files.
