#!/usr/bin/env bats

setup() {
  SKILLS="$BATS_TEST_DIRNAME/../home/dot_agents/exact_skills"
}

# skill の引数は本文の位置引数の形を置き換えるので、SKILL.md には書かない。
@test "SKILL.md は位置引数の形の文字列を含まない" {
  run grep -nE '\$[0-9]' "$SKILLS"/*/SKILL.md
  [ "$status" -eq 1 ] || {
    echo "$output"
    return 1
  }
}

# 本文から振り分けた手順を読めなくなるのを防ぐため、同じ skill 内の参照先を検査する。
# 別の skill への相対リンクは検査の対象にしない。
@test "SKILL.md の references への Markdown リンク先が実在する" {
  run bash -c '
    failed=0
    for skill in "$1"/*/SKILL.md; do
      while IFS= read -r reference; do
        if [ ! -f "${skill%/*}/$reference" ]; then
          echo "$skill: 参照先が存在しません: $reference"
          failed=1
        fi
      done < <(
        grep -oE "\[[^]]*\]\(references/[^)]+\.md\)" "$skill" |
          sed -E "s/^\[[^]]*\]\((.*)\)$/\1/"
      )
    done
    exit "$failed"
  ' _ "$SKILLS"
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}
