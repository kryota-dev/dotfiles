#!/usr/bin/env bats

# wave-orchestrator の hook ベース停止検知 (kryota-dev/dotfiles#437)。
#
# 記録側 (home/dot_claude/executable_wave-session-event.sh) と判定側
# (home/dot_agents/skills/wave-orchestrator/scripts/wave-events.sh) を、
# fixture の hook payload だけで検証する。判定は tmux にもプロセス状態にも
# 依存しないので、ここで固定できる。
#
# 3 つの既知欠陥への回帰テストを含む:
#   #435 状態判定が TUI の文言に依存しないこと
#   #436 過去のイベントに引きずられて停止を見落とさないこと
#   #438 送信の成否を画面テキストで判定しないこと

load helpers/setup

HOOK="${HOME_DIR}/dot_claude/executable_wave-session-event.sh"
EVENTS="${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/wave-events.sh"
SETTINGS="${HOME_DIR}/dot_claude/settings.json"

SID="b7dffef5-1179-4362-b3d5-3bfd83a88b17"
SID2="e7a64474-2161-417a-8763-5a491cde1c9c"

setup() {
  EVENT_DIR="${BATS_TEST_TMPDIR}/events"
}

# パーミッションを 3 桁 8 進で返す。CI は Ubuntu (GNU stat)、開発機は macOS
# (BSD stat) なので両方に対応させる。
#
# GNU を先に試すこと。GNU stat の -f は --file-system で、ファイルを渡しても
# エラーにならず別の値を返すため、BSD 形式を先に置くとフォールバックが働かない
# (macOS では通るのに CI だけ落ちた)。BSD stat に -c は無いので、この順序なら
# 双方で正しい値になる。
perms() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# hook を payload (stdin) 付きで実行する。記録は opt-in なので
# WAVE_ORCHESTRATOR_SESSION を立てる（orchestrator が子へ渡すのと同じ）。
run_hook() {
  run env WAVE_EVENT_DIR="$EVENT_DIR" WAVE_ORCHESTRATOR_SESSION=1 bash "$HOOK" <<<"$1"
}

# opt-in なしで hook を実行する（通常セッション相当）
run_hook_without_optin() {
  run env WAVE_EVENT_DIR="$EVENT_DIR" bash "$HOOK" <<<"$1"
}

# 判定スクリプトを実行する。settings も worktree 側を見せる（実環境の
# ~/.claude/settings.json に依存すると、テストが機械の状態で揺れる）。
run_events() {
  run env WAVE_EVENT_DIR="$EVENT_DIR" WAVE_SETTINGS_FILE="$SETTINGS" bash "$EVENTS" "$@"
}

# --- fixture payload -------------------------------------------------------

# prompt_id は同一ターンを束ねる鍵。3 イベントで一致することは実測済みで、
# 判定はこれを使って到着順への依存を断つ。既定は TURN1。
TURN1="67563479-3b56-4eea-8226-a2de831d6e66"
TURN2="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

payload_notification() {
  local sid="${1:-$SID}" type="${2:-permission_prompt}" pid="${3:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"Notification","notification_type":"%s","message":"Claude needs your permission","cwd":"/tmp/wt"}' "$sid" "$pid" "$type"
}

payload_prompt_submit() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"UserPromptSubmit","cwd":"/tmp/wt"}' "$sid" "$pid"
}

payload_stop() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"Stop","cwd":"/tmp/wt"}' "$sid" "$pid"
}

payload_ask_question() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}" first="${3:-青}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_1","cwd":"/tmp/wt","tool_input":{"questions":[{"question":"どれにしますか？","header":"選択","multiSelect":false,"options":[{"label":"%s","description":"1 番目"},{"label":"赤","description":"2 番目"},{"label":"緑","description":"3 番目"}]}]}}' "$sid" "$pid" "$first"
}

# --- 記録側 ---------------------------------------------------------------

@test "hook: payload を session_id ごとのファイルへ追記する" {
  run_hook "$(payload_notification)"
  [ "$status" -eq 0 ]
  [ -f "${EVENT_DIR}/${SID}.jsonl" ]
  run jq -r '.notification_type' "${EVENT_DIR}/${SID}.jsonl"
  [ "$output" = "permission_prompt" ]
}

