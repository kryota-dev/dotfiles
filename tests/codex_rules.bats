#!/usr/bin/env bats

setup() {
  command -v codex >/dev/null || skip "codex がインストールされていない"
  RULES="$BATS_TEST_DIRNAME/../home/dot_codex/rules/dotfiles.rules"
}

decision() {
  codex execpolicy check --rules "$RULES" -- "$@" | jq -r '.decision // "none"'
}

@test "破壊的なコマンドは承認が必要" {
  [ "$(decision terraform destroy)" = "prompt" ]
  [ "$(decision docker volume prune)" = "prompt" ]
  [ "$(decision gh repo delete foo)" = "prompt" ]
}

@test "force push は禁止" {
  [ "$(decision git push --force origin main)" = "forbidden" ]
}

@test "通常のコマンドには影響しない" {
  [ "$(decision ls -la)" = "none" ]
  [ "$(decision git push origin main)" = "none" ]
}

@test "spark の書き込み系サブコマンドは承認が必要で、読み取りには影響しない" {
  for sub in draft event comment action contact-action; do
    [ "$(decision spark "$sub" --help)" = "prompt" ]
  done
  [ "$(decision spark accounts)" = "none" ]
  [ "$(decision spark search foo)" = "none" ]
}
