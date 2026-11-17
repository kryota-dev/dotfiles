#!/usr/bin/env bats

setup() {
  SETTINGS="$BATS_TEST_DIRNAME/../home/dot_claude/settings.json"
}

@test "モデルは 1M の接尾辞なしの Opus 5.5 を使う" {
  run jq -e '.model == "claude-opus-5-5"' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "トップレベルに不要な effort と思考の設定を置かない" {
  run jq -e '
    (has("effortLevel") | not) and
    (has("modelSettings") | not) and
    (has("alwaysThinkingEnabled") | not)
  ' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "env に不要な思考と自動圧縮の設定を置かない" {
  run jq -e '.env |
    (has("MAX_THINKING_TOKENS") | not) and
    (has("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE") | not)
  ' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "advisor に Fable 5.2 を完全な ID で使う" {
  run jq -e '.advisorModel == "claude-fable-5-2"' "$SETTINGS"
  [ "$status" -eq 0 ]
}