@test "hook: 記録先ディレクトリは所有者のみ、ファイルは所有者のみ読み書き" {
  run_hook "$(payload_notification)"
  [ "$status" -eq 0 ]
  # ディレクトリ 700 / ファイル 600
  run perms "$EVENT_DIR"
  [ "$output" = "700" ]
  run perms "${EVENT_DIR}/${SID}.jsonl"
  [ "$output" = "600" ]
}

@test "hook: session_id が UUID 形式でなければ書き込まない (path traversal 拒否)" {
  run_hook '{"session_id":"../../evil","hook_event_name":"Notification","notification_type":"permission_prompt"}'
  [ "$status" -eq 0 ]
  # イベントディレクトリの外にも中にも書かれない
  [ ! -e "${BATS_TEST_TMPDIR}/evil.jsonl" ]
  [ ! -e "${EVENT_DIR}/../../evil.jsonl" ]
  run bash -c "ls '$EVENT_DIR' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "hook: session_id が無い payload では書き込まない" {
  run_hook '{"hook_event_name":"Notification","notification_type":"permission_prompt"}'
  [ "$status" -eq 0 ]
  run bash -c "ls '$EVENT_DIR' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "hook: 別セッションのイベントが混ざらない" {
  run_hook "$(payload_notification "$SID")"
  run_hook "$(payload_notification "$SID2")"
  run bash -c "wc -l < '${EVENT_DIR}/${SID}.jsonl' | tr -d ' '"
  [ "$output" = "1" ]
  run bash -c "wc -l < '${EVENT_DIR}/${SID2}.jsonl' | tr -d ' '"
  [ "$output" = "1" ]
}

@test "hook: opt-in が無い通常セッションでは記録しない" {
  # hook は全セッションに配線されるが、wave の子でなければ会話内容を残さない
  run_hook_without_optin "$(payload_notification)"
  [ "$status" -eq 0 ]
  run bash -c "ls '$EVENT_DIR' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "hook: jq が無くても Claude 本体を止めない (fail-open)" {
  # jq を PATH から外して実行しても exit 0
  run env WAVE_EVENT_DIR="$EVENT_DIR" PATH="/usr/bin:/bin" \
    bash -c "PATH=\$(echo \$PATH | tr ':' '\n' | grep -v jq | paste -sd: -); exec bash '$HOOK'" <<<"$(payload_notification)"
  [ "$status" -eq 0 ]
}

# --- 判定側 ---------------------------------------------------------------

@test "events: 停止イベントで ASK を返す" {
  run_hook "$(payload_notification)"
  run_events --session "$SID" --state
  [ "$status" -eq 0 ]
  [ "$output" = "ASK" ]
}

