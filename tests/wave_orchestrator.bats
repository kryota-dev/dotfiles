#!/usr/bin/env bats

# wave-orchestrator の hook ベース停止検知 (kryota-dev/dotfiles#437)。
#
# 記録側 (home/dot_claude/executable_wave-session-event.sh) と判定側
# (home/dot_agents/skills/wave-orchestrator/scripts/executable_wave-events.sh) を、
# fixture の hook payload だけで検証する。判定は tmux にもプロセス状態にも
# 依存しないので、ここで固定できる。
#
# 3 つの既知欠陥への回帰テストを含む:
#   #435 状態判定が TUI の文言に依存しないこと
#   #436 過去のイベントに引きずられて停止を見落とさないこと
#   #438 送信の成否を画面テキストで判定しないこと
#   #440 skill script が配置後に直接実行できること
#   #441 選択肢の確定を検証せずに成功と報告しないこと
#   #443 auto mode の permission_prompt を停止と誤判定しないこと
#   #444 SKILL.md の tmux target が zsh の history modifier に食われないこと
#   #447 Stop 以降に出た AskUserQuestion を隠さないこと
#   #448 回答・キャンセルで ASK_QUESTION が解除されること
#   #471 --resume で再開したセッションへ送信できること

load helpers/setup

HOOK="${HOME_DIR}/dot_claude/executable_wave-session-event.sh"
EVENTS="${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/executable_wave-events.sh"
SEND="${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/executable_send-to-pane.sh"
SKILL_MD="${HOME_DIR}/dot_agents/skills/wave-orchestrator/SKILL.md"
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

# 決着イベント。tool_use_id で PreToolUse と対にする。記録側は相関フィールドだけを
# 書くので、ここでも tool_input / tool_response は持たせない。
payload_post_tool_use() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}" tuid="${3:-toolu_1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"%s"}' "$sid" "$pid" "$tuid"
}

# Esc キャンセル時の決着イベント。PostToolUse は成功時のみ発火するため、これが
# 無いと Esc 経路で未回答が永久に残る。
payload_post_tool_use_failure() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}" tuid="${3:-toolu_1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"PostToolUseFailure","tool_name":"AskUserQuestion","tool_use_id":"%s"}' "$sid" "$pid" "$tuid"
}

# API エラーでターンが終わったとき。Stop は来ない。
payload_stop_failure() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"StopFailure"}' "$sid" "$pid"
}

# permission_mode つきの UserPromptSubmit。Notification には permission_mode が
# 入らないので、auto mode の判別はターン内の他イベントから行う。
payload_prompt_submit_mode() {
  local sid="${1:-$SID}" mode="${2:-auto}" pid="${3:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","permission_mode":"%s","hook_event_name":"UserPromptSubmit"}' "$sid" "$pid" "$mode"
}

# tool_use_id を持たない質問。決着と突き合わせられないので未回答として残す
# （決着信号が取れないことを「回答済み」と読むと停止を見落とす）。
payload_ask_question_no_id() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","cwd":"/tmp/wt","tool_input":{"questions":[{"question":"q","header":"h","multiSelect":false,"options":[{"label":"単独","description":"d"}]}]}}' "$sid" "$pid"
}

# 複数問。2 問目に 1 問目と同じラベルを置いて曖昧判定を検証する。
payload_ask_question_multi() {
  local sid="${1:-$SID}" pid="${2:-$TURN1}"
  printf '{"session_id":"%s","prompt_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_m","cwd":"/tmp/wt","tool_input":{"questions":[{"question":"q1","header":"h1","multiSelect":false,"options":[{"label":"X","description":"d"},{"label":"same","description":"d"}]},{"question":"q2","header":"h2","multiSelect":false,"options":[{"label":"Y","description":"d"},{"label":"same","description":"d"}]}]}}' "$sid" "$pid"
}

