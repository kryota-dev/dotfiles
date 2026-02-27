---
name: sdd-team
description: Spec-Driven Development (SDD) をエージェントチームで自律実行する。要件定義から設計、レビュー、実装、コードレビュー、PR作成までを5人のチームで協調して行う。「SDD」「仕様駆動」「エージェントチームで開発」と言及された際に使用。
argument-hint: "<issue-url-or-feature-description>"
user-invocable: true
---

**ultrathink**

# SDD Team - Spec-Driven Development with Agent Teams

エージェントチームを使ったSpec-Driven Developmentを実行します。
あなた（Leader）は、チームを統括し、各フェーズの品質管理と承認フローを管理します。

## チーム構成

| メンバー | エージェント名 | ロール | 担当フェーズ |
|---------|-------------|--------|------------|
| **Leader** (あなた) | - | プロジェクトマネージャー。全体統括・要件レビュー・承認管理 | 全フェーズ |
| **Designer** | sdd-designer | シニアソフトウェアアーキテクト。要件分析・設計・タスク分解 | Phase 1-3 |
| **Design Reviewer** | sdd-design-reviewer | テクニカルリードアーキテクト。設計品質の検証 | Phase 2.5 |
| **Worker** | sdd-worker | フルスタック実装エンジニア。コード実装・Git操作・PR作成 | Phase 4 |
| **Work Reviewer** | sdd-work-reviewer | シニアコードレビュアー。コード品質の検証 | Phase 4.5 |

---

## Phase 0: 準備

### 0-1. 引数の解析

`$ARGUMENTS` を解析する:

- **GitHub Issue URL の場合** (`https://github.com/` を含む):
  ```bash
  gh issue view {url} --json title,body,number,labels
  ```
  Issue番号とタイトル、本文を取得

- **Issue番号の場合** (`#123` 形式):
  ```bash
  gh issue view {number} --json title,body,number,labels
  ```

- **テキスト説明の場合**: そのまま使用

### 0-2. Spec名の決定

引数から適切な **kebab-case** のspec名を決定する。
例: "ブログタグページの追加" → `blog-tag-page`

### 0-3. ベースブランチの記録

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

### 0-4. Spec ディレクトリ確認

```bash
mkdir -p .spec-workflow/specs/{spec-name}
```

### 0-5. チーム作成

```
TeamCreate:
  team_name: "sdd-{spec-name}"
  description: "SDD Team for {spec-name}"
```

### 0-6. タスクの作成

以下の6タスクを作成し、依存関係を設定:

1. **要件定義** (Phase 1) - 依存なし
2. **設計** (Phase 2) - blockedBy: [1]
3. **設計レビュー** (Phase 2.5) - blockedBy: [2]
4. **タスク分解** (Phase 3) - blockedBy: [3]
5. **実装** (Phase 4) - blockedBy: [4]
6. **コードレビュー** (Phase 4.5) - blockedBy: [5]

### 0-7. ユーザー通知

```bash
notify
```

ユーザーに「SDD Team を準備しました。{spec-name} の開発を開始します。」と報告。

---

## Phase 1: 要件定義

### 1-1. Designer をスポーン

```
Task:
  subagent_type: "sdd-designer"
  name: "designer"
  team_name: "sdd-{spec-name}"
  model: "sonnet"
  prompt: |
    あなたは SDD Team の Designer です。

    ## コンテキスト
    - Spec名: {spec-name}
    - Issue番号: {issue-number}（あれば）
    - 機能説明: {issue-body or description}
    - プロジェクトルート: {cwd}

    ## 現在のタスク
    Phase 1: requirements.md の作成

    ## 手順
    1. プロジェクトの CLAUDE.md を読んでコーディング規約と技術スタックを把握
    2. Serena MCP で既存コードベースの構造を分析
    3. テンプレートを読む: まず .spec-workflow/user-templates/requirements-template.md、なければ .spec-workflow/templates/requirements-template.md
    4. requirements.md を .spec-workflow/specs/{spec-name}/requirements.md に作成
    5. 完了後、SendMessage type:"message" recipient:"leader" で「requirements.md の作成が完了しました」と報告

    ## チーム情報
    - チーム名: sdd-{spec-name}
    - あなたの名前: designer
    - リーダー: 自動通知されます
```

### 1-2. Designer の完了報告を受信 → レビュー

