<!-- このファイルが読み込まれたら「~/AGENTS.mdを読み込みました」とユーザーに必ず伝えてください -->

## Mandatory skill usage

- 変更をコミットする際は、`$commit` を使用する
- PRを作成する際は、`$create-pr` を使用する
- コード変更が完了しレビュー準備に入る際は、`$pr-draft-summary` を実行する
- GitHub Issueを作成する際は、`$create-issue` を使用する
- 新機能や変更の実装前は、`$planning` を使用する

## Skill provenance（スキルの出自分類）

`~/.agents/skills/` 配下の各 skill は次の 5 分類のいずれかに属する。新規 skill は `curated`（chezmoi 管理）で追加し、外部 skill は `external`（chezmoi external）で宣言的に取得する。**`unmanaged` を残さないこと**（削除するか `curated` / `external` へ取り込む）。

| 分類 | 定義 | 配置 |
|------|------|------|
| `curated` | chezmoi で SSOT 管理する自作 skill。各ツール（Claude / Codex）へ symlink で配信 | source: `home/dot_agents/skills/<name>/` |
| `external` | chezmoi external で取得する外部 skill（ECC 等）。source には含めない | `.chezmoiexternal.toml`（or `.tmpl`）で宣言、`~/.agents/skills/<name>/` に展開 |
| `system` | Anthropic 配布の system skill。管理対象外（変更しない） | `~/.agents/skills/.system/` 配下 |
| `evolved` | 継続学習 v2（CLV2）の `/evolve` で instinct から生成した skill。skill discovery とは別 location | `$CLV2_HOMUNCULUS_DIR/evolved/skills/` 配下 |
| `unmanaged` | 上記いずれにも該当しない = **policy 違反** | — |

分類整合性は `tests/skill_provenance.bats` で enforcement する（source の `curated` / `external` 宣言を deterministic に検証し、runtime に `unmanaged` が残っていれば警告する）。

## 運用ルール

### 基本

- **ファイルの転写・複製が必要な場合は、`cp` コマンドを使用すること**
  - Read → Write によるトークン消費を避け、正確性を担保する
  - 例: `cp source_file destination_file`
- **常に日本語で対応すること**
- **専門用語を積極的に使用すること**
  - 一般的な表現に言い換えず、正確な技術用語・業界用語をそのまま用いる
- **git のコミットや push 操作を行う際は、事故防止のため、ユーザーに確認を取ってから行うこと**
- **ファイルのリネーム時は `git mv` コマンドを使用し、Git 履歴を保持すること**
  - 削除 → 新規作成ではなく、必ず `git mv old_name new_name` でリネームする
- **ユーザーによる操作や承認が必要な場合は、通知音付きのプッシュ通知を配信して作業を即中断すること**
  - 通知コマンド: `osascript -e 'display notification "<メッセージ>" with title "Claude Code" sound name "Glass"'`
    - `<メッセージ>` には中断理由を簡潔に記述する（例: `1Password で git commit が失敗しました`）
  - ユーザー操作が必要な場面の一例:
    - `git commit` 時の1Passwordエラー

### memory への記録ポリシー

- **memory への記録は、ユーザーの判断を仰いでから行うこと**
  - エージェントが「保存価値あり」と判断しても、独断で `Write` / `Edit` してはならない
  - 「保存価値あり」と判断した場合は、放棄せず以下を提示してユーザーの判断を仰ぐ:
    - 記録対象（user / feedback / project / reference）
    - 内容案（フロントマター含むファイル全文）
    - 保存価値があると判断した理由
  - ユーザーが明示的に承認した場合のみ保存処理を実行する

### gitignore 対象ファイルへのアクセス

- **Glob / Grep ツールは内部で ripgrep を使用しており、`.gitignore`（グローバル gitignore 含む）対象ファイルをスキップする**
  - gitignore されたファイルを探す際は、Bash `ls` コマンドまたは Read ツール（絶対パス指定）を使用すること
  - 該当例: `.spec-workflow/user-templates/`、`.spec-workflow/steering/` 等

### ツール使用

- **GitHub 関連の指示や URL を受け取った際は、`gh`コマンドを使用すること**
  - `gh`コマンドが使用できない場合は、ユーザーにトラブルシューティングを依頼してください
- **GitHub の issue や PR、project の README に画像リンクがある場合は、`gh-asset` を使って画像をダウンロードして、その画像内の内容を含めて実装計画を作ること**
  - `gh-asset download <asset_id> .claude/gh-assets`
  - 参考: https://github.com/YuitoSato/gh-asset
- **画面に影響する変更を行った、もしくはブラウザでの動作確認を指示された際は、`Playwright MCP Server`を使用すること**
- **ユーザーから「DeepWiki を使用して」と指示された際は、`DeepWiki MCP Server`を使用すること**
- **MCP Server が利用不可な場合、MCP Server を有効にするようユーザーへ伝えること**
- **ユーザーから「Copilotにアサインして」と指示された際は、`copilot-swe-agent`をアサインすること**

### 開発サーバー

- **ターミナルセッションのトラブルを避けるため、開発サーバーの起動はユーザーに委任してください**

## Playwright MCP 使用時のルール

### ページサイズが大きい場合の対処法

**playwright-mcp を使用してページ内容を取得する際、ページが大きくて内容が取得できない場合は以下の手順で対処する：**

1. **browser_snapshot**等で内容取得に失敗または不完全な場合を検知
2. **browser_get_request_info API を使用**してリクエスト情報を取得
3. **生成された curl コマンドを使用**して HTML を直接ダウンロード
4. **ダウンロードした HTML ファイルを解析**して必要な情報を抽出

### 実装例

1. **browser_get_request_info でリクエスト情報取得**
2. **curl コマンドを実行して HTML を保存**

   ```bash
   curl '[取得したURL]' -H 'Cookie: [取得したCookie]' -o ./tmp/page_content.html
   ```

3. **HTML を解析（Ruby/Python 等で処理）**

この方法により、MCP の制限を回避して大きなページの完全な内容を取得できる。