# --- send-to-pane のスタブ環境 ---------------------------------------------
#
# tmux と ps に依存するので、キー送出の**順序と回数**を固定するためスタブへ
# 差し替える。実バイナリを呼ばないので CI でも動く。
# capture-pane は send-keys の後で別の内容を返せるようにしてあり、
# 「自分の操作の結果」を検証する経路をテストできる。
setup_pane_stubs() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "$STUB_DIR"
  STUB_LOG="${BATS_TEST_TMPDIR}/tmux.log"
  STUB_CAPTURE="${BATS_TEST_TMPDIR}/capture.txt"
  STUB_CAPTURE_AFTER="${BATS_TEST_TMPDIR}/capture-after.txt"
  STUB_SENT="${BATS_TEST_TMPDIR}/sent"
  : >"$STUB_LOG"
  : >"$STUB_CAPTURE"
  rm -f "$STUB_SENT" "$STUB_CAPTURE_AFTER"

  cat >"${STUB_DIR}/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  display-message) printf '%s\n' "${STUB_PANE_PID:-4242}" ;;
  capture-pane)
    if [ -e "$STUB_SENT" ] && [ -s "$STUB_CAPTURE_AFTER" ]; then
      cat "$STUB_CAPTURE_AFTER"
    else
      cat "$STUB_CAPTURE"
    fi
    ;;
  load-buffer) cat >/dev/null ;;
  send-keys) : >"$STUB_SENT" ;;
esac
exit 0
STUB

  cat >"${STUB_DIR}/ps" <<'STUB'
#!/bin/bash
# `-p <pid>` を読み、STUB_PS_SELF_PID と一致したら STUB_PS_ARGS_SELF を返す。
# 未設定なら従来どおり全 PID に STUB_PS_ARGS を返す (既存テストの挙動を保つ)。
queried=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) queried="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${STUB_PS_SELF_PID:-}" ] && [ "$queried" = "$STUB_PS_SELF_PID" ]; then
  printf '%s\n' "${STUB_PS_ARGS_SELF:-}"
else
  printf '%s\n' "${STUB_PS_ARGS:-}"
fi
exit 0
STUB

  cat >"${STUB_DIR}/pgrep" <<'STUB'
#!/bin/bash
# STUB_NO_CHILDREN=1 で「pane プロセスに子が居ない」状況を再現する
# (tmux にコマンドを直接渡すと sh が exec され pane_pid 自身が claude になる)。
[ -n "${STUB_NO_CHILDREN:-}" ] && exit 1
printf '%s\n' "${STUB_CHILD_PID:-4243}"
exit 0
STUB

  chmod +x "${STUB_DIR}/tmux" "${STUB_DIR}/ps" "${STUB_DIR}/pgrep"
}

run_send() {
  run env \
    WAVE_EVENT_DIR="$EVENT_DIR" \
    WAVE_SETTINGS_FILE="$SETTINGS" \
    WAVE_EVENTS_BIN="$EVENTS" \
    WAVE_TMUX_BIN="${STUB_DIR}/tmux" \
    WAVE_PS_BIN="${STUB_DIR}/ps" \
    WAVE_PGREP_BIN="${STUB_DIR}/pgrep" \
    WAVE_CONFIRM_TIMEOUT=1 \
    STUB_LOG="$STUB_LOG" \
    STUB_CAPTURE="$STUB_CAPTURE" \
    STUB_CAPTURE_AFTER="$STUB_CAPTURE_AFTER" \
    STUB_SENT="$STUB_SENT" \
    STUB_PS_ARGS="${STUB_PS_ARGS:-}" \
    STUB_PS_ARGS_SELF="${STUB_PS_ARGS_SELF:-}" \
    STUB_PS_SELF_PID="${STUB_PS_SELF_PID:-}" \
    STUB_NO_CHILDREN="${STUB_NO_CHILDREN:-}" \
    STUB_PANE_PID="${STUB_PANE_PID:-}" \
    STUB_CHILD_PID="${STUB_CHILD_PID:-}" \
    bash "$SEND" "$@"
}

