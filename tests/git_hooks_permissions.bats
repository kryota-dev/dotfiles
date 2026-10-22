#!/usr/bin/env bats
# apply の前後で hooks ディレクトリの書き込みの権限が切り替わる（after で作れなくなり、before で作れる）ことを確かめる。

setup() {
  BEFORE="$BATS_TEST_DIRNAME/../home/run_before_06-git-hooks-writable.sh"
  AFTER="$BATS_TEST_DIRNAME/../home/run_after_41-git-hooks-readonly.sh"
  export GIT_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$GIT_HOOKS_DIR"
}

teardown() {
  # bats が一時ディレクトリを消せるよう、書き込みの権限を戻す。
  chmod u+w "$GIT_HOOKS_DIR" 2>/dev/null || true
}

@test "after のスクリプトのあとは、hooks ディレクトリにファイルを作れない" {
  run bash "$AFTER"
  [ "$status" -eq 0 ]
  run bash -c 'printf x > "$1/f"' _ "$GIT_HOOKS_DIR"
  [ "$status" -ne 0 ]
}

@test "after のあとに before のスクリプトを走らせると、ファイルを作れる" {
  bash "$AFTER"
  run bash "$BEFORE"
  [ "$status" -eq 0 ]
  printf x > "$GIT_HOOKS_DIR/f"
  [ -f "$GIT_HOOKS_DIR/f" ]
}

@test "hooks ディレクトリが無いとき、before のスクリプトは 0 で終わる" {
  rmdir "$GIT_HOOKS_DIR"
  run bash "$BEFORE"
  [ "$status" -eq 0 ]
}
