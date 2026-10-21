#!/usr/bin/env bats

setup() {
  SOURCE="$BATS_TEST_DIRNAME/../home"
  ROLES="$SOURCE/dot_agents/exact_skills/pr-workflow/references/model-roles.md"
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
  for f in "$SOURCE/$1/agents/"*".$2"; do
    [ -f "$f" ] || continue
    basename "$f" ".$2"
  done | sort
}

@test "Claude の定義は必須の frontmatter を持ち、name がファイル名と一致する" {
  local f key name count=0
  for f in "$SOURCE/dot_claude/agents/"*.md; do
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
      f="$SOURCE/dot_claude/agents/$role.md"
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
      actual=$(definition_names dot_claude md)
    else
      actual=$(definition_names dot_codex toml)
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
    roles=$(grep -Eo '`(spec-designer|review-|implementer|reviewer-gpt|checker-gpt|fact-checker)[a-z-]*`' "$f" | sed 's/`//g' | sort -u)
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      [ "$role" = review-resolve-loop ] && continue
      [ -f "$SOURCE/dot_claude/agents/$role.md" ] || [ -f "$SOURCE/dot_codex/agents/$role.toml" ] || {
        echo "参照する役割 $role の定義がありません: $f"
        return 1
      }
    done <<<"$roles"
  done < <(find "$SOURCE/dot_agents/exact_skills" -type f -name '*.md')
}

# 役割表の文書にある起動の関数を取り出し、リポジトリの定義を ~/.claude/agents に見立てて読み込む。
load_role_helpers() {
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.claude" "$home/.codex"
  ln -sfn "$SOURCE/dot_claude/agents" "$home/.claude/agents"
  ln -sfn "$SOURCE/dot_codex/agents" "$home/.codex/agents"
  awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$ROLES" >"$BATS_TEST_TMPDIR/helpers.sh"
  HOME="$home"
  # shellcheck disable=SC1091
  source "$BATS_TEST_TMPDIR/helpers.sh"
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
}

@test "Claude の役割は Bash も Edit も Write も持たない" {
  local f tools
  for f in "$SOURCE/dot_claude/agents/"*.md; do
    tools=$(claude_field "$f" tools)
    [[ ",$tools," != *"Bash"* && ",$tools," != *"Edit"* && ",$tools," != *"Write"* ]] || {
      echo "書き込みかシェルの道具を持つ: $f ($tools)"
      return 1
    }
  done
}
