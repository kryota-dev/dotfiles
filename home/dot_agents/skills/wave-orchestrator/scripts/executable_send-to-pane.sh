#!/bin/bash
# 子セッションへの送信 (kryota-dev/dotfiles#437 で hook ベースへ移行)。
#
# 送信そのものは tmux の操作だが、**何を送るか**はすべて hook イベントから決める。
# 画面テキストからセッションの状態や質問内容を読むことはしない (#435 / #436)。
#
# ## 画面参照の境界 (重要)
#
# capture-pane を使う用途を 2 つに分け、**片方だけ**を許容する。
#
#   許容: **自分の操作の結果**の検証
#         - 入力欄に本文が残っているか
#         - 選択肢 UI がまだ開いているか
#         - どの問いが確定済みか (確定マークの個数)
#   禁止: **セッション状態**の判定
#         - 停止しているか稼働中か / 何を問うているか
#         → wave-events.sh (hook payload) だけを根拠にする
#
# これが #437 の設計意図を壊さないのは、**失敗の方向が逆**だから。#435 / #436 は
# 「画面を見て状態を決め、合致しなければ稼働中と誤断定する」形で fail-open だった。
# ここでの画面参照は「送ってよいかを決め、確認できなければ送らない」形で
# fail-closed であり、TUI が変わったときに起きるのは機能停止であって無言の誤送信
# ではない。
#
# ## 送出は bracketed paste
#
# 以前は send-keys -l で本文を流し込んでいた。これは 2 通りに壊れた:
#   #442 長文で後続の確定キーを取りこぼし、本文が入力欄に残る (再送で二重入力)
#   #445 選択肢が開いたまま本文が**キー入力として解釈され**、誰も選んでいない
#        回答が確定した (この skill が設計目的に掲げる事故そのもの)
# bracketed paste なら TUI 側が「貼り付け」として扱うため、本文がキーとして
# 解釈されない。
#
# ## 送信結果は 3 値
#
# 成否の二値をやめた。UserPromptSubmit は**キュー経由で届いたメッセージでは
# 発火しない**ため (#448 / #450 実測)、これ単独では成否を判定できない。二値の
# ままでは稼働中の子への送信を必ず「失敗」と報告し、呼び出し側を二重キューへ
# 誘導する。
#
#   DELIVERED           送信され、ターン開始を確認できた            exit 0
#   QUEUED_UNCONFIRMED  本文は手元を離れたがターン開始は未確認      exit 10  <- 再送禁止
#   PENDING_CONFIRM     本文が入力欄に残っている                    exit 11  <- 本文の再送禁止
#   UNVERIFIED          送ったが確定を検証できない                  exit 2
#   (ガード失敗)        **何も送っていない**                        exit 1   <- 原因を直して再実行可
#
# 呼び出し側は exit code ではなく **標準出力の先頭トークン**で分岐すること。
# 「何かを送ったか」を知りたいだけなら exit 1 かどうかを見る。
#
# usage:
#   send-to-pane.sh <pane> --session <uuid> --select "<選択肢のラベル>"   # 1 問ぶん
#   send-to-pane.sh <pane> --session <uuid> --submit                      # 確認画面を確定
#   send-to-pane.sh <pane> --session <uuid> --dismiss                     # 選択肢を閉じる
#   send-to-pane.sh <pane> --session <uuid> --text "<自由記述の指示>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS="${WAVE_EVENTS_BIN:-${SCRIPT_DIR}/wave-events.sh}"
EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
# 送信後に確認が取れるまで待つ上限 (秒)
CONFIRM_TIMEOUT="${WAVE_CONFIRM_TIMEOUT:-10}"

# テストから差し替えられるようにする (キー送出の順序と回数を bats で固定するため)。
TMUX_BIN="${WAVE_TMUX_BIN:-tmux}"
PS_BIN="${WAVE_PS_BIN:-ps}"
PGREP_BIN="${WAVE_PGREP_BIN:-pgrep}"

