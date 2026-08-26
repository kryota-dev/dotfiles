#!/bin/bash
# 子セッションへの送信 (kryota-dev/dotfiles#437 で hook ベースへ移行)。
#
# 送信そのものは tmux のキー入力だが、**何を送るか**と**送れたか**は hook
# イベントから決める。画面テキストは一切見ない。
#
# 以前は「ハイライト中の選択肢を capture で照合してから Enter を送る」形だった。
# これは事故 (意図と別の選択肢が無言で確定し、誰も答えていないのに「ユーザー
# 承認済み」が成果物に残る) を防ぐための照合だったが、TUI は数字キーで選択肢を
# 直接選べるため、そもそもハイライト位置に依存しない送り方ができる。照合を
# 消せるなら壊れる余地も消える。
#
# 送信の成否も同様に、入力欄のプレースホルダを読む方式をやめた (#438: キュー
# 状態の "Press up to edit queued messages" を未送信と誤読し、成功した送信を
# 失敗と報告したうえ確定キーを再送していた)。UserPromptSubmit イベントの出現で
# 判定する。
#
# usage:
#   send-to-pane.sh <pane> --session <uuid> --select "<選択肢のラベル>"
#   send-to-pane.sh <pane> --session <uuid> --text "<自由記述の指示>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS="${WAVE_EVENTS_BIN:-${SCRIPT_DIR}/wave-events.sh}"
EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
# 送信後に UserPromptSubmit が現れるまで待つ上限 (秒)
CONFIRM_TIMEOUT="${WAVE_CONFIRM_TIMEOUT:-10}"

die() {
  echo "$1" >&2
  exit 1
}

PANE="${1:-}"
[ -n "$PANE" ] || die "pane を指定すること"
shift

SESSION=""
MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --select | --text)
      MODE="${1#--}"
      ARG="${2:-}"
      shift 2
      ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$SESSION" ] || die "--session は必須 (hook イベントの参照に要る)"
[ -n "$MODE" ] || die "--select か --text を指定すること"
[ -n "$ARG" ] || die "--${MODE} には値が要る"

event_file() {
  printf '%s/%s.jsonl' "$EVENT_DIR" "$SESSION"
}

count_prompt_submits() {
  local f
  f="$(event_file)"
  [ -s "$f" ] || {
    echo 0
    return 0
  }
  grep -c '"hook_event_name":"UserPromptSubmit"' "$f" 2>/dev/null || echo 0
}

case "$MODE" in
  select)
    # 提示されている選択肢と照合して数字キーを決める。存在しないラベルなら
    # wave-events.sh が非 0 で落ちるので、ここで送信は起きない。
    key="$("$EVENTS" --session "$SESSION" --key-for "$ARG")" ||
      die "選択肢を特定できない。送信中止"
    tmux send-keys -t "$PANE" -l "$key"
    echo "選択を送信: ${ARG} (key=${key})"
    ;;

  text)
    before="$(count_prompt_submits)"
    # 選択肢が開いたまま自由記述を送ると解釈が曖昧になるので、先に閉じる。
    # 「開いているか」も画面ではなくイベントで判断する。
    state="$("$EVENTS" --session "$SESSION" --state 2>/dev/null || echo UNKNOWN)"
    if [ "$state" = "ASK" ]; then
      tmux send-keys -t "$PANE" Escape
    fi
    tmux send-keys -t "$PANE" -l "$ARG"
    tmux send-keys -t "$PANE" Enter

    # 送信できたかは UserPromptSubmit の増加で見る。増えなければ成功と報告しない。
    deadline=$((SECONDS + CONFIRM_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if [ "$(count_prompt_submits)" -gt "$before" ]; then
        echo "送信を確認: UserPromptSubmit"
        exit 0
      fi
      sleep 1
    done
    die "送信を確認できなかった (UserPromptSubmit が現れない)。ペインの状態を確認すること"
    ;;
esac
