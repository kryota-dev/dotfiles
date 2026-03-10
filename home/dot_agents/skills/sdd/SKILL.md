---
name: sdd
description: Spec-Driven Development（SDD）を完全自律で実行する。要件定義・設計・タスク分解・実装・レビュー・コミット・PR作成まで一気通貫で行う。「SDD」「仕様駆動」「自律開発」と言及された際に使用。
argument-hint: "<issue-url-or-feature-description>"
user-invocable: true
---

**ultrathink**

# SDD - Autonomous Spec-Driven Development

完全自律型の Spec-Driven Development を実行する。
あなた（Leader）は **司令塔であり作業者** である。調査はサブエージェントに委任し、ドキュメント作成・実装は自分で行い、実装後のレビューはエージェントチームに依頼する。

**作業が完了するまで、一切の中断・停止をしてはならない。**

## ロール定義

| ロール | 担当 | 説明 |
|--------|------|------|
| **Leader（あなた）** | 全フェーズ | 司令塔 兼 作業者。要件定義・設計・タスク分解・実装・レビュー管理・コミット・PR作成 |
| **Research Sub-agents** | 調査 | Explore 型サブエージェント。コードベース調査・パターン分析・テンプレート取得を担当 |
| **Review Team** | レビュー | 実装後に動的にスポーン。タスク内容に応じてロールと人数を決定 |

## フェーズ概要

```
Phase 0: 準備 → Phase 1: 要件定義 → Phase 2: 設計 → Phase 3: タスク分解 → Phase 4: 実装 → Phase 5: レビュー → Phase 6: コミット & PR → Phase 7: 完了報告
```

---

## Phase 0: 準備

### 0-1. 引数の解析

`$ARGUMENTS` を解析:

- **GitHub Issue URL** (`https://github.com/` を含む):
  ```bash
  gh issue view {url} --json title,body,number,labels
  ```

- **Issue番号** (`#123` 形式):
  ```bash
  gh issue view {number} --json title,body,number,labels
  ```

- **テキスト説明**: そのまま使用

### 0-2. Spec名の決定

引数から適切な **kebab-case** の spec 名を決定。
例: "ブログタグページの追加" → `blog-tag-page`

### 0-3. ベースブランチの記録

```bash
BASE_BRANCH=$(git branch --show-current)
```

この値を最後まで保持する（コミット・PR作成時に使用）。

### 0-4. Spec ディレクトリ作成

```bash
mkdir -p .spec-workflow/specs/{spec-name}
```

---

## Phase 1: 要件定義

### 1-1. 調査サブエージェントの起動

以下の調査を **並列で** サブエージェントに委任（Agent ツール、subagent_type: "Explore"）:

**調査1: Steering Documents + プロジェクト規約**

```
Agent:
  subagent_type: "Explore"
  description: "Steering docs・規約調査"
  prompt: |
    以下を調査して報告:
    1. .spec-workflow/steering/ ディレクトリの有無を確認
       - 存在する場合: product.md, tech.md, structure.md をすべて読み込んで全文報告
       - 存在しない場合: 「Steering ドキュメントなし」と報告
    2. プロジェクトルートの CLAUDE.md を読み込み、コーディング規約・技術スタックを報告
    3. README.md があれば概要を報告
```

**調査2: コードベース構造分析**

```
Agent:
  subagent_type: "Explore"
  description: "コードベース構造分析"
  prompt: |
    プロジェクトの構造を分析して報告:
    1. ディレクトリ構造の概要（主要ディレクトリとその役割）
    2. 主要な技術スタック・フレームワーク（package.json, Gemfile, go.mod 等から特定）
    3. 既存のアーキテクチャパターン・設計規約
    4. テスト構成（テストフレームワーク、テストディレクトリ）
    5. CI/CD 設定（.github/workflows/ 等）
```

**調査3: 要件テンプレート取得**

