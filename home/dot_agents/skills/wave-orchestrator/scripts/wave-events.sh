#!/bin/bash
# 子セッションの状態を hook イベントから判定する (kryota-dev/dotfiles#437)。
#
# 記録側は home/dot_claude/executable_wave-session-event.sh。ここは記録された
# payload を読むだけで、tmux にもプロセス状態にも依存しない。だから単体テスト
# (tests/wave_orchestrator.bats) で固定できる。
#
# fail-safe 契約: 記録側は fail-open (セッションを止めない) だが、こちらは逆。
# イベントが読めないことを「稼働中」と解釈せず UNKNOWN を返す。停止の見落とし
# は沈黙するので、判定不能を正常と混同させない (#436 の教訓)。
#
# **到着順を時系列として扱わない**: 4 つの hook はすべて async なので、書き込み
# 順は発生順と一致しない。単純な「最後の行」で状態を決めると、遅れて届いた
# UserPromptSubmit が停止中の子を RUNNING に見せてしまい、また停止を見落とす。
# そこで同一ターンを表す prompt_id で束ね、ターン内は論理順序 (UserPromptSubmit
# < Notification < Stop) で判定する。prompt_id が 3 イベントで一致することは
# 実測で確認済み。
#
# usage:
#   wave-events.sh --session <uuid> --state           # ASK | RUNNING | IDLE | UNKNOWN
#   wave-events.sh --session <uuid> --question        # 現在ターンの選択肢を JSON で
#   wave-events.sh --session <uuid> --key-for <label> # 選択肢に対応する数字キー
#   wave-events.sh --session <uuid> --purge           # 記録を削除する (wave 完了後)
#   wave-events.sh --self-check                       # 配線と記録先の確認
set -euo pipefail

EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
SETTINGS_FILE="${WAVE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# 停止を意味する notification_type。ここだけが「止まっている」の判定根拠で、
# 画面に描かれた文言は一切見ない (#435)。
STOP_NOTIFICATIONS='^(permission_prompt|idle_prompt|agent_needs_input)$'

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

die() {
  echo "$1" >&2
  exit 2
}

# session_id はファイル名に連結される。記録側だけでなく読取側でも検証する
# (呼び出し側の値が外部入力に影響されても、イベントディレクトリの外を読ませない)。
validate_session() {
  printf '%s' "$1" | grep -qE "$UUID_RE" || die "session が UUID 形式でない"
}

event_file() {
  printf '%s/%s.jsonl' "$EVENT_DIR" "$1"
}

# 壊れた行は飛ばして読める分だけを返す。同一セッションへの同時 hook 書き込みは
# 直列化されていないため行が壊れうるが、1 行の破損で監視全体を止めない。
read_events() {
  jq -c '.' "$1" 2>/dev/null || true
}

# 最新ターン (最後に現れた prompt_id) のイベントだけを取り出す。prompt_id を
# 持たない行は落とす。
latest_turn() {
  read_events "$1" | jq -sc '
    [ .[] | select(.prompt_id != null) ] as $evs
    | if ($evs | length) == 0 then []
      else ($evs | last | .prompt_id) as $pid
        | [ $evs[] | select(.prompt_id == $pid) ]
      end
  '
}

