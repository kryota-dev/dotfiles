#!/usr/bin/env bats
# グローバルの pre-commit hook が、remote に応じてクライアント名の検査を行うかを確かめる。
# gitleaks は呼ばれた設定ファイルを記録するだけの偽物に差し替える。

setup() {
  HOOK="$BATS_TEST_DIRNAME/../home/dot_config/git/hooks/executable_pre-commit"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/git" "$BATS_TEST_TMPDIR/bin"
  touch "$HOME/.config/git/gitleaks.toml" "$HOME/.config/git/gitleaks-own.toml"
  LOG="$BATS_TEST_TMPDIR/gitleaks.log"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$LOG" >"$BATS_TEST_TMPDIR/bin/gitleaks"
  chmod +x "$BATS_TEST_TMPDIR/bin/gitleaks"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
}

run_hook() {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$HOOK"
}

@test "自分の GitHub の remote ではクライアント名も検査する" {
  git -C "$REPO" remote add origin git@github.com:kryota-dev/example.git
  run_hook
  [ "$status" -eq 0 ]
  grep -q 'gitleaks-own.toml' "$LOG"
}

@test "remote が無いリポジトリではクライアント名も検査する" {
  run_hook
  [ "$status" -eq 0 ]
  grep -q 'gitleaks-own.toml' "$LOG"
}

@test "クライアントの vault（gcrypt の remote）ではクライアント名を検査せず、秘密情報だけを検査する" {
  git -C "$REPO" remote add origin "gcrypt::$HOME/Library/CloudStorage/GoogleDrive-x/My Drive/vault-backups/client-a"
  run_hook
  [ "$status" -eq 0 ]
  grep -q 'gitleaks.toml' "$LOG"
  run grep -c 'gitleaks-own.toml' "$LOG"
  [ "$output" = 0 ]
}

@test "personal の vault（gcrypt の remote）ではクライアント名も検査する" {
  git -C "$REPO" remote add origin "gcrypt::$HOME/Library/CloudStorage/GoogleDrive-x/My Drive/vault-backups/personal"
  run_hook
  [ "$status" -eq 0 ]
  grep -q 'gitleaks-own.toml' "$LOG"
}

@test "他者の remote ではクライアント名を検査しない" {
  git -C "$REPO" remote add origin git@github.com:someone/example.git
  run_hook
  [ "$status" -eq 0 ]
  run grep -c 'gitleaks-own.toml' "$LOG"
  [ "$output" = 0 ]
}
