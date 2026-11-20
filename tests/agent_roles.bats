#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  SOURCE="$BATS_TEST_DIRNAME/../home"
  ROLES="$SOURCE/dot_agents/exact_skills/pr-workflow/references/model-roles.md"
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL
}

claude_field() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
    }
  ' "$1"
}

codex_field() {
  sed -nE "s/^$2[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$/\1/p" "$1"
}

require_roles() {
  [ -f "$ROLES" ] || {
    echo "役割表がありません: $ROLES"
    return 1
  }
}

definition_names() {
  local f
  for f in "$SOURCE/$1/"*".$2"; do
    [ -f "$f" ] || continue
    basename "$f" ".$2"
  done | sort
}

@test "Claude の定義は必須の frontmatter を持ち、name がファイル名と一致する" {
  local f key name count=0
  for f in "$SOURCE/dot_agents/roles/"*.md; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    for key in name description model effort; do
      [ -n "$(claude_field "$f" "$key")" ] || {
        echo "frontmatter の $key がありません: $f"
        return 1
      }
    done
    name=$(basename "$f" .md)
    [ "$(claude_field "$f" name)" = "$name" ] || {
      echo "name がファイル名と一致しません: $f"
      return 1
    }
  done
  [ "$count" -gt 0 ] || {
    echo "Claude の定義ファイルがありません"
    return 1
  }
}

@test "Codex の定義は必須のキーを持ち、name がファイル名と一致する" {
  local f key name count=0
  for f in "$SOURCE/dot_codex/agents/"*.toml; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    for key in name description developer_instructions model model_reasoning_effort; do
      [ -n "$(codex_field "$f" "$key")" ] || {
        echo "キー $key がありません: $f"
        return 1
      }
    done
    name=$(basename "$f" .toml)
    [ "$(codex_field "$f" name)" = "$name" ] || {
      echo "name がファイル名と一致しません: $f"
      return 1
    }
  done
  [ "$count" -gt 0 ] || {
    echo "Codex の定義ファイルがありません"
    return 1
  }
}

