#!/usr/bin/env bats
# すべてのテンプレートが描画できることを確かめる。1Password を読むものは CI で使えないので除く。

setup() {
  SOURCE="$BATS_TEST_DIRNAME/../home"
}

render() {
  chezmoi execute-template --source "$SOURCE" "$@"
}

@test "1Password を参照しないテンプレートはすべて描画できる" {
  while IFS= read -r f; do
    grep -q onepasswordRead "$f" && continue
    [ "$(basename "$f")" = .chezmoi.toml.tmpl ] && continue
    run render <"$f"
    [ "$status" -eq 0 ] || {
      echo "描画に失敗: $f: $output"
      return 1
    }
  done < <(find "$SOURCE" -name '*.tmpl')
}

@test "設定のテンプレートは、入力された vault 名を手元の設定に残す" {
  # 手元の chezmoi.toml にある値を拾わないよう、空の設定で描画する。
  prompt=$(sed -n 's/.*promptStringOnce \. "op_vault" "\([^"]*\)".*/\1/p' "$SOURCE/.chezmoi.toml.tmpl")
  run render --config "$BATS_TEST_TMPDIR/empty.toml" --init --promptString "$prompt=example-vault" <"$SOURCE/.chezmoi.toml.tmpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *'op_vault = "example-vault"'* ]]
}

@test ".chezmoiexternal.toml は固定した URL で描画できる" {
  run render <"$SOURCE/.chezmoiexternal.toml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<no value>"* ]]
}

@test "Codex の設定は Codex が書いたキーを残し、管理するキーを設定する" {
  input=$'notify = ["x"]\n[projects."/tmp/p"]\ntrust_level = "trusted"\n[mcp_servers.node_repl]\ncommand = "node"\n'
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_config.toml")" <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *'notify = ["x"]'* ]]
  [[ "$output" == *'trust_level = "trusted"'* ]]
  [[ "$output" == *'[mcp_servers.node_repl]'* ]]
  [[ "$output" == *'[mcp_servers.context7]'* ]]
  [[ "$output" == *'memories = true'* ]]
}

@test "Codex の設定は model_context_window を消し、モデルの自動判定に任せる" {
  input=$'model_context_window = 1000000\n'
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_config.toml")" <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$output" != *'model_context_window'* ]]
}

@test "Codex の設定は空のファイルからでも描画できる" {
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_config.toml")" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'model = '* ]]
}

@test "Codex の profile は Codex が書いたキーを残し、管理するキーを設定する" {
  input=$'[tui.model_availability_nux]\n"gpt-5.5" = 3\n'
  for f in modify_private_astra.config.toml modify_private_agent.config.toml; do
    run render --with-stdin "$(cat "$SOURCE/dot_codex/$f")" <<<"$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"gpt-5.5" = 3'* ]]
  done
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_astra.config.toml")" <<<"$input"
  [[ "$output" == *'model = "gpt-6-astra"'* ]]
  [[ "$output" == *'model_reasoning_effort = "low"'* ]]
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_agent.config.toml")" <<<"$input"
  [[ "$output" == *'approval_policy = "never"'* ]]
  [[ "$output" == *'network_access = false'* ]]
}

@test "Codex の profile は空のファイルからでも描画できる" {
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_astra.config.toml")" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'model = "gpt-6-astra"'* ]]
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_agent.config.toml")" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'sandbox_mode = "workspace-write"'* ]]
}

@test "Claude Code の plugin のスクリプトは、github の marketplace だけを add する" {
  run render <"$SOURCE/run_onchange_after_17-claude-plugins.sh.tmpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *'claude plugin marketplace add "openai/codex-plugin-cc#'* ]]
  [[ "$output" != *'marketplace add ""'* ]]
  [[ "$output" != *'marketplace add "#'* ]]
  [[ "$output" == *'claude plugin install "spark@spark-mail" --scope user'* ]]
}

@test "Codex の設定は spark の MCP を、既定で無効かつ書き込み系だけ承認を求める形で宣言する" {
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_config.toml")" </dev/null
  [ "$status" -eq 0 ]
  spark=$(sed -n '/^ *\[mcp_servers.spark\]/,/^ *\[/p' <<<"$output")
  [[ "$spark" == *'default_tools_approval_mode = "writes"'* ]]
  [[ "$spark" == *'enabled = false'* ]]
}