# ターン内は論理順序で判定する（到着順を見ない）:
#   Stop があれば IDLE / 停止 Notification があれば ASK / それ以外は RUNNING
cmd_state() {
  local f turn
  f="$(event_file "$1")"
  [ -s "$f" ] || {
    echo "UNKNOWN"
    return 0
  }
  turn="$(latest_turn "$f")"
  local st
  st="$(printf '%s' "$turn" | jq -r --arg re "$STOP_NOTIFICATIONS" '
    if length == 0 then "UNKNOWN"
    elif any(.[]; .hook_event_name == "Stop") then "IDLE"
    elif any(.[]; .hook_event_name == "Notification"
                  and ((.notification_type // "") | test($re))) then "ASK"
    elif any(.[]; .hook_event_name == "UserPromptSubmit") then "RUNNING"
    else "UNKNOWN" end
  ' 2>/dev/null || true)"
  [ -n "$st" ] || st="UNKNOWN"
  echo "$st"
}

# 現在ターンの AskUserQuestion だけを返す。過去ターンの質問を掴まない
# (掴むと、前の質問の選択肢番号を今の画面へ送る事故になる)。
current_question() {
  latest_turn "$1" | jq -c '
    [ .[] | select(.hook_event_name == "PreToolUse" and .tool_name == "AskUserQuestion") ]
    | last | if . == null then empty else .tool_input end
  ' 2>/dev/null || true
}

cmd_question() {
  local f q
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  q="$(current_question "$f")"
  [ -n "$q" ] || die "現在ターンに選択肢のイベントが無い"
  printf '%s\n' "$q"
}

# 選択肢ラベルに対応する数字キーを返す。TUI は数字キーで直接選択でき、
# ハイライトの現在位置に依存しない。**現在ターンかつ ASK のときだけ**返す:
# 過去ターンの質問から番号を引くと、意図と別の選択肢を確定させてしまう。
cmd_key_for() {
  local f label idx state
  f="$(event_file "$1")"
  label="$2"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  state="$(cmd_state "$1")"
  [ "$state" = "ASK" ] || die "現在このセッションは応答待ちではない (state=$state)"
  idx="$(current_question "$f" | jq -r --arg label "$label" '
    if . == null then empty
    else ([ .questions[0].options[] | .label ] | index($label)) end
  ' 2>/dev/null || true)"
  case "$idx" in
    '' | null) die "現在の質問に提示されていない選択肢: $label" ;;
  esac
  echo $((idx + 1))
}

# wave 完了後に記録を消す。payload は質問文と選択肢 (会話内容) を含むので、
# 作業が終わったら残さない。
cmd_purge() {
  local f
  f="$(event_file "$1")"
  rm -f "$f"
  echo "削除: $f"
}

# 記録先を安全な mode で用意する。hook 側の umask 077 は**既存**ディレクトリの
# mode を直さないため、こちらが先に 755 で作ってしまうと保護が崩れる。
ensure_event_dir() {
  (
    umask 077
    mkdir -p "$EVENT_DIR" 2>/dev/null
  ) || return 1
  chmod 700 "$EVENT_DIR" 2>/dev/null || true
}

# 検証できたことと、この時点では検証できないことを区別して報告する。
# 「未観測」を「検証済み」と言わないのが要点 (検知器の静かな故障を隠さない)。
cmd_self_check() {
  local ok=0

  if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1 &&
    jq -e '[.hooks[]?[]?.hooks[]?.command] | map(select(test("wave-session-event"))) | length > 0' \
      "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "配線: settings に hook が入っている"
  else
    echo "配線: settings に hook が見つからない — 停止は検知できない" >&2
    ok=1
  fi

  if ensure_event_dir && [ -w "$EVENT_DIR" ]; then
    echo "記録先: 書き込み可能 ($EVENT_DIR)"
  else
    echo "記録先: 書き込めない ($EVENT_DIR)" >&2
    ok=1
  fi

  local n
  n="$(find "$EVENT_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt 0 ]; then
    echo "イベント: ${n} セッション分を観測済み"
  else
    echo "イベント: 未観測（まだ子セッションが動いていないだけの可能性あり。検証はできていない）"
  fi

  return "$ok"
}

SESSION=""
ACTION=""
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --state | --question | --purge)
      ACTION="${1#--}"
      shift
      ;;
    --key-for)
      ACTION="key-for"
      LABEL="${2:-}"
      shift 2
      ;;
    --self-check)
      ACTION="self-check"
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq が必要"

case "$ACTION" in
  state | question | purge)
    [ -n "$SESSION" ] || die "--session は必須"
    validate_session "$SESSION"
    "cmd_${ACTION}" "$SESSION"
    ;;
  key-for)
    [ -n "$SESSION" ] || die "--session は必須"
    [ -n "$LABEL" ] || die "--key-for にはラベルが要る"
    validate_session "$SESSION"
    cmd_key_for "$SESSION" "$LABEL"
    ;;
  self-check) cmd_self_check ;;
  *) die "--state / --question / --key-for / --purge / --self-check のいずれかを指定すること" ;;
esac
