# 契約終了時の vault の削除

クライアントの記録を消す操作で、元に戻せない。ユーザーに頼まれたときだけ行い、消す前に対象（vault のパス・バックアップのパス・`owners.md` の行）を示して確認を取る。

1. ローカルの vault を消す: `~/vaults/<owner>/`。
2. 暗号化したバックアップを消す: Google Drive の `vault-backups/<owner>/`。Drive のゴミ箱からも消す（ゴミ箱に 30 日残るため）。
3. personal の `owners.md` から、そのクライアントの行を消す。personal の `daily/` には匿名のラベルしか残っていないので、対応表を消せばクライアントとは結び付かなくなる。personal の `knowledge/` は固有名の検査を通したものだけなので、消さない。
4. 消したことを personal の `daily/` に、匿名のラベルで 1 行記録する。

Claude Code と Codex の会話の記録（`~/.claude/projects/`・`~/.codex/sessions/`）にも、そのクライアントの情報が残る。これを消すかどうかはユーザーに確かめる。