# tmux スタブのログから、特定のサブコマンドが何回呼ばれたかを数える。
stub_count() {
  grep -c -- "$1" "$STUB_LOG" 2>/dev/null || true
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

@test "events: 停止イベントで ASK_PERMISSION を返す" {
  run_hook "$(payload_notification)"
  run_events --session "$SID" --state
  [ "$status" -eq 0 ]
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: プロンプト送信後は RUNNING を返す" {
  run_hook "$(payload_prompt_submit)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: 応答完了後は IDLE を返す" {
  # auto mode では permission_prompt が自動承認され停止扱いにならないので、
  # Stop がそのまま IDLE を決める
  run_hook "$(payload_prompt_submit_mode "$SID" auto)"
  run_hook "$(payload_notification)"
  run_hook "$(payload_stop)"
  run_events --session "$SID" --state
  [ "$output" = "IDLE" ]
}

@test "events: 未解決の権限確認は Stop より優先される（fail-safe）" {
  # permission_prompt には AskUserQuestion の tool_use_id に相当する決着信号が
  # 無いため、Stop との前後関係を到着順に頼らず判別できない。サブエージェント
  # 委任ではターン途中に Stop が出る (#447) ので、Stop を優先すると**本物の
  # 権限待ちを IDLE と誤報告**しうる —— 送ってはいけないペインへ送る事故になる。
  #
  # 逆向きの誤り（ターン終了後も ASK_PERMISSION が残る）は、送信側が
  # fail-closed に落ちて何も送らないだけなので害が小さい。そちらへ倒す。
  run_hook "$(payload_prompt_submit_mode "$SID" default)"
  run_hook "$(payload_notification)"
  run_hook "$(payload_stop)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: #436 回帰 — 過去ターンの完了イベントに引きずられて停止を見落とさない" {
  # ターン 1 は完了済み。ターン 2 で停止している。過去ターンの Stop を拾わない
  run_hook "$(payload_prompt_submit "$SID" "$TURN1")"
  run_hook "$(payload_stop "$SID" "$TURN1")"
  run_hook "$(payload_prompt_submit "$SID" "$TURN2")"
  run_hook "$(payload_notification "$SID" permission_prompt "$TURN2")"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: 非同期の到着順が入れ替わっても停止を見落とさない" {
  # hook は async なので UserPromptSubmit が Notification より後に書かれうる。
  # 判定は集合演算なので、到着順に引きずられてはならない
  run_hook "$(payload_notification "$SID" permission_prompt "$TURN1")"
  run_hook "$(payload_prompt_submit "$SID" "$TURN1")"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: #435 回帰 — 状態は notification_type で決まり画面文言に依存しない" {
  # message を空にしても、notification_type だけで ASK_PERMISSION と判定される
  run_hook '{"session_id":"'"$SID"'","prompt_id":"'"$TURN1"'","hook_event_name":"Notification","notification_type":"agent_needs_input","message":""}'
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: 検知不能を稼働中と混同しない" {
  # イベントが 1 件も無い = 検知できていない。RUNNING ではなく UNKNOWN
  run_events --session "$SID" --state
  [ "$output" = "UNKNOWN" ]
}

@test "events: 未回答の AskUserQuestion は Notification を待たずに ASK_QUESTION を決める" {
  # 旧実装は PreToolUse を状態判定に使わず、Notification と同時発火する順序が
  # 保証されないことを理由に UNKNOWN を返していた。判定を tool_use_id の集合差へ
  # 移したので、決着イベントが無い PreToolUse は単独で「未回答」を意味する。
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]
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
  [ "$output" = "0:2" ]
}

@test "events: --key-for は提示されていない選択肢を拒否する" {
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --key-for "黄"
  [ "$status" -ne 0 ]
}

@test "events: --key-for は応答待ちでないとき拒否する" {
  # 質問は出たが決着イベントが来ている = 回答済み。番号を引かせてはならない
  # (閉じた画面へ裸の数字を打ち込む事故になる)
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_post_tool_use)"
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
  [ "$output" = "0:1" ]
}

@test "events: 読取側も session を UUID 検証する" {
  run_events --session "../../etc/passwd" --state
  [ "$status" -ne 0 ]
}

@test "events: 壊れた行があっても読める分で判定する" {
  run_hook "$(payload_notification)"
  printf 'this is not json\n' >> "${EVENT_DIR}/${SID}.jsonl"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
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

@test "settings: wave-session-event が 7 イベントへ配線されている" {
  for ev in Notification PreToolUse PostToolUse PostToolUseFailure Stop StopFailure UserPromptSubmit; do
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

# --- 状態判定の回帰（#443 / #447 / #448）----------------------------------

@test "events: #447 回帰 — Stop 以降に出た AskUserQuestion を隠さない" {
  # サブエージェントへ委任した親は一度 Stop を出し、同じ prompt_id のまま再開して
  # 質問を出す。any(Stop) を先に評価する論理順序では IDLE と誤報告していた
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  run_hook "$(payload_notification "$SID" idle_prompt)"
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]
}

@test "events: #448 回帰 — 回答されたら ASK_QUESTION を解除する" {
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]
  run_hook "$(payload_post_tool_use)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: #448 回帰 — Esc キャンセルでも ASK_QUESTION を解除する" {
  # PostToolUse は成功時のみ発火する。キャンセルは PostToolUseFailure で来るので
  # 片方だけ配線していると Esc 経路で未回答が永久に残る
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_post_tool_use_failure)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: 未回答判定はイベントの到着順に依存しない" {
  # 決着イベントが質問より先に書かれても結果は変わらない（集合の引き算だから）
  run_hook "$(payload_post_tool_use)"
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_prompt_submit)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: 未回答の質問は Stop より優先される" {
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_stop)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]
}

