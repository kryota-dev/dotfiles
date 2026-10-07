#!/usr/bin/env bats

setup() {
  STATUSLINE="$BATS_TEST_DIRNAME/../home/dot_claude/executable_statusline.sh"
}

@test "モデル・context・rate limit を表示する" {
  input='{"model":{"display_name":"Opus"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp"},"context_window":{"remaining_percentage":72.4},"rate_limits":{"five_hour":{"used_percentage":55},"seven_day":{"used_percentage":12}}}'
  run bash "$STATUSLINE" <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Opus"* ]]
  [[ "$output" == *"残り"*"72%"* ]]
  [[ "$output" == *"5h"*"55%"* ]]
  [[ "$output" == *"7d"*"12%"* ]]
}

@test "項目が欠けていても動く" {
  run bash "$STATUSLINE" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude"* ]]
}
