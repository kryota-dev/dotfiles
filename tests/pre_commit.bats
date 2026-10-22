#!/usr/bin/env bats
# グローバルの pre-commit hook が、remote に応じてクライアント名の検査を行うかを確かめる。
# gitleaks は呼ばれた設定ファイルを記録するだけの偽物に差し替える。

bats_require_minimum_version 1.5.0

setup() {
  HOOK="$BATS_TEST_DIRNAME/../home/dot_config/git/exact_hooks/executable_pre-commit"
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME/.config/git" "$BATS_TEST_TMPDIR/bin"
  touch "$HOME/.config/git/gitleaks.toml" "$HOME/.config/git/gitleaks-own.toml"
  LOG="$BATS_TEST_TMPDIR/gitleaks.log"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$LOG" >"$BATS_TEST_TMPDIR/bin/gitleaks"
  chmod +x "$BATS_TEST_TMPDIR/bin/gitleaks"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
}

teardown() {
  # フックが hooks ディレクトリの書き込みの権限を外すので、bats が一時ディレクトリを消せるよう戻す。
  chmod -R u+w "$BATS_TEST_TMPDIR"
}

run_hook() {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$HOOK"
}

# 本番と同じく ~/.config/git/hooks/pre-commit に置いたフックを走らせる（リポジトリのフックに書き換えられうる）。
run_installed_hook() {
  mkdir -p "$HOME/.config/git/hooks"
  GLOBAL_HOOK="$HOME/.config/git/hooks/pre-commit"
  cp "$HOOK" "$GLOBAL_HOOK"
  chmod +x "$GLOBAL_HOOK"
  run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$GLOBAL_HOOK"
}

# リポジトリ自身の .git/hooks/pre-commit を作る。
write_repo_hook() {
  mkdir -p "$REPO/.git/hooks"
  printf '%s\n' "#!/usr/bin/env bash" "$1" >"$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
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

@test "リポジトリのフックがグローバルの pre-commit を書き換えたら、元に戻して警告する" {
  write_repo_hook "printf '#!/usr/bin/env bash\necho replaced\n' >\"\$HOME/.config/git/hooks/pre-commit\""
  mkdir -p "$HOME/.config/git/hooks"
  cp "$HOOK" "$BATS_TEST_TMPDIR/original"
  run_installed_hook
  [ "$status" -eq 0 ]
  cmp -s "$BATS_TEST_TMPDIR/original" "$GLOBAL_HOOK"
  [ -x "$GLOBAL_HOOK" ]
  [[ "$stderr" == *"[pre-commit] WARNING:"* ]]
  [[ "$stderr" == *"chezmoi apply"* ]]
}

@test "リポジトリのフックの終了コードをそのまま返す" {
  write_repo_hook "exit 3"
  run_installed_hook
  [ "$status" -eq 3 ]
}

@test "書き換えが無いときは警告を出さない" {
  write_repo_hook "exit 0"
  run_installed_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"WARNING"* ]]
}
