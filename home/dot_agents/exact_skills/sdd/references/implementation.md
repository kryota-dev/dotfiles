# sdd: Phase 4（実装）

**Phase 3（tasks.md）の後、Phase 4 に入る前にこのファイルを Read する。**

## Phase 4: 実装

- requirements.md / design.md / tasks.md を読み、tasks.md を順に実装する。着手時に `[ ]` → `[-]`、完了時に `[-]` → `[x]` と更新する。テストが要るタスクはテストも書く。
- **実装は GPT の `implementer` に、tasks.md の 1 タスクずつ渡す**（役割は [`pr-workflow/references/model-roles.md`](../../pr-workflow/references/model-roles.md)）。Claude Code からは `codex/SKILL.md`「実装を任せる」の起動形、Codex からは `spawn_agent`（`agent_type: implementer`、`fork_turns: "none"`）で起動する。
  - 委譲プロンプトは `codex` skill の 4 部構成で書く。Goal にタスクの Purpose、Context に requirements.md・design.md の該当箇所と _Leverage のファイル、Constraints にタスクの File（書いてよいファイル）、Done when にタスクの受け入れ基準とテストを書く。
  - 渡すのは linked worktree の中にいるときだけ。worktree のガード・実行の順序・委任してよい範囲は `codex/SKILL.md` が SSOT で、ここに再掲しない。特に、`git diff` の全体を読んでから検証コマンドを走らせ、commit は親が行う（diff を読む前にテスト・lint・ビルドを実行しない）。
  - 親は diff を design.md と照らし、テストを弱めていないか、タスクの File の外を変えていないかを確かめる。だめなら原因を委譲プロンプトに足して渡し直し、格上げは model-roles.md の「実装の格上げ」に従う。
  - 親が自分で書いてよいのは、数行で済む修正と、secret や認証情報に触れうるタスク（`codex` skill が委任を禁じるもの）だけ。自分で書いたタスクは、PR の本文に理由を 1 行残す。
- subagent に作業ツリーへの書き込みがありうる作業を渡すときは、`pr-workflow`「共有作業ツリーでの subagent 委譲契約」節に従う（委譲プロンプトへの規約の記載と、spawn 前後の親の責務を含む。シェルを持つ調査用の subagent も対象）。
- 全タスクが終わったら、リポジトリの品質チェック（lint・型検査・フォーマット・テストなど。`package.json` の scripts や Makefile から選ぶ）を通るまで直して実行する。その前に、渡したタスクの diff の全体を読み終えていることを確かめる。

Phase 4 が終わったら [`delivery.md`](delivery.md) を Read して Phase 5 へ進む。
