---
name: codex
description: |
  Codex CLI（OpenAI）を使用してコードや文言について相談・レビューを行う。
  現在のセッションとは別のCLIエージェントが起動し、独立したコンテキストで分析を行う。
  トリガー: "codex", "codexと相談", "codexに聞いて", "codexでレビュー", "codexに分析させて"
  使用場面: (1) コードレビュー (2) バグ調査 (3) 設計の相談 (4) アーキテクチャ分析 (5) リファクタリング提案 (6) UI/UXデザイン評価
argument-hint: "<依頼内容>（日本語可）"
---

# Codex

Codex CLI を使用してコードレビュー・分析を実行するスキル。
現在のセッションとは別の CLI エージェントが起動し、独立したコンテキストで分析が得られる。

## SSOT としての位置づけ

本 skill は **Codex CLI 経由のレビュー・分析実行の Single Source of Truth**。`multi-review` skill から並列呼び出しされる場合も、本ファイルの実行コマンド・stdin パイプ問題への対処・プロンプトのルール・使用例に従う。multi-review 側で重複定義しない。

## codex アカウントの選択（cdx / cdx-r06 の再現）

起動中の Claude セッションに合わせて codex のアカウント（`CODEX_HOME`）を切り替える。

| 起動した Claude | 相当するエイリアス | `CODEX_HOME` | profile |
|----------------|------------------|-------------|---------|
| `cld-r06`（`CLAUDE_CONFIG_DIR` が `*.claude-r06`） | `cdx-r06` | `$HOME/.codex-r06` | `shared` |
| それ以外（`cld` など。`CLAUDE_CONFIG_DIR` 未設定/別値） | `cdx` | デフォルト（`~/.codex`） | `shared` |

**重要（エイリアスを直接呼べない理由）**: `cdx` / `cdx-r06` は zsh インタラクティブ設定のエイリアスで、Claude が叩く非対話 Bash には**ロードされない**（`type cdx` が `not found`）。そのため本 skill はエイリアスの中身（`CODEX_HOME` の設定 + `--profile shared` の付与）を**インラインで再現**する。

**重要（同一 Bash ブロック内に前置すること）**: Bash ツールは呼び出しごとに**別シェル**を起動するため、`export CODEX_HOME` は `codex exec` の実行と**同一の Bash コマンド内**に書かないと効かない。特に `run_in_background: true` の単発実行では、下記 prelude を heredoc ブロックと同じ Bash 呼び出しに必ず含める。

### アカウント選択 prelude

以降の**すべての `codex exec` 実行例の冒頭**に、次の 1 行（prelude）を同一ブロックで前置する:

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
```

- 条件が真（`cld-r06` セッション）のとき `CODEX_HOME=$HOME/.codex-r06` を export（= `cdx-r06` 相当）。
- 偽のときは何もせず、デフォルトの `~/.codex` が使われる（= `cdx` 相当）。
- `codex exec` には**常に `--profile shared` を付与**する（`shared.config.toml` を適用。`cdx`/`cdx-r06` と等価）。

## 実行コマンド

レビュー目的では **read-only sandbox** で十分。`--full-auto` は `--sandbox workspace-write` のエイリアスのため、レビューでは付けない。書き込みが必要な用途のときのみ `--full-auto` または `--sandbox workspace-write` を明示する。

### 推奨形式: stdin から prompt を渡し、結果のみをファイルに出力する

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
codex exec --profile shared --sandbox read-only --cd <project_directory> --color never -o <RESULT_FILE> - <<'PROMPT' >/tmp/codex-run.log 2>&1
<request>
PROMPT
```

ポイント:

- 末尾の `-` は「prompt を stdin から読む」ことを明示する。`run_in_background: true` を含む非対話環境でも stdin 待ちでハングしない。
- **`-o <RESULT_FILE>`（`--output-last-message`）で assistant の最終メッセージ（＝レビュー結果）のみをファイルに書き出す**。進捗ログ（workdir / model / reasoning / exec コマンド / tokens used 等）は混入しない。結論部の grep が不要になる。
- `--color never` で ANSI エスケープの混入を防ぐ。
- codex は進捗を **stderr**、最終メッセージを **stdout** に出す設計。端末側の stdout/stderr は確認不要なので `>/tmp/codex-run.log 2>&1` で別ログに退避する（`<RESULT_FILE>` には最終メッセージのみが残る）。
  - **重要**: 結果ファイルとして使うのは `-o` で指定した `<RESULT_FILE>` であって、リダイレクト先のログではない。`> file 2>&1` で stdout/stderr を併合したものを結果として読むと、進捗ログが大量に混入する。

