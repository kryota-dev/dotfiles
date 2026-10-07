# sdd: Phase 5（コミット & PR）と Phase 6（完了報告）

**Phase 5 に入る前にこのファイルを Read する。**

コミットと PR の規約（Conventional Commits・日本語メッセージ・1 コミット 1 目的、PR テンプレートの構成、`--assignee @me`）は `~/AGENTS.md`「git / PR / Issue の運用」が SSOT で、ここで上書きしない。ただし規約のうち承認に関するもの（コミットの分割計画の承認と、PR 本文の承認）は、この文脈では適用しない。sdd は承認で止まらない契約で、pr-workflow の承認点インベントリでも standard / large path ではコミットと PR の確認が発生しないため。

## Phase 5: コミット & PR

- ブランチ: pr-workflow 経由、またはフォールバックでワークツリーを作った場合は作成済み。現在のブランチが既定ブランチ（`$BASE`）のときだけ、`claude/{issue}/{spec-name}`（Issue が無ければ `claude/{spec-name}`）を作る。
- コミット: 変更を目的ごとに分け、依存の順に、ビルドが壊れない単位でコミットする。秘密情報（`.env` や認証情報）を含めない。
- push: `git push -u origin HEAD`。
- PR: 本文はリポジトリの PR テンプレートの構成に沿って一時ファイルに書き、Issue があれば `closes #{issue}` を入れる。`gh pr create --draft --base "$BASE" --head "$(git branch --show-current)" --assignee "@me" --body-file <file>` で作る。失敗したら原因を確かめて直し、`gh auth status` で認証も確かめる。

## Phase 6: 完了報告

`notify` を実行し、spec の 3 ファイルのパス、ブランチ、PR の URL、コミット一覧を報告する。
