# chezmoi Commands Reference

## Table of Contents
1. [Core Workflow](#core-workflow)
2. [Editing and Managing](#editing-and-managing)
3. [Inspection and Debugging](#inspection-and-debugging)
4. [State Management](#state-management)
5. [Git Integration](#git-integration)
6. [Encryption](#encryption)

---

## Core Workflow

### `chezmoi init [repo]`
Initialize chezmoi. If `repo` is given, clone it as source directory.
- `--apply` - Apply after init
- `--one-shot` - Init, apply, then remove chezmoi data (for ephemeral environments)
- Generates config from `.chezmoi.$FORMAT.tmpl` if it exists

### `chezmoi add [flags] targets...`
Add targets to the source state.
- `--template` - Add as template
- `--encrypt` - Encrypt the file
- `--exact` - Add directory as exact
- `--follow` - Follow symlinks

### `chezmoi apply [targets...]`
Update destination to match target state.
- `-v` / `--verbose` - Print changes
- `--dry-run` / `-n` - Don't make changes
- `-R` / `--refresh-externals` - Force re-download externals

### `chezmoi update`
Pull latest changes and apply. Runs `git pull --autostash --rebase` then `chezmoi apply`.

### `chezmoi diff [targets...]`
Show differences between target state and destination.
- `--reverse` - Reverse diff direction
- `--pager` / `--no-pager` - Control pager

## Editing and Managing

### `chezmoi edit [targets...]`
Edit source file(s). With no args, opens source directory.
- `--apply` - Apply changes after editor exits
- `--watch` - Apply on every save
- Handles encryption/decryption transparently
- Creates temp files with target-like names for correct syntax highlighting

### `chezmoi re-add [targets...]`
Re-add modified target files back to source state. Does NOT work with templates.

### `chezmoi chattr attributes targets...`
Change attributes on source files.
- `+template` / `-template` - Add/remove template attribute
- `+executable` / `-executable`
- `+private` / `-private`
- `+readonly` / `-readonly`
- `+empty` / `-empty`
- `+exact` / `-exact`
- `+encrypted` / `-encrypted`

### `chezmoi forget targets...`
Remove targets from source state (does not remove from destination).

### `chezmoi destroy targets...`
Remove from both source state AND destination.

### `chezmoi manage targets...`
Alias for `add`.

### `chezmoi unmanage targets...`
Alias for `forget`.

### `chezmoi merge targets...`
Three-way merge between source, target, and destination state.

### `chezmoi merge-all`
Merge all files that differ between source and destination.

## Inspection and Debugging

### `chezmoi cat targets...`
Print target state of files (what would be applied).

### `chezmoi diff`
Show what would change on next `apply`.

### `chezmoi status [targets...]`
Print status of targets. Status codes:
- `A` - Added
- `D` - Deleted
- `M` - Modified
- `R` - Script to Run

### `chezmoi data [--format json|toml|yaml]`
Print template data. Default format is JSON.

### `chezmoi managed [--path-style absolute|relative|source-absolute|source-relative]`
List all managed entries.

### `chezmoi unmanaged`
List entries in destination not managed by chezmoi.

### `chezmoi ignored`
List entries ignored by `.chezmoiignore`.

### `chezmoi source-path [targets...]`
Print source path for targets.

### `chezmoi target-path [sources...]`
Print target path for source files.

### `chezmoi execute-template [templates...]`
Execute template strings and print results. Without args, reads from stdin.
- `--init` - Enable init-time functions
- `--promptString key=value` - Pre-set prompt responses for testing
- `--promptBool key=value`
- `--promptInt key=value`
- `--promptChoice key=value`

### `chezmoi doctor`
Check for potential problems. Reports `ok`, `warning`, or `error` for each check.

### `chezmoi dump [targets...]`
Dump target state as JSON.

### `chezmoi dump-config`
Dump parsed configuration.

### `chezmoi cat-config`
Print config file contents.

### `chezmoi verify`
Verify destination matches target state. Exits 0 if matches, 1 if not.

## State Management

### `chezmoi state`
Manage chezmoi's persistent state database.
- `chezmoi state delete-bucket --bucket=scriptState` - Clear run_once_ state
- `chezmoi state delete-bucket --bucket=entryState` - Clear run_onchange_ state
- `chezmoi state dump` - Dump all state

## Git Integration

### `chezmoi cd`
Open shell in source directory. Exit shell to return.

### `chezmoi git -- args...`
Run git command in source directory. Use `--` to separate chezmoi flags from git flags.
```
chezmoi git -- add .
chezmoi git -- commit -m "Update dotfiles"
chezmoi git -- push
```

### Auto-commit/push
Configure in chezmoi config:
```toml
[git]
    autoCommit = true
    autoPush = true
    commitMessageTemplate = "{{ promptString \"Commit message\" }}"
```

## Encryption

### `chezmoi encrypt file`
Encrypt a file.

### `chezmoi decrypt file`
Decrypt a file.

### age Encryption Configuration
```toml
encryption = "age"
[age]
    identity = "~/.config/chezmoi/key.txt"
    recipient = "age1..."
```

Generate key: `chezmoi age-keygen --output ~/.config/chezmoi/key.txt`

## Other Commands

### `chezmoi import archive`
Import archive into source state.
- `--strip-components N` - Strip leading path components
- `--destination path` - Destination prefix

### `chezmoi archive [--format tar|zip]`
Create archive of target state.

### `chezmoi completion shell`
Generate shell completion script.

### `chezmoi generate git-commit-message`
Generate commit message from changes.

### `chezmoi secret`
Interact with secret managers. Subcommands vary by manager.
