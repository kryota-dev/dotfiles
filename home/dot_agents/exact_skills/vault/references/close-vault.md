# 契約終了時の vault の削除

クライアントの記録を消す操作で、元に戻せない。ユーザーに頼まれたときだけ行い、消す前に対象（vault のパス・別名の symlink・バックアップのパス）を示して確認を取る。

`chezmoi apply` は、Drive のバックアップのうち手元に無い vault を復元する（`run_after_31-vaults.sh`）。消した vault が戻らないよう、名前を `vault-backups/.closed` に記録してから消す。ほかの Mac に残った vault の push がバックアップを作り直しても、`.closed` にある名前は復元されない。

1. vault 名を Google Drive の `vault-backups/.closed` に 1 行で追記する（`printf '%s\n' <owner> >> "<vault-backups>/.closed"`）。
2. 暗号化したバックアップを消す: Google Drive の `vault-backups/<owner>/`。Drive のゴミ箱からも消す（ゴミ箱に 30 日残るため）。
3. ローカルの vault と、別名の symlink（`_vault.md` に書いたもの）を消す: `~/vaults/<owner>/`・`~/vaults/<別名>`。ほかの Mac でも消す。消し忘れた Mac では、apply のたびに「契約を終えた vault が残っています」と表示される。
4. personal は触らない。personal の `daily/` には匿名のラベルしか無く、ラベルとクライアントの対応はクライアントの vault の `_vault.md` にしか無かったので、手順 2・3 で結び付きが消える。personal の `knowledge/` は固有名の検査を通したものだけなので、消さない。
5. 消したことを personal の `daily/` に、匿名のラベルで 1 行記録する。

Claude Code と Codex の会話の記録（`~/.claude/projects/`・`~/.codex/sessions/`）にも、そのクライアントの情報が残る。これを消すかどうかはユーザーに確かめる。