@test "events: #443 回帰 — auto mode の permission_prompt を停止扱いしない" {
  # auto mode では自動承認されて子は止まらないのに通知は発火する
  run_hook "$(payload_prompt_submit_mode "$SID" auto)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --state
  [ "$output" = "RUNNING" ]
}

@test "events: #443 回帰 — 非 auto mode の permission_prompt は停止扱いする" {
  run_hook "$(payload_prompt_submit_mode "$SID" default)"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: #443 回帰 — permission_mode が混在するときは停止扱い（fail-safe）" {
  # ターン中に mode が変わった可能性がある。見落とさない側へ倒す
  run_hook "$(payload_prompt_submit_mode "$SID" auto)"
  run_hook "$(payload_ask_question)"
  run_hook "$(payload_post_tool_use)"
  printf '%s\n' '{"session_id":"'"$SID"'","prompt_id":"'"$TURN1"'","permission_mode":"default","hook_event_name":"Stop"}' >>"${EVENT_DIR}/${SID}.jsonl"
  run_hook "$(payload_notification)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: agent_needs_input は auto mode でも停止扱い" {
  # permission_prompt と違い自動承認の対象ではない
  run_hook "$(payload_prompt_submit_mode "$SID" auto)"
  run_hook "$(payload_notification "$SID" agent_needs_input)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_PERMISSION" ]
}

@test "events: idle_prompt は IDLE（人が答えるべき問いではない）" {
  run_hook "$(payload_prompt_submit_mode "$SID" auto)"
  run_hook "$(payload_notification "$SID" idle_prompt)"
  run_events --session "$SID" --state
  [ "$output" = "IDLE" ]
}

@test "events: StopFailure も IDLE の根拠になる" {
  # API エラーでターンが終わると Stop が来ない。拾わないと RUNNING に張り付く
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop_failure)"
  run_events --session "$SID" --state
  [ "$output" = "IDLE" ]
}

@test "events: tool_use_id を持たない質問は未回答として残す（fail-safe）" {
  # 決着と突き合わせられない = 回答済みと判断してはいけない
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question_no_id)"
  run_hook "$(payload_post_tool_use)"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]
}

@test "events: --pending-question は未回答の質問だけを返す" {
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  run_events --session "$SID" --pending-question
  [ "$status" -eq 0 ]
  run_hook "$(payload_post_tool_use)"
  # 回答済みになったら返さない（--question は返し続けるので使い分ける）
  run_events --session "$SID" --pending-question
  [ "$status" -ne 0 ]
  run_events --session "$SID" --question
  [ "$status" -eq 0 ]
}

@test "events: --key-for は複数問の問い index を返す" {
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question_multi)"
  run_events --session "$SID" --key-for "X"
  [ "$output" = "0:1" ]
  run_events --session "$SID" --key-for "Y"
  [ "$output" = "1:1" ]
}

@test "events: --key-for は複数の問いにある同名ラベルを曖昧として拒否する" {
  # どの問いに答えるつもりなのか決められないまま送るほうが危険
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question_multi)"
  run_events --session "$SID" --key-for "same"
  [ "$status" -ne 0 ]
}

# --- 記録側の射影（#448）--------------------------------------------------

