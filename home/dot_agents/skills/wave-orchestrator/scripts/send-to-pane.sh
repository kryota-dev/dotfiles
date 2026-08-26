#!/bin/sh
# セッションへの送信。実際に起きた 2 種類の事故から導かれた手順を固定する。
#   1. 選択肢が開いているペインへ確定キーを送ると、ハイライト中の選択肢が無言で選ばれ、
#      「ユーザー承認済み」という偽の記録が成果物に残る。
#   2. 長文を送った直後の確定キーは取りこぼされることがあり、指示が未送信のまま滞留する。
#
# usage:
#   send-to-pane.sh <pane> --select "<意図した選択肢の特徴文字列>"
#   send-to-pane.sh <pane> --text "<自由記述の指示>"

# ---- TUI 依存の定数（harness の TUI が変わったらここだけ直す）--------------
MARK_SELECTOR='Enter to select'                 # 選択肢が開いている
MARK_ENDED='Resume this session with'           # セッションが終了して shell に戻った
PROMPT_CHAR='❯'                                 # 入力欄とハイライト行の行頭
OPTION_RE="^${PROMPT_CHAR}[[:space:]]*[0-9]+\." # ハイライト中の選択肢の行
SETTLE=2
# ---------------------------------------------------------------------------

PANE="$1"
[ -n "$PANE" ] || {
  echo "pane を指定すること" >&2
  exit 2
}
shift

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
    [ -n "$want" ] || {
      echo "--select には意図した選択肢の特徴文字列が要る" >&2
      exit 2
    }
    cap=$(tmux capture-pane -p -t "$PANE")
    printf '%s' "$cap" | grep -q "$MARK_SELECTOR" || {
      echo "選択肢が開いていない。送信中止" >&2
      exit 1
    }
    # 確定キーが選ぶのは「ハイライト中の行」であって「画面のどこかに want がある行」ではない。
    # ここを見ずに送ると、意図と別の選択肢を無言で確定してしまう（事故 1 の実体）。
    hl=$(printf '%s\n' "$cap" | grep -E "$OPTION_RE")
    n=$(printf '%s\n' "$hl" | grep -c .)
    [ "$n" -eq 1 ] || {
      echo "ハイライト中の選択肢を一意に特定できない (検出 $n 件)。送信中止" >&2
      exit 1
    }
    case "$hl" in
      *"$want"*) ;;
      *)
        echo "ハイライト中の選択肢が意図と異なる。送信中止" >&2
        echo "  ハイライト: $hl" >&2
        echo "  期待した語: $want" >&2
        exit 1
        ;;
    esac
    tmux send-keys -t "$PANE" Enter
    echo "選択を送信: $hl"
    ;;
  --text)
    msg="$2"
    [ -n "$msg" ] || {
      echo "--text には送信する本文が要る" >&2
      exit 2
    }
    cap=$(tmux capture-pane -p -t "$PANE")
    # ペインが既にシェルへ戻っていると、本文 + 確定キーはコマンドとして実行される。
    # 文字種のブロックリストでは防げない（; や | や改行が素通りする）ので、状態で弾く。
    if printf '%s' "$cap" | grep -q "$MARK_ENDED"; then
      echo "ペインのセッションは終了している。送信中止" >&2
      exit 1
    fi
    # 選択肢が開いていたら閉じる。自由記述を選択肢経由で送ると解釈が曖昧になる。
    # MARK_SELECTOR が TUI 変更で一致しなくなっても選択肢行のパターンで拾えるよう二重化する。
    if printf '%s' "$cap" | grep -q "$MARK_SELECTOR" ||
      printf '%s\n' "$cap" | grep -qE "$OPTION_RE"; then
      tmux send-keys -t "$PANE" Escape
      sleep "$SETTLE"
    fi
    tmux send-keys -t "$PANE" -l "$msg"
    sleep "$SETTLE"
    tmux send-keys -t "$PANE" Enter
    sleep "$SETTLE"
    st=$(input_state)
    if [ "$st" = "PENDING" ]; then
      # 入力欄に本文が残っている = 確定キーの取りこぼし。ここは再送してよい。
      tmux send-keys -t "$PANE" Enter
      sleep "$SETTLE"
      st=$(input_state)
    fi
    case "$st" in
      EMPTY)
        echo "送信を確認: EMPTY"
        ;;
      PENDING)
        echo "送信に失敗（入力欄に残存）" >&2
        exit 1
        ;;
      *)
        # UNKNOWN では確定キーを再送しない。ペインが想定の TUI でない可能性があり、
        # 再送が入力済みテキストの実行になりうる。判定不能は失敗として止める。
        echo "送信の成否を判定できない (state=$st)。ペインの状態を確認すること" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "--select か --text を指定すること" >&2
    exit 2
    ;;
esac
