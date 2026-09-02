---
name: sdd
description: pr-workflow の standard/large tier から呼ばれる内部コンポーネント。Spec-Driven Development（要件定義・設計・タスク分解・実装・コミット・PR作成）を完全自律で実行し、PR 作成で完了する。レビューは pr-workflow の PR 作成後パイプライン（monitor-ci → multi-review → review-resolve-loop）に一本化されているため sdd 自身はレビューを行わない。単体起動はせず pr-workflow 経由でのみ実行する。
argument-hint: "[--prd <path>] [--plan <path>] <issue-url-or-feature-description>"
user-invocable: false
---

**ultrathink**

# SDD - Autonomous Spec-Driven Development

完全自律型の Spec-Driven Development を実行する。
あなた（Leader）は **司令塔であり作業者** である。調査はサブエージェントに委任し、ドキュメント作成・実装は自分で行う。実装後のレビューは行わない（レビューは pr-workflow の PR 作成後パイプラインが担う）。

**作業が完了するまで、一切の中断・停止をしてはならない。**

## この SKILL.md の責務（spec compiler）

**この SKILL.md が持つのは spec の compile —— 要件定義（`requirements.md`）・設計（`design.md`）・
タスク分解（`tasks.md`）の生成 —— と、その前段の gate / 準備だけ。** 実装・コミット・PR 作成は
compiler の所有物ではなく、`references/` の手順が呼び出し元の契約へ橋渡しする。

**縮退で規範を削ってはいない**（記述は移しただけで、どれも省略可能になっていない）。
**Phase 4 に入る前に [`references/implementation.md`](references/implementation.md) を、
Phase 5 に入る前に [`references/delivery.md`](references/delivery.md) を Read すること。**

| ファイル | 内容 | 責務の所有者 |
|---|---|---|
| `SKILL.md`（本ファイル） | Phase 0〜3（gate・準備・要件・設計・タスク分解） | `sdd`（spec compiler） |
| [`references/implementation.md`](references/implementation.md) | Phase 4（実装と品質チェック） | worker 委譲契約は `pr-workflow` / `codex` が SSOT |
| [`references/delivery.md`](references/delivery.md) | Phase 5（コミット & PR）・Phase 6（完了報告） | 規約は `commit` / `create-pr` が SSOT |

## ロール定義

| ロール | 担当 | 説明 |
|--------|------|------|
| **Leader（あなた）** | 全フェーズ | 司令塔 兼 作業者。要件定義・設計・タスク分解・実装・コミット・PR作成 |
| **Research Sub-agents** | 調査 | Explore 型サブエージェント。コードベース調査・パターン分析・テンプレート取得を担当 |

## フェーズ概要

```
Phase 0: 準備 → Phase 1: 要件定義 → Phase 2: 設計 → Phase 3: タスク分解 → Phase 4: 実装 → Phase 5: コミット & PR → Phase 6: 完了報告
```

---

## Phase 0: 準備

**Phase 0 冒頭で（遅くとも Phase 1 の spec 執筆より前に）`/execution-readiness-check <task context>` と `/model-fitness-check orchestration`（large / PRD 審議相当なら `large`）を両方起動する**。前者は adapter capability、account scope、rollout、permission manifest、risk を確認し、後者はセッション自身の model / effort floor を判定する（blocking）。**行種別も要求される model / effort 値もここに書かない**（テーブルと行種別判定はいずれも `/model-fitness-check` が唯一の SSOT）。2 つは直交する gate であり、片方で他方を代替しない。

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

#### Plan-PRD pipeline flag（任意 / opt-in, task #22）

以下の flag は **任意**。**未指定時は現状動作（`$ARGUMENTS` からの spec 起こし）を完全に維持する**。

| flag | 意味 |
|------|------|
| `--prd <path>` | `/grill-me --output-prd` 由来の PRD file を読み込み、Phase 1（要件定義）の入力 context にする（Acceptance Criteria を要件の起点に） |
| `--plan <path>` | `/planning --output-plan` 由来の Plan file を読み込み、Phase 2（設計）・Phase 3（タスク分解）の入力 context にする |

- 渡された file は Phase 0 で読み込み、以降の各 Phase に input として引き渡す（spec 名は PRD frontmatter の `slug` を優先採用）。
- 指定された file が**存在しない場合は error**にして、user に `/grill-me --output-prd` / `/planning --output-plan` での先行生成を案内する（PRD/Plan を捏造しない）。

### 0-2. Spec名の決定

`--prd` flag が指定されている場合は、読み込んだ PRD frontmatter の `slug` 値を spec 名として使用する（捏造しない）。それ以外の場合は、引数から適切な **kebab-case** の spec 名を決定。
例: "ブログタグページの追加" → `blog-tag-page`

