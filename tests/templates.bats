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

@test "Codex の設定は空のファイルからでも描画できる" {
  run render --with-stdin "$(cat "$SOURCE/dot_codex/modify_private_config.toml")" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'model = '* ]]
}