@test "hook: PostToolUse は相関フィールドだけを記録する（回答本文を残さない）" {
  run_hook '{"session_id":"'"$SID"'","prompt_id":"'"$TURN1"'","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_1","tool_input":{"questions":[]},"tool_response":{"answers":[{"choice":"SECRET_ANSWER"}]}}'
  run cat "${EVENT_DIR}/${SID}.jsonl"
  [[ "$output" == *"toolu_1"* ]]
  [[ "$output" != *"SECRET_ANSWER"* ]]
  [[ "$output" != *"tool_response"* ]]
  [[ "$output" != *"tool_input"* ]]
}

@test "hook: PostToolUseFailure も相関フィールドだけを記録する" {
  run_hook '{"session_id":"'"$SID"'","prompt_id":"'"$TURN1"'","hook_event_name":"PostToolUseFailure","tool_name":"AskUserQuestion","tool_use_id":"toolu_9","tool_response":{"error":"SECRET_ERROR"}}'
  run cat "${EVENT_DIR}/${SID}.jsonl"
  [[ "$output" == *"toolu_9"* ]]
  [[ "$output" != *"SECRET_ERROR"* ]]
}

@test "hook: 決着イベント以外は従来どおり verbatim で記録する" {
  local p
  p="$(payload_ask_question)"
  run_hook "$p"
  run cat "${EVENT_DIR}/${SID}.jsonl"
  [ "$output" = "$p" ]
}

@test "settings: 決着イベント 2 種が AskUserQuestion へ配線されている" {
  # 片方だけだと Esc 経路で未回答が永久に残る
  for ev in PostToolUse PostToolUseFailure; do
    run jq -r --arg ev "$ev" \
      '[.hooks[$ev][] | select(.matcher == "AskUserQuestion") | .hooks[].command] | map(select(test("wave-session-event"))) | length' \
      "$SETTINGS"
    [ "$output" -ge 1 ]
  done
}

# --- 配置とドキュメント（#440 / #444）------------------------------------

@test "#440 回帰: skill script の source は executable_ プレフィックスを持つ" {
  # chezmoi は executable_ が無いファイルの実行ビットを落とすため、SKILL.md に
  # 書かれた直接実行形が Permission denied になる
  [ -f "${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/executable_wave-events.sh" ]
  [ -f "${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/executable_send-to-pane.sh" ]
  [ ! -e "${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/wave-events.sh" ]
  [ ! -e "${HOME_DIR}/dot_agents/skills/wave-orchestrator/scripts/send-to-pane.sh" ]
}

@test "#440 回帰: send-to-pane は wave-events を bash 経由ではなく直接実行する" {
  run grep -n 'bash "\$EVENTS"' "$SEND"
  [ "$status" -ne 0 ]
}

@test "#440 回帰: --self-check は直接実行できるかを検査する" {
  # bash 経由なら self-check は通ってしまうので、明示的に試さないと
  # exit 126 の沈黙する故障を捕まえられない
  run_events --self-check
  [[ "$output" == *"直接実行"* ]]
}

@test "#444 回帰: SKILL.md のコードブロックにブレース無しの変数付き target が無い" {
  # zsh は "$SESS:wave1" の :w :a を history modifier として解釈して target を壊す。
  # 散文中の「やってはいけない例」は対象外にし、**コピペ対象になるフェンス付き
  # コードブロックだけ**を検査する
  run python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"^```[^\n]*\n(.*?)^```", src, re.S | re.M)
bad = []
for b in blocks:
    for m in re.finditer(r"\$[A-Za-z_][A-Za-z0-9_]*:", b):
        bad.append(m.group(0))
print(" ".join(bad))
' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- send-to-pane（#441 / #442 / #445 / #450 / #471）----------------------

@test "#471 回帰: --resume で再開したセッションでも生存確認が成立する" {
  # 再開後の argv には --session-id が無く --resume だけがある。片方しか見て
  # いなかったため代理応答が一切通らなかった
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  STUB_PS_ARGS="claude --model=opus --effort high --resume ${SID}"
  run_send "%1" --session "$SID" --text "補足指示"
  # ガードを通過して送信まで進んだこと（3 値のいずれかが出る）
  [[ "$output" == QUEUED_UNCONFIRMED* || "$output" == DELIVERED* ]]
  [ "$(stub_count 'paste-buffer')" -ge 1 ]
}

@test "#471 回帰: --session-id 形式でも生存確認が成立する" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  STUB_PS_ARGS="claude --model=opus --session-id ${SID} -n ident"
  run_send "%1" --session "$SID" --text "補足指示"
  [[ "$output" == QUEUED_UNCONFIRMED* || "$output" == DELIVERED* ]]
}