### 0-3. ベースブランチの記録

```bash
BASE_BRANCH=$(git branch --show-current)
```

この値を最後まで保持する（コミット・PR作成時に使用）。

### 0-4. ワークツリー戦略の選択

**ワークツリーの provisioning は spec compiler の所有物ではない。** `pr-workflow` から呼ばれる
既定経路では Phase 0.5 で `/wtp` により作成済みで、委譲プロンプトが**新規作成の抑止**を明示的に
オーバーライドする。その場合は本節をスキップし、現在のワークツリーで作業する。ワークツリー操作
そのものの SSOT は `wtp` skill。

以下は**呼び出し元がワークツリーを用意しなかった場合のフォールバック**である。この場合は
**SDD の本格着手前に、`AskUserQuestion` でワークツリー戦略をユーザーに確認する。**
これは SDD 全体で唯一のユーザー確認ポイントであり、これ以降は完全自律で実行する（「重要な注意事項」#1 参照）。

```
AskUserQuestion:
  questions:
    - header: "Worktree"
      question: "SDD を専用の Git ワークツリーで実行しますか、それとも現在のディレクトリで実行しますか？"
      multiSelect: false
      options:
        - label: "ワークツリーを作成"
          description: "wtp で専用ワークツリー（新規ブランチ）を作成し、そこへ移動して作業する。メインの作業ディレクトリを汚さずに並行作業できる。"
        - label: "現在の場所で作業"
          description: "ワークツリーを作成せず、現在のディレクトリでそのまま作業する。"
```

#### 「ワークツリーを作成」を選択した場合

`wtp` スキルに従い、Phase 5-1 と同じ命名規約のブランチで専用ワークツリーを作成して移動する:

- ブランチ名: Issue 番号がある場合は `claude/{issue-number}/{spec-name}`、ない場合は `claude/{spec-name}`

```bash
# 新規ブランチ + ワークツリーを BASE_BRANCH ベースで作成し、絶対パスを取得して移動
WORKTREE_DIR=$(wtp add -b {branch-name} "$BASE_BRANCH" --quiet)
cd "$WORKTREE_DIR"
```

以降の全フェーズ（Spec ディレクトリ作成・実装・コミット・PR 作成）はこのワークツリー内で行う。
**このケースではブランチが既に作成済みのため、Phase 5-1 のブランチ作成はスキップする。**

`wtp` が利用できない、または作成に失敗した場合は、その旨を踏まえて「現在の場所で作業」にフォールバックする。

#### 「現在の場所で作業」を選択した場合

ワークツリーは作成せず、現在のディレクトリのまま次のステップへ進む。Phase 5-1 で通常どおりブランチを作成する。

### 0-5. Spec ディレクトリ作成

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
  model: "haiku"   # retrieval 型（steering docs / CLAUDE.md の verbatim 抽出）は Haiku で十分
  description: "Steering docs・規約調査"
  prompt: |
    以下を調査して報告:
    ※ .spec-workflow/ 配下は gitignore されている可能性がある。Glob/Grep ではなく Bash `ls` + Read ツールで確認すること
    1. Bash で `ls .spec-workflow/steering/` を実行してディレクトリ内容を確認
       - ファイルが存在する場合: Read ツールで product.md, tech.md, structure.md を読み込んで全文報告
       - ディレクトリが存在しないかファイルがない場合: 「Steering ドキュメントなし」と報告
    2. プロジェクトルートの CLAUDE.md を読み込み、コーディング規約・技術スタックを報告
    3. README.md があれば概要を報告
```

**調査2: コードベース構造分析**

```
Agent:
  subagent_type: "Explore"
  model: "sonnet"   # pattern-recognition 型（既存構造・パターンの一般化）。見落としが下流の requirements/design に波及するため Sonnet
  description: "コードベース構造分析"
  prompt: |
    プロジェクトの構造を分析して報告:
    1. ディレクトリ構造の概要（主要ディレクトリとその役割）
    2. 主要な技術スタック・フレームワーク（package.json, Gemfile, go.mod 等から特定）
    3. 既存のアーキテクチャパターン・設計規約
    4. テスト構成（テストフレームワーク、テストディレクトリ）
    5. CI/CD 設定（.github/workflows/ 等）
