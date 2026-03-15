# chezmoi Template関数 Reference

## 目次
1. [Data Format関数](#data-format関数)
2. [File System関数](#file-system関数)
3. [Command実行](#command実行)
4. [Include関数](#include関数)
5. [Text処理](#text処理)
6. [1Password関数](#1password関数)
7. [Init-Time関数](#init-time関数)
8. [GitHub関数](#github関数)

---

## Data Format関数

### Parse
- **`fromJson`** *jsontext* - JSONをparse。integerはint64、floatはfloat64、overflowはstringで返される。
- **`fromJsonc`** *jsonctext* - JSONC（comment付きJSON）をparse。
- **`fromToml`** *tomltext* - TOMLをparse。例: `{{ (fromToml "[section]\nkey = \"value\"").section.key }}`
- **`fromYaml`** *yamltext* - YAMLをparse。例: `{{ (fromYaml "key: value").key }}`
- **`fromIni`** *initext* - INIをparse。例: `{{ (fromIni "[section]\nkey = value").section.key }}`

### Serialize
- **`toPrettyJson`** [*indent*] *value* - indent付きJSON（default 2 spaces）。例: `{{ dict "a" "b" | toPrettyJson "\t" }}`
- **`toToml`** *value* - TOMLにserialize。
- **`toYaml`** *value* - YAMLにserialize。
- **`toIni`** *value* - INIにserialize（入力はdictである必要あり）。

### Data操作
- **`jq`** *query* *input* - jq queryを実行。listを返す。例: `{{ dict "key" "value" | jq ".key" | first }}`
- **`setValueAtPath`** *path* *value* *dict* - nestedされた値を設定。例: `{{ fromJson .chezmoi.stdin | setValueAtPath "key.nested" "val" | toPrettyJson }}`
- **`deleteValueAtPath`** *path* *dict* - nestedされた値を削除。
- **`pruneEmptyDicts`** *dict* - 空のnested dictを削除。

## File System関数

- **`lookPath`** *file* - PATHからexecutableを検索。見つからない場合は空stringを返す。結果はcacheされる。
  ```
  {{ if lookPath "mise" }}eval "$(mise activate zsh)"{{ end }}
  ```

- **`findExecutable`** *file* *path-list* - 特定のdirectory（$HOMEからの相対path）からexecutableを検索。cacheされる。
  ```
  {{ if findExecutable "mise" (list "bin" ".local/bin" ".cargo/bin") }}...{{ end }}
  ```

- **`findOneExecutable`** *file-list* *path-list* - listから最初にmatchするexecutableを検索。cacheされる。
  ```
  {{ findOneExecutable (list "eza" "exa" "ls") (list ".cargo/bin" ".local/bin") }}
  ```

- **`stat`** *name* - file情報を返す。存在しない場合はfalse。field: `name`、`size`、`mode`、`perm`、`modTime`、`isDir`、`type`。
  ```
  {{ if stat (joinPath .chezmoi.homeDir ".pyenv") }}# pyenvが存在する{{ end }}
  ```

- **`lstat`** *name* - `stat` と同様だがsymlinkをfollowしない。

- **`glob`** *pattern* - destination directoryでdoublestar patternでfileをmatch。

- **`joinPath`** *element*... - OS固有のseparatorでpath要素を結合。

- **`isExecutable`** *name* - fileが存在し実行可能な場合にtrueを返す。

## Command実行

- **`output`** *name* [*arg*...] - commandを実行しstdoutを返す。template実行のたびに実行される。idempotentかつ高速であること。
  ```
  current-context: {{ output "kubectl" "config" "current-context" | trim }}
  ```

- **`exec`** *name* [*arg*...] - commandを実行し、成功/失敗をtrue/falseで返す。出力はdiscardされる。

## Include関数

- **`include`** *filename* - file内容をそのまま返す。相対pathはsource directory基準。

- **`includeTemplate`** *filename* [*data*] - fileをtemplateとして実行し結果を返す。`.chezmoitemplates` を先に検索し、次にsource directoryを検索。
  ```
  {{ includeTemplate "part.tmpl" . }}
  ```

## Text処理

- **`comment`** *prefix* *text* - 各行にcomment markerをprefix。
  ```
  {{ "line1\nline2\n" | comment "# " }}
  ```

- **`warnf`** *format* [*arg*...] - stderrに警告を出力し、空stringを返す。

- **`replaceAllRegex`** *pattern* *replacement* *input* - 正規表現で置換。

- **`eqFold`** *str1* *str2* - case-insensitiveな文字列比較。

- **`hexEncode`** / **`hexDecode`** - hex encoding/decoding。

- **`quoteList`** *list* - 各要素をquote。

- **`toString`** / **`toStrings`** - stringに変換。

- **`abortEmpty`** *value* - 値が空の場合errorでabort。

- **`ensureLinePrefix`** *prefix* *text* - まだprefixがない行にのみprefixを追加。

## 1Password関数

全関数は呼び出しごとに結果をcacheする。有効なsessionがない場合、userに対話的にsign-inを求める（`onepassword.prompt = false` でない限り）。

- **`onepasswordRead`** *url* [*account*] - `op read --no-newline` 経由で読み取り。単純なsecret取得に推奨。
  ```
  {{ onepasswordRead "op://vault/item/field" }}
  ```

- **`onepassword`** *uuid* [*vault* [*account*]] - `op item get --format json` 経由でitemをparse済みJSONとして取得。
  ```
  {{ range (onepassword "UUID").fields -}}
  {{   if and (eq .label "password") (eq .purpose "PASSWORD") -}}
  {{     .value -}}
  {{   end -}}
  {{ end }}
  ```

- **`onepasswordDocument`** *uuid* [*vault* [*account*]] - documentの内容を取得。1Password Connectでは利用不可。

- **`onepasswordDetailsFields`** *uuid* [*vault* [*account*]] - labelでindexされたfield。
  ```
  {{ (onepasswordDetailsFields "UUID").password.value }}
  ```

- **`onepasswordItemFields`** *uuid* [*vault* [*account*]] - labelでindexされたitem field。
  ```
  {{ (onepasswordItemFields "UUID").exampleLabel.value }}
  ```

### 1Password Mode
configの `[onepassword]` で指定: `mode = "account"`（default）、`"connect"`、または `"service"`。

## Init-Time関数

これらの関数は `chezmoi init` 実行中（`.chezmoi.$FORMAT.tmpl` 内）でのみ動作する。

- **`promptString`** *prompt* [*default*] - string入力を要求。
- **`promptStringOnce`** *map* *path* *prompt* [*default*] - 既存値を返すか、なければ入力を要求。config templateで最もよく使われる。
  ```
  {{ $email := promptStringOnce . "email" "Email address" }}
  ```
- **`promptBool`** *prompt* [*default*] - boolean値を要求（yes/no、true/false、1/0）。
- **`promptBoolOnce`** *map* *path* *prompt* [*default*]
- **`promptInt`** *prompt* [*default*] - integer値を要求。
- **`promptIntOnce`** *map* *path* *prompt* [*default*]
- **`promptChoice`** *prompt* *choices* [*default*] - listから選択。
  ```
  {{ $type := promptChoice "Host type" (list "desktop" "laptop" "server") }}
  ```
- **`promptChoiceOnce`** *map* *path* *prompt* *choices* [*default*]
- **`promptMultichoice`** *prompt* *choices* [*defaults*] - 複数選択。
- **`promptMultichoiceOnce`** *map* *path* *prompt* *choices* [*defaults*]
- **`stdinIsATTY`** - stdinがterminalの場合trueを返す（CI環境で有用）。
- **`writeToStdout`** *string*... - init中にstdoutに出力。
- **`exit`** - errorなしでinitを終了。

## GitHub関数

- **`gitHubKeys`** *user* - SSH public keyを取得。
  ```
  {{ range gitHubKeys "username" }}{{ .Key }}{{ end }}
  ```
- **`gitHubLatestRelease`** *owner/repo* - 最新release情報。
- **`gitHubLatestReleaseAssetURL`** *owner/repo* *pattern* - patternにmatchする最新release assetのURL。
- **`gitHubLatestTag`** *owner/repo* - 最新tag名。
- **`gitHubRelease`** *owner/repo* *tag* - 特定release情報。
- **`gitHubReleaseAssetURL`** *owner/repo* *tag* *pattern* - 特定release assetのURL。
- **`gitHubReleases`** *owner/repo* - 全release。
- **`gitHubTags`** *owner/repo* - 全tag。
