#!/usr/bin/env bats
# CI に tmux が無くても、印付けと前景の確認によって既存の作業を保護できるか確かめる。

setup() {
  bats_require_minimum_version 1.5.0
  HOOK="$BATS_TEST_DIRNAME/../home/dot_config/tmux/executable_claude-resume.sh"
  STUB="$BATS_TEST_TMPDIR/bin"
  export BATS_TEST_TMPDIR
  export HOME="$BATS_TEST_TMPDIR/home"
  export PATH="$STUB:$PATH"
  export TMUX='/tmp/tmux-test/default,1,0'
  unset XDG_DATA_HOME TMUX_FAIL MARK_FAIL SEND_FAIL PS_FAIL
  mkdir -p "$STUB" "$HOME"
  SESSION_ID='877fc4a7-0c4e-4d7b-96f2-0a35c3cbd8dc'
  SAVE_DIR="$HOME/.local/share/tmux/resurrect"
  SAVE_FILE="$BATS_TEST_TMPDIR/保存 ファイル"
  : >"$BATS_TEST_TMPDIR/save-panes"
  : >"$BATS_TEST_TMPDIR/panes"
  : >"$BATS_TEST_TMPDIR/displays"
  : >"$BATS_TEST_TMPDIR/resurrect-dir"
  printf '%s\n' ttys016 >"$BATS_TEST_TMPDIR/tty"
  cat >"$STUB/ps" <<'EOF'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$@" >>"$BATS_TEST_TMPDIR/ps-args"
[ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = tty= ] && [ "$3" = -p ] || exit 1
[ -z "${PS_FAIL:-}" ] || { echo 'ps が失敗した' >&2; exit 1; }
printf '  %s  \n' "$(cat "$BATS_TEST_TMPDIR/tty")"
EOF
  cat >"$STUB/tmux" <<'EOF'
#!/bin/bash
printf '%s\t' "$@" >>"$BATS_TEST_TMPDIR/tmux-args"
printf '\n' >>"$BATS_TEST_TMPDIR/tmux-args"
[ "${TMUX_FAIL:-}" != "$1" ] || { echo 'tmux が失敗した' >&2; exit 1; }
case "$1" in
  list-panes)
    [ "$#" -eq 4 ] && [ "$2" = -a ] && [ "$3" = -F ] || exit 1
    case "$4" in
      '#{pane_id}') cat "$BATS_TEST_TMPDIR/panes" ;;
      $'#{session_name}\t#{window_index}\t#{pane_index}\t#{@claude-session-id}\t#{@claude-pid}\t#{pane_tty}')
        cat "$BATS_TEST_TMPDIR/save-panes" ;;
      *) exit 1 ;;
    esac
    ;;
  show-option)
    [ "$#" -eq 3 ] && [ "$2" = -gqv ] || exit 1
    case "$3" in
      @claude-resume-ready) if [ -f "$BATS_TEST_TMPDIR/ready" ]; then cat "$BATS_TEST_TMPDIR/ready"; fi ;;
      @resurrect-dir) cat "$BATS_TEST_TMPDIR/resurrect-dir" ;;
      *) exit 1 ;;
    esac
    ;;
  set-option)
    if [ "$#" -eq 3 ] && [ "$2" = -gu ] && [ "$3" = @claude-resume-ready ]; then
      rm -f "$BATS_TEST_TMPDIR/ready"
    elif [ "$#" -eq 4 ] && [ "$2" = -g ] && [ "$3" = @claude-resume-ready ] && [ "$4" = 1 ]; then
      printf '1\n' >"$BATS_TEST_TMPDIR/ready"
    elif [ "$#" -eq 6 ] && [ "$2" = -p ] && [ "$3" = -t ] &&
      [ "$5" = @claude-resume-skip ] && [ "$6" = 1 ]; then
      [ "${MARK_FAIL:-}" != "$4" ] || { echo '印付けが失敗した' >&2; exit 1; }
    else
      exit 1
    fi
    ;;
  display-message)
    [ "$#" -eq 5 ] && [ "$2" = -p ] && [ "$3" = -t ] &&
      [ "$5" = $'#{@claude-resume-skip}\t#{pane_current_command}' ] || exit 1
    awk -F '\t' -v target="$4" '$1 == target { print substr($0, length($1) + 2); found=1; exit }
      END { if (!found) exit 1 }' "$BATS_TEST_TMPDIR/displays"
    ;;
  send-keys)
    [ "$#" -eq 5 ] && [ "$2" = -t ] && [ "$5" = C-m ] || exit 1
    [ "${SEND_FAIL:-}" != "$3" ] || { echo '送信が失敗した' >&2; exit 1; }
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUB/ps" "$STUB/tmux"
}

