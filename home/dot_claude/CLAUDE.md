<!-- このファイルが読み込まれたら「~/.claude/CLAUDE.mdを読み込みました」とユーザーに必ず伝えてください -->

@~/AGENTS.md

上記 `@~/AGENTS.md` で harness 非依存の運用ルール（Skill provenance / 基本運用 / coding standards 等）を取り込みます。以下は **Claude Code 固有**のルールです。

## Mandatory skill usage

- 変更をコミットする際は、`$commit` を使用する
- PRを作成する際は、`$create-pr` を使用する
- コード変更が完了しレビュー準備に入る際は、`$pr-draft-summary` を実行する
- GitHub Issueを作成する際は、`$create-issue` を使用する
- 新機能や変更の実装前は、`$planning` を使用する

## memory への記録ポリシー

- **memory への記録は、ユーザーの判断を仰いでから行うこと**
  - エージェントが「保存価値あり」と判断しても、独断で `Write` / `Edit` してはならない
  - 「保存価値あり」と判断した場合は、放棄せず以下を提示してユーザーの判断を仰ぐ:
    - 記録対象（user / feedback / project / reference）
    - 内容案（フロントマター含むファイル全文）
    - 保存価値があると判断した理由
  - ユーザーが明示的に承認した場合のみ保存処理を実行する

## gitignore 対象ファイルへのアクセス

- **Glob / Grep ツールは内部で ripgrep を使用しており、`.gitignore`（グローバル gitignore 含む）対象ファイルをスキップする**
  - gitignore されたファイルを探す際は、Bash `ls` コマンドまたは Read ツール（絶対パス指定）を使用すること
  - 該当例: `.spec-workflow/user-templates/`、`.spec-workflow/steering/` 等

## ツール使用（Claude 固有）

- **画面に影響する変更を行った、もしくはブラウザでの動作確認を指示された際は、`Playwright MCP Server`を使用すること**
- **ユーザーから「DeepWiki を使用して」と指示された際は、`DeepWiki MCP Server`を使用すること**
- **MCP Server が利用不可な場合、MCP Server を有効にするようユーザーへ伝えること**

## hook によるガードレール緩和（Claude 固有）

`@~/AGENTS.md` の保守的な既定ルールのうち、Claude Code では以下が hook で機械的に担保されるため、明示確認・委任は不要:

- **git push**: git-push-reminder hook が push 操作時に stderr で注意喚起するため、push の明示確認は不要（commit の確認は維持する）。
- **開発サーバー**: auto-tmux-dev hook が dev server を tmux 内で detached 起動するため、ユーザーへの起動委任は不要。

（これらの hook を持たない harness（例: Codex）では、`@~/AGENTS.md` の保守的な既定ルールがそのまま適用される。）

### Skill provenance

`~/.agents/skills/` 配下の skill は次の 5 分類いずれかに必ず属する。unmanaged 分類は policy 違反として `tests/skill_provenance.bats` で検出される。

| 分類 | 物理場所 | 管理 model |
|---|---|---|
| `curated` | `~/.agents/skills/<name>/` | chezmoi 直接管理 (自作 + fork) |
| `external` | `~/.agents/skills/<name>/` | chezmoi external + SHA pin + 168h refresh |
| `system` | `~/.agents/skills/.system/<name>/` | Anthropic 配布 (管理外) |
| `evolved` | `$CLV2_HOMUNCULUS_DIR/evolved/skills/<name>/` | ECC continuous-learning v2 + /evolve 生成 |
| `unmanaged` | `~/.agents/skills/<name>/` provenance 不明 | **policy 違反、整理対象** |

新規 skill 取り込み時、上記いずれかに分類されることを確認すること。

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
