# sdd: Phase 4（実装）

**Phase 3（tasks.md）の後、Phase 4 に入る前にこのファイルを Read する。**

## Phase 4: 実装

- requirements.md / design.md / tasks.md を読み、tasks.md を順に実装する。着手時に `[ ]` → `[-]`、完了時に `[-]` → `[x]` と更新する。テストが要るタスクはテストも書く。
- **実装は既定で自分で行う。** 行き詰まったときや別系統の視点が欲しいときだけ、Claude Code から実行しているなら自己完結したタスク（tasks.md の 1 タスク分で、他のタスクに依存せず、並行するタスクと状態を共有しない）を Codex worker（`codex exec --profile agent`）に渡してよい。
  - Codex に渡すのは linked worktree の中にいるときだけ。呼び出し形・worktree ガード・実行順序・委任範囲は `codex/SKILL.md`「agent profile（workspace-write 実行）」節が SSOT で、ここに再掲しない。特に、`git diff` の全体をレビューしてから検証コマンドを走らせ、commit は親が行う（diff を読む前にテスト・lint・ビルドを実行しない）。
- subagent に作業ツリーへの書き込みがありうる作業を渡すときは、`pr-workflow`「共有作業ツリーでの subagent 委譲契約」節に従う（委譲プロンプトへの規約の記載と、spawn 前後の親の責務を含む。シェルを持つ調査用の subagent も対象）。
- 全タスクが終わったら、リポジトリの品質チェック（lint・型検査・フォーマット・テストなど。`package.json` の scripts や Makefile から選ぶ）を通るまで直して実行する。Codex に渡したタスクがあれば、その前に diff の全体を読む。

Phase 4 が終わったら [`delivery.md`](delivery.md) を Read して Phase 5 へ進む。