invoke_hook() {
  run --separate-stderr bash "$HOOK" "$@"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

log_call() {
  printf '%s\t' "$@"
  printf '\n'
}

save_pane() {
  printf '作業 session\t1\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-/dev/ttys016}" >>"$BATS_TEST_TMPDIR/save-panes"
}

restore_pane() {
  printf 'claude_session\t作業 session\t1\t%s\t%s\n' "$1" "${2:-$SESSION_ID}" >>"$SAVE_DIR/last"
}

display_pane() {
  printf '=作業 session:1.%s\t%s\t%s\n' "$1" "$2" "$3" >>"$BATS_TEST_TMPDIR/displays"
}

prepare_restore() {
  mkdir -p "$SAVE_DIR"
  : >"$SAVE_DIR/last"
  printf '1\n' >"$BATS_TEST_TMPDIR/ready"
}

sent_calls() {
  awk -F '\t' '$1 == "send-keys"' "$BATS_TEST_TMPDIR/tmux-args"
}

@test "save は生きていて tty が一致する有効な記録だけを既存の内容に追記する" {
  local dead_pid expected
  # 実在したプロセスの終了を待ち、kill をスタブにせず死んだ PID を検査する。
  (exit 0) &
  dead_pid=$!
  wait "$dead_pid"
  save_pane 1 "$SESSION_ID" "$$"
  save_pane 2 "$SESSION_ID" "$dead_pid"
  save_pane 3 "$SESSION_ID" "$$" /dev/ttys017
  save_pane 4 '壊れた ID' "$$"
  save_pane 5 '' ''
  save_pane 6 "$SESSION_ID" '数字ではない'
  save_pane 7 '' "$$"
  save_pane 8 "$SESSION_ID" ''
  save_pane 9 "${SESSION_ID}x" "$$"
  printf 'pane\t既存の内容\n' >"$SAVE_FILE"
  invoke_hook save "$SAVE_FILE"
  expected=$(printf 'pane\t既存の内容\nclaude_session\t作業 session\t1\t1\t%s' "$SESSION_ID")
  [ "$(cat "$SAVE_FILE")" = "$expected" ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/ps-args")" -eq 2 ]
  [ -z "$stderr" ]
}

@test "save は Linux の pts 形式の tty でも追記する" {
  printf 'pts/3\n' >"$BATS_TEST_TMPDIR/tty"
  save_pane 1 "$SESSION_ID" "$$" /dev/pts/3
  invoke_hook save "$SAVE_FILE"
  [ "$(cat "$SAVE_FILE")" = "$(printf 'claude_session\t作業 session\t1\t1\t%s' "$SESSION_ID")" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ps-args")" = "$(printf '%s\t%s\t%s\t%s' -o tty= -p "$$")" ]
}

@test "save は記録が無ければファイルを作らない" {
  invoke_hook save "$SAVE_FILE"
  [ ! -e "$SAVE_FILE" ]
}

@test "save は ps の失敗した行を飛ばして後続の行も調べる" {
  export PS_FAIL=1
  save_pane 1 "$SESSION_ID" "$$"
  save_pane 2 "$SESSION_ID" "$$"
  invoke_hook save "$SAVE_FILE"
  [ ! -e "$SAVE_FILE" ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/ps-args")" -eq 2 ]
  [ -n "$stderr" ]
}

@test "save は一覧の取得や追記に失敗しても正常終了する" {
  export TMUX_FAIL=list-panes
  invoke_hook save "$SAVE_FILE"
  [ ! -e "$SAVE_FILE" ]
  [ -n "$stderr" ]
  unset TMUX_FAIL
  save_pane 1 "$SESSION_ID" "$$"
  invoke_hook save "$BATS_TEST_TMPDIR/存在しないディレクトリ/file"
  [ -n "$stderr" ]
}

@test "mark は古い ready を消して全ペインに印を付けてから ready を立てる" {
  local expected
  printf '1\n' >"$BATS_TEST_TMPDIR/ready"
  printf '%%1\n%%2\n%%3\n' >"$BATS_TEST_TMPDIR/panes"
  invoke_hook mark
  expected=$(
    log_call set-option -gu @claude-resume-ready
    log_call list-panes -a -F '#{pane_id}'
    log_call set-option -p -t %1 @claude-resume-skip 1
    log_call set-option -p -t %2 @claude-resume-skip 1
    log_call set-option -p -t %3 @claude-resume-skip 1
    log_call set-option -g @claude-resume-ready 1
  )
  [ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" = "$expected" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ready")" = 1 ]
}

@test "mark は途中の失敗でも後続ペインに印を付けるが ready は立てない" {
  local expected
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  printf '%%1\n%%2\n%%3\n' >"$BATS_TEST_TMPDIR/panes"
  export MARK_FAIL='%2'
  invoke_hook mark
  expected=$(
    log_call set-option -gu @claude-resume-ready
    log_call list-panes -a -F '#{pane_id}'
    log_call set-option -p -t %1 @claude-resume-skip 1
    log_call set-option -p -t %2 @claude-resume-skip 1
    log_call set-option -p -t %3 @claude-resume-skip 1
  )
  [ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" = "$expected" ]
  [ ! -e "$BATS_TEST_TMPDIR/ready" ]
  [ -n "$stderr" ]
  invoke_hook restore
  [ -z "$(sent_calls)" ]
}

@test "mark は一覧を取得できなければ古い ready を消したままにする" {
  printf '1\n' >"$BATS_TEST_TMPDIR/ready"
  export TMUX_FAIL=list-panes
  invoke_hook mark
  [ ! -e "$BATS_TEST_TMPDIR/ready" ]
  [ -n "$stderr" ]
}

@test "mark は ready を消せなければ一覧を取得しない" {
  export TMUX_FAIL=set-option
  invoke_hook mark
  [ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" = "$(log_call set-option -gu @claude-resume-ready)" ]
  [ -n "$stderr" ]
}

@test "restore は ready が無いか 1 以外なら何も送らない" {
  local ready
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  rm "$BATS_TEST_TMPDIR/ready"
  invoke_hook restore
  for ready in '' 0 11; do
    printf '%s\n' "$ready" >"$BATS_TEST_TMPDIR/ready"
    invoke_hook restore
  done
  [ -z "$(sent_calls)" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" != *display-message* ]]
}

@test "restore は印なしのシェルにだけ正確な対象と UUID で再開を送る" {
  local expected
  prepare_restore
  printf 'pane\t上流の行\nclaude_session_extra\t作業 session\t1\t9\t%s\n' "$SESSION_ID" >>"$SAVE_DIR/last"
  restore_pane 1
  display_pane 1 '' zsh
  restore_pane 2
  display_pane 2 1 zsh
  restore_pane 3
  display_pane 3 '' claude
  restore_pane 4 '壊れた ID; echo 実行しない'
  display_pane 4 '' zsh
  restore_pane 5
  restore_pane 6
  display_pane 6 '' -bash
  invoke_hook restore
  expected=$(
    log_call send-keys -t '=作業 session:1.1' "claude --resume $SESSION_ID" C-m
    log_call send-keys -t '=作業 session:1.6' "claude --resume $SESSION_ID" C-m
  )
  [ "$(sent_calls)" = "$expected" ]
  [ ! -e "$BATS_TEST_TMPDIR/ready" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" != *'=作業 session:1.4'* ]]
  [ "$(sed -n '2p' "$BATS_TEST_TMPDIR/tmux-args")" = "$(log_call set-option -gu @claude-resume-ready)" ]
  invoke_hook restore
  [ "$(sent_calls)" = "$expected" ]
}

@test "restore は許可した全シェルとログインシェルを再開する" {
  local shell pane=0 expected=''
  prepare_restore
  for shell in zsh bash sh fish dash -zsh -bash -sh -fish -dash; do
    pane=$((pane + 1))
    restore_pane "$pane"
    display_pane "$pane" '' "$shell"
    expected+="$(log_call send-keys -t "=作業 session:1.$pane" "claude --resume $SESSION_ID" C-m)"$'\n'
  done
  invoke_hook restore
  [ "$(sent_calls)" = "${expected%$'\n'}" ]
}

@test "restore は空や不正な前景のコマンドをシェルと見なさない" {
  local command pane=0
  prepare_restore
  for command in '' vim /bin/zsh --zsh 'zsh -l' zshx; do
    pane=$((pane + 1))
    restore_pane "$pane"
    display_pane "$pane" '' "$command"
  done
  invoke_hook restore
  [ -z "$(sent_calls)" ]
}

@test "restore は ready の取得や消去に失敗したら何も送らない" {
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  export TMUX_FAIL=show-option
  invoke_hook restore
  [ -n "$stderr" ]
  export TMUX_FAIL=set-option
  invoke_hook restore
  [ -n "$stderr" ]
  [ -z "$(sent_calls)" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/tmux-args")" != *display-message* ]]
}

@test "restore は送信の失敗で止まらず次のペインに進む" {
  prepare_restore
  restore_pane 1
  restore_pane 2
  display_pane 1 '' zsh
  display_pane 2 '' zsh
  export SEND_FAIL='=作業 session:1.1'
  invoke_hook restore
  [ "$(sent_calls | wc -l)" -eq 2 ]
  [ -n "$stderr" ]
}

@test "restore は保存ファイルが無くても ready を消して正常終了する" {
  printf '1\n' >"$BATS_TEST_TMPDIR/ready"
  invoke_hook restore
  [ ! -e "$BATS_TEST_TMPDIR/ready" ]
  [ -z "$(sent_calls)" ]
  [ -z "$stderr" ]
}

@test "restore は設定された保存先のチルダを HOME に展開する" {
  SAVE_DIR="$HOME/保存 データ"
  printf '~/保存 データ\n' >"$BATS_TEST_TMPDIR/resurrect-dir"
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/別の保存先"
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  invoke_hook restore
  [ "$(sent_calls)" = "$(log_call send-keys -t '=作業 session:1.1' "claude --resume $SESSION_ID" C-m)" ]
}

@test "restore は設定された保存先の HOME を文字列として展開する" {
  SAVE_DIR="$HOME/保存 データ"
  printf '$HOME/保存 データ\n' >"$BATS_TEST_TMPDIR/resurrect-dir"
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  invoke_hook restore
  [ -n "$(sent_calls)" ]
}

@test "restore は保存先のコマンド置換を実行しない" {
  SAVE_DIR="$BATS_TEST_TMPDIR/\$(touch 実行しない)"
  printf '%s\n' "$SAVE_DIR" >"$BATS_TEST_TMPDIR/resurrect-dir"
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  invoke_hook restore
  [ -n "$(sent_calls)" ]
  [ -z "$stderr" ]
}

@test "restore は保存先が未設定なら XDG_DATA_HOME を使う" {
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/XDG データ"
  SAVE_DIR="$XDG_DATA_HOME/tmux/resurrect"
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  invoke_hook restore
  [ -n "$(sent_calls)" ]
}

@test "restore は XDG_DATA_HOME が空でも HOME の既定の保存先を使う" {
  export XDG_DATA_HOME=''
  prepare_restore
  restore_pane 1
  display_pane 1 '' zsh
  invoke_hook restore
  [ -n "$(sent_calls)" ]
}

@test "引数が不正なら使い方を stderr に出して異常終了する" {
  local args
  for args in '' 'save' 'mark extra' 'restore extra' 'unknown' 'save file extra'; do
    # ここでは余分な引数を含む呼び出しを作るため、意図的に単語へ分割する。
    # shellcheck disable=SC2086
    run --separate-stderr bash "$HOOK" $args
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *使い方:* ]]
  done
  run --separate-stderr bash "$HOOK" save ''
  [ "$status" -ne 0 ]
  [[ "$stderr" == *使い方:* ]]
  [ ! -e "$BATS_TEST_TMPDIR/tmux-args" ]
}
