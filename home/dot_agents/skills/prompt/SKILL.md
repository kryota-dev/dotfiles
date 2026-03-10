---
name: prompt
description: プロンプトを作成する。requirementsの指定を引数で指定する。
argument-hint: "[requirements]"
disable-model-invocation: true
---

天才プロンプトエンジニア目線で、要件それぞれ役立つプロンプトを作成して。
初級、中級、上級、天才 レベル別で、それぞれのプロンプトを省略せずに１つずつ丁寧に、構造化して整理して作成して。
それぞれのプロンプトは下に、追加文章を貼り付けるだけで成立するような汎用的で柔軟なプロンプトを考えてください。

### 要件

{$requirements}

### 1. 事前準備フェーズ

- ユーザーがClaude Codeに対して、実行したいタスクの概要を伝える
- このフェーズで !`mkdir -p ./.claude/prompts` を実行します
- `./.claude/prompts` 内にタスクの概要から適切なプロンプト名を考えて、その名前のディレクトリを作成します
  - たとえば、「記事コンポーネントを作成する」というタスクなら `./.claude/prompts/{timestamp}-create-article-component` という名前のディレクトリを作成します
  - `{timestamp}` は `YYYYMMDD-HHMMSS` 形式のタイムスタンプです
  - `date +"%Y%m%d-%H%M%S"` でタイムスタンプを生成すること
- 以下ファイルを作成するときはこのディレクトリの中に作成します

### 2. 初級プロンプトの作成フェーズ

- 初級プロンプトを作成してください
- ファイル名は `beginner.md` とします
- `code ./.claude/prompts/{timestamp}-{task-name}/beginner.md` を実行して、作成したファイルを開く

### 3. 中級プロンプトの作成フェーズ

- 中級プロンプトを作成してください
- ファイル名は `intermediate.md` とします
- `code ./.claude/prompts/{timestamp}-{task-name}/intermediate.md` を実行して、作成したファイルを開く

### 4. 上級プロンプトの作成フェーズ

- 上級プロンプトを作成してください
- ファイル名は `advanced.md` とします
- `code ./.claude/prompts/{timestamp}-{task-name}/advanced.md` を実行して、作成したファイルを開く

### 5. 天才プロンプトの作成フェーズ

- 天才プロンプトを作成してください
- ファイル名は `genius.md` とします
- `code ./.claude/prompts/{timestamp}-{task-name}/genius.md` を実行して、作成したファイルを開く

### 6. プロンプトのユーザー確認フェーズ

- `AskUserQuestion` ツールを使用して、作成したプロンプトを提示し、問題がないかをユーザーに確認する
  - question: "プロンプトを作成しました。内容を確認してください。問題ありませんか？"
  - header: "確認"
  - options:
    - { label: "問題ない", description: "このプロンプトで確定する" }
    - { label: "修正が必要", description: "修正箇所をフィードバックする" }
  - multiSelect: false