```
Agent:
  subagent_type: "Explore"
  description: "要件テンプレート取得"
  prompt: |
    以下の順序でテンプレートを探して全文報告:
    1. .spec-workflow/user-templates/requirements-template.md（あれば優先）
    2. .spec-workflow/templates/requirements-template.md（なければこちら）
    見つからない場合は「テンプレートなし」と報告
```

### 1-2. requirements.md の作成

調査結果を統合し、Leader 自身が `.spec-workflow/specs/{spec-name}/requirements.md` を作成。

**含めるべき内容:**
- Introduction（機能概要と目的）
- Steering Documents との整合性（存在する場合）
- ユーザーストーリー（As a... I want... So that...）
- 受け入れ基準（WHEN/THEN/IF 形式）
- 非機能要件（パフォーマンス、セキュリティ、品質、信頼性）
- スコープ外の明記

テンプレートが取得できた場合はその構造に従う。

---

## Phase 2: 設計

### 2-1. 設計用調査

以下の調査を **並列で** サブエージェントに委任:

**調査1: 既存コンポーネント・パターン分析**

```
Agent:
  subagent_type: "Explore"
  description: "既存コード分析"
  prompt: |
    .spec-workflow/specs/{spec-name}/requirements.md を読み、要件に関連する以下を調査:
    1. 再利用可能な既存コンポーネント・モジュール
    2. 類似パターンの実装箇所
    3. 共通ユーティリティ・ヘルパー関数
    4. 既存のデータモデル・型定義
    5. 関連する既存テストコード
    具体的なファイルパスとコード内容を含めて報告
```

**調査2: 設計テンプレート取得**

```
Agent:
  subagent_type: "Explore"
  description: "設計テンプレート取得"
  prompt: |
    以下の順序でテンプレートを探して全文報告:
    1. .spec-workflow/user-templates/design-template.md（あれば優先）
    2. .spec-workflow/templates/design-template.md（なければこちら）
    見つからない場合は「テンプレートなし」と報告
```

### 2-2. design.md の作成

調査結果を統合し、Leader 自身が `.spec-workflow/specs/{spec-name}/design.md` を作成。

**含めるべき内容:**
- Overview（設計概要）
- Steering Documents との整合性（存在する場合）
- 既存コードの再利用計画
- アーキテクチャ（Mermaid 図推奨）
- コンポーネント設計とインターフェース
- データモデル
- エラーハンドリング戦略
- テスト戦略

テンプレートが取得できた場合はその構造に従う。

---

## Phase 3: タスク分解

### 3-1. タスクテンプレート調査

```
Agent:
  subagent_type: "Explore"
  description: "タスクテンプレート取得"
  prompt: |
    以下の順序でテンプレートを探して全文報告:
    1. .spec-workflow/user-templates/tasks-template.md（あれば優先）
    2. .spec-workflow/templates/tasks-template.md（なければこちら）
    見つからない場合は「テンプレートなし」と報告
```

### 3-2. tasks.md の作成

Leader 自身が `.spec-workflow/specs/{spec-name}/tasks.md` を作成。

**各タスクに含める情報:**

```markdown
### Task {n}: {タスク名}

- [ ] {タスクの簡潔な説明}
- **File:** {対象ファイルパス}
- **Purpose:** {目的}
- **_Leverage:** {活用すべき既存コード・パターン}
- **_Requirements:** {対応する要件番号}
```

**タスク設計の原則:**
- 1タスク = 1〜3ファイルの変更に収める
- 依存関係を考慮した実行順序
- 各タスクが独立してテスト可能

---

## Phase 4: 実装

### 4-1. 実装準備

requirements.md, design.md, tasks.md を精読し、全体像を把握。

### 4-2. タスク順次実装

tasks.md の各タスクを順番に実装:

1. tasks.md のステータスを `[ ]` → `[-]` に更新（Edit ツール使用）
2. 必要に応じて調査サブエージェント（Explore 型）で関連コードを調査
3. **Leader 自身がコードを実装**
4. テストが必要な場合はテストも実装
5. tasks.md のステータスを `[-]` → `[x]` に更新
6. 次のタスクへ