Designer がタスクを完了すると、SendMessage であなた（Leader）に自動的にメッセージが届きます。
**sleep や polling は絶対に使わないこと。** メッセージは会話の次のターンとして自動配信されるため、ただ待っていれば届きます。

Designer から「requirements.md の作成が完了しました」というメッセージを受信したら、次のステップへ進みます。

### 1-3. requirements.md のレビュー（Leader が実行）

Leader 自身が `.spec-workflow/specs/{spec-name}/requirements.md` を読み、以下を確認:
- ユーザーストーリーが適切に定義されているか
- EARS形式の受け入れ基準があるか
- 非機能要件が網羅されているか
- Out of Scope が明記されているか

問題がある場合は designer に SendMessage でフィードバックを送り、修正を依頼。

### 1-4. 承認フロー

```
mcp__spec-workflow__approvals:
  action: "request"
  category: "spec"
  categoryName: "{spec-name}"
  type: "document"
  title: "Requirements: {spec-name}"
  filePath: ".spec-workflow/specs/{spec-name}/requirements.md"
```

```bash
notify
```

### 1-5. ユーザー承認待機

ダッシュボードでの承認操作を待つため、`AskUserQuestion` でユーザーに通知し待機する:

```
AskUserQuestion:
  question: "requirements.md を作成しました。ダッシュボード (http://localhost:4004) で内容を確認し、承認操作を行ってください。承認完了後、こちらで「承認した」を選択してください。"
  header: "要件定義の承認待ち"
  options:
    - label: "承認した"
      description: "ダッシュボードで承認済み。次のフェーズに進む"
    - label: "修正が必要"
      description: "修正すべき点をフィードバックする"
  multiSelect: false
```

### 1-6. 承認ステータス確認

ユーザーが「承認した」を選択した場合:
1. `mcp__spec-workflow__approvals` の `action: "status"` で承認済みを確認
2. **approved**: `action: "delete"` でクリーンアップ → Phase 2 へ
3. **まだ pending/needs-revision の場合**: 再度 AskUserQuestion で待機

ユーザーが「修正が必要」を選択した場合:
1. ユーザーのフィードバックを受け取る
2. `mcp__spec-workflow__approvals` の `action: "status"` を確認
3. needs-revision の場合はダッシュボードのコメントも読み取る
4. designer に修正指示を SendMessage で送信 → 1-3 に戻る

### 1-7. TaskUpdate

Phase 1 タスクを `completed` に更新。

---

## Phase 2: 設計

### 2-1. Designer に設計フェーズ開始を指示

```
SendMessage:
  type: "message"
  recipient: "designer"
  content: |
    Phase 2: design.md の作成を開始してください。

    ## 手順
    1. .spec-workflow/specs/{spec-name}/requirements.md を精読
    2. テンプレートを読む: まず .spec-workflow/user-templates/design-template.md、なければ .spec-workflow/templates/design-template.md
    3. Serena MCP で既存コンポーネント・ユーティリティ・パターンを分析
    4. design.md を .spec-workflow/specs/{spec-name}/design.md に作成
    5. 完了後 SendMessage で報告
  summary: "設計フェーズ開始指示"
```

### 2-2. Designer の完了報告を受信

Designer から「design.md の作成が完了しました」というメッセージが自動配信されるのを待ちます。
**sleep や polling は使わないこと。** メッセージは次のターンとして届きます。

受信したら次のステップへ進みます。

### 2-3. 承認フロー

```
mcp__spec-workflow__approvals:
  action: "request"
  category: "spec"
  categoryName: "{spec-name}"
  type: "document"
  title: "Design: {spec-name}"
  filePath: ".spec-workflow/specs/{spec-name}/design.md"
```

```bash
notify
```

### 2-4. ユーザー承認待機

```
AskUserQuestion:
  question: "design.md を作成しました。ダッシュボード (http://localhost:4004) で内容を確認し、承認操作を行ってください。承認完了後、こちらで「承認した」を選択してください。"
  header: "設計の承認待ち"
  options:
    - label: "承認した"
      description: "ダッシュボードで承認済み。設計レビューフェーズに進む"
    - label: "修正が必要"
      description: "修正すべき点をフィードバックする"
  multiSelect: false
```

### 2-5. 承認ステータス確認

ユーザーが「承認した」を選択した場合:
1. `mcp__spec-workflow__approvals` の `action: "status"` で承認済みを確認
2. **approved**: `action: "delete"` でクリーンアップ → Phase 2.5 へ
3. **まだ pending/needs-revision の場合**: 再度 AskUserQuestion で待機

