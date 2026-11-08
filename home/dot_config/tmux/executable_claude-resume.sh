#!/bin/bash
# resurrect の保存に会話の ID を追記し、復元で作られたシェルだけで同じ会話を再開する。
# 既存のペインへ文字を送らないよう、印付けの完了を確認してから復元する。
exec >/dev/null

# tmux サーバーが mise を有効にしていない環境でも、tmux を見つけられるようにする。
command -v tmux >/dev/null || PATH="$HOME/.local/share/mise/shims:$PATH"

UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
RESTORE_SHELLS='zsh bash sh fish dash'

warn() {
  echo "claude-resume: $1" >&2
}

save() {
  local file=$1 panes session window pane session_id pid pane_tty terminal tty
  panes=$(tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{pane_index}\t#{@claude-session-id}\t#{@claude-pid}\t#{pane_tty}') || {
    warn "ペインの一覧を読めない"
    return
  }
  while IFS=$'\t' read -r session window pane session_id pid pane_tty; do
    [[ "$session_id" =~ $UUID_PATTERN && "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    terminal=$(ps -o tty= -p "$pid") || {
      warn "PID $pid の制御端末を読めない"
      continue
    }
    read -r tty <<<"$terminal"
    [ "/dev/$tty" = "$pane_tty" ] || continue
    printf 'claude_session\t%s\t%s\t%s\t%s\n' "$session" "$window" "$pane" "$session_id" >>"$file" ||
      warn "保存ファイルに追記できない"
  done <<<"$panes"
}

mark() {
  local panes pane failed=0
  tmux set-option -gu @claude-resume-ready || {
    warn "復元の完了の印を消せない"
    return
  }
  panes=$(tmux list-panes -a -F '#{pane_id}') || {
    warn "ペインの一覧を読めない"
    return
  }
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    if ! tmux set-option -p -t "$pane" @claude-resume-skip 1; then
      warn "ペイン $pane に印を付けられない"
      failed=1
    fi
  done <<<"$panes"
  if [ "$failed" -eq 0 ]; then
    tmux set-option -g @claude-resume-ready 1 || warn "復元の完了の印を付けられない"
  fi
}

restore() {
  local ready dir kind session window pane session_id target state skip command shell
  ready=$(tmux show-option -gqv @claude-resume-ready) || {
    warn "復元の完了の印を読めない"
    return
  }
  [ "$ready" = 1 ] || return 0
  # 印を先に消し、途中で失敗しても次の復元で使い回さない。
  tmux set-option -gu @claude-resume-ready || {
    warn "復元の完了の印を消せない"
    return
  }
  dir=$(tmux show-option -gqv @resurrect-dir) || {
    warn "保存先を読めない"
    return
  }
  dir=${dir//\~/$HOME}
  dir=${dir//\$HOME/$HOME}
  dir=${dir:-${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect}
  [ -f "$dir/last" ] || return 0
  while IFS=$'\t' read -r kind session window pane session_id; do
    [ "$kind" = claude_session ] || continue
    [[ "$session_id" =~ $UUID_PATTERN ]] || continue
    target="=$session:$window.$pane"
    state=$(tmux display-message -p -t "$target" $'#{@claude-resume-skip}\t#{pane_current_command}') || {
      warn "ペイン $target の状態を読めない"
      continue
    }
    # IFS のタブは空欄を詰めるため、先頭が空の「印なし」を文字列のまま取り出す。
    [[ "$state" == *$'\t'* ]] || continue
    skip=${state%%$'\t'*}
    command=${state#*$'\t'}
    [ -z "$skip" ] || continue
    command=${command#-}
    for shell in $RESTORE_SHELLS; do
      [ "$command" = "$shell" ] || continue
      tmux send-keys -t "$target" "claude --resume $session_id" C-m ||
        warn "ペイン $target に再開のコマンドを送れない"
      break
    done
  done <"$dir/last"
}

case "${1:-}" in
  save)
    if [ "$#" -eq 2 ] && [ -n "$2" ]; then
      save "$2"
      exit 0
    fi
    ;;
  mark)
    if [ "$#" -eq 1 ]; then
      mark
      exit 0
    fi
    ;;
  restore)
    if [ "$#" -eq 1 ]; then
      restore
      exit 0
    fi
    ;;
esac
echo '使い方: claude-resume.sh save <保存ファイル> | mark | restore' >&2
exit 1
