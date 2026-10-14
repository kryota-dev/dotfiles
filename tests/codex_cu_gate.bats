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
  # 複数行の依頼と、tool_result が未記録の js 呼び出し 1 つを持つ transcript。
  cat >"$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"Chrome は触らないで\nMusic App で PUSHIM のプレイリストを再生して"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"ToolSearch","input":{"query":"select:mcp__codex-cu__js"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Tool loaded."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"js1","name":"mcp__codex-cu__js","input":{"title":"ミュージックを開く","code":"let music = await cua.getApp(\"com.apple.Music\");"}}]}}
EOF
}

elicit() {
  jq -n --arg m "$1" --arg t "$TRANSCRIPT" --arg agent "${2:-}" \
    '{hook_event_name: "Elicitation", mcp_server_name: "codex-cu", message: $m, mode: "form", transcript_path: $t}
     + (if $agent == "" then {} else {agent_id: $agent} end)'
}

accepted() {
  [ "$(jq -r '.hookSpecificOutput.action' <<<"$output")" = accept ]
}

not_classified() {
  [ ! -e "$BATS_TEST_TMPDIR/claude-args" ]
}

@test "アプリの許可以外の elicitation には何も出力しない" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to record computer audio?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  not_classified
}

@test "必ず聞くアプリは分類器を呼ばずにダイアログへ委ねる" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Script Editor"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  not_classified
}

@test "常に許可するアプリは分類器を呼ばずに accept する" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?')
  [ "$status" -eq 0 ]
  accepted
  not_classified
}

@test "日本語の表示名でも、必ず聞くアプリはダイアログへ委ね、常に許可するアプリは accept する" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "システム設定"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "ミュージック"?')
  [ "$status" -eq 0 ]
  accepted
  not_classified
}

@test "transcript が無ければ分類器を呼ばずにダイアログへ委ねる" {
  TRANSCRIPT="$BATS_TEST_TMPDIR/missing.jsonl"
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  not_classified
}

@test "subagent の中ではダイアログへ委ねる" {
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Music"?' agent-1)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  not_classified
}

@test "それ以外のアプリは依頼の全文と未完了の js を分類器に渡し、ok なら accept する" {
  export CLASSIFIER_RESULT='{"ok": true, "reason": "依頼どおり"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  accepted
  args=$(cat "$BATS_TEST_TMPDIR/claude-args")
  [[ "$args" == *'"app":"Finder"'* ]]
  [[ "$args" == *'Chrome は触らないで\nMusic App で PUSHIM のプレイリストを再生して'* ]]
  [[ "$args" == *'"title":"ミュージックを開く"'* ]]
  # hook を読まない独立セッションで動かす。
  [[ "$args" == *$'--setting-sources\n\n'* ]]
  [[ "$args" == *'--strict-mcp-config'* ]]
}

@test "完了した js は選ばず、未完了の js だけを渡す" {
  cat >>"$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"js1","content":"opened"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"js2","name":"mcp__codex-cu__js","input":{"title":"再生する","code":"await music.click(1);"}}]}}
EOF
  export CLASSIFIER_RESULT='{"ok": true, "reason": "ok"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  accepted
  args=$(cat "$BATS_TEST_TMPDIR/claude-args")
  [[ "$args" == *'"title":"再生する"'* ]]
  [[ "$args" != *'ミュージックを開く'* ]]
}

@test "未完了の js が複数あれば planned_js を渡さない" {
  cat >>"$TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"js2","name":"mcp__codex-cu__js","input":{"title":"並列","code":"await x();"}}]}}
EOF
  export CLASSIFIER_RESULT='{"ok": true, "reason": "ok"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  accepted
  [[ "$(cat "$BATS_TEST_TMPDIR/claude-args")" == *'"planned_js":null'* ]]
}

@test "js の code が長すぎれば切り詰めずにダイアログへ委ねる" {
  long=$(printf 'a%.0s' $(seq 1 2001))
  cat >>"$TRANSCRIPT" <<EOF
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"js1","content":"opened"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"js2","name":"mcp__codex-cu__js","input":{"title":"長い","code":"$long"}}]}}
EOF
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  not_classified
}

@test "分類器が否ならダイアログへ委ねる" {
  export CLASSIFIER_RESULT='{"ok": false, "reason": "依頼と無関係"}'
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "分類器が失敗してもダイアログへ委ねる（decline にしない）" {
  export CLASSIFIER_EXIT=1
  run --separate-stderr bash "$GATE" < <(elicit 'Allow Computer Use to use "Finder"?')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
