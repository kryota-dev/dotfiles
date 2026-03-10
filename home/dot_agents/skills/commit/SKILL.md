---
name: commit
description: 現在の差分を分析し、適切なブランチを作成して論理的な粒度でコミットを作成する
argument-hint: "[branch-name]"
disable-model-invocation: true
---

現在の差分を分析し、適切なブランチを作成して論理的な粒度でコミットを作成します。

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

   `AskUserQuestion`ツールを使用して、この計画でコミットを作成してよいかユーザーに確認を取ること。

   AskUserQuestionパラメータ:
   - question: "上記のコミット計画で作成してよろしいですか？"
   - header: "Commit"
   - options:
     - { label: "はい", description: "この計画でコミットを作成する" }
     - { label: "修正が必要", description: "計画の調整が必要な箇所を伝える" }
   - multiSelect: false
   ```

4. ブランチ作成（main ブランチでない場合のみ）：

   ```bash
   # 現在のブランチがmainの場合、新しいブランチを作成
   if [ "$(git branch --show-current)" = "main" ]; then
     # ブランチ名の提案（引数があればそれを使用、なければ変更内容から生成）
     branch_name="${ARGUMENTS:-feat/auto-generated-branch-name}"

     # ブランチ作成とチェックアウト
     git checkout -b "$branch_name"
   fi
   ```

5. 論理的なコミット単位で変更をステージング＆コミット：

   ステップ3でユーザーの承認を得た後、各コミットごとに：

   - 関連するファイルをグループ化
   - 適切なコミットメッセージを生成
   - コミット実行

   ```bash
   # 例: 機能追加のコミット
   git add [関連ファイル]
   git commit -m "$(cat <<'EOF'
   feat(scope): 簡潔な説明

   - 詳細な変更内容1
   - 詳細な変更内容2
   - 詳細な変更内容3
   EOF
   )"
   ```

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
   - `AskUserQuestion`ツールを使用してユーザーの承認を得てから実行（ステップ3と同様のパラメータを使用）

重要事項：

- git 設定は変更しない
- 対話的なコマンドは使用しない（-i フラグ、add -p 等）
- 空のコミットは作成しない
- 関係ないファイルは含めない
- コミットメッセージは Conventional Commits に従う
- 機密情報が含まれていないか確認する
- コミットメッセージは必ず日本語で生成すること
