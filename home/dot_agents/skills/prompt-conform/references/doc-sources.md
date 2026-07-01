# 公式ドキュメント取得先（ポインタのみ）

このファイルは**ドキュメントの在り処**だけを持つ。ベストプラクティスの中身は書かない
（陳腐化するため）。SKILL.md Step 3 で、対象モデル系に対応する URL をライブ取得すること。

URL は移設・改称されうる。リダイレクトは追う。404 や大幅改稿に当たったら、末尾の
「見つからないときの探し方」に従い公式ドメイン内を探す。

## モデル系 → 取得先

### Claude 系（`claude-*` / Anthropic）

- 索引（現行全モデル共通の定石）:
  `https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices`
- 概要:
  `https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview`
- **モデル別ページ**は索引からリンクされる。対象モデルに一致するページを辿る。例:
  - Opus 系: `.../prompt-engineering/prompting-claude-opus-4-8`
  - Fable/Mythos 系: `.../prompt-engineering/prompting-claude-fable-5`
- 旧ドメイン `docs.anthropic.com/...` は `platform.claude.com/...` へリダイレクトされる。

### GPT / Codex 系（`gpt-*` / `o*` / `codex-*` / OpenAI）

プロンプトの正典は **OpenAI 公式ドキュメント**に限定する:

- プロンプトエンジニアリングガイド:
  `https://platform.openai.com/docs/guides/prompt-engineering`
- 推論モデル向けの指針:
  `https://platform.openai.com/docs/guides/reasoning-best-practices`
- GPT-5 系プロンプトガイド（Cookbook）:
  `https://cookbook.openai.com/examples/gpt-5/gpt-5_prompting_guide`
- Codex（エージェント）ドキュメント:
  `https://developers.openai.com/codex/`
- 注: `platform.openai.com/...` および `cookbook.openai.com/...` は `developers.openai.com/...`
  へリダイレクトされる場合がある。リダイレクトは追ってよい。

**`AGENTS.md`（`https://agents.md`）は prompting best-practice の根拠にしない。** これはモデル系の
公式プロンプトガイドではなく、リポジトリ指示ファイルの**フォーマット仕様**（Linux Foundation 配下の
stewardship）。Codex 向け最適化で `AGENTS.md` 自体の指示設計を対象にする場合の**ファイル形式リファレンス**
としてのみ参照し、「公式ベストプラクティス」としては扱わない。

### Gemini 系（`gemini-*` / Google）

- `https://ai.google.dev/gemini-api/docs/prompting-strategies`

### その他・不明なモデル

下記「見つからないときの探し方」に従う。

## 見つからないときの探し方（discovery）

1. モデル提供元の**公式ドメイン**を特定する（Anthropic→platform.claude.com、
   OpenAI→platform.openai.com / developers.openai.com / cookbook.openai.com、Google→ai.google.dev 等）。
2. web 検索を**公式ドメインに限定**して「<モデル名> prompt engineering best practices」等で探す。
   一般ブログや二次情報は根拠にしない（公式のみ）。
3. モデル別ページが見つかれば最優先。無ければそのモデル系の汎用プロンプトガイドを使う。
4. どうしても正典が見つからなければ、SKILL.md「環境制約・フォールバック」に従い、
   ユーザーに確認するか、暫定案に「要検証」ラベルを付ける。
