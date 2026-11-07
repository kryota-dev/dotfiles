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
