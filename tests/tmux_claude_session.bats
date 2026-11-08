#!/usr/bin/env bats
# 実際の tmux やプロセスに依存せず、子の非対話セッションによる上書きを防げるか確かめる。

setup() {
  bats_require_minimum_version 1.5.0
  HOOK="$BATS_TEST_DIRNAME/../home/dot_claude/executable_tmux-claude-session.sh"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  export BATS_TEST_TMPDIR
  export TMUX_PANE='%7'
  export PANE_TTY='/dev/ttys016'
  export PATH="$STUB:$PATH"
  unset PS_FAIL TMUX_FAIL
  SESSION_ID='877fc4a7-0c4e-4d7b-96f2-0a35c3cbd8dc'
  INPUT="{\"session_id\":\"$SESSION_ID\"}"
  # 表に無い PID は実行ごとに変わる hook の親。固定の PID へつなぐことで本番の $PPID を使う。
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 200 /bin/sh ?? 0 0
200 300 /usr/local/bin/claude ttys016 200 200
300 1 -zsh ttys016 300 200
EOF
  cat >"$STUB/ps" <<'EOF'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$@" >>"$BATS_TEST_TMPDIR/ps-args"
[ "$1" = -o ] && [ "$3" = -p ] || exit 1
[ "${PS_FAIL:-}" != "$2" ] || exit 1
row=$(awk -v pid="$4" '$1 == pid { print; found=1; exit } END { if (!found) exit 1 }' "$BATS_TEST_TMPDIR/processes")
if [ -z "$row" ]; then
  row=$(awk '$1 == "parent" { print }' "$BATS_TEST_TMPDIR/processes")
  printf '%s' "$4" >"$BATS_TEST_TMPDIR/hook-parent-pid"
fi
read -r pid ppid comm tty pgid tpgid <<<"$row"
case "$2" in
  ppid=,comm=) printf '  %s %s\n' "$ppid" "$comm" ;;
  tty=,pgid=,tpgid=) printf '  %s  %s  %s\n' "$tty" "$pgid" "$tpgid" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$STUB/tmux" <<'EOF'
#!/bin/bash
printf '%s\t' "$@" >>"$BATS_TEST_TMPDIR/tmux-args"
printf '\n' >>"$BATS_TEST_TMPDIR/tmux-args"
[ "${TMUX_FAIL:-}" != "$1" ] || { echo 'tmux が失敗した' >&2; exit 1; }
case "$1" in
  display-message) printf '%s\n' "$PANE_TTY" ;;
  set-option) echo '文脈に入れてはいけない出力' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUB/ps" "$STUB/tmux"
}

invoke_hook() {
  run --separate-stderr bash "$HOOK" <<<"$INPUT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

not_recorded() {
  [[ "$(cat "$BATS_TEST_TMPDIR/tmux-args" 2>/dev/null)" != *set-option* ]]
}

recorded() {
  local pid="${1:-200}" expected
  expected=$(
    printf '%s\t' display-message -p -t "$TMUX_PANE" '#{pane_tty}'
    printf '\n'
    printf '%s\t' set-option -p -t "$TMUX_PANE" @claude-session-id "$SESSION_ID" \; \
      set-option -p -t "$TMUX_PANE" @claude-pid "$pid"
  )
  [ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" = "$expected" ]
}

@test "TMUX_PANE が無ければ外部コマンドを呼ばない" {
  unset TMUX_PANE
  invoke_hook
  [ ! -e "$BATS_TEST_TMPDIR/tmux-args" ]
  [ ! -e "$BATS_TEST_TMPDIR/ps-args" ]
}

@test "TMUX_PANE が空でも何も記録しない" {
  export TMUX_PANE=''
  invoke_hook
  not_recorded
}

@test "sh を挟む前景の対話では同じペインに会話と Claude の PID を記録する" {
  invoke_hook
  recorded
}

@test "親が直接 Claude のときはその PID を記録する" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 300 /usr/local/bin/claude ttys016 200 200
300 1 -zsh ttys016 300 200
EOF
  invoke_hook
  recorded "$(cat "$BATS_TEST_TMPDIR/hook-parent-pid")"
}

@test "フルパスのシェルとログインシェルを飛ばす" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 101 /bin/bash ?? 0 0
101 102 -zsh ?? 0 0
102 103 /bin/dash ?? 0 0
103 200 /bin/sh ?? 0 0
200 300 claude ttys016 200 200
EOF
  invoke_hook
  recorded
}

