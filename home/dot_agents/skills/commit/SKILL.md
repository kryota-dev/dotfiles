---
name: commit
description: 変更をコミットする際に使用。現在の差分を分析し、適切なブランチ作成と論理的な粒度でのコミット分割を行う。コミット計画を提示しユーザー承認後に実行する。
argument-hint: "[branch-name]"
---

現在の差分を分析し、適切なブランチを作成して論理的な粒度でコミットを作成します。

## Harness contract

commit 計画の user 承認は `~/.agents/workflow/README.md` の approval capability で得る。Claude では
`AskUserQuestion` を使える。Codex の非対話実行は `agent-workflow approve <run-id> commit` の後にだけ
`agent-workflow commit <run-id> --message-file <file> -- <path>...` を使う。任意 command や main worktree
への commit は許可しない。

引数: $ARGUMENTS（ブランチ名の提案。未指定の場合は変更内容から自動生成）

実行手順：

1. 現在の差分を確認：
   現在のブランチ名を確認 !`git branch --show-current`

   未追跡ファイルと変更を確認 !`git status`

   変更内容の詳細確認 !`git diff`

   ステージング済みの変更確認 !`git diff --cached`

2. 変更内容を分析：

   - 変更されたファイルをグループ化（機能、モジュール、変更タイプ別）
   - 各グループの変更の性質を特定（feat, fix, docs, chore, refactor 等）
   - 依存関係を考慮した適切なコミット順序を決定

3. コミット計画の提案とユーザー確認：
   変更内容の分析結果に基づいて、以下のようなコミット計画を提示：

   ```
   📝 コミット計画の提案:

   1. feat(auth): ユーザー認証機能の追加
      - apps/api/src/features/auth/login-usecase.ts
      - apps/api/src/features/auth/route.ts

   2. test(auth): 認証機能のテストケース追加
      - apps/api/src/features/auth/login-usecase.spec.ts

   3. docs(api): API仕様書の更新
      - docs/api/authentication.md

   4. chore(deps): 認証ライブラリの追加
      - package.json
      - pnpm-lock.yaml

   approval capability で、この計画・対象 path・外向き影響を提示して明示承認を得る。Claude adapter は
   `AskUserQuestion` を使う。Codex 非対話では user が TTY で `agent-workflow approve <run-id> commit` を
   実行するまで `waiting-for-user` として停止する。
   ```

4. ブランチの検証：

   pr-workflow からは Phase 0.5 で作成済みの linked worktree / branch を使う。main worktree の branch 作成・
   checkout はこの skill の責務外であり、Codex sandbox 内で実行しない。run state と実際の branch が一致しなければ
   `blocked` とする。

5. 論理的なコミット単位で変更をステージング＆コミット：

   ステップ3でユーザーの承認を得た後、各コミットごとに：

   - 関連するファイルをグループ化
   - 適切なコミットメッセージを生成
   - コミット実行

   Codex は message file を linked worktree 内に作り、次の固定 action を使う:

   ```bash
   agent-workflow commit <run-id> --message-file <message-file> -- <related-file>...
   ```

   runner は worktree・recorded branch・path containment・承認済み gate を検証する。Claude adapter の直接実行も
   同じ approval contract を満たす必要がある。

6. コミット作成の原則：

   - 1 コミット 1 目的（単一責任の原則）
   - 依存関係を考慮した順序
   - ビルドが壊れないように注意
   - 各コミット後にテストが通ることを確認（可能な場合）

7. コミット分割の例：

   - **新機能追加**: feat(module): 機能名
   - **バグ修正**: fix(module): 修正内容
   - **ドキュメント**: docs(module): 更新内容
   - **リファクタリング**: refactor(module): リファクタリング内容
   - **テスト追加**: test(module): テスト内容
   - **設定変更**: chore(config): 設定変更内容

8. 実行前の確認：

   - 重要な変更がある場合は、コミット計画をユーザーに提示
   - approval capability でユーザーの承認を得てから実行する

重要事項：

- git 設定は変更しない
- 対話的なコマンドは使用しない（-i フラグ、add -p 等）
- 空のコミットは作成しない
- 関係ないファイルは含めない
- コミットメッセージは Conventional Commits に従う
- 機密情報が含まれていないか確認する
- コミットメッセージは必ず日本語で生成すること
