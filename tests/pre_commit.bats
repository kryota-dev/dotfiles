#!/usr/bin/env bats
# グローバルの pre-commit hook が、remote に応じてクライアント名の検査を行うかを確かめる。
# gitleaks は呼ばれた設定ファイルを記録するだけの偽物に差し替える。

bats_require_minimum_version 1.5.0

setup() {
  HOOK="$BATS_TEST_DIRNAME/../home/dot_config/git/exact_hooks/readonly_executable_pre-commit"
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
  # 本番の apply 後の状態に合わせる。
  [ -z "${HOOK_READONLY:-}" ] || chmod a-w "$GLOBAL_HOOK"
  [ -z "${HOOKS_DIR_LOCKED:-}" ] || chmod a-w "$HOME/.config/git/hooks"
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

@test "グローバルの pre-commit が読み取り専用でも、リポジトリのフックが rm して書き直したら、元に戻して警告する" {
  # chezmoi の readonly_ のファイルは、上書きでは書き換えられないので、rm してから書き直す。
  write_repo_hook "d=\"\$HOME/.config/git/hooks\"; chmod u+w \"\$d\"; rm -f \"\$d/pre-commit\"; printf '#!/usr/bin/env bash\necho replaced\n' >\"\$d/pre-commit\""
  cp "$HOOK" "$BATS_TEST_TMPDIR/original"
  HOOK_READONLY=1 run_installed_hook
  [ "$status" -eq 0 ]
  cmp -s "$BATS_TEST_TMPDIR/original" "$GLOBAL_HOOK"
  [ -x "$GLOBAL_HOOK" ]
  [ ! -w "$GLOBAL_HOOK" ]
  [[ "$stderr" == *"[pre-commit] WARNING:"* ]]
}

@test "hooks ディレクトリが書き込める状態で走ったら、書き込みの権限を外して警告する" {
  write_repo_hook "exit 0"
  run_installed_hook
  [ "$status" -eq 0 ]
  [ ! -w "$HOME/.config/git/hooks" ]
  [[ "$stderr" == *"[pre-commit] WARNING:"* ]]
}

@test "リポジトリのフックの終了コードをそのまま返す" {
  write_repo_hook "exit 3"
  run_installed_hook
  [ "$status" -eq 3 ]
}

@test "書き換えが無いときは警告を出さない" {
  write_repo_hook "exit 0"
  HOOKS_DIR_LOCKED=1 run_installed_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"WARNING"* ]]
}

# グローバルの core.hooksPath を設定し、リポジトリのフックが見る git の hooks の場所を記録させる。
record_git_path_hooks() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global core.hooksPath "$HOME/.config/git/hooks"
  write_repo_hook "$1git rev-parse --path-format=absolute --git-path hooks >\"$BATS_TEST_TMPDIR/git-path-hooks\""
}

@test "リポジトリのフックの子プロセスでは、core.hooksPath がリポジトリの hooks を指す" {
  record_git_path_hooks ""
  run_installed_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/git-path-hooks")" = "$(cd "$REPO/.git/hooks" && pwd -P)" ]
}

@test "GIT_CONFIG_COUNT が設定済みでも壊さず、続きの番号で core.hooksPath を足す" {
  record_git_path_hooks "git config user.name >\"$BATS_TEST_TMPDIR/user-name\"; "
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=probe run_installed_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/user-name")" = probe ]
  [ "$(cat "$BATS_TEST_TMPDIR/git-path-hooks")" = "$(cd "$REPO/.git/hooks" && pwd -P)" ]
}
