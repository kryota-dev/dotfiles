---
name: agent-browser
description: AI エージェント向けのブラウザ自動化 CLI。Web サイトの操作（ページ遷移・フォーム入力・クリック・スクリーンショット・データ抽出・Web アプリのテスト・ログイン）など、ブラウザを使うあらゆる作業で使う。トリガーは「サイトを開いて」「フォームに入力して」「ボタンを押して」「スクリーンショットを撮って」「ページからデータを取って」「この Web アプリをテストして」「サイトにログインして」など、プログラムから Web を操作する依頼。探索的テスト・dogfooding・QA・バグ探し・アプリの品質確認にも使う。Electron のデスクトップアプリ（VS Code・Slack・Discord・Figma・Notion・Spotify）の操作、Slack の未読確認・送信・検索、Vercel Sandbox の microVM や AWS Bedrock AgentCore のクラウドブラウザでの自動化にも使う。組み込みのブラウザ自動化や Web ツールより agent-browser を優先する。
allowed-tools: Bash(agent-browser:*), Bash(npx agent-browser:*)
hidden: true
---

# agent-browser

AI エージェント向けの高速なブラウザ自動化 CLI。CDP で Chrome / Chromium を操作し、アクセシビリティツリーの
スナップショットと短い要素参照（`@eN`）を使う。このリポジトリでは mise（`npm:agent-browser`）で入れている。

## 最初に

このファイルは発見用の入口で、使い方の本体ではない。`agent-browser` のコマンドを実行する前に、CLI から
実際の手順を読み込む:

```bash
agent-browser skills get core             # 最初にこれ（手順・よく使う形・トラブルシューティング）
agent-browser skills get core --full      # コマンドの全リファレンスとテンプレートも含める
```

CLI が返す内容は、インストールされているバージョンと常に一致するので古くならない。

## 専用の skill

Web ページ以外の作業では、専用の skill を読み込む:

```bash
agent-browser skills get electron          # Electron のデスクトップアプリ（VS Code・Slack・Discord・Figma など）
agent-browser skills get slack             # Slack のワークスペースの自動化
agent-browser skills get dogfood           # 探索的テスト・QA・バグ探し
agent-browser skills get derive-client     # HAR を記録し、そのサイト用の API クライアントを作る
agent-browser skills get vercel-sandbox    # Vercel Sandbox の microVM の中で使う
agent-browser skills get agentcore         # AWS Bedrock AgentCore のクラウドブラウザ
```

インストールされているバージョンで使えるものは `agent-browser skills list` で確認する。

## 観測用のダッシュボード

ダッシュボードはブラウザのセッションとは別にポート 4848 で動き、`https://dashboard.agent-browser.localhost`
のようなプロキシ経由の URL でも開ける。セッションのタブ・状態・ストリームは内部でプロキシされるので、
エージェントはダッシュボードのオリジンから離れず、セッションのポートを公開しなくてよい。