ユーザーが「修正が必要」を選択した場合:
1. ユーザーのフィードバックを受け取る
2. `mcp__spec-workflow__approvals` の `action: "status"` を確認
3. designer に修正指示を SendMessage で送信 → 2-1 に戻る

### 2-6. TaskUpdate: Phase 2 タスクを `completed` に更新

---

## Phase 2.5: 設計レビュー

### 2.5-1. Design Reviewer をスポーン

```
Task:
  subagent_type: "sdd-design-reviewer"
  name: "design-reviewer"
  team_name: "sdd-{spec-name}"
  model: "sonnet"
  prompt: |
    あなたは SDD Team の Design Reviewer です。

    ## コンテキスト
    - Spec名: {spec-name}
    - プロジェクトルート: {cwd}

    ## レビュー対象
    - 要件: .spec-workflow/specs/{spec-name}/requirements.md
    - 設計: .spec-workflow/specs/{spec-name}/design.md

    ## タスク
    1. requirements.md と design.md を読み込む
    2. Serena MCP でコードベースを検証
    3. レビュー結果を .spec-workflow/specs/{spec-name}/design-review.md に出力
    4. SendMessage type:"message" recipient:"leader" で総合評価と概要を報告

    ## チーム情報
    - チーム名: sdd-{spec-name}
    - あなたの名前: design-reviewer
```

### 2.5-2. Design Reviewer の結果報告を受信

Design Reviewer から総合評価と概要を含むメッセージが自動配信されます。
**sleep や polling は使わないこと。** 受信したら次のステップへ進みます。

### 2.5-3. レビュー結果の処理

レビュー結果を確認し、AskUserQuestion でユーザーに提示:

```
AskUserQuestion:
  question: "設計レビューが完了しました。{総合評価}です。{[must]項目の概要}。どうしますか？"
  header: "設計レビュー"
  options:
    - label: "設計を承認"
      description: "設計に問題なし。タスク分解フェーズに進む"
    - label: "Designerに修正を依頼"
      description: "レビュー指摘に基づいて設計を修正する"
```

- **設計を承認**: Phase 3 へ
- **修正を依頼**: designer にレビューフィードバックを SendMessage → Phase 2 の design.md 修正を再実行

### 2.5-4. Design Reviewer のシャットダウン

```
SendMessage:
  type: "shutdown_request"
  recipient: "design-reviewer"
  content: "設計レビュー完了。お疲れ様でした。"
```

### 2.5-5. TaskUpdate: Phase 2.5 タスクを `completed` に更新

---

## Phase 3: タスク分解

### 3-1. Designer にタスクフェーズ開始を指示

```
SendMessage:
  type: "message"
  recipient: "designer"
  content: |
    Phase 3: tasks.md の作成を開始してください。

    ## 手順
    1. requirements.md と design.md を精読
    2. テンプレートを読む: まず .spec-workflow/user-templates/tasks-template.md、なければ .spec-workflow/templates/tasks-template.md
    3. tasks.md を .spec-workflow/specs/{spec-name}/tasks.md に作成
       - 各タスクに _Prompt フィールド（実装者への詳細指示）を含める
       - _Leverage で活用すべき既存コードを明記
       - _Requirements で対応する要件番号を参照
    4. 完了後 SendMessage で報告
  summary: "タスク分解フェーズ開始指示"
```

### 3-2. Designer の完了報告を受信

Designer から「tasks.md の作成が完了しました」というメッセージが自動配信されます。
**sleep や polling は使わないこと。** 受信したら次のステップへ進みます。

### 3-3. 承認フロー

```
mcp__spec-workflow__approvals:
  action: "request"
  category: "spec"
  categoryName: "{spec-name}"
  type: "document"
  title: "Tasks: {spec-name}"
  filePath: ".spec-workflow/specs/{spec-name}/tasks.md"
```

```bash
notify
```

### 3-4. ユーザー承認待機

```
AskUserQuestion:
  question: "tasks.md を作成しました。ダッシュボード (http://localhost:4004) で内容を確認し、承認操作を行ってください。承認完了後、こちらで「承認した」を選択してください。"
  header: "タスクの承認待ち"
  options:
    - label: "承認した"
      description: "ダッシュボードで承認済み。実装フェーズに進む"
    - label: "修正が必要"
      description: "修正すべき点をフィードバックする"
  multiSelect: false
```

### 3-5. 承認ステータス確認

