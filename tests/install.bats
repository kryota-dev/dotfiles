#!/usr/bin/env bats
# install.sh の 1Password の待機が、op の対話の確認で止まらないことを確かめる。

setup() {
  INSTALL="$BATS_TEST_DIRNAME/../install.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # 標準入力から読めたら失敗する op の代役。本物はここで手動追加の確認を出す。
  printf '#!/bin/bash\n! read -r _\n' >"$BATS_TEST_TMPDIR/bin/op"
  chmod +x "$BATS_TEST_TMPDIR/bin/op"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "op の待機は、op に標準入力を渡さない" {
  check=$(sed -nE 's/^until (op vault list.*); do$/\1/p' "$INSTALL")
  [ -n "$check" ]
  run bash -c "$check" <<<"Y"
  [ "$status" -eq 0 ]
}
