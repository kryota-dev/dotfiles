#!/bin/sh
# 各ペインの状態を「pane_id 名前 状態」の 1 行で出す。
#
# 判定は「間隔を空けた 2 回のキャプチャの差分」で行う。稼働中はスピナーのタイマーが
# 毎秒動くので必ず差分が出るため。スピナーの文字列を照合する方式は TUI の版で壊れ、
# 実際に稼働中のセッションを「停止」と誤判定した実績がある。
#
# usage:
#   pane-state.sh --prefix <window-name-prefix> [--settle <sec>]
#   pane-state.sh --prefix <window-name-prefix> --self-check
#
# 状態: BUSY / ASK / IDLE / ENDED / GONE

# ---- TUI 依存の定数（harness の TUI が変わったらここだけ直す）--------------
MARK_SELECTOR='Enter to select'                               # 選択肢が開いている
MARK_ENDED='Resume this session with'                         # セッションが終了して shell に戻った
MARK_BGWAIT='shell still running|auto mode on . [0-9]+ shell' # BG シェル待ち = 停止ではない
PROMPT_CHAR='❯'                                               # 入力欄の行頭
CAPTURE_LINES=25
SETTLE_SECONDS=4
# ---------------------------------------------------------------------------

PREFIX=""
SELF_CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --settle)
      SETTLE_SECONDS="$2"
      shift 2
      ;;
    --self-check)
      SELF_CHECK=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$PREFIX" ] || {
  echo "--prefix は必須" >&2
  exit 2
}
command -v tmux >/dev/null 2>&1 || {
  echo "tmux が無い" >&2
  exit 3
}

D=$(mktemp -d)
PANES=$(tmux list-panes -a -F '#{window_name}|#{pane_id}|#{pane_title}' 2>/dev/null | grep "^$PREFIX")

if [ "$SELF_CHECK" = "1" ]; then
  # 検知器が「今の TUI を読めているか」を確かめる。読めないまま監視に入ると、
  # 静かな故障が「誰も停止していない」と見分けがつかなくなる。
  [ -n "$PANES" ] || {
    echo "SELF-CHECK FAIL: prefix '$PREFIX' に一致する pane が無い" >&2
    exit 4
  }
  p=$(printf '%s\n' "$PANES" | head -1 | cut -d'|' -f2)
  cap=$(tmux capture-pane -p -t "$p" -S -$CAPTURE_LINES 2>/dev/null)
  [ -n "$cap" ] || {
    echo "SELF-CHECK FAIL: pane $p のキャプチャが空" >&2
    exit 4
  }
  if ! printf '%s' "$cap" | grep -q "$PROMPT_CHAR"; then
    echo "SELF-CHECK FAIL: 入力欄の目印 '$PROMPT_CHAR' を検出できない。TUI が変わった可能性がある" >&2
    echo "  → pane-state.sh 冒頭の定数表を更新すること" >&2
    exit 4
  fi
  echo "SELF-CHECK OK: $(printf '%s\n' "$PANES" | wc -l | tr -d ' ') pane, 目印を検出"
  exit 0
fi

printf '%s\n' "$PANES" | while IFS='|' read -r w p t; do
  [ -n "$p" ] && tmux capture-pane -p -t "$p" -S -$CAPTURE_LINES >"$D/$p.a" 2>/dev/null
done
sleep "$SETTLE_SECONDS"
printf '%s\n' "$PANES" | while IFS='|' read -r w p t; do
  [ -z "$p" ] && continue
  name=$(printf '%s' "$t" | sed 's/[^a-zA-Z0-9_.-]//g')
  tmux capture-pane -p -t "$p" -S -$CAPTURE_LINES >"$D/$p.b" 2>/dev/null
  cap=$(cat "$D/$p.b" 2>/dev/null)
  if [ -z "$cap" ]; then
    st=GONE
  elif printf '%s' "$cap" | grep -qE "$MARK_BGWAIT"; then
    st=BUSY
  elif ! cmp -s "$D/$p.a" "$D/$p.b"; then
    st=BUSY
  elif printf '%s' "$cap" | grep -q "$MARK_ENDED"; then
    st=ENDED
  elif printf '%s' "$cap" | grep -q "$MARK_SELECTOR"; then
    st=ASK
  else
    st=IDLE
  fi
  printf '%s %s %s\n' "$p" "$name" "$st"
done
