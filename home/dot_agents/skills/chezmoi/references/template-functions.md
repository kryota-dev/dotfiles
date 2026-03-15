# chezmoi Template Functions Reference

## Table of Contents
1. [Data Format Functions](#data-format-functions)
2. [File System Functions](#file-system-functions)
3. [Command Execution](#command-execution)
4. [Include Functions](#include-functions)
5. [Text Processing](#text-processing)
6. [1Password Functions](#1password-functions)
7. [Init-Time Functions](#init-time-functions)
8. [GitHub Functions](#github-functions)

---

## Data Format Functions

### Parsing
- **`fromJson`** *jsontext* - Parse JSON. Integers returned as int64, floats as float64, overflows as string.
- **`fromJsonc`** *jsonctext* - Parse JSONC (JSON with comments).
- **`fromToml`** *tomltext* - Parse TOML. Example: `{{ (fromToml "[section]\nkey = \"value\"").section.key }}`
- **`fromYaml`** *yamltext* - Parse YAML. Example: `{{ (fromYaml "key: value").key }}`
- **`fromIni`** *initext* - Parse INI. Example: `{{ (fromIni "[section]\nkey = value").section.key }}`

### Serializing
- **`toPrettyJson`** [*indent*] *value* - JSON with indentation (default 2 spaces). Example: `{{ dict "a" "b" | toPrettyJson "\t" }}`
- **`toToml`** *value* - Serialize to TOML.
- **`toYaml`** *value* - Serialize to YAML.
- **`toIni`** *value* - Serialize to INI (input must be dict).

### Data Manipulation
- **`jq`** *query* *input* - Run jq query. Returns list. Example: `{{ dict "key" "value" | jq ".key" | first }}`
- **`setValueAtPath`** *path* *value* *dict* - Set nested value. Example: `{{ fromJson .chezmoi.stdin | setValueAtPath "key.nested" "val" | toPrettyJson }}`
- **`deleteValueAtPath`** *path* *dict* - Delete nested value.
- **`pruneEmptyDicts`** *dict* - Remove empty nested dicts.

## File System Functions

- **`lookPath`** *file* - Search PATH for executable. Returns empty string if not found. Result is cached.
  ```
  {{ if lookPath "mise" }}eval "$(mise activate zsh)"{{ end }}
  ```

- **`findExecutable`** *file* *path-list* - Find executable in specific directories (relative to $HOME). Cached.
  ```
  {{ if findExecutable "mise" (list "bin" ".local/bin" ".cargo/bin") }}...{{ end }}
  ```

- **`findOneExecutable`** *file-list* *path-list* - Find first matching executable from list. Cached.
  ```
  {{ findOneExecutable (list "eza" "exa" "ls") (list ".cargo/bin" ".local/bin") }}
  ```

- **`stat`** *name* - Returns file info or false if not exists. Fields: `name`, `size`, `mode`, `perm`, `modTime`, `isDir`, `type`.
  ```
  {{ if stat (joinPath .chezmoi.homeDir ".pyenv") }}# pyenv exists{{ end }}
  ```

- **`lstat`** *name* - Like `stat` but does not follow symlinks.

- **`glob`** *pattern* - Match files in destination directory using doublestar patterns.

- **`joinPath`** *element*... - Join path elements with OS separator.

- **`isExecutable`** *name* - Returns true if file exists and is executable.

## Command Execution

- **`output`** *name* [*arg*...] - Execute command, return stdout. Runs every template execution; must be idempotent and fast.
  ```
  current-context: {{ output "kubectl" "config" "current-context" | trim }}
  ```

- **`exec`** *name* [*arg*...] - Execute command, return true/false for success/failure. Output is discarded.

## Include Functions

- **`include`** *filename* - Return literal file contents. Relative paths interpreted relative to source directory.

- **`includeTemplate`** *filename* [*data*] - Execute file as template and return result. Searches `.chezmoitemplates` first, then source directory.
  ```
  {{ includeTemplate "part.tmpl" . }}
  ```

## Text Processing

- **`comment`** *prefix* *text* - Prefix each line with comment marker.
  ```
  {{ "line1\nline2\n" | comment "# " }}
  ```

- **`warnf`** *format* [*arg*...] - Print warning to stderr, returns empty string.

- **`replaceAllRegex`** *pattern* *replacement* *input* - Regex replace.

- **`eqFold`** *str1* *str2* - Case-insensitive string comparison.

- **`hexEncode`** / **`hexDecode`** - Hex encoding/decoding.

- **`quoteList`** *list* - Quote each element.

- **`toString`** / **`toStrings`** - Convert to string(s).

- **`abortEmpty`** *value* - Abort with error if value is empty.

- **`ensureLinePrefix`** *prefix* *text* - Add prefix only to lines that don't already have it.

## 1Password Functions

All functions cache results per invocation. If no valid session exists, user is interactively prompted to sign in (unless `onepassword.prompt = false`).

- **`onepasswordRead`** *url* [*account*] - Read via `op read --no-newline`. Preferred for simple secret retrieval.
  ```
  {{ onepasswordRead "op://vault/item/field" }}
  ```

- **`onepassword`** *uuid* [*vault* [*account*]] - Get item as parsed JSON via `op item get --format json`.
  ```
  {{ range (onepassword "UUID").fields -}}
  {{   if and (eq .label "password") (eq .purpose "PASSWORD") -}}
  {{     .value -}}
  {{   end -}}
  {{ end }}
  ```

- **`onepasswordDocument`** *uuid* [*vault* [*account*]] - Get document contents. Not available with 1Password Connect.

- **`onepasswordDetailsFields`** *uuid* [*vault* [*account*]] - Fields indexed by label for easy access.
  ```
  {{ (onepasswordDetailsFields "UUID").password.value }}
  ```

- **`onepasswordItemFields`** *uuid* [*vault* [*account*]] - Item fields indexed by label.
  ```
  {{ (onepasswordItemFields "UUID").exampleLabel.value }}
  ```

### 1Password Modes
Set in config `[onepassword]`: `mode = "account"` (default), `"connect"`, or `"service"`.

## Init-Time Functions

These functions only work during `chezmoi init` (in `.chezmoi.$FORMAT.tmpl`).

- **`promptString`** *prompt* [*default*] - Prompt for string input.
- **`promptStringOnce`** *map* *path* *prompt* [*default*] - Return existing value or prompt. Most common for config templates.
  ```
  {{ $email := promptStringOnce . "email" "Email address" }}
  ```
- **`promptBool`** *prompt* [*default*] - Prompt for boolean (yes/no, true/false, 1/0).
- **`promptBoolOnce`** *map* *path* *prompt* [*default*]
- **`promptInt`** *prompt* [*default*] - Prompt for integer.
- **`promptIntOnce`** *map* *path* *prompt* [*default*]
- **`promptChoice`** *prompt* *choices* [*default*] - Choose from list.
  ```
  {{ $type := promptChoice "Host type" (list "desktop" "laptop" "server") }}
  ```
- **`promptChoiceOnce`** *map* *path* *prompt* *choices* [*default*]
- **`promptMultichoice`** *prompt* *choices* [*defaults*] - Choose multiple.
- **`promptMultichoiceOnce`** *map* *path* *prompt* *choices* [*defaults*]
- **`stdinIsATTY`** - Returns true if stdin is a terminal (useful for CI).
- **`writeToStdout`** *string*... - Write to stdout during init.
- **`exit`** - Exit init without error.

## GitHub Functions

- **`gitHubKeys`** *user* - Get SSH public keys.
  ```
  {{ range gitHubKeys "username" }}{{ .Key }}{{ end }}
  ```
- **`gitHubLatestRelease`** *owner/repo* - Latest release info.
- **`gitHubLatestReleaseAssetURL`** *owner/repo* *pattern* - URL of latest release asset matching pattern.
- **`gitHubLatestTag`** *owner/repo* - Latest tag name.
- **`gitHubRelease`** *owner/repo* *tag* - Specific release info.
- **`gitHubReleaseAssetURL`** *owner/repo* *tag* *pattern* - Specific release asset URL.
- **`gitHubReleases`** *owner/repo* - All releases.
- **`gitHubTags`** *owner/repo* - All tags.