### 引数で渡す場合（前景での対話的実行のみ）

引数で渡すときは、バックグラウンド・パイプ環境で stdin が「piped 状態」と判定され二重入力扱いになる。明示的に stdin を切ること:

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
codex exec --profile shared --sandbox read-only --cd <project_directory> "<request>" </dev/null
```

`</dev/null` を忘れると `run_in_background: true` 環境で「Reading additional input from stdin...」のメッセージのみで早期終了する（後述「stdin パイプ問題」参照）。

## 起動オプション

| オプション | 値 | 理由 |
|------------|-----|------|
| `CODEX_HOME`（環境変数 / prelude で設定） | `$HOME/.codex-r06`（`cld-r06` 時のみ） | 起動した Claude セッションに合わせてアカウントを切り替え（`cdx-r06` 相当）。上記「codex アカウントの選択」参照 |
| `--profile shared` | - | `shared.config.toml`（SSOT 静的設定）を適用。`cdx`/`cdx-r06` と等価にするため常に付与 |
| `--sandbox read-only` | - | 読み取り専用。レビュー用途では十分 |
| `--cd <dir>` | プロジェクトディレクトリ | 対象プロジェクトのルートを指定 |
| `-o, --output-last-message <FILE>` | 結果ファイルパス | assistant 最終メッセージ（レビュー結果）のみをファイル出力。進捗ログが混入しない |
| `--color never` | - | ANSI エスケープの混入防止 |
| `-`（位置引数） | stdin から prompt を読み込む | バックグラウンド実行で stdin 待ちを防ぐ |
| `--full-auto` | （付けない） | `--sandbox workspace-write` のエイリアス。レビュー用途では不要、`--sandbox read-only` と併用すると挙動が紛らわしくなる |

（実機確認: codex-cli 0.139.0。`codex exec --help` で `-o, --output-last-message <FILE>` と `-p, --profile <CONFIG_PROFILE_V2>` を確認。`--profile shared` で `model: gpt-5.5` / `reasoning effort: xhigh`（`shared.config.toml`）が適用されることも実機確認済み。公式: https://developers.openai.com/codex/noninteractive ）

## 引数の解釈

`$ARGUMENTS` をユーザーの依頼内容としてそのまま使用する。
引数が省略された場合は、ユーザーに依頼内容を確認する。

依頼内容に応じて、以下のように適切なプロンプトを構築する:

| 依頼の種類 | 判定キーワード | プロンプトの方向性 |
|-----------|---------------|-------------------|
| コードレビュー | "レビュー", "review" | 改善点の指摘、修正案の提示 |
| バグ調査 | "バグ", "エラー", "bug", "error" | 原因の特定、修正案の提示 |
| アーキテクチャ分析 | "アーキテクチャ", "設計", "構造" | 構造の説明、改善提案 |
| リファクタリング | "リファクタ", "技術的負債", "refactor" | 負債の特定、具体的な計画 |
| UI/UXデザイン | "UI", "UX", "デザイン", "ユーザビリティ" | 視覚/操作性の評価、コード付き改善案 |
| その他 | 上記以外 | 依頼内容に応じた分析・提案 |

## プロンプトのルール

**重要**: codex に渡すリクエストには、以下の 2 点を必ず末尾に含めること:

1. 「確認や質問は不要です。具体的な提案・修正案・コード例まで自主的に出力してください。」
2. 「ライブラリ・フレームワーク・言語仕様について断定する場合、確信が持てないなら必ず本文に **『（未確認）』** または **『（要検証）』** と明示してください。学習データのカットオフ後の変更を見落とすリスクがあるため、自信満々に誤情報を出力するのは避けてください。」

2 点目（技術的主張の確実性）は、レビュー結果を呼び出し元が事実確認する際の負荷を減らすために重要。`run_in_background` で codex を呼び出す `multi-review` スキル等では、親プロセス側で context7 等での fact-check が必要になるため、不確実な箇所は自己申告で markup される方が望ましい。

## 使用例

### コードレビュー

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
cat <<'PROMPT' | codex exec --profile shared --sandbox read-only --cd /path/to/project -
このプロジェクトのコードをレビューして、改善点を指摘してください。
確認や質問は不要です。具体的な修正案とコード例まで自主的に出力してください。
ライブラリ・フレームワーク・言語仕様について断定する場合、確信が持てないなら本文に「（未確認）」と明示してください。
PROMPT
```