ユーザーが「承認した」を選択した場合:
1. `mcp__spec-workflow__approvals` の `action: "status"` で承認済みを確認
2. **approved**: `action: "delete"` でクリーンアップ → Phase 4 へ
3. **まだ pending/needs-revision の場合**: 再度 AskUserQuestion で待機

ユーザーが「修正が必要」を選択した場合:
1. ユーザーのフィードバックを受け取る
2. `mcp__spec-workflow__approvals` の `action: "status"` を確認
3. designer に修正指示を SendMessage で送信 → 3-1 に戻る

### 3-6. Designer のシャットダウン

```
SendMessage:
  type: "shutdown_request"
  recipient: "designer"
  content: "全ドキュメント作成完了。お疲れ様でした。"
```

### 3-7. TaskUpdate: Phase 3 タスクを `completed` に更新

```bash
notify
```
ユーザーに「Spec 完了。実装フェーズの準備ができました。」と報告。

---

## Phase 4: 実装

### 4-1. Worker をスポーン

```
Task:
  subagent_type: "sdd-worker"
  name: "worker"
  team_name: "sdd-{spec-name}"
  model: "sonnet"
  prompt: |
    あなたは SDD Team の Worker です。

    ## コンテキスト
    - Spec名: {spec-name}
    - Issue番号: {issue-number}（あれば）
    - ベースブランチ: {base-branch}
    - プロジェクトルート: {cwd}

    ## ブランチ命名規則
    claude/{issue-number}/{spec-name}
    （Issue番号がない場合: claude/{spec-name}）

    ## タスク
    1. プロジェクトの CLAUDE.md を読んでコーディング規約を把握
    2. .spec-workflow/specs/{spec-name}/tasks.md を読む
    3. .spec-workflow/specs/{spec-name}/design.md を読む
    4. .spec-workflow/specs/{spec-name}/requirements.md を読む
    5. ブランチを作成: git checkout -b claude/{issue-number}/{spec-name}
    6. tasks.md の各タスクを順番に実装
       - 各タスクの _Prompt フィールドに従う
       - tasks.md のステータスを更新 ([ ] → [-] → [x])
       - pnpm quality:check && pnpm test を各タスク後に実行
    7. 適切な粒度でコミット（Conventional Commits、日本語）
    8. 全タスク完了後: pnpm build:next で静的ビルド確認
    9. git push -u origin claude/{issue-number}/{spec-name}
    10. gh pr create --draft で PR 作成
        - .github/PULL_REQUEST_TEMPLATE.md を読み込んでテンプレートに従う
        - Issue番号がある場合は "closes #{issue-number}" を含める
    11. SendMessage type:"message" recipient:"leader" で完了報告（PR URL含む）

    ## チーム情報
    - チーム名: sdd-{spec-name}
    - あなたの名前: worker
```

### 4-2. Worker の完了報告を受信

Worker から完了タスク一覧、コミット一覧、PR URL、テスト結果を含むメッセージが自動配信されます。
**sleep や polling は使わないこと。** 受信したら次のステップへ進みます。

### 4-3. Implementation Log の記録

Worker の報告内容に基づき、Leader が `mcp__spec-workflow__log-implementation` を使用して実装ログを記録。

### 4-4. TaskUpdate: Phase 4 タスクを `completed` に更新

```bash
notify
```
ユーザーに「実装が完了しました。コードレビューを開始します。」と報告。

---

## Phase 4.5: コードレビュー

### 4.5-1. Work Reviewer をスポーン

```
Task:
  subagent_type: "sdd-work-reviewer"
  name: "work-reviewer"
  team_name: "sdd-{spec-name}"
  model: "sonnet"
  prompt: |
    あなたは SDD Team の Work Reviewer です。

    ## コンテキスト
    - Spec名: {spec-name}
    - プロジェクトルート: {cwd}
    - ベースブランチ: {base-branch}

    ## レビュー対象
    - 要件: .spec-workflow/specs/{spec-name}/requirements.md
    - 設計: .spec-workflow/specs/{spec-name}/design.md
    - タスク: .spec-workflow/specs/{spec-name}/tasks.md
    - コード差分: git diff {base-branch}...HEAD

    ## タスク
    1. 上記ドキュメントを読み込み
    2. git diff で変更差分を確認
    3. Serena MCP でコード品質を検証
    4. pnpm quality:check && pnpm test を実行
    5. レビュー結果を .spec-workflow/specs/{spec-name}/code-review.md に出力
    6. SendMessage type:"message" recipient:"leader" で総合評価と概要を報告

    ## チーム情報
    - チーム名: sdd-{spec-name}
    - あなたの名前: work-reviewer
```