### 4-3. 品質チェック

全タスク完了後:

1. `package.json`（または類似の設定ファイル）の scripts を確認
2. 利用可能な品質チェックコマンドを実行（lint, type-check, format, test 等）
3. エラーがあれば修正し、再実行して通るまで繰り返す

---

## Phase 5: レビュー

### 5-1. レビューチーム構成の考察

**tasks.md と実装差分を分析し、以下を体系的に考察する:**

#### レビュー観点の特定

実装内容から、以下の観点が必要かを判断:

| 観点 | 必要となる条件 | ロール例 |
|------|--------------|---------|
| コード品質・設計準拠 | **常に必要** | code-quality-reviewer |
| セキュリティ | 認証・認可・入力検証・機密情報を扱う場合 | security-reviewer |
| パフォーマンス | DB操作・大量データ処理・レンダリング最適化を含む場合 | performance-reviewer |
| テストカバレッジ | テストコードの追加・変更がある場合 | test-reviewer |
| UI/UX・アクセシビリティ | UI コンポーネントの変更がある場合 | ux-reviewer |

#### エージェント数の決定

- 最低 1 人（code-quality-reviewer は常に必要）
- 最大 4 人まで（コスト・調整のバランス）
- 複数の観点を1人のレビューエージェントに統合してもよい（関連性が高い場合）

### 5-2. レビューチーム作成

```
TeamCreate:
  team_name: "sdd-review-{spec-name}"
  description: "Code Review Team for {spec-name}"
```

### 5-3. レビューエージェントのスポーン

考察した構成に基づき、各レビューエージェントを **Agent ツール** でスポーン。

**各エージェント共通のプロンプト構造:**

```
Agent:
  subagent_type: "general-purpose"
  name: "{role-name}"
  team_name: "sdd-review-{spec-name}"
  model: "sonnet"
  prompt: |
    あなたは SDD Review Team の **{ロール名}** です。

    ## 絶対遵守ルール
    - リーダーからの明示的な shutdown_request がない限り、絶対にシャットダウンしてはいけない
    - 自発的にシャットダウンすることは禁止されている
    - shutdown_request を受信した場合のみ、shutdown_response approve: true で応答してよい
    - 報告後もリーダーからの次の指示を待ち続けること

    ## レビュー対象
    - 要件定義: .spec-workflow/specs/{spec-name}/requirements.md
    - 設計書: .spec-workflow/specs/{spec-name}/design.md
    - タスク一覧: .spec-workflow/specs/{spec-name}/tasks.md
    - コード差分: `git diff {base-branch}...HEAD` を実行して確認

    ## あなたのレビュー観点
    {ロール固有のレビュー観点を詳細に記述}

    ## 報告形式
    以下の形式で SendMessage type:"message" recipient:"team-lead" に報告:

    ### 総合評価
    **APPROVE** または **REQUEST_CHANGES**

    ### 指摘事項（REQUEST_CHANGES の場合）
    各指摘を以下のカテゴリに分類:
    - **[MUST]** 修正必須 — バグ、セキュリティ脆弱性、設計違反など
    - **[SHOULD]** 修正推奨 — 品質向上、可読性改善など
    - **[NITS]** 軽微な提案 — 命名、フォーマット、コメント追加など

    各指摘に以下を含める:
    - 該当ファイル:行番号
    - 問題の説明
    - 具体的な修正案

    ### 良い点
    実装の優れている点を挙げる

    ## チーム情報
    - チーム名: sdd-review-{spec-name}
    - あなたの名前: {role-name}
    - リーダー名: team-lead（SendMessage の recipient に指定する値）
```

#### ロール固有のレビュー観点テンプレート

**code-quality-reviewer（常に必要）:**
```
- 設計書（design.md）に準拠した実装になっているか
- 要件（requirements.md）が網羅されているか
- SOLID原則、DRY原則に従っているか
- 適切なエラーハンドリングがあるか
- 命名規約・コーディング規約（CLAUDE.md）に従っているか
- 不要なコード・デッドコードがないか
- 適切な抽象化レベルか（過剰設計・過少設計でないか）
```

