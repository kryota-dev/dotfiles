#!/usr/bin/env bats
# codex-cu の app 承認 elicitation に応答する hook を、claude のスタブと偽の transcript で確かめる。

setup() {
  GATE="$BATS_TEST_DIRNAME/../home/dot_claude/executable_codex-cu-gate.sh"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  # claude -p の呼び出しを記録し、CLASSIFIER_RESULT を structured_output として返す。
  cat >"$STUB/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/claude-args"
[ -n "$CLASSIFIER_EXIT" ] && exit "$CLASSIFIER_EXIT"
printf '{"structured_output": %s}' "${CLASSIFIER_RESULT:-null}"
EOF
  chmod +x "$STUB/claude"
  export PATH="$STUB:$PATH"
  export BATS_TEST_TMPDIR
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  cat >"$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"Music App で PUSHIM のプレイリストを再生して"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:mcp__codex-cu__js"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Tool loaded."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__codex-cu__js","input":{"title":"ミュージックを開く","code":"let music = await cua.getApp(\"com.apple.Music\");"}}]}}
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
  [ ! -e "$BATS_TEST_TMPDIR/claude-args" ]
}

@test "ALWAYS_ASK のアプリは分類器を呼ばずにダイアログへ委ねる" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "1Password"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-args" ]
}

@test "ALWAYS_ALLOW のアプリは分類器を呼ばずに accept する" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?')
  [ "$status" -eq 0 ]
  accepted
  [ ! -e "$BATS_TEST_TMPDIR/claude-args" ]
}

@test "それ以外のアプリは transcript の依頼と js の code を分類器に渡し、ok なら accept する" {
  export CLASSIFIER_RESULT='{"ok": true, "reason": "依頼どおり"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Google Chrome"?')
  [ "$status" -eq 0 ]
  accepted
  args=$(cat "$BATS_TEST_TMPDIR/claude-args")
  [[ "$args" == *'"app":"Google Chrome"'* ]]
  [[ "$args" == *'PUSHIM のプレイリストを再生して'* ]]
  [[ "$args" == *'cua.getApp(\"com.apple.Music\")'* ]]
  # hook を読まない独立セッションで動かす。
  [[ "$args" == *$'--setting-sources\n\n'* ]]
  [[ "$args" == *'--strict-mcp-config'* ]]
}

@test "分類器が否ならダイアログへ委ねる" {
  export CLASSIFIER_RESULT='{"ok": false, "reason": "依頼と無関係"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Google Chrome"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "分類器が失敗してもダイアログへ委ねる（decline にしない）" {
  export CLASSIFIER_EXIT=1
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Google Chrome"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "transcript が無くてもアプリ名だけで分類器に問う" {
  export CLASSIFIER_RESULT='{"ok": true, "reason": "ok"}'
  TRANSCRIPT="$BATS_TEST_TMPDIR/missing.jsonl"
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Google Chrome"?')
  [ "$status" -eq 0 ]
  accepted
  [[ "$(cat "$BATS_TEST_TMPDIR/claude-args")" == *'"planned_js":null'* ]]
}