### 4.5-2. Work Reviewer の結果報告を受信

Work Reviewer から総合評価と概要を含むメッセージが自動配信されます。
**sleep や polling は使わないこと。** 受信したら次のステップへ進みます。

### 4.5-3. レビュー結果の処理

レビュー結果を確認し、AskUserQuestion でユーザーに提示:

```
AskUserQuestion:
  question: "コードレビューが完了しました。{総合評価}です。{[must]項目があれば概要}。どうしますか？"
  header: "コードレビュー"
  options:
    - label: "承認・完了"
      description: "コードに問題なし。SDDプロセスを完了する"
    - label: "Workerに修正を依頼"
      description: "レビュー指摘に基づいてコードを修正する"
```

- **承認・完了**: Phase 5 (クリーンアップ) へ
- **修正を依頼**: worker にレビューフィードバックを SendMessage → Worker が修正 → 再レビュー

### 4.5-4. TaskUpdate: Phase 4.5 タスクを `completed` に更新

---

## Phase 5: クリーンアップ

### 5-1. 全メンバーをシャットダウン

```
SendMessage type: "shutdown_request" → "work-reviewer"
SendMessage type: "shutdown_request" → "worker"
```

各メンバーから `shutdown_response` が自動配信されます。全員の応答を受信してから次へ進みます。

### 5-2. チーム削除

```
TeamDelete
```

### 5-3. 最終通知

```bash
notify
```

### 5-4. 最終レポート

ユーザーに以下を報告:

```
## SDD 完了レポート: {spec-name}

### 成果物
- 要件定義: .spec-workflow/specs/{spec-name}/requirements.md
- 設計書: .spec-workflow/specs/{spec-name}/design.md
- タスク一覧: .spec-workflow/specs/{spec-name}/tasks.md
- 設計レビュー: .spec-workflow/specs/{spec-name}/design-review.md
- コードレビュー: .spec-workflow/specs/{spec-name}/code-review.md

### Git
- ブランチ: claude/{issue-number}/{spec-name}
- PR: {pr-url} (Draft)

### 次のアクション
1. Draft PR の内容を確認
2. 必要に応じて追加修正
3. PR を Ready for Review に変更
```

---

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| エージェントがドキュメント作成に失敗 | SendMessage で具体的なエラー内容と再試行指示を送信。3回失敗で `notify` + ユーザーに報告 |
| spec-workflow approvals が needs-revision | ユーザーのコメントを読み取り、該当エージェントに修正指示を送信 |
| approvals delete 失敗 | 再度 `action: "status"` で確認 → 再delete。5回失敗で `notify` + ユーザーに報告 |
| Worker のビルド/テスト失敗 | Worker がエラー内容を報告 → Leader がフィードバックを返して再試行 |
| Git 操作失敗（1Password等） | `notify` でユーザーに通知し、手動介入を依頼。作業を中断 |
| MCP 接続エラー | `notify` でユーザーに通知し、MCP再起動を依頼 |

## 重要な注意事項

1. **sleep / polling 禁止**: `sleep` コマンドや `while` ループでの待機は**絶対に使わないこと**。チームメイトからのメッセージは SendMessage により会話の次のターンとして自動配信される。メンバーをスポーンしたら、メッセージが届くまでただ待機すればよい
2. **メッセージベース通信**: メンバーとの連携は全て SendMessage で行う。メンバーが idle 状態になるのは正常動作であり、SendMessage を送れば再開する
3. **Leader は管理に専念**: 自分でタスクを実装せず、メンバーからの報告メッセージを受信して次のアクションを判断する
4. **フォアグラウンド実行**: バックグラウンドではMCPツールが使えないため、全メンバーをフォアグラウンドで実行
5. **逐次実行**: 各フェーズは依存関係があるため並列実行しない（Designer → Design Reviewer → Worker → Work Reviewer）
6. **Designer の再利用**: Phase 1-3 は同一 Designer インスタンスで実行（コンテキスト保持のため）
7. **コスト最適化**: Leader=Opus（inherit）、全メンバー=Sonnet。不要なメンバーは即シャットダウン
8. **通知タイミング**: 承認待ち、レビュー完了、エラー発生時に `notify` を実行
