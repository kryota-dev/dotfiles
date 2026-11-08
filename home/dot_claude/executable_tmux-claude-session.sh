#!/bin/bash
# SessionStart で会話と PID をペインに記録し、復元時に同じ会話を選べるようにする。
# 非対話の子も TMUX_PANE を継承するため、制御端末と前景のプロセスグループで判定する。
# stdout は Claude Code の文脈に入るので、診断は stderr にだけ出す。
exec >/dev/null
[ -n "${TMUX_PANE:-}" ] || exit 0

# mise を有効にしていない環境から起動されても jq・tmux を見つけられるようにする。
if ! command -v jq >/dev/null || ! command -v tmux >/dev/null; then
  PATH="$HOME/.local/share/mise/shims:$PATH"
fi

skip() {
  echo "tmux-claude-session: $1" >&2
  exit 0
}

UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
MAX_ANCESTOR_DEPTH=5

# コマンド置換で末尾の改行が消える前に UUID の長さも調べ、不正な ID を受け入れない。
session_id=$(jq -er '.session_id | strings | select(length == 36)') || skip "session_id を読めない"
[[ "$session_id" =~ $UUID_PATTERN ]] || skip "session_id が UUID の形でない"

# hook の起動に挟まるシェルだけを飛ばす。最初の非シェルで止めないと、claude -p の外側にある
# 対話の Claude Code を見つけ、別の会話の ID で上書きしてしまう。
claude_pid=$PPID
for ((depth = 0; depth < MAX_ANCESTOR_DEPTH; depth++)); do
  [[ "$claude_pid" =~ ^[1-9][0-9]*$ ]] || skip "親の PID が不正"
  process=$(ps -o ppid=,comm= -p "$claude_pid") || skip "親プロセスを調べられない"
  read -r parent_pid comm <<<"$process"
  [ -n "$comm" ] || skip "親プロセスの名前が空"
  comm=${comm##*/}
  comm=${comm#-}
  case "$comm" in
    sh | bash | zsh | dash) claude_pid=$parent_pid ;;
    *) break ;;
  esac
done
[ "$depth" -lt "$MAX_ANCESTOR_DEPTH" ] || skip "親プロセスの探索上限に達した"

terminal=$(ps -o tty=,pgid=,tpgid= -p "$claude_pid") || skip "制御端末を調べられない"
read -r tty pgid tpgid <<<"$terminal"
[[ "$pgid" =~ ^[1-9][0-9]*$ && "$tpgid" =~ ^[1-9][0-9]*$ ]] || skip "前景のプロセスグループが無い"
[[ -n "$tty" && "$tty" != '?' && "$tty" != '??' ]] || skip "制御端末が無い"
[ "$pgid" = "$tpgid" ] || skip "前景のジョブでない"
pane_tty=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}') || skip "ペインの tty を読めない"
[ "/dev/$tty" = "$pane_tty" ] || skip "ペインの tty と一致しない"

tmux set-option -p -t "$TMUX_PANE" @claude-session-id "$session_id" \; \
  set-option -p -t "$TMUX_PANE" @claude-pid "$claude_pid" || skip "ペインの記録に失敗した"
exit 0
