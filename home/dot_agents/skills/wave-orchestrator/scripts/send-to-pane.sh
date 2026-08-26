#!/bin/bash
# 子セッションへの送信 (kryota-dev/dotfiles#437 で hook ベースへ移行)。
#
# 送信そのものは tmux のキー入力だが、**何を送るか**と**送れたか**は hook
# イベントから決める。画面テキストは一切見ない。
#
# 以前は「ハイライト中の選択肢を capture で照合してから Enter を送る」形だった。
# これは事故 (意図と別の選択肢が無言で確定し、誰も答えていないのに「ユーザー
# 承認済み」が成果物に残る) を防ぐための照合だったが、TUI は数字キーで選択肢を
# 直接選べるため、そもそもハイライト位置に依存しない送り方ができる。
#
# ただし照合を消すだけでは同じ事故が別経路で戻る。次の 2 つを送信前に必ず確認する:
#   1. **対象ペインで狙ったセッションが生きているか** (pane の子プロセスの argv に
#      --session-id <uuid> があるか)。ペイン ID の取り違え・古い ID・セッション
#      終了後に、shell へ本文がそのままコマンドとして流れ込むのを防ぐ。
#   2. **その選択肢が今まさに提示されているか** (wave-events.sh が現在ターンの
#      質問に限定して番号を返す)。過去ターンの質問から番号を引かない。
#
# 送信の成否も画面ではなくイベントで見る (#438: キュー状態の "Press up to edit
# queued messages" を未送信と誤読し、成功した送信を失敗と報告したうえ確定キーを
# 再送していた)。UserPromptSubmit の出現で判定する。
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

# chezmoi は skill の scripts に実行ビットを付けないので bash 経由で起動する
# (直接実行すると Permission denied になる)。
events() {
  bash "$EVENTS" "$@"
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

# ペインと セッションの結び付きを実プロセスで検証する。ここを省くと、
# A のイベントから得た番号を B のペインへ送れてしまう (送信先の取り違え)。
assert_pane_runs_session() {
  local shell_pid child
  shell_pid="$(tmux display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$shell_pid" ] || die "ペインが見つからない: $PANE"
  for child in $(pgrep -P "$shell_pid" 2>/dev/null || true); do
    if ps -o args= -p "$child" 2>/dev/null | grep -qF -- "--session-id $SESSION"; then
      return 0
    fi
  done
  die "ペイン $PANE で session $SESSION が動いていない (終了済み / ID 取り違えの可能性)。送信中止"
}

count_prompt_submits() {
  local f n
  f="${EVENT_DIR}/${SESSION}.jsonl"
  [ -s "$f" ] || {
    echo 0
    return 0
  }
  # grep -c は 0 件でも "0" を出力して exit 1 を返す。`|| echo 0` を足すと
  # 0 が二重に出て以降の整数比較が壊れるので、出力を捨てて数え直さない。
  n="$(grep -c '"hook_event_name":"UserPromptSubmit"' "$f" 2>/dev/null)" || n=0
  [ -n "$n" ] || n=0
  echo "$n"
}

assert_pane_runs_session

case "$MODE" in
  select)
    # 現在ターンの質問に限定して番号を決める。過去の質問や、そもそも応答待ちで
    # ない状態なら wave-events.sh が非 0 で落ちるので、ここで送信は起きない。
    key="$(events --session "$SESSION" --key-for "$ARG")" ||
      die "選択肢を特定できない。送信中止"
    tmux send-keys -t "$PANE" -l "$key"
    echo "選択を送信: ${ARG} (key=${key})"
    ;;

  text)
    state="$(events --session "$SESSION" --state 2>/dev/null || echo UNKNOWN)"
    # UNKNOWN は「検知できていない」であって「送ってよい」ではない。
    case "$state" in
      ASK | RUNNING | IDLE) ;;
      *) die "状態を検知できない (state=$state)。送信中止" ;;
    esac

    before="$(count_prompt_submits)"
    # 選択肢が開いたまま自由記述を送ると解釈が曖昧になるので、先に閉じる。
    # 「開いているか」も画面ではなくイベントで判断する。
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
