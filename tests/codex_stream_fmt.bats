#!/usr/bin/env bats

# codex-stream-fmt（multi-review の Codex ライブ観測ペイン整形ヘルパー）のテスト。
# codex exec --json の JSONL イベント（codex-cli 0.145.0 実測形）を簡潔な 1 行へ
# 整形できること、未知/不正入力を握り潰さないこと、jq 不在時に素通しすることを検証する。

load helpers/setup

setup() {
  SCRIPT="${HOME_DIR}/dot_agents/skills/multi-review/executable_codex-stream-fmt"
}

@test "codex-stream-fmt: スクリプトが存在する" {
  [ -f "$SCRIPT" ]
}

@test "codex-stream-fmt: thread.started → session 短縮（resume 用 thread_id 先頭）" {
  run bash "$SCRIPT" gen <<< '{"type":"thread.started","thread_id":"019fb164-17a2-7fc2-8264-62e27c10b3c8"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[gen]"* ]]
  [[ "$output" == *"▸ session 019fb164"* ]]
}

@test "codex-stream-fmt: turn.started → start" {
  run bash "$SCRIPT" gen <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[gen] ▸ start"* ]]
}

@test "codex-stream-fmt: turn.completed → done + output_tokens" {
  run bash "$SCRIPT" gen <<< '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":237}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ done (tokens: 237)"* ]]
}

@test "codex-stream-fmt: item.completed reasoning → …" {
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"エラーハンドリングを確認"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ts] … エラーハンドリングを確認"* ]]
}

@test "codex-stream-fmt: item.completed command_execution → ⚙" {
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"rg catch src/"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚙ rg catch src/"* ]]
}

@test "codex-stream-fmt: item.completed agent_message → ✎" {
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"[MUST] auth.ts:31 未 await"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"✎ [MUST] auth.ts:31 未 await"* ]]
}

@test "codex-stream-fmt: item.completed error → ⚠（握り潰さない）" {
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i0","type":"error","message":"Skill descriptions were shortened"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ Skill descriptions were shortened"* ]]
}

@test "codex-stream-fmt: 未知の item type は種別だけ出す（· type）" {
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"iX","type":"widget"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ts] · widget"* ]]
}

@test "codex-stream-fmt: 未知のトップレベル type も種別だけ出す" {
  run bash "$SCRIPT" ts <<< '{"type":"session.updated"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ts] · session.updated"* ]]
}

@test "codex-stream-fmt: パース不能な行は leg タグ付きで素通し" {
  run bash "$SCRIPT" gen <<< 'not a json line'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[gen] not a json line"* ]]
}

@test "codex-stream-fmt: 空行は出力しない" {
  run bash "$SCRIPT" gen <<< ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex-stream-fmt: 長い本文は 80 文字で切り詰めて … を付ける" {
  local long
  long=$(printf 'x%.0s' {1..100})
  run bash "$SCRIPT" ts <<< "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"${long}\"}}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"…"* ]]
  # 100 文字全部は出さない（切り詰められている）
  [[ "$output" != *"$long"* ]]
}

@test "codex-stream-fmt: leg 名を省略すると codex になる" {
  run bash "$SCRIPT" <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[codex] ▸ start"* ]]
}

@test "codex-stream-fmt: jq 不在時は leg タグ付きで生 JSONL を素通し（フォールバック）" {
  # PATH から jq を外して起動（/bin/bash は絶対パスで解決）。フォールバック分岐は
  # read/printf ビルトインのみで動くため外部コマンド不要。
  run env PATH="${BATS_TEST_TMPDIR:-/tmp}" /bin/bash "$SCRIPT" fb <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'[fb] {"type":"turn.started"}'* ]]
}