# 選択肢 UI の検出マーカー。**TUI のバージョン差に耐えるよう共通部分だけを使う**。
# 実測した 2 バージョンのフッタは文言が違うが、いずれも "Enter to select" を含む:
#   旧: Enter to select . up/down to navigate . n to add notes . Tab to switch questions . Esc to cancel
#   新: Enter to select . Tab/Arrow keys to navigate . Esc to cancel
#
# 合致しなくなったときは「確認できない」として **送らずに落ちる** (fail-closed)。
# 状態判定に使っていないので、ここが壊れても停止の見落としにはならない。
OPTION_UI_MARKER="${WAVE_OPTION_UI_MARKER:-Enter to select}"
SUBMIT_MARKER="${WAVE_SUBMIT_MARKER:-Ready to submit}"
QUEUE_MARKER="${WAVE_QUEUE_MARKER:-Press up to edit queued messages}"
INPUT_PROMPT_MARKER="${WAVE_INPUT_PROMPT_MARKER:-❯}"
CONFIRMED_MARK="${WAVE_CONFIRMED_MARK:-☒}"

# bracketed paste を使うか。TUI 側が対応しない環境向けの逃げ道として env で
# 落とせるようにしてあるが、既定は on (これが #445 の対策の本体)。
PASTE_BRACKETED="${WAVE_PASTE_BRACKETED:-1}"

die() {
  echo "$1" >&2
  exit 1
}

# source 側は executable_ プレフィックスを持つので chezmoi が 755 で配置する
# (#440)。よって bash を挟まず直接実行する。
events() {
  "$EVENTS" "$@"
}

tmux_cmd() {
  "$TMUX_BIN" "$@"
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
    --submit | --dismiss)
      MODE="${1#--}"
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$SESSION" ] || die "--session は必須 (hook イベントの参照に要る)"
[ -n "$MODE" ] || die "--select / --submit / --dismiss / --text のいずれかを指定すること"
case "$MODE" in
  select | text) [ -n "$ARG" ] || die "--${MODE} には値が要る" ;;
esac

# ペインとセッションの結び付きを実プロセスで検証する。ここを省くと、A のイベント
# から得た番号を B のペインへ送れてしまう (送信先の取り違え)。セッション終了後の
# shell へ本文がコマンドとして流れ込むのも防ぐ。
#
# **起動形式は 2 つある**。--session-id <uuid> で起動したセッションを終了して
# --resume <uuid> で再開すると、argv から --session-id が消える。片方しか見て
# いなかったため、再開後の wave では代理応答が一切通らなかった (#471)。
# ガード自体は正しいので外さない。直すのは検出条件の網羅性だけ。
#
# **プロセスの位置も 2 通りある**。ペインを対話 shell 経由で立てると claude は
# pane_pid の子になるが、tmux にコマンドを直接渡すと sh が exec で置き換わり
# **pane_pid 自身が claude** になる (実機で確認)。子だけを見ていると後者で
# 「動いていない」と誤判定するので、pane_pid 自身も照合する。
#
# なお `pgrep -P` は **自分自身とその祖先を既定で除外する** (man pgrep の -a)。
# 送信元セッションが自分のペインを対象にすると、ps は親子関係を返すのに pgrep は
# 空を返す。Leader は子ペインを対象にするため実運用では当たらないが、ガードを手で
# 検証するときは必ず別のペインを対象にすること。
assert_pane_runs_session() {
  local shell_pid pid args
  shell_pid="$(tmux_cmd display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$shell_pid" ] || die "ペインが見つからない: $PANE"
  # pane_pid 自身 → その子。どちらかが当該セッションなら生存。
  for pid in "$shell_pid" $("$PGREP_BIN" -P "$shell_pid" 2>/dev/null || true); do
    args="$("$PS_BIN" -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"--session-id $SESSION"* | *"--resume $SESSION"*) return 0 ;;
    esac
  done
  die "ペイン $PANE で session $SESSION が動いていない (終了済み / ID 取り違えの可能性)。送信中止"
}

# --- 画面参照 (自分の操作の結果の検証にのみ使う) ---------------------------

capture() {
  tmux_cmd capture-pane -p -t "$PANE" 2>/dev/null || true
}

option_ui_open() {
  case "$1" in
    *"$OPTION_UI_MARKER"* | *"$SUBMIT_MARKER"*) return 0 ;;
  esac
  return 1
}

submit_screen_open() {
  case "$1" in
    *"$SUBMIT_MARKER"*) return 0 ;;
  esac
  return 1
}