### PR 差分のレビュー（multi-review 経由を含む）

`codex exec` の sandbox 内で `gh pr diff <PR番号>` を実行すると認証トークンが届かず差分取得に失敗するケースがある。**PR 差分は呼び出し側で取得し、heredoc 内に埋め込んで渡す** のが確実。

**stdin 堅牢化（推奨）**: heredoc 内に `$(gh pr diff <PR番号>)` をインラインで埋め込むと、`run_in_background: true` 環境で稀に `No prompt provided via stdin.` で失敗することがある（コマンド置換と stdin 供給の競合）。**差分を事前に変数へ確保してから heredoc に展開する**ことで安定する:

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
RESULT=/tmp/codex-review-<PR番号>.txt
DIFF=$(gh pr diff <PR番号>)
codex exec --profile shared --sandbox read-only --cd "$(pwd)" --color never -o "$RESULT" - <<PROMPT >/tmp/codex-run.log 2>&1
PR #<PR番号> のコード差分をレビューしてください。

## 差分

\`\`\`diff
${DIFF}
\`\`\`

## レビュー観点
1. バグ・論理エラー
2. 設計・アーキテクチャの一貫性
3. 可読性・保守性
4. エラーハンドリング
5. パフォーマンス
6. テストの十分性

各指摘を以下のカテゴリで分類:
- [MUST] 修正必須
- [SHOULD] 修正推奨
- [NITS] 軽微な提案
- [GOOD] 良い実装

確認や質問は不要です。具体的な提案・修正案・コード例まで自主的に出力してください。
ライブラリ・フレームワーク・言語仕様について断定する場合、確信が持てないなら本文に「（未確認）」と明示してください。
PROMPT
# レビュー結果は "$RESULT" に最終メッセージのみが書き込まれる（grep 不要）
```

注意点:

- `<<PROMPT`（シングルクォート無し）で変数展開 `${DIFF}` を有効化（差分は事前に `DIFF=$(...)` で確保済み）
- heredoc 内のバッククォート（`` ` ``）は `\`` でエスケープ
- `-o "$RESULT"` により `$RESULT` には**レビュー結果（最終メッセージ）のみ**が入る。進捗ログは `/tmp/codex-run.log` に退避
- 差分が極端に大きい場合（数千行以上）はトークン上限に注意。必要なら `gh pr diff <PR番号> -- <path>` でファイル限定する

その他の使用例でも同じ「（未確認）」明示ルールを末尾に追加すること。以下の例では簡潔のため省略しているが、実際には必ず付与する。

### バグ調査

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
cat <<'PROMPT' | codex exec --profile shared --sandbox read-only --cd /path/to/project -
認証処理でエラーが発生する原因を調査してください。
確認や質問は不要です。原因の特定と具体的な修正案まで自主的に出力してください。
PROMPT
```

### アーキテクチャ分析

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
cat <<'PROMPT' | codex exec --profile shared --sandbox read-only --cd /path/to/project -
このプロジェクトのアーキテクチャを分析して説明してください。
確認や質問は不要です。改善提案まで自主的に出力してください。
PROMPT
```

