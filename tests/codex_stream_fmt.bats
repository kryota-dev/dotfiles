#!/usr/bin/env bats

# codex-stream-fmt（multi-review の Codex ライブ観測ペイン整形ヘルパー）のテスト。
# codex exec --json の JSONL イベント（codex-cli 0.145.0 実測形）を簡潔な 1 行へ
# 整形できること、未知/不正入力を握り潰さないこと、jq 不在時に素通しすること、
# 端末エスケープ（ANSI/OSC 等）を無害化することを検証する。

load helpers/setup

setup() {
  SCRIPT="${HOME_DIR}/dot_agents/skills/multi-review/executable_codex-stream-fmt"
}

# 整形は jq に依存する。jq が無い環境（最小 CI コンテナ等）では jq 必須ケースを
# fail させず skip する（jq 不在フォールバック自体のテストは別途 PATH を空にして起動する）。
require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

@test "codex-stream-fmt: スクリプトが存在する" {
  [ -f "$SCRIPT" ]
}

@test "codex-stream-fmt: thread.started → session 短縮（resume 用 thread_id 先頭）" {
  require_jq
  run bash "$SCRIPT" gen <<< '{"type":"thread.started","thread_id":"019fb164-17a2-7fc2-8264-62e27c10b3c8"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[gen]"* ]]
  [[ "$output" == *"▸ session 019fb164"* ]]
}

@test "codex-stream-fmt: turn.started → start（完全一致）" {
  require_jq
  run bash "$SCRIPT" gen <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  # 単一イベントは substring ではなく完全一致で契約を固定する。
  [ "$output" = "[gen] ▸ start" ]
}

@test "codex-stream-fmt: turn.completed → done + output_tokens" {
  require_jq
  run bash "$SCRIPT" gen <<< '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":237}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[gen] ✓ done (tokens: 237)" ]
}

@test "codex-stream-fmt: turn.completed の usage 欠落時は output_tokens 既定 0" {
  require_jq
  # usage/output_tokens が無いイベントでも `// 0` フォールバックで 0 を出す。
  run bash "$SCRIPT" gen <<< '{"type":"turn.completed"}'
  [ "$status" -eq 0 ]
  [ "$output" = "[gen] ✓ done (tokens: 0)" ]
}

@test "codex-stream-fmt: item.completed reasoning → …" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"エラーハンドリングを確認"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] … エラーハンドリングを確認" ]
}

@test "codex-stream-fmt: reasoning の text 欠落時は summary にフォールバック" {
  require_jq
  # text が無ければ summary を使う（short() の `$ev.item.text // $ev.item.summary`）。
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"type":"reasoning","summary":"要約のみ"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] … 要約のみ" ]
}

@test "codex-stream-fmt: item.completed command_execution → ⚙" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"rg catch src/"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] ⚙ rg catch src/" ]
}

@test "codex-stream-fmt: command_execution の command 欠落時は cmd にフォールバック" {
  require_jq
  # command が無ければ cmd を使う（short() の `$ev.item.command // $ev.item.cmd`）。
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"type":"command_execution","cmd":"ls -la"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] ⚙ ls -la" ]
}

@test "codex-stream-fmt: item.completed agent_message → ✎" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"[MUST] auth.ts:31 未 await"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"✎ [MUST] auth.ts:31 未 await"* ]]
}

@test "codex-stream-fmt: item.completed error → ⚠（握り潰さない）" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"i0","type":"error","message":"Skill descriptions were shortened"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ Skill descriptions were shortened"* ]]
}

@test "codex-stream-fmt: 未知の item type は種別だけ出す（· type）" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"item.completed","item":{"id":"iX","type":"widget"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] · widget" ]
}

@test "codex-stream-fmt: 未知のトップレベル type も種別だけ出す" {
  require_jq
  run bash "$SCRIPT" ts <<< '{"type":"session.updated"}'
  [ "$status" -eq 0 ]
  [ "$output" = "[ts] · session.updated" ]
}

@test "codex-stream-fmt: パース不能な行は leg タグ付きで素通し" {
  require_jq
  run bash "$SCRIPT" gen <<< 'not a json line'
  [ "$status" -eq 0 ]
  [ "$output" = "[gen] not a json line" ]
}