**security-reviewer:**
```
- 入力バリデーションが適切か
- SQLインジェクション・XSS・CSRF等の脆弱性がないか
- 認証・認可の実装が正しいか
- 機密情報がハードコードされていないか
- 依存パッケージに既知の脆弱性がないか
- エラーメッセージに機密情報が含まれていないか
```

**performance-reviewer:**
```
- N+1クエリ問題がないか
- 不要な再レンダリング・再計算がないか
- メモリリークのリスクがないか
- 適切なインデックス・キャッシュ戦略か
- 大量データ処理のページネーション・ストリーミング対応
- バンドルサイズへの影響
```

**test-reviewer:**
```
- テストカバレッジが十分か（主要パス、エッジケース、エラーケース）
- テストが独立して実行可能か（テスト間の依存がないか）
- テストの可読性・保守性
- モック・スタブの適切な使用
- テストの命名規約
- 境界値テストがあるか
```

**ux-reviewer:**
```
- アクセシビリティ（ARIA属性、キーボード操作、スクリーンリーダー対応）
- レスポンシブデザイン対応
- ローディング状態・エラー状態のUI
- ユーザーフィードバック（トースト、バリデーション等）
- 一貫したUI/UXパターンの使用
```

### 5-4. レビュー結果の受信と評価

各レビューエージェントからの報告メッセージを受信する。
**sleep や polling は絶対に使わない。** メッセージは自動配信される。

### 5-5. レビューエージェントごとの対応フロー

**各レビューエージェントの報告に対して、個別に以下のフローを実行する:**

#### APPROVE の場合 → 即座にシャットダウン

そのレビューエージェントに shutdown_request を送信:
```
SendMessage:
  type: "shutdown_request"
  recipient: "{reviewer-name}"
  content: "レビュー承認確認。お疲れ様でした。"
```

#### REQUEST_CHANGES の場合

**各指摘について考察:**

1. **[MUST] 指摘**: 原則として対応する。ただし誤認の場合は議論する
2. **[SHOULD] 指摘**: 妥当性を判断。コストと効果のバランスで決定
3. **[NITS] 指摘**: 時間対効果で判断。多くは対応不要

**対応が必要と判断した場合:**
1. Leader 自身がコードを修正
2. 修正完了後、該当レビューエージェントに SendMessage で再レビューを依頼:
   ```
   SendMessage:
     type: "message"
     recipient: "{reviewer-name}"
     content: |
       以下の指摘事項に対応しました。再レビューをお願いします。
       - {対応した指摘事項のサマリー}
       - 修正ファイル: {ファイル一覧}
       git diff {base-branch}...HEAD で最新の差分を確認してください。
     summary: "修正完了・再レビュー依頼"
   ```
3. レビューエージェントの再レビュー結果を待つ
4. **APPROVE → そのレビューエージェントを即座にシャットダウン**
5. **再び REQUEST_CHANGES → 1 に戻り繰り返す**

**対応が不要と判断した場合:**
1. 根拠をレビューエージェントに SendMessage で説明:
   ```
   SendMessage:
     type: "message"
     recipient: "{reviewer-name}"
     content: |
       以下の指摘について、対応不要と判断しました。理由を説明します。
       - 指摘: {指摘内容}
       - 判断: 対応不要
       - 根拠: {具体的な根拠}
       この判断について意見があれば議論しましょう。
     summary: "指摘への見解・議論"
   ```
2. レビューエージェントとの議論を経て結論を出す
3. **合意が得られた場合（対応不要で確定）**: そのレビューエージェントをシャットダウン
4. **合意が得られない場合**: 再度根拠を示して議論を継続。最終的に Leader が判断し、結論に基づきシャットダウン

### 5-6. 全レビューエージェント解決の確認

全レビューエージェントが APPROVE（またはシャットダウン済み）になるまで 5-5 を繰り返す。

