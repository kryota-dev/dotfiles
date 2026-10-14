#!/usr/bin/env bats
# codex-cu の app 承認 elicitation に応答する hook を、偽の transcript で確かめる。

setup() {
  GATE="$BATS_TEST_DIRNAME/../home/dot_claude/executable_codex-cu-gate.sh"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript auto
}

# permission mode の記録を持つ transcript を書く。
write_transcript() {
  cat >"$TRANSCRIPT" <<EOF
{"type":"permission-mode","permissionMode":"$1"}
{"type":"user","message":{"role":"user","content":"Music App で PUSHIM のプレイリストを再生して"}}
EOF
}

elicit() {
  jq -n --arg m "$1" --arg t "$TRANSCRIPT" \
    '{hook_event_name: "Elicitation", mcp_server_name: "codex-cu", message: $m, mode: "form", transcript_path: $t}'
}

accepted() {
  [ "$(jq -r '.hookSpecificOutput.action' <<<"$output")" = accept ]
}

@test "アプリの許可以外の elicitation には何も出力しない" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to record computer audio?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "必ず聞くアプリはダイアログへ委ねる" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Script Editor"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "常に許可するアプリは accept する" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?')
  [ "$status" -eq 0 ]
  accepted
}

@test "permission mode が auto でなければ、常に許可するアプリでもダイアログへ委ねる" {
  write_transcript default
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "transcript が無ければダイアログへ委ねる" {
  TRANSCRIPT="$BATS_TEST_TMPDIR/missing.jsonl"
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "どちらのリストにも無いアプリはダイアログへ委ねる" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
