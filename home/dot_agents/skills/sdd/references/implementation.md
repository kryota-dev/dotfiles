# sdd: Phase 4（実装）

`SKILL.md` が compile した `tasks.md` を実行に移す手順。**Phase 3 完了後、Phase 4 に入る前にこの
ファイルを Read する。**

**この Phase は spec compiler の所有物ではない。** worker の選定と委譲契約の SSOT は
`pr-workflow`「共有作業ツリーでの Claude subagent 委譲契約」節（Claude subagent）と
`codex/SKILL.md`「agent profile（workspace-write 実行）」節（Codex worker）にある。ここは
compiler の出力（tasks.md）をその契約へ橋渡しする手順だけを持ち、契約本文を再掲しない。

## Phase 4: 実装

### 4-1. 実装準備

requirements.md, design.md, tasks.md を精読し、全体像を把握。

### 4-2. タスク順次実装

**実装の委譲方針**: 複数ファイル横断・context 継続が要るタスクは Leader が実装する（context continuity）。**自己完結タスク**（単一ファイル・tasks.md 上で他タスクへの依存記載なし・並行実行中の他タスクと共有状態を持たない）は、Sonnet worker（`model: sonnet`）または Codex worker（`codex exec --profile agent`、workspace-write）に委譲してよい。既定は Leader / Sonnet worker、cross-model diversity が欲しいときに Codex。

**Codex worker の前提条件と契約**:

- **linked worktree 内でのみ委譲する**。0-4 で「現在の場所で作業」を選んだ／`wtp` にフォールバックした結果 **main worktree にいる場合は Codex 委譲を選択肢から外す**（Leader or Sonnet worker に限定）。判定は `codex/SKILL.md` の fail-closed worktree ガードをそのまま前置して機械的に行い、abort したら委譲を諦める（回避しない）。
- **呼び出し形・`CODEX_HOME` prelude・worktree ガード・実行順序契約・委任範囲の制約は `codex/SKILL.md`「agent profile（workspace-write 実行）」節が唯一の SSOT**。ここに再掲せず必ずそれに従う。特に **`git -C <worktree> diff` の全体レビュー → ホスト側の検証コマンド（lint / test / build）→ commit** の順序を守り、**diff レビュー前にテスト・lint・ビルドを一切実行しない**（Codex が書いたテスト・Makefile・設定は sandbox 外で走るため）。commit は親が行う（`.git` は Codex から read-only）。

**Claude subagent（Sonnet worker / Explore）の前提条件と契約**:

- **共有作業ツリーへの書き込みガードは `pr-workflow`「共有作業ツリーでの Claude subagent 委譲契約」節が唯一の SSOT**。ここに再掲せず必ずそれに従う（委譲プロンプトに規約を含めること、および spawn 前後の親の責務を含む）。4-2 の実装 worker だけでなく、**Phase 1・2 と本節手順 2 で起動する Explore 型の調査サブエージェントも対象**である（`Edit` / `Write` を持たなくても `Bash` 経由で作業ツリーを書き換えられるため）。

tasks.md の各タスクを順番に実装:

1. tasks.md のステータスを `[ ]` → `[-]` に更新（Edit ツール使用）
2. 必要に応じて調査サブエージェント（Explore 型）で関連コードを調査
3. **Leader 自身がコードを実装**
4. テストが必要な場合はテストも実装
5. tasks.md のステータスを `[-]` → `[x]` に更新
6. 次のタスクへ

### 4-3. 品質チェック

**前提（Codex 委譲がある場合は必須）**: 4-2 で Codex worker に委譲したタスクが 1 つでもある場合、本節のコマンドを実行する**前に** `git -C <worktree> diff` の全体を必ずレビューする。品質チェックはホスト（sandbox 外）で実行されるため、レビュー前の実行は任意コード実行に到達しうる（`codex/SKILL.md`「実行順序契約」）。

全タスク完了後:

1. `package.json`（または類似の設定ファイル）の scripts を確認
2. 利用可能な品質チェックコマンドを実行（lint, type-check, format, test 等）
3. エラーがあれば修正し、再実行して通るまで繰り返す

Phase 4 完了後は [`delivery.md`](delivery.md) を Read して Phase 5 へ進む。
