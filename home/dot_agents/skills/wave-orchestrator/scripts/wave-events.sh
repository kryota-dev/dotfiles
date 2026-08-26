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
# usage:
#   wave-events.sh --session <uuid> --state          # ASK | RUNNING | IDLE | UNKNOWN
#   wave-events.sh --session <uuid> --question       # 最新の選択肢を JSON で
#   wave-events.sh --session <uuid> --key-for <label> # 選択肢に対応する数字キー
#   wave-events.sh --self-check                      # 配線と記録先の確認
set -euo pipefail

EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
SETTINGS_FILE="${WAVE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# 停止を意味する notification_type。ここだけが「止まっている」の判定根拠で、
# 画面に描かれた文言は一切見ない (#435)。
STOP_NOTIFICATIONS='^(permission_prompt|idle_prompt|agent_needs_input)$'

die() {
  echo "$1" >&2
  exit 2
}

event_file() {
  printf '%s/%s.jsonl' "$EVENT_DIR" "$1"
}

# 最後の「状態を決めるイベント」から状態を導く。PreToolUse は状態を決めない
# (Notification と同時発火し順序が保証されないため、判定根拠を一本化する)。
cmd_state() {
  local f
  f="$(event_file "$1")"
  [ -s "$f" ] || {
    echo "UNKNOWN"
    return 0
  }
  local st
  st="$(jq -rs --arg re "$STOP_NOTIFICATIONS" '
    [ .[] | select(
        (.hook_event_name == "Notification"
          and ((.notification_type // "") | test($re)))
        or .hook_event_name == "Stop"
        or .hook_event_name == "UserPromptSubmit"
      ) ]
    | last
    | if . == null then "UNKNOWN"
      elif .hook_event_name == "Notification" then "ASK"
      elif .hook_event_name == "Stop" then "IDLE"
      else "RUNNING" end
  ' "$f" 2>/dev/null || true)"
  [ -n "$st" ] || st="UNKNOWN"
  echo "$st"
}

# 最新の AskUserQuestion の tool_input を返す
cmd_question() {
  local f
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  local q
  q="$(jq -cs '
    [ .[] | select(.hook_event_name == "PreToolUse" and .tool_name == "AskUserQuestion") ]
    | last | if . == null then empty else .tool_input end
  ' "$f" 2>/dev/null || true)"
  [ -n "$q" ] || die "選択肢のイベントが記録されていない"
  printf '%s\n' "$q"
}

# 選択肢ラベルに対応する数字キーを返す。TUI は数字キーで直接選択でき、
# ハイライトの現在位置に依存しない。照合が外れたら鍵を返さず失敗させる
# (意図と別の選択肢を無言で確定する事故を防ぐ)。
cmd_key_for() {
  local f label idx
  f="$(event_file "$1")"
  label="$2"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  idx="$(jq -rs --arg label "$label" '
    [ .[] | select(.hook_event_name == "PreToolUse" and .tool_name == "AskUserQuestion") ]
    | last
    | if . == null then empty
      else ([ .tool_input.questions[0].options[] | .label ] | index($label)) end
  ' "$f" 2>/dev/null || true)"
  case "$idx" in
    '' | null) die "提示されていない選択肢: $label" ;;
  esac
  echo $((idx + 1))
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

  if mkdir -p "$EVENT_DIR" 2>/dev/null && [ -w "$EVENT_DIR" ]; then
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
    --state | --question)
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
  state)
    [ -n "$SESSION" ] || die "--session は必須"
    cmd_state "$SESSION"
    ;;
  question)
    [ -n "$SESSION" ] || die "--session は必須"
    cmd_question "$SESSION"
    ;;
  key-for)
    [ -n "$SESSION" ] || die "--session は必須"
    [ -n "$LABEL" ] || die "--key-for にはラベルが要る"
    cmd_key_for "$SESSION" "$LABEL"
    ;;
  self-check) cmd_self_check ;;
  *) die "--state / --question / --key-for / --self-check のいずれかを指定すること" ;;
esac
