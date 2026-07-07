#!/usr/bin/env bats

load helpers/setup

CAPTURE_SH="${HOME_DIR}/dot_agents/skills/session-summary/scripts/capture.sh"

@test "capture.sh exists and is executable" {
  [ -f "$CAPTURE_SH" ]
  [ -x "$CAPTURE_SH" ]
}

@test "capture.sh rejects SESSION_ID with path traversal (../)" {
  run bash "$CAPTURE_SH" "../../etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"許可されない文字"* ]]
}

@test "capture.sh rejects SESSION_ID with slash" {
  run bash "$CAPTURE_SH" "abc/def"
  [ "$status" -eq 1 ]
  [[ "$output" == *"許可されない文字"* ]]
}

@test "capture.sh rejects SESSION_ID with whitespace" {
  run bash "$CAPTURE_SH" "abc def"
  [ "$status" -eq 1 ]
  [[ "$output" == *"許可されない文字"* ]]
}

@test "capture.sh rejects SESSION_ID with shell metacharacters" {
  run bash "$CAPTURE_SH" 'abc$injection'
  [ "$status" -eq 1 ]
  [[ "$output" == *"許可されない文字"* ]]
}

@test "capture.sh rejects empty SESSION_ID" {
  run bash "$CAPTURE_SH" ""
  [ "$status" -ne 0 ]
}

@test "capture.sh accepts UUID-formatted SESSION_ID (validation passes)" {
  # Use a synthetic UUID that cannot exist as a real session file. The validation
  # regex should accept it; the script then fails at the session-file lookup
  # stage with a different, distinguishable error.
  run bash "$CAPTURE_SH" "00000000-0000-0000-0000-000000000000"
  [ "$status" -eq 1 ]
  [[ "$output" != *"許可されない文字"* ]]
  [[ "$output" == *"セッションファイルが見つかりません"* ]]
}