### リファクタリング提案

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
cat <<'PROMPT' | codex exec --profile shared --sandbox read-only --cd /path/to/project -
技術的負債を特定し、リファクタリング計画を提案してください。
確認や質問は不要です。具体的なコード例まで自主的に出力してください。
PROMPT
```

### デザイン相談（UI/UX）

```bash
if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi
cat <<'PROMPT' | codex exec --profile shared --sandbox read-only --cd /path/to/project -
あなたは世界トップクラスのUIデザイナーです。以下の観点からこのプロジェクトのUIを評価してください:
(1) 視覚的階層構造とタイポグラフィ
(2) 余白・スペーシングのリズム
(3) カラーパレットのコントラストとアクセシビリティ
(4) インタラクションパターンの一貫性
(5) ユーザーの認知負荷の軽減
確認や質問は不要です。具体的な改善案をコード例付きで提示してください。
PROMPT
```

## 実行手順

1. **依頼内容を受け取る**: `$ARGUMENTS` またはユーザーの指示から依頼内容を特定する
2. **プロジェクトディレクトリを特定する**: 現在のワーキングディレクトリ（`pwd`）またはユーザー指定のパス
3. **`codex` コマンドの存在を確認する**: 見つからない場合はインストールを案内
4. **プロンプトを構築する**: 依頼内容 + 「確認不要」指示を末尾に追加
5. **codex を実行する**（Bash の timeout は **300000ms = 5分** に設定）。実行する Bash コマンドの冒頭に「codex アカウントの選択」の prelude を同一ブロックで前置し、`codex exec` には `--profile shared` を付与する
6. **結果をユーザーに報告する**

## 注意事項

### stdin パイプ問題（バックグラウンド実行時）

`run_in_background: true` で `codex exec` を起動すると、Bash ツールは stdin をパイプ open 状態で渡す。`codex exec` の仕様で「stdin が piped かつ引数に prompt がある場合、stdin を `<stdin>` ブロックとして prompt に追加する」挙動があるため、空 stdin が即時 EOF に達して **「Reading additional input from stdin...」のメッセージのみで早期終了する**（exit code 0、実質 0 行のレビュー結果）。

回避策（どちらかを必ず使う）:

| 形式 | コマンド例 | 適用場面 |
|------|----------|---------|
| **推奨**: stdin から渡す | `codex exec ... -o <FILE> - <<'PROMPT' ... PROMPT` | バックグラウンド/前景どちらでも安全 |
| 代替: stdin を切る | `codex exec ... "<request>" </dev/null` | 引数で渡したい場合のみ |

### `No prompt provided via stdin.` で失敗する場合

heredoc 内に `$(gh pr diff ...)` 等のコマンド置換をインラインで埋め込むと、`run_in_background: true` 環境で稀にプロンプトが空のまま `codex` に渡り、`No prompt provided via stdin.` で即終了することがある（コマンド置換の実行と stdin 供給のタイミング競合と推定）。

**回避策**: 差分やコマンド出力は heredoc に直接書かず、**事前に変数へ確保**してから `<<PROMPT`（クォート無し）で `${VAR}` 展開する。上記「PR 差分のレビュー」の例を参照。発生時は 1 回リトライ（事前確保パターンに切り替え）する。

### `--full-auto` と `--sandbox` の関係

- `--full-auto` は `--sandbox workspace-write` のエイリアス。`--sandbox read-only` と併用すると意図が紛らわしい
- レビュー用途では `--full-auto` を **付けない**。`--sandbox read-only` のみ指定する
- 書き込みが必要な用途では `--full-auto` か `--sandbox workspace-write` のどちらか一方のみ指定する

### タイムアウト

- codex の実行は時間がかかる場合がある。Bash の timeout を **300000ms**（5分）に設定すること
- タイムアウトした場合はリトライまたは依頼内容を絞ることを提案

### エラーハンドリング

- `codex` コマンドが見つからない場合: `npm install -g @openai/codex` のインストールを案内
- 認証エラーの場合: `OPENAI_API_KEY` の設定を確認
- 長時間応答がない場合: タイムアウト後にリトライを提案
- 出力が「Reading additional input from stdin...」のみで終了: 上記「stdin パイプ問題」を参照、stdin 形式に切り替える
- `No prompt provided via stdin.` で即終了: コマンド置換のインライン埋め込みが原因。差分を事前に変数へ確保してから heredoc に展開する（上記「stdin パイプ問題」参照）
- 結果ファイルに進捗ログ（workdir / model / reasoning / exec 等）が混入: `> file 2>&1` で stdout/stderr を併合している。`-o <FILE>` で最終メッセージのみを出力する形式に切り替える
