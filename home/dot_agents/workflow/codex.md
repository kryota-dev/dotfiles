# Codex adapter

この adapter は `README.md` の共通 capability を Codex で実現する方法だけを定義する。
対話型 Codex と `codex exec` は同じ gate と state contract を守る。

## Main session

interactive main session は `main` profile を使う。これは workspace-write sandbox を維持しつつ、GitHub の
read API と live web search のための network access を有効にする。worker 用 `agent` profile は network を
無効のまま維持する。network access は outbound の境界だけを変え、commit / push / PR 作成 / worktree 作成の
authority を Codex child に渡すものではない。

開始時は、main worktree の人間が TTY で linked worktree を作成する。

```bash
agent-workflow worktree-init <run-id> --branch <branch> --base <base>
codex --profile main --cd <linked-worktree>
```

以降の main session はその linked worktree を作業 root にする。Codex sandbox 内で `git worktree add` を
実行したり、`--add-dir` や sandbox の緩和で main worktree の `.git` に書き込んだりしない。

## Child process

- review と research は shared profile / read-only sandbox で実行する。
- self-contained な実装だけを agent profile / workspace-write sandbox に委任する。対象は linked
  worktree に限定し、親は全 diff を確認してから検証する。
- child の prompt には shared rubric、対象、差分の取得方法、result file を渡す。必要な Claude leg を
  省略せず、同じ rubric を使う独立した Codex leg に置換する。
- child が失敗したら 1 回だけ retry する。必須 leg が再失敗した場合は `blocked`、optional specialist
  だけは欠落を結果に明記して継続できる。

## Non-interactive approval and resume

`codex exec` は approval gate で `waiting-for-user` を返す。user が TTY で次を実行した後だけ、
同じ run id を `--resume` できる。

```bash
agent-workflow approve <run-id> <gate>
agent-workflow status <run-id>
```

`--resume` は phase と result file の場所を復元するだけで、approval を追加しない。外向き操作は
`agent-workflow` の固定 manifest action に渡し、sandbox の緩和や任意 command 実行で代用しない。
