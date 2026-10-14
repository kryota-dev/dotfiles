#!/usr/bin/env bats
# Codex の computer use を codex-cu として登録するスクリプトを、偽の HOME と mise のスタブで実行して確かめる。

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../home/run_onchange_after_14-claude-codex-cu.sh.tmpl"
  SOURCE="$BATS_TEST_DIRNAME/../home"
  export HOME="$BATS_TEST_TMPDIR/home"
  PLUGIN="$HOME/.codex/plugins/cache/openai-bundled/unified-computer-use"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$STUB"
  # mise exec -- claude mcp <subcommand> codex-cu [json] --scope user の呼び出しを記録する。
  cat >"$STUB/mise" <<'EOF'
#!/bin/bash
echo "$5" >>"$BATS_TEST_TMPDIR/calls"
[ "$5" = add-json ] && printf '%s' "$7" >"$BATS_TEST_TMPDIR/payload.json"
exit 0
EOF
  chmod +x "$STUB/mise"
  export PATH="$STUB:$PATH"
}

write_mcp() {
  mkdir -p "$PLUGIN/$1"
  cat >"$PLUGIN/$1/.mcp.json" <<EOF
{"mcpServers": {"cua_repl": {
  "command": "/node-$1", "args": ["/cua-repl.mjs"], "env": {"VERSION": "$1"},
  "enabled_tools": ["js"], "startup_timeout_sec": 120
}}}
EOF
}

render() {
  chezmoi execute-template --source "$SOURCE" <"$SCRIPT"
}

run_script() {
  render >"$BATS_TEST_TMPDIR/script.sh"
  bash "$BATS_TEST_TMPDIR/script.sh"
}

@test "最新のバージョンの command・args・env だけを stdio のサーバーとして登録する" {
  write_mcp 26.999.1
  write_mcp 26.1007.30912
  run run_script
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" = $'remove\nadd-json' ]
  expected='{"type":"stdio","command":"/node-26.1007.30912","args":["/cua-repl.mjs"],"env":{"VERSION":"26.1007.30912"}}'
  [ "$(jq -cS . "$BATS_TEST_TMPDIR/payload.json")" = "$(jq -cS . <<<"$expected")" ]
}

@test ".mcp.json が無ければ登録を消すだけにする" {
  run run_script
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" = remove ]
}

@test "cua_repl が無い .mcp.json では失敗する" {
  mkdir -p "$PLUGIN/1.0.0"
  echo '{"mcpServers": {}}' >"$PLUGIN/1.0.0/.mcp.json"
  run run_script
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/payload.json" ]
}

@test ".mcp.json が変わると描画結果も変わる（run_onchange が再実行される）" {
  write_mcp 1.0.0
  before=$(render)
  write_mcp 1.0.1
  [ "$(render)" != "$before" ]
}
