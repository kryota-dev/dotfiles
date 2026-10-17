#!/usr/bin/env bats
# vault をそろえるスクリプトが、足りないものだけを作り、使えないものがあるときは apply を止めないことを確かめる。
# op・gpg・security・git などは、呼び出しを記録するだけの偽物に差し替える。

setup() {
  SOURCE="$BATS_TEST_DIRNAME/../home"
  SCRIPT="$BATS_TEST_TMPDIR/vaults.sh"
  chezmoi execute-template --source "$SOURCE" <"$SOURCE/run_after_31-vaults.sh.tmpl" >"$SCRIPT"
  BIN="$BATS_TEST_TMPDIR/bin"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$BIN"
  export OP_VAULT=test
  export VAULTS_HOME="$BATS_TEST_TMPDIR/vaults"
  export CLOUD_STORAGE="$BATS_TEST_TMPDIR/cloud"
  export OBSIDIAN_JSON="$BATS_TEST_TMPDIR/obsidian/obsidian.json"
  BACKUPS="$CLOUD_STORAGE/GoogleDrive-me@example.com/My Drive/vault-backups"

  stub op 'case "$*" in
  *fingerprint*) echo FPR ;;
  *drive_account*) echo me@example.com ;;
  *password*) echo secret ;;
  esac'
  stub gpg 'case "$*" in
  *--with-keygrip*) printf "grp:::::::::GRIP1:\ngrp:::::::::GRIP2:\n" ;;
  esac'
  stub security 'case "$1" in find-generic-password) exit 1 ;; esac'
  stub git 'if [ "$1" = clone ]; then for a; do d=$a; done; mkdir -p "$d"; fi'
  stub git-remote-gcrypt ''
  stub pinentry-mac ''
  stub pgrep 'exit 1'
  export PATH="$BIN:$PATH"
}

# 呼び出しを記録してから、与えた本文を実行する偽物のコマンドを作る。
stub() {
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

@test "1Password を読めなければ何もせず、apply を止めない" {
  stub op 'exit 1'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"読めません"* ]]
  [ ! -e "$VAULTS_HOME" ]
}

@test "Google Drive のバックアップが無ければ何もせず、apply を止めない" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault-backups が見つかりません"* ]]
}

@test "手元に無い vault だけを、participants を指定して clone する" {
  mkdir -p "$BACKUPS/personal" "$BACKUPS/client-a" "$VAULTS_HOME/personal"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "git clone -q -c remote.origin.gcrypt-participants=FPR gcrypt::$BACKUPS/client-a $VAULTS_HOME/client-a" "$LOG"
  run grep -c 'git clone' "$LOG"
  [ "$output" = 1 ]
}

@test "キーチェーンの項目を keygrip ごとに作る" {
  mkdir -p "$BACKUPS"
  run bash "$SCRIPT"
  grep -q 'security add-generic-password -s GnuPG -a GRIP1' "$LOG"
  grep -q 'security add-generic-password -s GnuPG -a GRIP2' "$LOG"
}

@test "_vault.md の owners から別名の symlink を作る" {
  mkdir -p "$BACKUPS" "$VAULTS_HOME/client-a"
  printf -- '---\nowners: [client-a, client-a-labs]\nlabel: c1\n---\n' >"$VAULTS_HOME/client-a/_vault.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(readlink "$VAULTS_HOME/client-a-labs")" = client-a ]
}

@test "Obsidian に vault を一度だけ登録し、別名の symlink は登録しない" {
  mkdir -p "$BACKUPS" "$VAULTS_HOME/personal" "$VAULTS_HOME/client-a"
  ln -s client-a "$VAULTS_HOME/client-a-labs"
  bash "$SCRIPT"
  bash "$SCRIPT"
  run grep -o '"path"' "$OBSIDIAN_JSON"
  [ "${#lines[@]}" -eq 2 ]
  run grep -c 'client-a-labs' "$OBSIDIAN_JSON"
  [ "$output" = 0 ]
}

@test "Obsidian の起動中は vault の一覧に触らない" {
  mkdir -p "$BACKUPS" "$VAULTS_HOME/personal"
  stub pgrep 'exit 0'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$OBSIDIAN_JSON" ]
}