@test "send-to-pane: セッションが argv に無ければ何も送らずに落ちる" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  STUB_PS_ARGS="claude --model=opus"
  run_send "%1" --session "$SID" --text "補足指示"
  [ "$status" -eq 1 ]
  [ "$(stub_count 'paste-buffer')" -eq 0 ]
  [ "$(stub_count 'send-keys')" -eq 0 ]
}

@test "#445 回帰: --text は選択肢が開いているとき本文を送らずに中止する" {
  # 暗黙に Escape を送って状態を変えない。効かなかったときに本文がキー入力として
  # 解釈され、誰も選んでいない回答が確定する
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  run_send "%1" --session "$SID" --text "訂正の指示"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--dismiss"* ]]
  [ "$(stub_count 'paste-buffer')" -eq 0 ]
  [ "$(stub_count 'send-keys')" -eq 0 ]
}

@test "#448 派生の回帰: --select は選択肢 UI が画面に無ければ数字キーを送らない" {
  # Esc で閉じた後もイベント側の条件は成立しうる。実在を確かめないと閉じた画面へ
  # 裸の数字が入力欄に打ち込まれる
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  : >"$STUB_CAPTURE" # 選択肢 UI のマーカーが無い画面
  run_send "%1" --session "$SID" --select "赤"
  [ "$status" -eq 1 ]
  [ "$(stub_count 'send-keys')" -eq 0 ]
}

@test "#441 回帰: --select は数字キーのみを送り Enter を投機的に送らない" {
  # claude 2.1.221 以降は数字キーが確定して次の問いへ進むため、続けて Enter を
  # 送ると次の問いの既定値を確定させる（誰も答えていない問いに ✔ が付いた）
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE"
  # 数字キー送出後の画面は確認画面へ進んでいる（= 確定した）
  printf 'Ready to submit your answers?\n' >"$STUB_CAPTURE_AFTER"
  run_send "%1" --session "$SID" --select "赤"
  [ "$status" -eq 0 ]
  [[ "$output" == CONFIRMED_* ]]
  # 送ったキーは数字の 1 回だけ。Enter は送っていない
  [ "$(stub_count 'send-keys')" -eq 1 ]
  [ "$(stub_count 'Enter')" -eq 0 ]
  run grep -c -- '-l 2' "$STUB_LOG"
  [ "$output" -eq 1 ]
}

@test "#442 / #450 回帰: --text は本文が入力欄に残っても本文を再送しない" {
  # 失われたのは確定キーだけ。本文を再送すると連結して二重入力になる。
  # 入力欄をクリアもしない（届いた指示を捨てることになる）
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf '%s\n' '❯ 送れなかった本文がここに残っている' >"$STUB_CAPTURE"
  run_send "%1" --session "$SID" --text "長文の指示"
  [ "$status" -eq 11 ]
  [[ "$output" == *"PENDING_CONFIRM"* ]]
  # 本文の送出は 1 回だけ（再送していない）
  [ "$(stub_count 'paste-buffer')" -eq 1 ]
  [ "$(stub_count 'load-buffer')" -eq 1 ]
  # 確定キーは初回 + 1 回だけの再送
  [ "$(stub_count 'Enter')" -eq 2 ]
}

@test "#450 回帰: 入力欄が空なら配信済みとして扱い再送を促さない" {
  # UserPromptSubmit はキュー経由では発火しない。二値の成否だと必ず「失敗」を
  # 報告し、呼び出し側を二重キューへ誘導する
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_stop)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf '%s\n' '❯ ' >"$STUB_CAPTURE"
  run_send "%1" --session "$SID" --text "補足指示"
  [ "$status" -eq 10 ]
  [[ "$output" == QUEUED_UNCONFIRMED* ]]
  [[ "$output" == *"再送しない"* ]]
  [ "$(stub_count 'paste-buffer')" -eq 1 ]
}

@test "send-to-pane: --dismiss は選択肢が閉じたことを確認してから成功を報告する" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE"
  # Escape 送出後は選択肢 UI が消えている
  printf 'no option ui here\n' >"$STUB_CAPTURE_AFTER"
  run_send "%1" --session "$SID" --dismiss
  [ "$status" -eq 0 ]
  [[ "$output" == CLOSED* ]]
  [ "$(stub_count 'Escape')" -eq 1 ]
}

