---
description: "spec-driven development"
---

**ultrathink**

Claude Codeを用いたspec-driven developmentを行います。

## spec-driven development とは

spec-driven development は、以下の5つのフェーズからなる開発手法です。
@.cursor/tasks/planning.md をベースに、以下のフェーズを実行します。

### 1. 事前準備フェーズ

- ユーザーがClaude Codeに対して、実行したいタスクの概要を伝える
- このフェーズで !`mkdir -p ./.claude/specs` を実行します
- `./.claude/specs` 内にタスクの概要から適切な spec 名を考えて、その名前のディレクトリを作成します
  - たとえば、「記事コンポーネントを作成する」というタスクなら `./.claude/specs/{timestamp}-create-article-component` という名前のディレクトリを作成します
  - `{timestamp}` は `YYYYMMDD-HHMMSS` 形式のタイムスタンプです
  - `date +"%Y%m%d-%H%M%S"` でタイムスタンプを生成すること
- 以下ファイルを作成するときはこのディレクトリの中に作成します

### 2. 要件フェーズ

- ファイル名は `requirements.md` とします
- Claude Codeがユーザーから伝えられたタスクの概要に基づいて、タスクが満たすべき「要件ファイル」を作成する
- `code ./.claude/specs/{timestamp}-{task-name}/requirements.md` を実行して、作成したファイルを開く
- Claude Codeがユーザーに対して「要件ファイル」を提示し、問題がないかを尋ねる
- ユーザーが「要件ファイル」を確認し、問題があればClaude Codeに対してフィードバックする
- ユーザーが「要件ファイル」を確認し、問題がないと答えるまで「要件ファイル」に対して修正を繰り返す

### 3. 設計フェーズ

- ファイル名は `design.md` とします
- Claude Codeは、「要件ファイル」に記載されている要件を満たすような設計を記述した「設計ファイル」を作成する
- `code ./.claude/specs/{timestamp}-{task-name}/design.md` を実行して、作成したファイルを開く
- Claude Codeがユーザーに対して「設計ファイル」を提示し、問題がないかを尋ねる
- ユーザーが「設計ファイル」を確認し、問題があればClaude Codeに対してフィードバックする
- ユーザーが「設計ファイル」を確認し、問題がないと答えるまで「要件ファイル」に対して修正を繰り返す

### 4. 実装計画フェーズ

- ファイル名は `plan.md` とします
- Claude Codeは、「設計ファイル」に記載されている設計を実装するための「実装計画ファイル」を作成する
- `code ./.claude/specs/{timestamp}-{task-name}/plan.md` を実行して、作成したファイルを開く
- Claude Codeがユーザーに対して「実装計画ファイル」を提示し、問題がないかを尋ねる
- ユーザーが「実装計画ファイル」を確認し、問題があればClaude Codeに対してフィードバックする
- ユーザーが「実装計画ファイル」を確認し、問題がないと答えるまで「要件ファイル」に対して修正を繰り返す

### 5. 実装フェーズ

- Claude Codeは、「実装計画ファイル」に基づいて実装を開始する
- 実装するときは「要件ファイル」「設計ファイル」に記載されている内容を守りながら実装してください