@test "events: プロンプト送信後は RUNNING を返す" {
  run_hook "$(payload_prompt_submit)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: 応答完了後は IDLE を返す" {
  run_hook "$(payload_notification)"
  run_hook "$(payload_stop)"
  run_events --session "$SID" --state
  [ "$output" = "IDLE" ]
}

@test "events: #436 回帰 — 過去ターンの完了イベントに引きずられて停止を見落とさない" {
  # ターン 1 は完了済み。ターン 2 で停止している。過去ターンの Stop を拾わない
  run_hook "$(payload_prompt_submit "$SID" "$TURN1")"
  run_hook "$(payload_stop "$SID" "$TURN1")"
  run_hook "$(payload_prompt_submit "$SID" "$TURN2")"
  run_hook "$(payload_notification "$SID" permission_prompt "$TURN2")"
  run_events --session "$SID" --state
  [ "$output" = "ASK" ]
}

@test "events: 非同期の到着順が入れ替わっても停止を見落とさない" {
  # hook は async なので UserPromptSubmit が Notification より後に書かれうる。
  # 同一ターン内は論理順序で判定するので、到着順に引きずられてはならない
  run_hook "$(payload_notification "$SID" permission_prompt "$TURN1")"
  run_hook "$(payload_prompt_submit "$SID" "$TURN1")"
  run_events --session "$SID" --state
  [ "$output" = "ASK" ]
}

@test "events: #435 回帰 — 状態は notification_type で決まり画面文言に依存しない" {
  # message を空にしても、notification_type だけで ASK と判定される
  run_hook '{"session_id":"'"$SID"'","prompt_id":"'"$TURN1"'","hook_event_name":"Notification","notification_type":"agent_needs_input","message":""}'
  run_events --session "$SID" --state
  [ "$output" = "ASK" ]
}

@test "events: 検知不能を稼働中と混同しない" {
  # イベントが 1 件も無い = 検知できていない。RUNNING ではなく UNKNOWN
  run_events --session "$SID" --state
  [ "$output" = "UNKNOWN" ]
}

@test "events: PreToolUse は状態を決めない (Notification と同時発火し順序が保証されないため)" {
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --state
  [ "$output" = "UNKNOWN" ]
}

@test "events: --question が質問文と選択肢ラベルを返す" {
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --question
  [ "$status" -eq 0 ]
  run bash -c "env WAVE_EVENT_DIR='$EVENT_DIR' bash '$EVENTS' --session '$SID' --question | jq -r '.questions[0].options[1].label'"
  [ "$output" = "赤" ]
}

@test "events: --key-for が選択肢の位置に対応する数字キーを返す" {
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --key-for "赤"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "events: --key-for は提示されていない選択肢を拒否する" {
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --key-for "黄"
  [ "$status" -ne 0 ]
}

@test "events: --key-for は応答待ちでないとき拒否する" {
  # 質問イベントはあるが停止していない（Notification 無し）
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --key-for "赤"
  [ "$status" -ne 0 ]
}

@test "events: --key-for は過去ターンの選択肢を使わない" {
  # ターン 1 の質問は「青/赤/緑」。ターン 2 の質問は「黄/赤/緑」で停止中。
  # ターン 1 にしかないラベルを指定したら拒否されなければならない
  run_hook "$(payload_ask_question "$SID" "$TURN1" 青)"
  run_hook "$(payload_stop "$SID" "$TURN1")"
  run_hook "$(payload_ask_question "$SID" "$TURN2" 黄)"
  run_hook "$(payload_notification "$SID" permission_prompt "$TURN2")"
  run_events --session "$SID" --key-for "青"
  [ "$status" -ne 0 ]
  # 現在ターンのラベルは通る
  run_events --session "$SID" --key-for "黄"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "events: 読取側も session を UUID 検証する" {
  run_events --session "../../etc/passwd" --state
  [ "$status" -ne 0 ]
}

@test "events: 壊れた行があっても読める分で判定する" {
  run_hook "$(payload_notification)"
  printf 'this is not json\n' >> "${EVENT_DIR}/${SID}.jsonl"
  run_events --session "$SID" --state
  [ "$output" = "ASK" ]
}

@test "events: --self-check は記録先を 700 で作る" {
  # hook より先に self-check が走っても保護が崩れないこと
  run_events --self-check
  run perms "$EVENT_DIR"
  [ "$output" = "700" ]
}

@test "events: --purge が記録を削除する" {
  run_hook "$(payload_notification)"
  [ -f "${EVENT_DIR}/${SID}.jsonl" ]
  run_events --session "$SID" --purge
  [ "$status" -eq 0 ]
  [ ! -e "${EVENT_DIR}/${SID}.jsonl" ]
}

@test "events: --self-check は検証できていない項目を検証済みと報告しない" {
  run_events --self-check
  [ "$status" -eq 0 ]
  # 実イベントを観測していない状態では「未観測」と明示される
  [[ "$output" == *"未観測"* ]]
}

# --- 配線 -----------------------------------------------------------------

@test "settings: wave-session-event が 4 イベントへ配線されている" {
  for ev in Notification PreToolUse Stop UserPromptSubmit; do
    run jq -r --arg ev "$ev" \
      '[.hooks[$ev][] | select(.id | startswith("") ) | .hooks[].command] | map(select(test("wave-session-event"))) | length' \
      "$SETTINGS"
    [ "$output" -ge 1 ]
  done
}

@test "settings: 既存 hook を壊していない" {
  # 通知系 hook が Notification に残っていること
  run jq -r '[.hooks.Notification[] | .hooks[].command] | map(select(test("ntfy-notify"))) | length' "$SETTINGS"
  [ "$output" -ge 1 ]
  # 各イベントの既存エントリ数が減っていないこと（wave 追加後の下限）
  run jq -r '.hooks.PreToolUse | length' "$SETTINGS"
  [ "$output" -ge 9 ]
  run jq -r '.hooks.Stop | length' "$SETTINGS"
  [ "$output" -ge 7 ]
}

@test "settings: 旧 pane-state.sh が残っていない" {
  [ ! -e "${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/pane-state.sh" ]
}