@test "探索上限までシェルが続いたら記録しない" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 101 /bin/sh ?? 0 0
101 102 /bin/sh ?? 0 0
102 103 /bin/sh ?? 0 0
103 104 /bin/sh ?? 0 0
104 200 /bin/sh ?? 0 0
200 300 claude ttys016 200 200
EOF
  invoke_hook
  not_recorded
  [ "$(wc -l <"$BATS_TEST_TMPDIR/ps-args")" -eq 5 ]
}

@test "制御端末の無い claude -p から外側の対話まで遡らない" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 200 /bin/sh ?? 0 0
200 210 claude ?? 200 0
210 220 timeout ?? 210 0
220 300 /bin/zsh ?? 220 0
300 400 claude ttys016 300 300
EOF
  invoke_hook
  not_recorded
  [[ "$(cat "$BATS_TEST_TMPDIR/ps-args")" != *$'\t210'* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/ps-args")" != *$'\t300'* ]]
}

@test "前景グループが一致しても制御端末が無ければ記録しない" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 200 /bin/sh ?? 0 0
200 300 claude ?? 200 200
EOF
  export PANE_TTY='/dev/??'
  invoke_hook
  not_recorded
}

@test "ペインの tty が違えば記録しない" {
  export PANE_TTY='/dev/ttys017'
  invoke_hook
  not_recorded
}

@test "背景のジョブは記録しない" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 200 /bin/sh ?? 0 0
200 300 claude ttys016 200 300
EOF
  invoke_hook
  not_recorded
}

@test "Linux の pts 形式でも前景の対話を記録する" {
  cat >"$BATS_TEST_TMPDIR/processes" <<'EOF'
parent 200 sh ? 0 -1
200 300 claude pts/3 200 200
EOF
  export PANE_TTY='/dev/pts/3'
  invoke_hook
  recorded
}

@test "UUID でない ID や不正な JSON では記録しない" {
  local input
  for input in '{}' '{"session_id":123}' '{"session_id":null}' \
    '{"session_id":"877FC4A7-0C4E-4D7B-96F2-0A35C3CBD8DC"}' \
    '{"session_id":"877fc4a7-0c4e-4d7b-96f2-0a35c3cbd8dc\n"}' \
    '{"session_id":"not-a-uuid"}' '{'; do
    INPUT="$input"
    invoke_hook
    not_recorded
  done
  [ ! -e "$BATS_TEST_TMPDIR/ps-args" ]
}

@test "親プロセスの ps が失敗しても記録せず正常終了する" {
  export PS_FAIL='ppid=,comm='
  invoke_hook
  not_recorded
  [ -n "$stderr" ]
}

@test "制御端末の ps が失敗しても記録せず正常終了する" {
  export PS_FAIL='tty=,pgid=,tpgid='
  invoke_hook
  not_recorded
  [ -n "$stderr" ]
}

@test "ps の結果が空でも記録しない" {
  cat >"$STUB/ps" <<'EOF'
#!/bin/bash
exit 0
EOF
  invoke_hook
  not_recorded
}

@test "ペインの tty の取得に失敗しても記録せず正常終了する" {
  export TMUX_FAIL='display-message'
  invoke_hook
  not_recorded
  [ -n "$stderr" ]
}

@test "オプションの設定に失敗しても stdout を出さず正常終了する" {
  export TMUX_FAIL='set-option'
  invoke_hook
  [ -n "$stderr" ]
}

@test "SessionStart は matcher 無しで timeout 10 秒のコマンドとして宣言する" {
  run jq -e '.hooks.SessionStart == [{hooks: [{type: "command",
    command: "$HOME/.claude/tmux-claude-session.sh", timeout: 10}]}]' \
    "$BATS_TEST_DIRNAME/../home/dot_claude/settings.json"
  [ "$status" -eq 0 ]
}