@test "役割表と定義のモデル・エフォート・件数・集合が一致する" {
  require_roles
  local rows role family model effort f actual_model actual_effort expected actual
  rows=$(awk -F '|' '
    /^\| `[a-z-]+` \| (Claude|GPT) \| [^ |]+ \| [^ |]+ \|/ {
      for (i = 2; i <= 5; i++) gsub(/[ `]/, "", $i)
      print $2, $3, $4, $5
    }
  ' "$ROLES")
  [ -n "$rows" ] || {
    echo "役割表に役割の行がありません: $ROLES"
    return 1
  }
  while read -r role family model effort; do
    if [ "$family" = Claude ]; then
      f="$SOURCE/dot_agents/roles/$role.md"
    else
      f="$SOURCE/dot_codex/agents/$role.toml"
    fi
    [ -f "$f" ] || {
      echo "役割表の $role に対応する定義がありません: $f"
      return 1
    }
    if [ "$family" = Claude ]; then
      actual_model=$(claude_field "$f" model)
      actual_effort=$(claude_field "$f" effort)
    else
      actual_model=$(codex_field "$f" model)
      actual_effort=$(codex_field "$f" model_reasoning_effort)
    fi
    [ "$actual_model" = "$model" ] && [ "$actual_effort" = "$effort" ] || {
      echo "$role のモデル・エフォートが不一致: 表=$model/$effort 定義=$actual_model/$actual_effort"
      return 1
    }
  done <<<"$rows"
  for family in Claude GPT; do
    expected=$(echo "$rows" | awk -v family="$family" '$2 == family { print $1 }' | sort)
    if [ "$family" = Claude ]; then
      actual=$(definition_names dot_agents/roles md)
    else
      actual=$(definition_names dot_codex/agents toml)
    fi
    # 重複行も残して比較し、集合だけでなく件数の食い違いも検出する。
    [ "$expected" = "$actual" ] || {
      echo "$family の役割表と定義の件数・集合が不一致: 表=[$expected] 定義=[$actual]"
      return 1
    }
  done
}

@test "skill の Markdown で参照する役割には定義ファイルが存在する" {
  require_roles
  local f roles role
  while IFS= read -r f; do
    roles=$(grep -Eo '`(spec-designer|review-|implementer|reviewer-gpt|checker-gpt|fact-checker|grill-counterpart)[a-z-]*`' "$f" | sed 's/`//g' | sort -u)
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      [ "$role" = review-resolve-loop ] && continue
      [ -f "$SOURCE/dot_agents/roles/$role.md" ] || [ -f "$SOURCE/dot_codex/agents/$role.toml" ] || {
        echo "参照する役割 $role の定義がありません: $f"
        return 1
      }
    done <<<"$roles"
  done < <(find "$SOURCE/dot_agents/exact_skills" -type f -name '*.md')
}

@test "GPT の役割の値を読む Bash ブロックは本文も読み、起動時に渡す" {
  local f failed=0
  while IFS= read -r f; do
    awk '
      /^```bash$/ { in_bash=1; block=""; start=FNR; next }
      /^```$/ && in_bash {
        if (block ~ /gpt_role[^\n]*model_reasoning_effort/) {
          if (block !~ /gpt_body[[:space:]]/) {
            printf "役割の本文を読んでいません: %s:%d\n", FILENAME, start
            failed=1
          }
          if (block ~ /codex exec/ && block !~ /-c[[:space:]]+developer_instructions=/) {
            printf "役割の本文を渡していません: %s:%d\n", FILENAME, start
            failed=1
          }
        }
        in_bash=0
      }
      in_bash && $0 !~ /^[[:space:]]*#/ { block=block $0 "\n" }
      END { exit failed }
    ' "$f" || failed=1
  done < <(find "$SOURCE/dot_agents/exact_skills" -type f -name '*.md')
  [ "$failed" -eq 0 ]
}

@test "GPT の役割の起動表は Claude Code の起動形に本文を含める" {
  require_roles
  awk '
    /^## GPT の役割の起動$/ { in_section=1; next }
    /^## / { in_section=0 }
    in_section && /^\| Claude Code \|/ {
      split($0, spans, "`")
      if (spans[2] ~ /codex exec.*-c developer_instructions=/) found=1
    }
    END {
      if (!found) {
        print "Claude Code の起動形に役割の本文がありません: " FILENAME
        exit 1
      }
    }
  ' "$ROLES"
}

# 役割表の文書にある起動の関数を取り出し、リポジトリの定義を ~/.agents/roles と ~/.codex/agents に見立てて読み込む。
load_role_helpers() {
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.agents" "$home/.codex"
  ln -sfn "$SOURCE/dot_agents/roles" "$home/.agents/roles"
  ln -sfn "$SOURCE/dot_codex/agents" "$home/.codex/agents"
  awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$ROLES" >"$BATS_TEST_TMPDIR/helpers.sh"
  HOME="$home"
  # shellcheck disable=SC1091
  source "$BATS_TEST_TMPDIR/helpers.sh"
}

# 実物の結果を持ち込まず、補助の haiku の出力が多い正常系を基準に、判定に関係する欄だけを変える。
write_claude_result() {
  jq -n '{
    is_error: false, stop_reason: "end_turn", terminal_reason: "completed", safety_stops: 0,
    modelUsage: {
      "claude-opus-5-5": {outputTokens: 1200},
      "claude-haiku-5-5": {outputTokens: 20409}
    }
  }' | jq "${1:-.}" >"$BATS_TEST_TMPDIR/result.json"
}

assert_check() {
  load_role_helpers
  write_claude_result "$1"
  run claude_check "$BATS_TEST_TMPDIR/result.json" claude-opus-5-5
  [ "$status" -eq 0 ] && [ "$output" = "$2" ] || {
    echo "status=$status output=$output"
    return 1
  }
}

@test "claude_check は補助の haiku の出力が多くても正常終了を ok とする" {
  assert_check '.' ok
}

@test "claude_check は haiku が載らない正常終了も ok とする" {
  assert_check 'del(.modelUsage["claude-haiku-5-5"])' ok
}

@test "claude_check は補助以外のモデルが載れば safety_stops より fallback を優先する" {
  assert_check '.modelUsage["claude-opus-4-8"] = {outputTokens: 23732} | .safety_stops = 2' fallback
}

@test "claude_check はモデルの切り替えが無くても safety_stops が正なら stopped とする" {
  assert_check '.safety_stops = 1' stopped
}

@test "claude_check は safety_stops の欄が無ければ stopped とする" {
  assert_check 'del(.safety_stops)' stopped
}

@test "claude_check は要求したモデルの出力が 0 なら fallback とする" {
  assert_check '.modelUsage["claude-opus-5-5"].outputTokens = 0' fallback
}

@test "claude_check は要求したモデルが載らなければ fallback とする" {
  assert_check 'del(.modelUsage["claude-opus-5-5"])' fallback
}

@test "claude_check は is_error が true なら abnormal とする" {
  assert_check '.is_error = true' abnormal
}

@test "claude_check は stop_reason が end_turn 以外なら abnormal とする" {
  assert_check '.stop_reason = "refusal"' abnormal
}

@test "claude_check は terminal_reason が completed 以外なら abnormal とする" {
  assert_check '.terminal_reason = "error"' abnormal
}

@test "claude_check は fallback と stopped の条件を満たしても abnormal を優先する" {
  assert_check '.is_error = true | .modelUsage["claude-opus-4-8"] = {outputTokens: 23732} | .safety_stops = 2' abnormal
}

@test "claude_check は環境変数で指定した haiku のモデルを補助とみなす" {
  local ANTHROPIC_DEFAULT_HAIKU_MODEL=x
  assert_check '.modelUsage.x = .modelUsage["claude-haiku-5-5"] | del(.modelUsage["claude-haiku-5-5"])' ok
}

@test "claude_check は haiku のモデルを環境変数で変えたら既定の haiku を fallback とする" {
  local ANTHROPIC_DEFAULT_HAIKU_MODEL=x
  assert_check '.modelUsage.x = {outputTokens: 1}' fallback
}

@test "claude_check は空・空白だけ・壊れた JSON・配列を非ゼロ終了で拒否する" {
  load_role_helpers
  # 関数の未定義による非ゼロ終了を、不正入力を拒否できたという成功にしない。
  type claude_check >/dev/null
  local input
  for input in '' $' \n\t' '{"is_error":' '[]'; do
    printf '%s' "$input" >"$BATS_TEST_TMPDIR/result.json"
    run claude_check "$BATS_TEST_TMPDIR/result.json" claude-opus-5-5
    [ "$status" -ne 0 ] || {
      printf '不正な入力を拒否しませんでした: %q\n' "$input"
      return 1
    }
  done
}

@test "claude_check は modelUsage の欄が無ければ判定に失敗せず fallback とする" {
  assert_check 'del(.modelUsage)' fallback
}

@test "役割表の文書の起動の関数は shellcheck を通る" {
  command -v shellcheck >/dev/null || skip "shellcheck がインストールされていない"
  awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$ROLES" | shellcheck -s bash -
}

@test "起動の関数は定義から model・effort・道具・本文を読む" {
  load_role_helpers
  [ "$(claude_role review-security model)" = claude-opus-5-5 ]
  [ "$(claude_role review-security effort)" = high ]
  [ "$(claude_role fact-checker tools | tr -d ,)" = "WebFetch WebSearch" ]
  body=$(claude_body review-security)
  [[ "$body" == *"pasted_content"* ]]
  [[ "$body" != *"model:"* ]]
  [ "$(gpt_role implementer model)" = gpt-6.1-sol ]
  [ "$(gpt_role reviewer-gpt model_reasoning_effort)" = high ]
  gbody=$(gpt_body grill-counterpart-gpt)
  [[ "$gbody" == "あなたは"* ]]
  local f role
  # codex exec は本文が空なら起動しないので、すべての GPT の役割で本文が取れることを確かめる。
  for f in "$SOURCE/dot_codex/agents/"*.toml; do
    role=$(basename "$f" .toml)
    gbody=$(gpt_body "$role")
    [ -n "$gbody" ] || {
      echo "本文が空です: $role"
      return 1
    }
    [[ "$gbody" != *"model ="* && "$gbody" != *'"""'* ]] || {
      echo "本文に定義のほかの部分が混ざっています: $role"
      return 1
    }
  done
}

@test "Bash を持つのは implementer-claude* だけ、書き込みの道具を持つのは spec-designer と implementer-claude* だけ" {
  local f tools name
  for f in "$SOURCE/dot_agents/roles/"*.md; do
    tools=$(claude_field "$f" tools)
    name=$(basename "$f" .md)
    case $name in implementer-claude*) continue ;; esac
    [[ "$tools" != *Bash* ]] || {
      echo "Bash を持つ: $f"
      return 1
    }
    [ "$name" = spec-designer ] && continue
    [[ "$tools" != *Edit* && "$tools" != *Write* ]] || {
      echo "書き込みの道具を持つ: $f ($tools)"
      return 1
    }
  done
}

@test "claude_leg は道具を --tools で絞り、Read を作業ディレクトリに限る" {
  load_role_helpers
  # claude の代わりに引数を書き出すだけの関数を置き、組み立てた起動の引数を確かめる。
  claude() { printf '%s\n' "$@"; }
  claude_leg fact-checker "$BATS_TEST_TMPDIR/out.json" </dev/null
  args=$(cat "$BATS_TEST_TMPDIR/out.json")
  [[ "$args" == *$'--tools\nWebFetch\nWebSearch\n'* ]]
  [[ "$args" == *$'--allowedTools\nRead(./**)\nWebFetch\nWebSearch\n'* ]]
  [[ "$args" == *$'--setting-sources\n\n'* ]]
  [[ "$args" == *"--permission-mode"$'\n'"dontAsk"* ]]
  [[ "$args" != *$'\nRead\n'* ]]
}

@test "claude_leg は switchModelsOnFlag を true にした settings を明示する" {
  load_role_helpers
  claude() { printf '%s\n' "$@"; }
  claude_leg fact-checker "$BATS_TEST_TMPDIR/out.json" </dev/null
  args=$(cat "$BATS_TEST_TMPDIR/out.json")
  [[ "$args" == *$'--settings\n{"switchModelsOnFlag":true}\n'* ]]
}

# linked worktree を作り、そのパスを出す。
make_linked_worktree() {
  local repo="$BATS_TEST_TMPDIR/main" wt="$BATS_TEST_TMPDIR/wt"
  git init -q "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$wt"
  echo "$wt"
}

@test "claude_impl は linked worktree の外では claude を呼ばずに止まる" {
  load_role_helpers
  claude() { echo called >"$BATS_TEST_TMPDIR/called"; }
  git init -q "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr claude_impl implementer-claude </dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "claude_impl は sandbox の設定・道具・権限を組み立てる" {
  load_role_helpers
  claude() { printf '%s\n' "$@"; }
  export EXAMPLE_SERVICE_API_KEY=dummy
  local wt gcd settings out
  wt=$(make_linked_worktree)
  gcd=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  cd "$wt"
  out=$(claude_impl implementer-claude example.com </dev/null)
  args=$(cat "$out")
  settings=$(awk '/^--settings$/{getline; print; exit}' "$out")
  [ "$(jq -r '.sandbox.enabled' <<<"$settings")" = true ]
  [ "$(jq -r '.sandbox.allowUnsandboxedCommands' <<<"$settings")" = false ]
  [ "$(jq -r '.sandbox.failIfUnavailable' <<<"$settings")" = true ]
  [ "$(jq -r '.sandbox.network.strictAllowlist' <<<"$settings")" = true ]
  [ "$(jq -r '.sandbox.network.allowedDomains | join(",")' <<<"$settings")" = example.com ]
  [ "$(jq -r --arg gcd "$gcd" '.sandbox.filesystem.denyWrite | index($gcd) != null' <<<"$settings")" = true ]
  [ "$(jq -r '.sandbox.credentials.files | map(select(.path == "~/.ssh" and .mode == "deny")) | length' <<<"$settings")" = 1 ]
  [[ "$args" == *$'--tools\nBash\n'* ]]
  [[ "$args" == *$'--setting-sources\n\n'* ]]
  [[ "$args" == *"--permission-mode"$'\n'"dontAsk"* ]]
  # 実装者が cd しても基準が移らないよう、許可は worktree のルートの絶対パスで固定する。
  root=$(git rev-parse --show-toplevel)
  [[ "$args" == *$'\n'"Edit(/$root/**)"$'\n'* ]]
  [[ "$args" != *'Edit(./**)'* ]]
  [[ "$args" == *$'\n'"Read(/$root/**)"$'\n'* ]]
  [[ "$args" == *$'--disallowedTools\nRead(//**/.env)\n'* ]]
  [ "$(jq -r '.sandbox.credentials.envVars | map(select(.name == "GH_TOKEN" and .mode == "deny")) | length' <<<"$settings")" = 1 ]
  [ "$(jq -r '.sandbox.credentials.files | map(select(.path == "~/.gmail-mcp")) | length' <<<"$settings")" = 1 ]
  # 固定の一覧に無い変数も、名前が認証情報らしければ拒否に入る。
  [ "$(jq -r '.sandbox.credentials.envVars | map(select(.name == "EXAMPLE_SERVICE_API_KEY" and .mode == "deny")) | length' <<<"$settings")" = 1 ]
  [ "$(jq -r '.sandbox.credentials.envVars | map(select(.name == "HOME")) | length' <<<"$settings")" = 0 ]
  [[ "$args" != *SUBPROCESS_ENV_SCRUB* ]]
  # settings を重ねると sandbox の設定を失いうるため、同じ JSON の最上位に含める。
  [ "$(awk '/^--settings$/{n++} END {print n+0}' "$out")" = 1 ]
  [ "$(jq -r '.switchModelsOnFlag == true' <<<"$settings")" = true ]
}

@test "claude_impl は結果の置き場所を作業場所の外に作り、denyWrite に入れてパスだけを出す" {
  load_role_helpers
  claude() { printf '%s\n' "$@"; }
  local wt root settings out
  wt=$(make_linked_worktree)
  cd "$wt"
  root=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
  run --separate-stderr claude_impl implementer-claude </dev/null
  [ "$status" -eq 0 ]
  # 標準出力は結果のパスの 1 行だけ。
  [ "${#lines[@]}" -eq 1 ]
  out=$output
  [ -s "$out" ]
  [ "$(cd "$(dirname "$out")" && pwd -P)" = "$(dirname "$out")" ]
  [[ "$out/" != "$root"/* ]]
  settings=$(awk '/^--settings$/{getline; print; exit}' "$out")
  [ "$(jq -r --arg d "$(dirname "$out")" '.sandbox.filesystem.denyWrite | index($d) != null' <<<"$settings")" = true ]
  # 起動のたびに別の置き場所を作る。
  [ "$(claude_impl implementer-claude </dev/null)" != "$out" ]
}

@test "claude_impl は claude が失敗しても結果のパスを出し、終了コードを返す" {
  load_role_helpers
  claude() { echo partial; return 3; }
  cd "$(make_linked_worktree)"
  run --separate-stderr claude_impl implementer-claude </dev/null
  [ "$status" -eq 3 ]
  [ "$(cat "$output")" = partial ]
}

@test "claude_impl は TMPDIR が worktree の中なら claude を呼ばずに止まる" {
  load_role_helpers
  claude() { echo called >"$BATS_TEST_TMPDIR/called"; }
  local wt
  wt=$(make_linked_worktree)
  mkdir "$wt/tmp"
  cd "$wt"
  TMPDIR="$wt/tmp" run --separate-stderr claude_impl implementer-claude </dev/null
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/called" ]
  # 作りかけの置き場所を残さない。
  [ -z "$(ls -A "$wt/tmp")" ]
}