```

**テンプレート取得（Leader 自身が実行）**

テンプレートは gitignore されている可能性があるため、サブエージェント（Glob/Grep 依存）ではなく **Leader 自身が Bash `ls` + Read ツール** で直接取得する:

1. `ls .spec-workflow/user-templates/requirements-template.md 2>/dev/null` で存在確認
2. 存在すれば Read ツールで全文読み込み（優先）
3. 存在しなければ `ls .spec-workflow/templates/requirements-template.md 2>/dev/null` で確認
4. いずれも存在しなければ「テンプレートなし」として進行

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
  model: "sonnet"   # pattern-recognition 型（再利用可能コンポーネント発見）。reuse-first 原則が効くよう false negative を避ける
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

**テンプレート取得（Leader 自身が実行）**

テンプレートは gitignore されている可能性があるため、**Leader 自身が Bash `ls` + Read ツール** で直接取得する:

1. `ls .spec-workflow/user-templates/design-template.md 2>/dev/null` で存在確認
2. 存在すれば Read ツールで全文読み込み（優先）
3. 存在しなければ `ls .spec-workflow/templates/design-template.md 2>/dev/null` で確認
4. いずれも存在しなければ「テンプレートなし」として進行

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

### 3-1. タスクテンプレート取得（Leader 自身が実行）

テンプレートは gitignore されている可能性があるため、**Leader 自身が Bash `ls` + Read ツール** で直接取得する:

1. `ls .spec-workflow/user-templates/tasks-template.md 2>/dev/null` で存在確認
2. 存在すれば Read ツールで全文読み込み（優先）
3. 存在しなければ `ls .spec-workflow/templates/tasks-template.md 2>/dev/null` で確認
4. いずれも存在しなければ「テンプレートなし」として進行

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

## Phase 4〜6: 実装・コミット & PR・完了報告

**ここから先は spec compiler の所有物ではない。** 手順は `references/` にあり、**着手前に必ず
Read する**（節を飛ばさない）:

1. **Phase 4（実装・品質チェック）** → [`references/implementation.md`](references/implementation.md)
   worker 選定と委譲契約の SSOT は `pr-workflow`「共有作業ツリーでの Claude subagent 委譲契約」節と
   `codex/SKILL.md`「agent profile（workspace-write 実行）」節。
2. **Phase 5（コミット & PR）・Phase 6（完了報告）** → [`references/delivery.md`](references/delivery.md)
   commit 規約は `commit/SKILL.md`、PR 作成手順は `create-pr/SKILL.md` が SSOT。

レビューは行わない（`pr-workflow` の PR 作成後パイプラインが担う。frontmatter 参照）。

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| サブエージェントの調査失敗 | 別のサブエージェントで再試行。3回失敗したら自身で調査 |
| ビルド・テスト失敗 | エラー内容を分析し自身で修正。修正後再実行 |
| Git 操作失敗（1Password 等） | `notify` でユーザーに通知後、`AskUserQuestion` で待機し手動介入を依頼。**この場合のみ作業を中断** |
| PR 作成失敗 | エラー内容を確認し、修正して再試行。`gh auth status` で認証を確認 |

## 重要な注意事項

1. **完全自律実行**: ユーザー確認は Phase 0-4 のワークツリー戦略の選択（`AskUserQuestion`）のみ。それ以降は Phase 6 まで承認フローを挟まず一切止まらずに実行する
2. **MCP ツール不使用**: spec-workflow MCP のツール（approvals, spec-status, log-implementation 等）は一切使用しない
3. **sleep / polling 禁止**: `sleep` コマンドや `while` ループでの待機は**絶対に使わない**。サブエージェントの結果は完了時に自動で返る
4. **Leader = 司令塔 + 作業者**: ドキュメント作成と、複数ファイル横断・context 継続が要るコード実装は Leader 自身が行う。調査、および 4-2 の**自己完結タスク**はサブエージェント / Codex worker に委任してよい（判定基準は 4-2）
5. **コスト最適化 / model・effort tier**: Leader = セッション model（要求水準は `/model-fitness-check` が SSOT。Phase 0 で起動済み。値をここに再掲しない）。**調査はタスク形状別**: retrieval 型（steering docs 転記）= Haiku、pattern-recognition 型（コードベース構造・再利用パターン分析）= Sonnet（Explore に `model` を明示 pin）。**自己完結タスク**（単一ファイル・tasks.md 上で他タスク非依存・並行タスクと共有状態なし）は Sonnet worker or Codex worker に委譲してよい（前提条件・契約は 4-2 を参照。Codex の起動経路・禁止事項は `codex/SKILL.md` が SSOT）。
6. **通知は最後だけ**: 作業中にユーザーに通知するのは Phase 6 の完了時のみ。例外は Git 操作エラー時（`notify` + `AskUserQuestion` で待機）
7. **gitignore 対象ファイルへのアクセス**: `.spec-workflow/` 配下のファイル（テンプレート・Steering docs 等）は gitignore されている可能性がある。Glob/Grep は ripgrep ベースで gitignore を尊重するため検出できない。必ず Bash `ls` + Read ツールで直接アクセスすること