@test "codex-stream-fmt: 空行は出力しない" {
  require_jq
  run bash "$SCRIPT" gen <<< ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex-stream-fmt: 複数行 JSONL は入力順に 1 行ずつ整形する（順序契約）" {
  require_jq
  # tail -f が渡す複数行を、順序を保って 1:1 で整形することを固定する。
  run bash "$SCRIPT" ts <<< $'{"type":"thread.started","thread_id":"aabbccdd-0000-0000-0000-000000000000"}\n{"type":"turn.started"}\n{"type":"turn.completed","usage":{"output_tokens":5}}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "[ts] ▸ session aabbccdd" ]
  [ "${lines[1]}" = "[ts] ▸ start" ]
  [ "${lines[2]}" = "[ts] ✓ done (tokens: 5)" ]
}

@test "codex-stream-fmt: 長い本文は 80 文字で切り詰めて … を付ける" {
  require_jq
  local long
  long=$(printf 'x%.0s' {1..100})
  run bash "$SCRIPT" ts <<< "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"${long}\"}}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"…"* ]]
  # 100 文字全部は出さない（切り詰められている）
  [[ "$output" != *"$long"* ]]
}

@test "codex-stream-fmt: leg 名を省略すると codex になる" {
  require_jq
  run bash "$SCRIPT" <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  [ "$output" = "[codex] ▸ start" ]
}

@test "codex-stream-fmt: jq 不在時は leg タグ付きで生 JSONL を素通し（フォールバック）" {
  # PATH から jq を外して起動（/bin/bash は絶対パスで解決）。フォールバック分岐は
  # read/printf ビルトインのみで動くため外部コマンド不要。
  run env PATH="${BATS_TEST_TMPDIR:-/tmp}" /bin/bash "$SCRIPT" fb <<< '{"type":"turn.started"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'[fb] {"type":"turn.started"}'* ]]
}

# --- 端末エスケープ無害化（terminal escape injection 対策） ---

@test "codex-stream-fmt: agent_message 内の ANSI/OSC エスケープを無害化する（valid JSON 経路）" {
  require_jq
  # ESC を含む値を jq で valid JSON に組み立て（値のバイトは実行時 printf で生成）、fromjson→short 経由で
  # 出力される。無害化前は ESC/BEL が素通しされる（このテストが RED を示す）。
  local esc bel input
  esc=$(printf '\033'); bel=$(printf '\007')
  input=$(jq -cn --arg t "start${esc}[31mRED${esc}[0m${esc}]0;pwn${bel}end" \
    '{type:"item.completed",item:{type:"agent_message",text:$t}}')
  run bash "$SCRIPT" ts <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]   # ESC 除去
  [[ "$output" != *$'\007'* ]]   # BEL 除去
  [[ "$output" == *"RED"* ]]     # 可視テキストは残る（不活性化のみ）
}

@test "codex-stream-fmt: パース不能な生行のエスケープも無害化する（raw 素通し経路）" {
  require_jq
  local input
  input=$(printf 'not json \033[2Jclear \033]0;pwn\007 tail')
  run bash "$SCRIPT" gen <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *$'\007'* ]]
  [[ "$output" == *"tail"* ]]
}

@test "codex-stream-fmt: jq 不在フォールバックでもエスケープを無害化する" {
  local input
  input=$(printf 'raw \033[31mx\007y')
  run env PATH="${BATS_TEST_TMPDIR:-/tmp}" /bin/bash "$SCRIPT" fb <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *$'\007'* ]]
  [[ "$output" == *"[fb]"* ]]
}

@test "codex-stream-fmt: jq 経路は C1 制御文字(0x80-0x9F)を除去し日本語は保持する" {
  require_jq
  # C1（U+009B = 8bit CSI 導入子）を含む値を jq で valid JSON に組み立てる。jq 経路は
  # codepoint 単位で無害化するため C1 は除去され、日本語（U+3000 以降）は保持される。
  # フォールバック経路はバイト単位のため C1 を残す（保証範囲の差、スクリプト冒頭コメント参照）。
  local input c1
  input=$(jq -cn '{type:"item.completed",item:{type:"agent_message",text:("日本語" + ([155]|implode) + "X")}}')
  c1=$(jq -rn '[155]|implode')   # U+009B 実体（byte 誤検知を避けるため codepoint で照合）
  run bash "$SCRIPT" ts <<< "$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$c1"* ]]     # C1 は出力に残らない
  [[ "$output" == *"日本語"* ]]   # 日本語は保持される
  [[ "$output" == *"X"* ]]
}
