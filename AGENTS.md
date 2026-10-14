# AGENTS.md

chezmoi で管理する macOS 用の dotfiles。ソースのルートは `home/`（`.chezmoiroot`）。構成を変える前に
[ARCHITECTURE.md](ARCHITECTURE.md) を読むこと。

## ルール

- このリポジトリは環境の宣言にとどめる。ランタイム・サーバー・状態ストア・CLI を足さず、Claude Code・
  Codex・chezmoi・Renovate の標準機能を使う。
- エージェント向けのものは、Claude Code と Codex の両方で動くようにする。共通のルールは `home/AGENTS.md`、
  共通の skill は `home/dot_agents/exact_skills/` に置く。
- 他者が公開している skill をそのまま使うときは、翻訳して置かず、`.chezmoiexternal.toml` で上流から取得する
  （再配布に伴うライセンス表記を持たないため）。一部だけを取り込んだときは、その箇所に出典とライセンスを書く。
- コメントには「なぜ」を数行で書く。経緯は git に残し、コメントには書かない。
- public リポジトリなので、クライアント・勤務先の固有名をコミットしない。秘密情報は `onepasswordRead` で
  1Password から読む。
- スクリプト・テンプレート・zsh の設定・CI を変えたら、コミットの前に `make test` を実行する。

## 言語

文書・コードのコメント・テスト名・コミット・PR・Issue・レビューコメント・skill は、すべて日本語で書く
（コミットは Conventional Commits で、`type(scope):` だけ英語）。外部のツールが生成する部分（Brewfile の説明など）は
そのままにする。