queue_shown() {
  case "$1" in
    *"$QUEUE_MARKER"*) return 0 ;;
  esac
  return 1
}

# 確定済みの問いの個数。複数問の TUI はタブ見出しに確定マークを描くので、
# 「自分の操作がどこまで進んだか」をこれで数える。単一問では 0 のまま。
confirmed_count() {
  local n
  n="$(printf '%s' "$1" | grep -o "$CONFIRMED_MARK" 2>/dev/null | wc -l | tr -d ' ')" || n=0
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# 入力欄に本文が残っているか。最後の入力プロンプト行の、マーカー以降に非空白が
# あれば「残っている」と見なす。**送信済みの本文が会話領域にエコーされている**
# ことと区別するため、行頭がプロンプトマーカーの行だけを見る。
input_box_has_body() {
  local line rest
  line="$(printf '%s' "$1" | grep -E "^[[:space:]]*${INPUT_PROMPT_MARKER}" | tail -1 || true)"
  [ -n "$line" ] || return 1
  rest="${line#*"${INPUT_PROMPT_MARKER}"}"
  rest="${rest//[[:space:]]/}"
  [ -n "$rest" ]
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

state_now() {
  events --session "$SESSION" --state 2>/dev/null || echo UNKNOWN
}

settled() {
  [ "$(state_now)" != "ASK_QUESTION" ]
}

# --- 送出 -----------------------------------------------------------------

# 本文を bracketed paste で流し込む。send-keys -l を使わないのが要点 (#442 / #445)。
# 選択肢の閉鎖を**画面で確認したうえで**、決着イベントを記録側のログへ書き戻す。
#
# **なぜ送信側が書くのか**: Esc キャンセルは hook イベントを一切出さない (実機で
# 確認済み)。--dismiss が Escape を送って閉じた場合も同じで、記録側からは
# 「質問が閉じた」ことを知る手段が無い。その結果 state は ASK_QUESTION に固着し、
# --select は「UI が無い」で拒否、--text は「選択肢が開いている」で拒否、
# --purge しても UNKNOWN で拒否となり、Leader が完全に手詰まりになる (実測)。
#
# 書き戻すのは **閉鎖を capture で直接確認できた場合に限る**。推測では書かない。
# 記録は synthetic として印を付け、本物の hook イベントと区別できるようにする。
record_dismissal() {
  local ids id f line
  ids="$(events --session "$SESSION" --pending-ids 2>/dev/null || true)"
  [ -n "$ids" ] || return 0
  f="${EVENT_DIR}/${SESSION}.jsonl"
  # 記録側と同じ 600 / 700 を保つ。
  umask 077
  mkdir -p "$EVENT_DIR" 2>/dev/null || return 1
  local pid
  while IFS=$'\t' read -r id pid; do
    [ -n "$id" ] || continue
    # prompt_id は必須。これを欠くと latest_turn() がこの行をターンから外し、
    # 決着として読まれない (実機で踏んだ)。
    [ -n "$pid" ] || return 1
    line="$(jq -c -n \
      --arg s "$SESSION" --arg t "$id" --arg p "$pid" \
      '{session_id: $s, prompt_id: $p, hook_event_name: "PostToolUseFailure",
        tool_name: "AskUserQuestion", tool_use_id: $t, synthetic: "dismiss"}' \
      2>/dev/null || true)"
    [ -n "$line" ] || return 1
    printf '%s\n' "$line" >>"$f" 2>/dev/null || return 1
  done <<<"$ids"
  return 0
}

paste_body() {
  local body="$1" buf opts
  buf="wave-$$-${RANDOM}"
  printf '%s' "$body" | tmux_cmd load-buffer -b "$buf" - ||
    die "本文をバッファへ読み込めなかった。何も送っていない"
  # -d は貼り付け後にバッファを消す (利用者のバッファを汚さない)。
  # -p は bracketed paste (TUI に「貼り付け」として扱わせる)。
  opts="-d"
  [ "$PASTE_BRACKETED" = "1" ] && opts="-d -p"
  # shellcheck disable=SC2086  # opts は意図的に単語分割する
  tmux_cmd paste-buffer $opts -b "$buf" -t "$PANE" ||
    die "本文を貼り付けられなかった。何も送っていない"
}

send_key() {
  tmux_cmd send-keys -t "$PANE" "$@"
}

# 条件が成立するまで待つ。成立したら 0、時間切れなら 1。
wait_until() {
  local deadline
  deadline=$((SECONDS + CONFIRM_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

assert_pane_runs_session

case "$MODE" in

  dismiss)
    st="$(state_now)"
    if [ "$st" != "ASK_QUESTION" ]; then
      echo "ALREADY_DISMISSED 選択肢の応答待ちではない (state=$st)。何も送っていない"
      exit 0
    fi
    cap="$(capture)"
    if ! option_ui_open "$cap"; then
      # 人が Esc で閉じた場合がここに来る。イベントが出ないので state だけが
      # 取り残されている。閉鎖は画面で確認できているので決着を書き戻して回復する。
      if record_dismissal; then
        echo "ALREADY_CLOSED 選択肢は既に閉じていた (Esc 等)。決着を記録して state を解除した"
        exit 0
      fi
      echo "UNVERIFIED 選択肢は閉じているが決着を記録できなかった。state は ASK_QUESTION のまま" >&2
      exit 2
    fi
    if submit_screen_open "$cap"; then
      die "確認画面が出ている。Escape の行き先が曖昧なので中止。Cancel を明示的に選ぶこと (何も送っていない)"
    fi
    send_key Escape || die "Escape を送れなかった"
    ui_closed() {
      local c
      c="$(capture)"
      if option_ui_open "$c"; then return 1; fi
      return 0
    }
    if wait_until ui_closed; then
      # Escape も hook イベントを出さないので、ここでも書き戻さないと固着する。
      if record_dismissal; then
        echo "CLOSED 選択肢を閉じ、決着を記録した"
        exit 0
      fi
      echo "UNVERIFIED 選択肢は閉じたが決着を記録できなかった。state は ASK_QUESTION のまま" >&2
      exit 2
    fi
    echo "UNVERIFIED Escape を送ったが選択肢 UI が閉じたことを確認できない。本文は送っていない" >&2
    exit 2
    ;;

  select)
    st="$(state_now)"
    [ "$st" = "ASK_QUESTION" ] || die "選択肢の応答待ちではない (state=$st)。送信中止"
    cap="$(capture)"
    # Esc で閉じた後も wave-events.sh の条件は成立しうる。選択肢 UI が実在する
    # ことを確かめないと、閉じた画面へ**裸の数字が入力欄に打ち込まれる** (#448 派生)。
    if ! option_ui_open "$cap"; then
      die "選択肢 UI を画面で確認できない。数字キーが入力欄へ入る危険があるので中止 (何も送っていない)"
    fi

    before_confirmed="$(confirmed_count "$cap")"
    # 現在ターンの未回答の質問に限って番号を引く。過去ターン・回答済みからは引かない。
    key_spec="$(events --session "$SESSION" --key-for "$ARG")" || die "選択肢を特定できない。送信中止"
    qidx="${key_spec%%:*}"
    num="${key_spec##*:}"
    # 1 問ずつ順に答える前提なので、確定済みの個数が今答えるべき問いの index になる。
    [ "$qidx" = "$before_confirmed" ] ||
      die "指定した選択肢は問い ${qidx} のものだが、画面は問い ${before_confirmed} を表示している。1 問ずつ順に送ること (何も送っていない)"

    # **数字キーのみを送る。** claude 2.1.221 以降は数字キーが確定して次の問いへ
    # 進むため、続けて Enter を送ると**次の問いの既定値を確定させる** (#441 実測)。
    # 確定するかは問い数ではなく選択肢の preview/notes の有無で変わるので、
    # キー列を固定せず「送って検証する」形にしてある。
    send_key -l "$num" || die "数字キーを送れなかった"

    advanced() {
      local c
      c="$(capture)"
      if [ "$(confirmed_count "$c")" -gt "$before_confirmed" ]; then return 0; fi
      if submit_screen_open "$c"; then return 0; fi
      return 1
    }
    confirmed_or_done() {
      if settled; then return 0; fi
      advanced
    }

    if wait_until confirmed_or_done; then
      if settled; then
        echo "CONFIRMED_CALL_COMPLETE 選択を確定し、呼び出し全体が完了した: ${ARG} (問い ${qidx}, key=${num})"
      else
        echo "CONFIRMED_MORE 選択を確定した。続きの問いがある: ${ARG} (問い ${qidx}, key=${num})"
      fi
      exit 0
    fi

    # 数字キーで確定しない TUI / 選択肢 (preview 付き等) では Enter が要る。
    # **1 回だけ**送る。投機的に複数送ると次の問いを既定値で確定させる。
    send_key Enter || die "確定キーを送れなかった"
    if wait_until confirmed_or_done; then
      if settled; then
        echo "CONFIRMED_CALL_COMPLETE 選択を確定し、呼び出し全体が完了した (Enter 併用): ${ARG}"
      else
        echo "CONFIRMED_MORE 選択を確定した。続きの問いがある (Enter 併用): ${ARG}"
      fi
      exit 0
    fi
    echo "UNVERIFIED 数字キー ${num} と Enter を送ったが確定を検証できない。画面を確認すること" >&2
    exit 2
    ;;

  submit)
    cap="$(capture)"
    if ! submit_screen_open "$cap"; then
      die "確認画面 (${SUBMIT_MARKER}) を画面で確認できない。中止 (何も送っていない)"
    fi
    send_key Enter || die "確定キーを送れなかった"
    if wait_until settled; then
      echo "CONFIRMED_CALL_COMPLETE 確認画面を確定した"
      exit 0
    fi
    echo "UNVERIFIED Enter を送ったが呼び出しの完了を検証できない。画面を確認すること" >&2
    exit 2
    ;;

  text)
    st="$(state_now)"
    case "$st" in
      RUNNING | IDLE) ;;
      ASK_QUESTION)
        # 暗黙に Escape を送って状態を変えない。効かなかったときに本文が
        # キー入力として解釈され、誰も選んでいない回答が確定する (#445)。
        die "選択肢が開いている (state=ASK_QUESTION)。先に --dismiss で明示的に閉じること (何も送っていない)"
        ;;
      ASK_PERMISSION)
        die "権限確認で停止している (state=ASK_PERMISSION)。自由記述で答える場面ではないので中止 (何も送っていない)"
        ;;
      *)
        die "状態を検知できない (state=$st)。送信中止 (何も送っていない)"
        ;;
    esac

    before="$(count_prompt_submits)"
    paste_body "$ARG"
    send_key Enter || die "確定キーを送れなかった"

    submitted() {
      [ "$(count_prompt_submits)" -gt "$before" ]
    }

    if wait_until submitted; then
      echo "DELIVERED 送信を確認した (UserPromptSubmit)"
      exit 0
    fi

    # UserPromptSubmit はキュー経由の配信では発火しない (#450 実測)。ここから先は
    # 「自分の本文が入力欄を離れたか」だけを画面で見る。セッション状態は見ない。
    cap="$(capture)"
    if queue_shown "$cap"; then
      echo "QUEUED_UNCONFIRMED キューに入った。ターン開始は未確認。**再送しないこと** (二重キューになる)"
      exit 10
    fi
    if ! input_box_has_body "$cap"; then
      echo "QUEUED_UNCONFIRMED 入力欄は空。配信された可能性が高いがターン開始は未確認。**再送しないこと**"
      exit 10
    fi

    # 本文は届いており、失われたのは確定キーだけ (#442)。**入力欄をクリアしない** --
    # クリアは届いた指示を捨てることになる。Enter を 1 回だけ送って再判定する。
    send_key Enter || die "確定キーを再送できなかった"
    if wait_until submitted; then
      echo "DELIVERED 送信を確認した (Enter 再送後)"
      exit 0
    fi
    cap="$(capture)"
    if ! input_box_has_body "$cap"; then
      echo "QUEUED_UNCONFIRMED 入力欄は空になった。ターン開始は未確認。**再送しないこと**"
      exit 10
    fi
    echo "PENDING_CONFIRM 本文が入力欄に残っている。**本文を再送しないこと** (連結して二重入力になる)。Enter のみ送るか画面を確認すること" >&2
    exit 11
    ;;
esac