# Esc キャンセルは hook イベントを一切出さない (実機で確認)。決着を書き戻さないと
# state が ASK_QUESTION に固着し、--select は「UI が無い」、--text は「選択肢が
# 開いている」、--purge 後は UNKNOWN で拒否となり Leader が完全に手詰まりになる。
@test "send-to-pane: --dismiss は人が Esc で閉じた後の固着を解除する" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  # 人が既に Esc で閉じている: 画面に選択肢 UI が無い
  printf 'no option ui here\n' >"$STUB_CAPTURE"
  run_events --session "$SID" --state
  [ "$output" = "ASK_QUESTION" ]

  run_send "%1" --session "$SID" --dismiss
  [ "$status" -eq 0 ]
  [[ "$output" == ALREADY_CLOSED* ]]
  # Escape は送らない (既に閉じているので送る先が無い)
  [ "$(stub_count 'Escape')" -eq 0 ]

  # 決着が書き戻され、state が解除されている
  run_events --session "$SID" --state
  [ "$output" != "ASK_QUESTION" ]
}

@test "send-to-pane: 書き戻す決着は prompt_id を持つ" {
  # latest_turn() は prompt_id が非 null のイベントだけを取り、最後の prompt_id で
  # 束ねる。prompt_id を欠いた行はターンから丸ごと落ちるので、決着として書いても
  # state が解除されない (実機で踏んだ)。
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf 'no option ui here\n' >"$STUB_CAPTURE"
  run_send "%1" --session "$SID" --dismiss
  [ "$status" -eq 0 ]

  local line
  line="$(grep '"synthetic":"dismiss"' "${EVENT_DIR}/${SID}.jsonl")"
  [ -n "$line" ]
  [ "$(printf '%s' "$line" | jq -r '.prompt_id')" = "$TURN1" ]
  [ "$(printf '%s' "$line" | jq -r '.tool_use_id')" = "toolu_1" ]
  [ "$(printf '%s' "$line" | jq -r '.hook_event_name')" = "PostToolUseFailure" ]
}

@test "send-to-pane: Escape で閉じた場合も決着を書き戻す" {
  # Escape も hook イベントを出さないので、こちらの経路でも書き戻しが要る。
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE"
  printf 'no option ui here\n' >"$STUB_CAPTURE_AFTER"
  run_send "%1" --session "$SID" --dismiss
  [ "$status" -eq 0 ]
  [ "$(stub_count 'Escape')" -eq 1 ]
  run_events --session "$SID" --state
  [ "$output" != "ASK_QUESTION" ]
}

# ペインの立て方で claude の位置が変わる。対話 shell 経由なら pane_pid の子だが、
# tmux にコマンドを直接渡すと sh が exec で置き換わり pane_pid 自身が claude に
# なる (実機で確認)。子だけを見ていると後者で「動いていない」と誤拒否する。
@test "send-to-pane: pane プロセス自身が claude でも生存と判定する" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  export STUB_PANE_PID=4242
  export STUB_PS_SELF_PID=4242
  export STUB_PS_ARGS_SELF="claude --session-id ${SID}"
  # 子は居ない (exec されたため) / 子の argv も無関係なものにしておく
  export STUB_NO_CHILDREN=1
  export STUB_PS_ARGS="npm exec some-mcp-server"
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE"
  printf '☒ 選択\n' >"$STUB_CAPTURE_AFTER"
  run_send "%1" --session "$SID" --select "青"
  # 生存判定を通過している (「動いていない」で落ちない)
  [[ "$output" != *"動いていない"* ]]
}

@test "send-to-pane: --dismiss は閉じたことを確認できなければ非 0 で終わる" {
  setup_pane_stubs
  run_hook "$(payload_prompt_submit)"
  run_hook "$(payload_ask_question)"
  STUB_PS_ARGS="claude --resume ${SID}"
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE"
  # Escape を送っても選択肢 UI が残っている
  printf 'Enter to select · Esc to cancel\n' >"$STUB_CAPTURE_AFTER"
  run_send "%1" --session "$SID" --dismiss
  [ "$status" -eq 2 ]
  [ "$(stub_count 'paste-buffer')" -eq 0 ]
}
