# sdd: Phase 5（コミット & PR）と Phase 6（完了報告）

**Phase 5 に入る前にこのファイルを Read する。**

**この 2 Phase も spec compiler の所有物ではない。** commit の規約（Conventional Commits・日本語
メッセージ・1 コミット 1 目的）は `commit/SKILL.md` が、PR 下書きの生成・テンプレート適用・
`gh pr create` の形と下書きファイルの後処理は `create-pr/SKILL.md` が SSOT。以下はその規約を
**`sdd` の自律実行文脈（承認ゲートを挟まない）で適用する手順**であり、規約そのものを上書きしない。
規約に変更が要るときは各 skill 側を直すこと。

- **`/commit` / `/create-pr` を skill として起動しない。** どちらも user 承認ゲートを持ち、
  `sdd` の「Phase 0-4 以降は止まらない」契約（`SKILL.md`「重要な注意事項」#1）と、`pr-workflow` の
  承認点インベントリ（standard/large path では commit/PR の確認が発生しない）に反するため。
  参照するのは**規約**であって起動経路ではない。

## Phase 5: コミット & PR

### 5-1. ブランチ作成

**Phase 0-4 で「ワークツリーを作成」を選択した場合は、ブランチが既に作成済みのためこのステップをスキップする。**

それ以外の場合:

```bash
CURRENT=$(git branch --show-current)
# ベースブランチ（main/master）にいる場合のみ新しいブランチを作成
if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  # Issue番号がある場合: claude/{issue-number}/{spec-name}
  # ない場合: claude/{spec-name}
  git checkout -b {branch-name}
fi
```

### 5-2. 変更内容の分析とコミット計画

1. `git status` で未追跡ファイルと変更を確認
2. `git diff` と `git diff --cached` で変更内容を詳細確認
3. 変更ファイルをグループ化（機能・モジュール・変更タイプ別）
4. 各グループの変更性質を特定（feat, fix, docs, chore, refactor, test 等）
5. 依存関係を考慮した適切なコミット順序を決定

### 5-3. 論理的な粒度でコミット

各コミット:

```bash
git add {関連ファイル}
git commit -m "$(cat <<'EOF'
{type}({scope}): {簡潔な説明}

- {詳細な変更内容1}
- {詳細な変更内容2}
EOF
)"
```

**コミットの原則:**
- 1コミット1目的（単一責任の原則）
- Conventional Commits 形式
- コミットメッセージは**日本語**で記述
- 機密情報（.env, credentials 等）が含まれていないか確認
- ビルドが壊れないコミット順序

### 5-4. リモートにプッシュ

```bash
git push -u origin {branch-name}
```

### 5-5. PR作成

1. **PR テンプレートの読み込み**:
   `.github/PULL_REQUEST_TEMPLATE.md` が存在すれば読み込み、テンプレートに従う

2. **PR 下書きファイルの保存**:
   ```bash
   mkdir -p .claude/pull-requests/drafts/{branchName}
   ```
   `.claude/pull-requests/drafts/{branchName}/{timestamp}.md` に保存（timestamp は `YYYYMMDD-HHMMSS` 形式）

3. **PR 作成**:
   ```bash
   gh pr create \
     --draft \
     --title "{type}: {簡潔なタイトル}" \
     --body-file .claude/pull-requests/drafts/{branchName}/{timestamp}.md \
     --base "{base-branch}" \
     --head "{branch-name}" \
     --assignee "@me"
   ```

4. **後処理**:
   - PR 番号を取得
   - 下書きファイルをリネーム: `.claude/pull-requests/drafts/{branchName}/{timestamp}.md` → `.claude/pull-requests/{prNumber}.md`
   - 空になったブランチディレクトリを削除

### 5-6. Issue 紐付け

Issue 番号がある場合、PR 本文に `closes #{issue-number}` を含める。

---

## Phase 6: 完了報告

### 6-1. ユーザー通知

```bash
notify
```

### 6-2. 最終レポート

以下の形式でユーザーに報告:

```markdown
## SDD 完了レポート: {spec-name}

### 成果物
- 要件定義: .spec-workflow/specs/{spec-name}/requirements.md
- 設計書: .spec-workflow/specs/{spec-name}/design.md
- タスク一覧: .spec-workflow/specs/{spec-name}/tasks.md

### Git
- ブランチ: {branch-name}
- PR: {pr-url}
- コミット:
  - {commit-hash1} {commit-message1}
  - {commit-hash2} {commit-message2}
  - ...
```
