<!-- このファイルが読み込まれたら「~/AGENTS.mdを読み込みました」とユーザーに必ず伝えてください -->

## 必ず遵守すべき重要なルール

- **常に日本語で対応すること**
- **GitHub 関連の指示や URL を受け取った際は、`gh`コマンドを使用すること**
  - `gh`コマンドが使用できない場合は、`GitHub MCP Server`を使用すること
  - `GitHub MCP Server`も使用できない場合は、ユーザーにトラブルシューティングを依頼してください
- **GitHub の issue や PR、project の README に画像リンクがある場合は 、`gh-asset` を使って画像をダウンロードして、その画像内の内容を含めて実装計画を作ること**
  - `gh-asset download <asset_id> .claude/gh-assets`
  - 参考: https://github.com/YuitoSato/gh-asset
- **画面に影響する変更を行った、もしくはブラウザでの動作確認を指示された際は、`Playwright MCP Server`を使用すること**
- **ユーザーから「DeepWiki を使用して」と指示された際は、`DeepWiki MCP Server`を使用すること**
- **ターミナルセッションのトラブルを避けるため、開発サーバーの起動はユーザーに委任してください**
- **MCP Server が利用不可な場合、MCP Server を有効にするようユーザーへ伝えること**
- **git のコミットや push 操作を行う際は、事故防止のため、ユーザーに確認を取ってから行うこと**
- **ファイルのリネーム時は `git mv` コマンドを使用し、Git 履歴を保持すること**
  - 削除 → 新規作成ではなく、必ず `git mv old_name new_name` でリネームする
- **ユーザーによる操作や承認が必要な場合は、通知音を鳴らしてユーザーに通知し、作業を即中断すること**
  - 通知音コマンド: `notify`
  - ユーザー操作が必要な場面の一例:
    - `git commit` 時の1Passwordエラー
- **ユーザーから「Copilotにアサインして」と指示された際は、`copilot-swe-agent`をアサインすること**

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
