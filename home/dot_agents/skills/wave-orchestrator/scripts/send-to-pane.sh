#!/bin/sh
# セッションへの送信。2 種類の実事故から導かれた手順を固定する。
#   1. 選択肢が開いているペインへ確定キーを送ると、ハイライト中の選択肢が無言で選ばれ、
#      「ユーザー承認済み」という偽の記録が成果物に残る。
#   2. 長文を送った直後の確定キーは取りこぼされることがあり、指示が未送信のまま滞留する。
#
# usage:
#   send-to-pane.sh <pane> --select "<意図した選択肢の特徴文字列>"
#   send-to-pane.sh <pane> --text "<自由記述の指示>"

MARK_SELECTOR='Enter to select'
PROMPT_CHAR='❯'
SETTLE=2

PANE="$1"
shift
[ -n "$PANE" ] || {
  echo "pane を指定すること" >&2
  exit 2
}

# 入力欄に未送信テキストが残っているか。ペイン全体の grep では判定できない
# （送信後もトランスクリプトに同じ文字列がエコーとして残るため）。
# pane 名を含む区切り線の直後の行だけを見る。
input_state() {
  tmux capture-pane -p -t "$PANE" | awk -v pc="$PROMPT_CHAR" '
    /^─+.*──$/ { seen=1; next }
    seen==1 && index($0, pc)==1 { line=$0; seen=2 }
    END {
      if (line == "") { print "UNKNOWN" }
      else { sub(/^[^ ]*[[:space:]]*/, "", line); if (line == "") print "EMPTY"; else print "PENDING" }
    }'
}

case "$1" in
  --select)
    want="$2"
    cap=$(tmux capture-pane -p -t "$PANE")
    printf '%s' "$cap" | grep -q "$MARK_SELECTOR" || {
      echo "選択肢が開いていない。送信中止" >&2
      exit 1
    }
    printf '%s' "$cap" | grep -qF "$want" || {
      echo "意図した選択肢 '$want' が見当たらない。送信中止" >&2
      exit 1
    }
    tmux send-keys -t "$PANE" Enter
    echo "選択を送信: $want"
    ;;
  --text)
    msg="$2"
    case "$msg" in *'`'* | *'$'*)
      echo "送信文に展開されうる文字が含まれる。除去すること" >&2
      exit 2
      ;;
    esac
    # 選択肢が開いていたら、まず閉じる。自由記述を選択肢経由で送ると解釈が曖昧になる。
    if tmux capture-pane -p -t "$PANE" | grep -q "$MARK_SELECTOR"; then
      tmux send-keys -t "$PANE" Escape
      sleep "$SETTLE"
    fi
    tmux send-keys -t "$PANE" -l "$msg"
    sleep "$SETTLE"
    tmux send-keys -t "$PANE" Enter
    sleep "$SETTLE"
    st=$(input_state)
    if [ "$st" = "PENDING" ]; then
      tmux send-keys -t "$PANE" Enter
      sleep "$SETTLE"
      st=$(input_state)
    fi
    [ "$st" = "PENDING" ] && {
      echo "送信に失敗（入力欄に残存）" >&2
      exit 1
    }
    echo "送信を確認: $st"
    ;;
  *)
    echo "--select か --text を指定すること" >&2
    exit 2
    ;;
esac
