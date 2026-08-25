# Claude adapter

この adapter は `README.md` の共通 capability を Claude Code で実現する方法だけを定義する。
既存の Claude Code 起動方法と skill 引数は維持する。

- approval は `AskUserQuestion`、notification は `notify`、worker/reviewer は custom Agent を使う。
- `home/dot_claude/agents/*.md.tmpl` は共通 rubric を include する thin adapter であり、観点・出力形式を
  重複定義しない。
- linked worktree が必要な操作は `wtp` で作成した worktree 内で行う。commit、push、PR 作成、
  ready-for-review は共通 host runner を使ってもよい。
- state の新規保存先は共通契約に従う。legacy `.claude/` は migration input としてだけ読む。