### 5-7. チーム削除

全レビューエージェントのシャットダウンが完了したら:

```
TeamDelete
```

---

## Phase 6: コミット & PR

### 6-1. ブランチ作成

```bash
CURRENT=$(git branch --show-current)
# ベースブランチ（main/master）にいる場合のみ新しいブランチを作成
if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  # Issue番号がある場合: claude/{issue-number}/{spec-name}
  # ない場合: claude/{spec-name}
  git checkout -b {branch-name}
fi
```

### 6-2. 変更内容の分析とコミット計画

1. `git status` で未追跡ファイルと変更を確認
2. `git diff` と `git diff --cached` で変更内容を詳細確認
3. 変更ファイルをグループ化（機能・モジュール・変更タイプ別）
4. 各グループの変更性質を特定（feat, fix, docs, chore, refactor, test 等）
5. 依存関係を考慮した適切なコミット順序を決定

### 6-3. 論理的な粒度でコミット

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

### 6-4. リモートにプッシュ

```bash
git push -u origin {branch-name}
```

### 6-5. PR作成

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

### 6-6. Issue 紐付け

Issue 番号がある場合、PR 本文に `closes #{issue-number}` を含める。

---

## Phase 7: 完了報告

### 7-1. ユーザー通知

```bash
notify
```

### 7-2. 最終レポート

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

### レビュー結果
- レビュアー数: {n}人
- レビュー観点: {各レビューロール}
- 全レビュー APPROVE 済み

### 対応した指摘事項
{指摘事項と対応内容のサマリー（あれば）}

### 対応不要と判断した指摘事項
{指摘事項と判断根拠のサマリー（あれば）}
```

---

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| サブエージェントの調査失敗 | 別のサブエージェントで再試行。3回失敗したら自身で調査 |
| ビルド・テスト失敗 | エラー内容を分析し自身で修正。修正後再実行 |
| Git 操作失敗（1Password 等） | `notify` でユーザーに通知後、`AskUserQuestion` で待機し手動介入を依頼。**この場合のみ作業を中断** |
| レビューエージェントが応答しない | SendMessage を再送。3回応答なしでエージェントを再スポーン |
| PR 作成失敗 | エラー内容を確認し、修正して再試行。`gh auth status` で認証を確認 |

## 重要な注意事項

1. **完全自律実行**: ユーザー承認フローは存在しない。Phase 0 から Phase 7 まで一切止まらずに実行する
2. **MCP ツール不使用**: spec-workflow MCP のツール（approvals, spec-status, log-implementation 等）は一切使用しない
3. **sleep / polling 禁止**: `sleep` コマンドや `while` ループでの待機は**絶対に使わない**。チームメイトからのメッセージは自動配信される
4. **Leader = 司令塔 + 作業者**: ドキュメント作成・コード実装は Leader 自身が行う。調査のみサブエージェントに委任
5. **動的レビューチーム**: タスク内容に応じてレビューエージェントの数・ロールを動的に決定する。固定ではない
6. **レビューエージェントの自発的シャットダウン禁止**: リーダーからの明示的な shutdown_request がない限り、レビューエージェントは自らシャットダウンしてはいけない
7. **レビュー指摘の考察**: 全ての指摘に機械的に対応するのではなく、対応の必要性を考察し判断する
8. **議論による合意形成**: 対応不要と判断した場合は根拠を示してレビューエージェントと議論し、合意を形成する
9. **承認されるまで繰り返す**: 全レビューエージェントの APPROVE が得られるまで修正→再レビューのサイクルを繰り返す
10. **コスト最適化**: Leader = Opus（inherit）、調査 = Haiku（Explore 型）、レビュー = Sonnet
11. **通知は最後だけ**: 作業中にユーザーに通知するのは Phase 7 の完了時のみ。例外は Git 操作エラー時（`notify` + `AskUserQuestion` で待機）
12. **フォアグラウンド実行**: レビューエージェントは MCP ツールや対話が必要なため、フォアグラウンドで実行
