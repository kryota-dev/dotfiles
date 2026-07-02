---
name: multi-review
description: |
  3つのレビューツール（cc-code-review / cc-security-review / Codex）を並列でバックグラウンド実行し、
  結果を統合サマリーにまとめた上で、GitHub PR にレビュー（body サマリー + インラインコメント）として投稿する。
  PRの包括的レビューを一度に実行したい場合に使用する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー", "3ツールレビュー"
  使用場面: PRのコードレビュー・セキュリティレビュー・Codexレビューを一括で実行したい場合
argument-hint: "<PR番号> (#付きまたは数字のみ) [--arch]"
---

# Multi Review

3つのレビューツールを並列でバックグラウンド実行し、結果を統合サマリーにまとめる。
既存レビュー（CodeRabbit / Devin / claude[bot] / 人間レビュアー）と重複する指摘を除外したうえで、
統合結果をユーザーに提示し、承認があれば GitHub PR にレビュー（body サマリー + インラインコメント、または インラインのみ）を投稿する（投稿方法はユーザーが選択）。

```
引数解析 → 差分取得 → 既存レビュー取得 + 3ツール並列実行 → 結果収集 → 統合サマリー
  → 既存レビューとの重複除外 → ユーザー確認（投稿方法を選択）→ 投稿
```

**重複除外の意義**: 既存レビュアーが既に同じ指摘をしている場合、再投稿は冗長でレビュアーの認知負荷を増やす。
重複を除外することで、新規視点・追加価値のある指摘のみが投稿される。

## 引数の解釈

以下の優先順で判定する:

1. **PR番号** (`^\d+$` または `^#\d+$`): `gh pr diff <番号>` で差分取得
2. **PR URL** (`github.com` を含む URL): URL から PR 番号を抽出し、`gh pr diff` で差分取得
3. **引数なし**: 現在のブランチに関連する PR を `gh pr view --json number --jq '.number'` で自動検出
4. **`--arch`**（任意フラグ）: 指定時のみ **aggregate-view reviewer**（`architecture-reviewer`）を別レイヤで追加 spawn する（「aggregate-view reviewer」節参照）。未指定時は spawn しない（毎 PR は走らせないコスト方針）。pr-workflow の large tier からは自動でこのフラグ相当が要請される。

## SSOT（Single Source of Truth）

レビューの実体（ペルソナ・観点・出力形式・「（未確認）」ルール）は各ツール側に集約し、multi-review 側で重複定義しない。

| ツール | 実行方式 | SSOT |
|--------|---------|------|
| cc-code-review | カスタムサブエージェント（Agent ツール、`subagent_type: cc-code-review`） | エージェント定義 `~/.claude/agents/cc-code-review.md`（レビュー観点・出力形式）／ skill `~/.agents/skills/cc-code-review/SKILL.md`（対象解決・起動方法） |
| cc-security-review | カスタムサブエージェント（Agent ツール、`subagent_type: cc-security-review`） | エージェント定義 `~/.claude/agents/cc-security-review.md`（OWASP チェックリスト・出力形式）／ skill（対象解決・起動方法） |
| codex | CLI（`codex exec`、バックグラウンド Bash） | skill `~/.agents/skills/codex/SKILL.md`（実行コマンド・`-o` 出力・stdin 堅牢化・プロンプトルール・**アカウント選択 prelude / `--profile shared`**） |

- **cc-code-review / cc-security-review**: レビュー観点・出力形式・OWASP チェックリストはエージェント定義（system prompt）に内蔵されており、サブエージェント起動時に自動適用される。multi-review はプロンプトに「対象の説明 + 差分 + 作業ディレクトリの絶対パス」のみを渡し、観点・出力形式を再掲しない。エージェント定義は起動時に自動ロードされるため multi-review 側で Read する必要はない。
- **codex**: Phase 2 開始前に `~/.agents/skills/codex/SKILL.md` を Read し、`-o <FILE>` 出力・stdin 堅牢化・タイムアウト・「（未確認）」ルールに従ってコマンドを組み立てる。

### 動的 specialist roster（言語/ドメイン特化レビュアー）

常設 3 ツール（cc-code-review / cc-security-review / codex）に加え、**差分の言語・ドメインに応じて専門レビュアーを動的に追加**する。汎用レビュー（cc-code-review）が見落としがちな言語固有・データ層固有の観点を補強するため。専門レビュアーは自前 curated のサブエージェント（`model: sonnet` をエージェント frontmatter で固定 = #28 model-tier 整合、rubric は常設ツールと同一の `[MUST]/[SHOULD]/[NITS]/[GOOD]`）。

| specialist | subagent_type | spawn 条件（変更ファイル） |
|------------|---------------|--------------------------|
| TypeScript | `typescript-reviewer` | `.ts` / `.tsx` / `.mts` / `.cts` |
| React | `react-reviewer` | `.tsx` / `.jsx`（JSX コンポーネント） |
| Python | `python-reviewer` | `.py` / `.pyi` |
| Database | `database-reviewer` | `*.sql` / `migrations/` 配下 / `schema.prisma` / `*.schema.ts`（drizzle 等の schema） |

- **検出方法**: Phase 1 の手順 2 で確保した `${DIFF}` のヘッダ行（`diff --git a/<path> b/<path>`）、または `gh pr diff <番号> --name-only` で変更ファイルのパス一覧を取得し、上表のマッチ基準で specialist を選ぶ。マッチ基準は列ごとに異なる: **拡張子一致**（`.ts` / `.tsx` / `.mts` / `.cts` / `.jsx` / `.py` / `.pyi` / `*.sql` / `*.schema.ts`）、**パスに `migrations/` を含む**、**basename が `schema.prisma`**（パス不問）。
- **重複 spawn 可**: 例えば `.tsx` を含む PR では typescript-reviewer と react-reviewer の両方が立つ（観点が直交するため許容）。
- **マッチ 0 件なら常設 3 ツールのみ**。dotfiles（shell/zsh/bats）のような非対象言語の PR では specialist を spawn しない。
- **roster 外の agent**: `renovate-analyzer` 等の専用 skill / フローから起動するエージェントは本動的 roster の spawn 対象外。今後 specialist を増やす場合も「diff の言語・ドメインで自動 spawn する reviewer」のみを上表に載せる。
- **SSOT**: 各 specialist の観点・出力形式・「（未確認）」ルールはエージェント定義（`~/.claude/agents/<lang>-reviewer.md`）に内蔵。multi-review は cc-code-review と同じく「対象説明 + 差分取得コマンド + 作業ディレクトリ + 棄却台帳」のみ渡し、観点を再掲しない。

### aggregate-view reviewer（repo/architecture 集約視点, #223）

diff 起動の specialist roster とは **別レイヤ**の reviewer。常設 3 ツールも specialist も **diff 起点**のため、「既存抽象との重複」「不要な結合」「意図した設計からの drift」のような **単一 PR の差分だけでは見えない集約視点の問題**は誰も検出できない。それを埋めるのが `architecture-reviewer`（`~/.claude/agents/architecture-reviewer.md`、`model: sonnet` 固定 = #28 model-tier 整合）。

- **対象が違う**: 上記 roster は diff を起点にするが、architecture-reviewer は **repo tree・既存モジュール・設計ドキュメント（`docs/architecture/`・design-rationale・steering docs）を横断スキャン**する（diff は探索の起点に過ぎない）。よって roster の「diff 言語で自動 spawn」ロジックには載せず、別レイヤとして扱う。
- **gated（毎 PR は走らせない・コスト方針）**: whole-repo スキャンは高コストなため、**opt-in（`--arch`）または pr-workflow の large tier から要請されたときのみ** spawn する。デフォルト（無印の multi-review）では spawn しない。この gating が #223 の「per-PR vs periodic」コスト方針の SSOT（＝毎 PR ではなく large/opt-in の per-PR）。
- **SSOT**: 観点・出力形式・「（未確認）」ルールはエージェント定義（`~/.claude/agents/architecture-reviewer.md`）に内蔵。multi-review は「対象 PR 説明 + 差分取得コマンド + 作業ディレクトリ絶対パス + 棄却台帳」のみ渡す（cc-code-review と同形。差分はエージェント自身が取得し、そこから repo 全体へ探索を広げる）。

## 実行手順

### Phase 1: 準備

1. **引数を解析**してPR番号を特定する
2. **差分を取得**する: `gh pr diff <PR番号>` を実行。差分が空の場合は「レビュー対象の差分がありません」と報告して終了。差分は変数に確保しておく（`DIFF=$(gh pr diff <PR番号>)`）。これは **codex 用**（codex は sandbox 内で `gh pr diff` できないためプロンプトに埋め込む）。サブエージェント（cc-code-review / cc-security-review）はセッション内で自分で差分を取得するため埋め込み不要。
3. **リポジトリ情報を取得**する: `gh repo view --json nameWithOwner --jq '.nameWithOwner'` で owner/repo を取得

### Phase 1.5: 既存レビュー・対応状況の取得

Phase 4 の重複除外で使用する。3 種類の API レスポンスと、対応状況の機械的判定をここで揃える。

1. **既存レビュー・コメントを取得**する:

   ```bash
   # a. レビュー本体（state, body）
   gh api repos/{owner}/{repo}/pulls/<PR番号>/reviews --paginate \
     --jq '[.[] | select(.body | length > 0) | {user: .user.login, state: .state, body: .body, submitted_at: .submitted_at}]'

   # b. インラインレビューコメント（path, line, body, in_reply_to_id）
   gh api repos/{owner}/{repo}/pulls/<PR番号>/comments --paginate \
     --jq '[.[] | {user: .user.login, path: .path, line: .line, body: .body, in_reply_to_id: .in_reply_to_id}]'

   # c. PR 全体への issue コメント
   gh api repos/{owner}/{repo}/issues/<PR番号>/comments --paginate \
     --jq '[.[] | {user: .user.login, body: .body}]'
   ```

2. **既存スレッドの対応状況を取得**する。`comments` API では resolved 状態が取れないため、GraphQL `reviewThreads` を使う:

   ```bash
   gh api graphql -f query='
   {
     repository(owner: "{owner}", name: "{repo}") {
       pullRequest(number: <PR番号>) {
         reviewThreads(first: 100) {
           nodes {
             id
             isResolved
             path
             line
             comments(first: 20) {
               nodes {
                 author { login }
                 body
                 createdAt
               }
             }
           }
         }
       }
     }
   }'
   ```

   このレスポンスを基に、各既存指摘の対応状況を 3 つに分類する:

   | 判定 | 条件 |
   |------|------|
   | **resolved** | `isResolved == true` |
   | **fixed-replied** | スレッド内子コメントに `Fixed in [0-9a-f]{7,40}` または `addressed in [0-9a-f]{7,40}` の正規表現マッチ |
   | **open** | 上記いずれでもない（未対応） |

   `resolved` と `fixed-replied` は **対応済み** として扱い、`open` は **未対応** として扱う。

### Phase 2: 並列実行

常設 3 ツール + マッチした動的 specialist を **同一メッセージ内で並列起動**する。cc-code-review / cc-security-review および各 specialist は **Agent ツール**（`run_in_background: true`）、codex は **バックグラウンド Bash**（`run_in_background: true`）。

**Phase 2 開始前**: 「動的 specialist roster」節の検出方法（`gh pr diff <番号> --name-only`）で spawn 対象 specialist を確定する。

#### 起動内容

| ツール | 起動方法 | 渡すもの |
|--------|---------|---------|
| cc-code-review | Agent ツール `subagent_type: cc-code-review`, `run_in_background: true` | プロンプト = 「PR #<番号>（owner/repo）のレビュー依頼 + 差分取得コマンド（`gh pr diff <番号>`）+ 作業ディレクトリ絶対パス」。**差分はエージェント自身が取得**するため埋め込まない。観点・出力形式はエージェント定義に内蔵のため再掲しない |
| cc-security-review | Agent ツール `subagent_type: cc-security-review`, `run_in_background: true` | 同上（セキュリティ観点）。差分はエージェント自身が取得。OWASP チェックリストはエージェント定義に内蔵 |
| codex | バックグラウンド Bash `run_in_background: true` | codex skill「PR 差分のレビュー」コマンド（`-o <RESULT_FILE>` で結果のみファイル出力、差分は事前変数 `${DIFF}` を埋め込み。codex は sandbox 内で `gh pr diff` できないため）。**冒頭に codex skill のアカウント選択 prelude を同一ブロックで前置し、`codex exec` に `--profile shared` を付与する**（起動した Claude セッションに応じて `cdx`/`cdx-r06` を再現） |
| 動的 specialist（マッチ分のみ） | Agent ツール `subagent_type: <lang>-reviewer`, `run_in_background: true` | cc-code-review と同じプロンプト（「対象説明 + 差分取得コマンド + 作業ディレクトリ絶対パス + 棄却台帳」）。**差分はエージェント自身が取得**。観点・出力形式・`model: sonnet` はエージェント定義に内蔵のため再掲・再指定しない |
| architecture-reviewer（**`--arch` / large tier のときのみ**） | Agent ツール `subagent_type: architecture-reviewer`, `run_in_background: true` | cc-code-review と同形のプロンプト（「対象 PR 説明 + 差分取得コマンド + 作業ディレクトリ絶対パス + 棄却台帳」）。**差分は起点として自身が取得し、そこから repo 全体へ探索を広げる**。観点・出力形式・`model: sonnet` はエージェント定義に内蔵。diff 言語では spawn 判定せず、フラグ/tier で判定する（「aggregate-view reviewer」節参照） |

#### 手順

1. **codex skill を Read**（codex のコマンド構築の SSOT）。cc-code-review / cc-security のエージェント定義は起動時に自動ロードされるため、multi-review 側で Read 不要。
2. **同一メッセージ内で 常設 3 ツール + マッチ specialist（+ `--arch`/large tier 時は architecture-reviewer）を並列起動**:
   - Agent × 2（cc-code-review, cc-security-review）: `run_in_background: true`。プロンプトに差分取得コマンド・作業ディレクトリ絶対パス・（多ラウンド時は）棄却台帳を含める（**差分そのものは埋め込まず、エージェントに取得させる**）。
   - Agent × N（マッチした `<lang>-reviewer`、0〜4 個）: cc-code-review と同形のプロンプトで `run_in_background: true` 起動。`model` は指定不要（エージェント frontmatter の `sonnet` が適用）。
   - Agent × 0〜1（`--arch` または large tier 要請時のみ `architecture-reviewer`）: cc-code-review と同形のプロンプトで `run_in_background: true` 起動。diff 言語に依存せず、フラグ/tier のみで spawn 判定する。`model` は指定不要（frontmatter の `sonnet`）。
   - Bash × 1（codex）: `run_in_background: true`、`-o <RESULT_FILE>` 形式で事前確保した `${DIFF}` を埋め込む。`RESULT_FILE` パスを記録する。**コマンド冒頭に codex skill のアカウント選択 prelude（`if [[ "${CLAUDE_CONFIG_DIR:-}" == *.claude-r06 ]]; then export CODEX_HOME="$HOME/.codex-r06"; fi`）を同一 Bash ブロックで前置し、`codex exec --profile shared` を使う**（Bash ツールは呼び出しごとに別シェルのため、export を別ブロックにすると効かない）。
3. **失敗時のリトライ**: 1 回までリトライ。codex が `No prompt provided via stdin.` の場合は事前変数確保パターンで再実行（codex skill 参照）。再失敗なら該当ツールをスキップして Phase 3 へ。

#### 棄却台帳（多ラウンドレビュー時）

同一 PR を複数ラウンドでレビューする場合、ツール（特に codex）は **前ラウンドで棄却した誤指摘を繰り返し再提起する**ことがある（差分とリポジトリ全体しか見ておらず、過去の棄却判断を知らないため）。実例として、ある PR では codex が同一の誤指摘（ルートグループ独立を誤認した `<html lang>` 汚染）を 6 ラウンド連続で再提起した。

**対策**: 過去ラウンドで棄却した指摘を「棄却台帳」としてプロンプト冒頭に明示注入する。

1. Phase 1.5 で取得した過去ラウンドの review body（自分が投稿した統合サマリーの「事実検証で棄却した指摘」節）から、棄却済み指摘を抽出する。
2. 3 ツールすべてのプロンプト冒頭に以下を付与:
   ```
   ## 過去ラウンドで棄却済みの誤指摘（再提起禁止）
   1. [禁止] <誤指摘の要約>
      - 棄却理由: <一次情報に基づく根拠>
   ...
   ```
3. これにより同一誤指摘の再出力が抑制され、各ラウンドが新規指摘に集中できる（実証済み）。

#### multi-review 固有の補足

| 項目 | 内容 |
|------|------|
| プロンプトの内容 | cc-code-review / cc-security へは「対象説明 + 差分取得コマンド + 作業ディレクトリ + 棄却台帳」のみ（差分はエージェントが取得）。観点・出力形式・チェックリストはエージェント定義が SSOT。codex は codex skill のコマンドをそのまま使う（差分は埋め込み） |
| 統合・検証は親の責務 | 統合・重複除外・事実確認は Phase 3〜4 で親 Claude が行う。サブエージェントには fact-check 用 MCP を持たせず、検証は親に集約する |
| stdin パイプ問題 | codex の `No prompt provided via stdin.` 回避（事前変数確保）は codex skill 側で SSOT 化済み |

### Phase 3: 結果収集と統合

1. 各バックグラウンドタスクの完了通知を待つ
2. 完了したタスクの出力ファイルを Read で読み取る
3. **失敗したツールがあればリトライ**（最大1回）。リトライも失敗した場合は該当ツールをスキップ
4. 全ツールの結果を統合サマリーにまとめる

#### 統合サマリーのフォーマット

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価

常設 3 列に加え、spawn した specialist の列を動的に追加する（spawn しなかった specialist の列は出さない）:

| カテゴリ | cc-code-review | cc-security-review | codex | （spawn 時）typescript-reviewer | … |
|---------|-----------|-------------------|-------|--------------------------------|---|
| MUST    | N件       | N件               | N件   | N件                            | … |
| SHOULD  | N件       | N件               | N件   | N件                            | … |
| NITS    | N件       | N件               | N件   | N件                            | … |
| GOOD    | N件       | N件               | N件   | N件                            | … |

### セキュリティ
- 総合リスクレベル: <Level>
- 検出された脆弱性数: N件

### [MUST] 修正必須（全ツール統合）
{ファイル:行番号でグループ化した指摘一覧}

### [SHOULD] 修正推奨（全ツール統合）
{ファイル:行番号でグループ化した指摘一覧}

### [NITS] 軽微な提案
{指摘一覧}

### [GOOD] 良い実装
{称賛すべき点の一覧}

### 横断まとめ

| 観点 | 結果 |
|------|------|
| バグ・論理エラー | ... |
| 設計・アーキテクチャ | ... |
| セキュリティ | ... |
| 後方互換性 | ... |
| テスト | ... |
```

#### 統合時の事実確認（親 Claude の責務）

レビューツール（cc-code-review / cc-security-review サブエージェント / codex）が出力する **断定的な主張** は、親 Claude（multi-review 実行者）が必ず一次情報で検証する。サブエージェント／codex は差分中心の限定コンテキストで動くため、**検証責務は親側に集約** する（fact-check 用の context7 等の MCP は親が持つ。サブエージェントには意図的に持たせず、「生成はサブエージェント・検証は親」の分業を明確にしている）。誤情報を自信満々に PR コメントとして投稿してしまうリスクを防ぐ。

##### 検証カテゴリ A: 技術的主張（ライブラリ・フレームワーク・言語仕様）

###### 検証対象の例

- 「ライブラリ X は機能 Y を **サポートしていない**」のような否定的断定
- 「API Z は **deprecated** / **使えない**」のような状態主張
- 「型システム T は **挙動 W になる**」のような仕様主張
- 学習データのカットオフ後にリリースされた可能性のある機能への言及

###### 検証手段（**3 段階すべて実施** が原則）

1. **context7 MCP**（`mcp__context7__resolve-library-id` → `mcp__context7__query-docs`）: 公式ドキュメントの最新版を直接照会
2. **実装の実体確認**（必須・最も信頼できる）: `node_modules` 直接確認で実装の有無を判定
   - pnpm: `find node_modules/.pnpm -maxdepth 1 -name "<lib>@*" -type d` で実体パスを特定し、export ファイル（`*.d.ts` / `index.js`）を Read / ls
   - npm/yarn: `node_modules/<lib>` を直接確認
   - **ドキュメント記載の有無と実装の有無は別問題**（ドキュメント未整備でも実装されているケース、逆もある）
3. **URL 引用前の WebFetch 検証**（必須・URL を本文に書く場合）: 引用する URL のページに **該当記述が実際にあるか** を WebFetch で確認する。context7 はドキュメント全体（legacy ページ含む）から記述を拾うため、メインドキュメントに記載があるとは限らない

###### よくある誤りパターン

- ❌ context7 が `/docs/foo` での記述を拾ったと思い込み、実際は `/docs/foo-legacy` にしか記載がなかった
- ❌ ドキュメントに記載がないことを「実装サポート無し」と断定したが、`node_modules` には実装ファイルが存在した
- ❌ コメント本文に URL を書いたが、その URL のページに該当記述が無かった

これらは **読み手から「裏取りしていない」と即座に見抜かれる** 誤りで、レビュー全体の信頼を損なう。URL を引用する際は引用元ページの該当箇所を WebFetch で必ず確認する。

##### 検証カテゴリ B: 設計・運用ポリシーの未定義主張（PR 関連 ADR / Design Doc）

レビューツールが「保持期間が未定義」「retention policy が無い」「ADR が無い」のような **「無いことを根拠とする指摘」** を出す場合、**サブセッションは PR 差分しか見ていない** ため、すでに別ドキュメントで定義されているのを見落としている可能性が高い。

###### 検証対象の例

- 「retention / 保持期間が未定義」「保持ポリシーが無い」
- 「ADR が無い」「Design Doc が無い」「設計判断の根拠が不明」
- 「migration plan が無い」「rollback 方針が無い」
- 「監視・アラートが定義されていない」

###### 検証手段

1. **PR 本文を必ず読む**: `gh pr view <PR番号> --json body` で PR 本文を取得し、ADR / Design Doc / `docs/` 配下のリンクを抽出する
2. **リンク先を Read する**: PR 本文に記載された ADR (`docs/design/adr/*.md`) / Design Doc (`docs/design/design-docs/*/`) を実際に読み、関連キーワード（「保持」「retention」「削除」「migration」等）を Grep で確認する
3. **見つかった場合は指摘を破棄**: 「無い」とする指摘は誤指摘。投稿候補から削除する
4. **見つからなかった場合のみ採用**: 本文に「PR 本文記載の ADR / Design Doc を確認したが該当記述なし」と根拠を添えて投稿する

##### 検証結果の反映

| 検証結果 | 反映方法 |
|---------|---------|
| 誤りが判明（無いと言っているが実在する／否定的断定が事実誤認） | 統合サマリーから当該指摘を **削除** |
| 部分的に正しい（趣旨は合うが詳細に誤りあり） | 訂正版に書き換え。誤主張を出した tool 名と訂正の根拠 URL / ドキュメントパスを本文に明記 |
| 裏が取れた | 主張をそのまま採用。根拠 URL / ドキュメントパスを本文に追加すると説得力が増す |
| 検証不能 | コメント本文に「（未確認の可能性あり）」と明示、または投稿候補から外す |

### Phase 4: 既存レビューとの重複除外

Phase 1.5 で取得した既存レビュー・コメントと、Phase 3 の統合サマリーを突き合わせ、重複指摘を除外する。

#### 重複判定の基準

ファイル:行番号と指摘内容の **両方** を比較する。「同じ趣旨」かどうかは LLM の意味解釈で判定する（語の一致率ではない）:

| 既存指摘の状態 | 対応状況の判定（Phase 1.5 の手順 2） | multi-review の扱い |
|--------------|----------------------------------|-------------------|
| 同じファイル:行番号 + 同じ趣旨 | `resolved` または `fixed-replied` | **除外**（再指摘は冗長） |
| 同じファイル:行番号 + 同じ趣旨 | `open`（未対応） | **除外**（multi-review は新規 review コメントの投稿のみ担う。既存スレッドへの reply 投稿は責務外。補強が必要なら別 skill `review-resolve-loop` 等を使う） |
| 同じファイル:行番号 + **異なる視点（深堀り・反対意見・新たな根拠）** | 問わない | **残す**（新規価値あり、本文に「既存指摘への補足/反論」テンプレを付与。下記参照） |
| 異なるファイル:行番号 | 問わない | **残す** |
| `[GOOD]` で既存レビュアーが言及済み | 問わない | **除外**（重複称賛は冗長） |
| `[GOOD]` で未言及 | 問わない | **残す** |

#### 「異なる視点」のコメント本文テンプレート

「同じファイル:行番号 + 異なる視点」を **残す** ケースでは、コメント本文の冒頭に以下のテンプレを付ける（読み手が既存スレッドとの関係を理解できるようにするため）:

```markdown
**既存指摘への補足/反論** （@<reviewer-login> による <ファイル>:<行> での「<既存指摘の要約 1 行>」）

[MUST] / [SHOULD] / [NITS] のいずれか — 本文...
```

`<reviewer-login>` には bot を含む実 login（例: `coderabbitai[bot]`、`sasamuku`）を入れる。`<既存指摘の要約 1 行>` は既存指摘本文を 30〜60 字に圧縮する。

**注意**: テンプレに署名は含めない。投稿時に「PR コメント投稿手順」の署名ルールが自動で末尾に付与されるため、テンプレ側で署名を書くと **二重署名** になる。

#### bot レビューのノイズ除外

以下の login と本文パターンの組合せに合致するレビュー・コメントは **重複判定の対象から外す**（中身がないため）:

| login | 除外パターン（本文に含まれる文字列、いずれか） |
|-------|---------------------------------------|
| `coderabbitai[bot]` | `Walkthrough`、`Reviews paused`、`auto-pause_after_reviewed_commits`、`✅ Addressed in commit` 単独 |
| `devin-ai-integration[bot]` | `No Issues Found`、`No potential bugs to report` |
| `claude[bot]` | （除外なし。本文を中身として扱う） |
| `github-actions[bot]` | （内容に応じて。CI 通知のみなら除外） |

**判定の進め方**: login が上記リストにマッチし、かつ本文が除外パターンに一致する場合のみ除外。`coderabbitai[bot]` の **Actionable comments** 等の実質的な指摘は除外せず、Phase 4 の重複判定対象に含める。

#### 重複除外結果の提示

統合サマリーの末尾に以下を追記:

```markdown
### 既存レビュー指摘との重複チェック

| 既存指摘（要約） | 既存レビュアー | 対応状況 | multi-review との重複 | 判定 |
|----------------|--------------|---------|--------------------|------|
| <指摘要約 1> | sasamuku (self-review) | Fixed in c6c81c4 | cc-code-review SHOULD #1 と同趣旨 | 除外 |
| <指摘要約 2> | claude[bot] | 未対応 | cc-security Info と同趣旨 | 除外 |
| <指摘要約 3> | （対応する既存指摘なし） | - | - | 残す |

### 投稿候補（重複除外後）

| カテゴリ | 件数（除外前 → 除外後） |
|---------|---------------------|
| MUST    | N → M               |
| SHOULD  | N → M               |
| NITS    | N → M               |
| GOOD    | N → M               |
```

### Phase 5: ユーザー確認と PR コメント投稿

1. 重複除外後の統合サマリーをユーザーに表示する
2. **AskUserQuestion で投稿方法を確認する**（`notify` で通知音。存在しない環境ではスキップ）。質問文には投稿対象のインライン件数（重複除外後の N 件）を明示し、以下の 3 択を提示する:

   | 選択肢 | 内容 |
   |--------|------|
   | **サマリーを body に含めて投稿** | レビュー本体の `body` に統合サマリー（セキュリティ評価・事実検証で棄却した指摘・GOOD・重複チェック等）を記載し、インラインコメント（重複除外後の MUST/SHOULD/NITS）を付けて投稿（submit）する |
   | **body なしで投稿** | インラインコメントのみ投稿。`body` は付けない |
   | **投稿しない** | 統合サマリーの表示のみで終了 |

3. **「サマリーを body に含めて投稿」/「body なしで投稿」が選ばれた場合**: 下記「PR コメント投稿手順」の対応する方法で投稿する。
4. **「投稿しない」が選ばれた場合**: 統合サマリーの表示のみで終了。

## PR コメント投稿手順

### 署名ルール

Claude がレビューコメントを作成する際は、コメント末尾に必ず署名を付与する:

```
コメント本文

---
*Co-Authored-By: Claude {モデル名} <noreply@anthropic.com>*
```

`{モデル名}` には現在実行中のモデルを **山括弧なしで** 入れる（例: `Opus 4.8 (1M context)`、`Sonnet 4.6 (1M context)`）。会話冒頭のシステム情報に記載のモデル名を採用する。`{モデル名}` プレースホルダーをそのまま残してはならない。

**重要（markdown レンダリングのバグ回避）**: モデル名を `<Sonnet 4.6>` のように **山括弧で囲まないこと**。`< >` は markdown/HTML でタグとして解釈され、表示時にモデル名が消える。正しくは `Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>`（モデル名は裸、メールアドレスのみ山括弧）。

### 投稿方法の対応（Phase 5 の回答に対応）

| Phase 5 の選択 | 投稿方法 | submit |
|---------------|---------|--------|
| サマリーを body に含めて投稿 | 下記「A. サマリー付きで submit」。`event: "COMMENT"` + `body`（統合サマリー）+ `comments`（インライン） | 即時 submit（body が即表示される） |
| body なしで投稿 | 下記「B. Pending Review 作成」または「A」で `body` を空にする。デフォルトは Pending（`event` 省略）でユーザーに submit を委ねる | Pending（ユーザーが GitHub UI で submit） |

### A. サマリー付きで submit（body にサマリー + インライン）

`event: "COMMENT"` を指定すると即座に submit される（`body` とインラインが即表示）。`body` には Phase 3〜4 の統合サマリーを記載する。

```bash
cat <<'PAYLOAD' | gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --method POST --input -
{
  "event": "COMMENT",
  "body": "## 🤖 Multi-Review 統合レビュー結果\n\n（セキュリティ評価・事実検証で棄却した指摘・GOOD・既存レビュー重複チェック等のサマリー）\n\n---\n*Co-Authored-By: Claude {モデル名} <noreply@anthropic.com>*",
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[SHOULD] コメント本文\n\n---\n*Co-Authored-By: Claude {モデル名} <noreply@anthropic.com>*"
    }
  ]
}
PAYLOAD
```

- `body` の末尾にも署名を付ける（インライン各コメントとは別に 1 つ）。
- インラインコメントは差分行（diff hunk 内）にしか付けられない。差分外ファイルへの指摘は body サマリーに記載するか、関連する差分内ファイルの行に紐付ける。

### B. Pending Review 作成（body なし・インラインのみ・ユーザーが submit）

### 1. 既存の Pending Review を確認

```bash
gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews \
  --jq '.[] | select(.state == "PENDING") | {id, state, user: .user.login}'
```

### 2. Pending Review がない場合: 新規作成

`event` フィールドを **省略** すると pending 状態になる（`event: "PENDING"` を明示的に指定すると `422` エラー）。

```bash
cat <<'PAYLOAD' | gh api repos/{owner}/{repo}/pulls/{PR番号}/reviews --method POST --input -
{
  "comments": [
    {
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[SHOULD] コメント本文\n\n---\n*Co-Authored-By: Claude {モデル名} <noreply@anthropic.com>*"
    }
  ]
}
PAYLOAD
```

### 3. Pending Review が既にある場合: GraphQL でコメント追加

REST API では既存の pending review にコメントを追加できないため、GraphQL API を使用する。

#### 3.1. Node ID を取得

```bash
gh api graphql -f query='
{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {PR番号}) {
      reviews(states: PENDING, first: 5) {
        nodes {
          id
          state
          author { login }
        }
      }
    }
  }
}'
```

#### 3.2. コメントを追加

```bash
cat <<'GQL' | gh api graphql --input -
{
  "query": "mutation($input: AddPullRequestReviewThreadInput!) { addPullRequestReviewThread(input: $input) { thread { id comments(first: 1) { nodes { id body } } } } }",
  "variables": {
    "input": {
      "pullRequestReviewId": "PRR_kwDOxxxxxxx",
      "path": "src/example.ts",
      "line": 10,
      "side": "RIGHT",
      "body": "[SHOULD] コメント本文\n\n---\n*Co-Authored-By: Claude {モデル名} <noreply@anthropic.com>*"
    }
  }
}
GQL
```

### コメント対象の選定（Phase 4 の重複除外後）

- **[MUST]** と **[SHOULD]**（重複除外後の新規指摘のみ）をインラインコメントとして投稿する
- **[GOOD]**（既存レビュアーが未言及のもののみ）は称賛コメントとして投稿する（数が多い場合は代表的なものに絞る）
- **[NITS]** は投稿するかどうかをユーザー判断に委ねる
- 既存指摘と同じファイル:行番号で **異なる視点** のときは、Phase 4 の「異なる視点のコメント本文テンプレート」を適用して投稿する
- submit はユーザーに委ねる（Pending 状態のまま）

### コメント本文プレフィクス

multi-review が投稿するインラインコメントの本文先頭には、必ず Phase 3 の統合分類に対応するプレフィクスを付ける:

| 統合分類 | プレフィクス | 用途 |
|---------|-----------|------|
| MUST    | `[MUST]`     | 修正必須（バグ・セキュリティ・設計違反） |
| SHOULD  | `[SHOULD]`   | 修正推奨 |
| NITS    | `[NITS]`     | 軽微な提案 |
| GOOD    | `[GOOD]`     | 称賛 |

**プロジェクト独自 prefix の自動判定**: PR 本文に独自のレビュー prefix 規約（例: `<!-- for AI code review rule -->` ブロックや「以下の prefix をつけてください」という記述で `[must]/[imo]/[nits]/[typo]/[ask]/[fyi]` 等が指定されている場合）があれば、Phase 1.5 で取得した PR 本文から検出し、**そのプロジェクト規約に合わせて投稿する**。統合分類との対応例: MUST→`[must]`、SHOULD→`[imo]`、NITS→`[nits]`、GOOD→`[fyi]` または称賛。検出した規約はユーザーへの提示時に「PR 規約の prefix（`[must]/[imo]` 等）に合わせる」と明示する。

**デフォルト**: 独自規約が検出できない場合は `[MUST]/[SHOULD]/[NITS]/[GOOD]` の 4 種に統一する。Conventional Comments 記法（`[imo]` `[ask]` `[fyi]` 等）はデフォルトでは使わない。判断に迷う場合はユーザーに確認する。

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| cc-code-review / cc-security サブエージェントの失敗・スキップ | 1回リトライ。再失敗なら該当ツールをスキップして残りで続行 |
| 動的 specialist の失敗・未定義（`<lang>-reviewer` 未配備） | 1回リトライ。再失敗なら該当 specialist のみスキップし、常設 3 ツール + 他 specialist で続行（specialist は補強レイヤのため必須ではない） |
| `cc-code-review` / `cc-security-review` サブエージェント未定義 | `~/.claude/agents/` に定義があるか確認を案内（chezmoi apply 済みか）。該当ツールをスキップ |
| `codex` コマンド未発見 | 警告を出力し、残り2ツール（cc-code-review, cc-security-review サブエージェント）のみで続行 |
| codex が `No prompt provided via stdin.` で終了 | 差分を事前変数確保するパターンで1回リトライ（codex skill 参照） |
| codex 結果ファイルにログ混入 | `-o <FILE>` 形式になっているか確認（`> file 2>&1` 併合をやめる） |
| 個別ツールのタイムアウト | 1回リトライ。2回目も失敗なら該当ツールをスキップ |
| 空の差分 | 「レビュー対象の差分がありません」と報告して終了 |
| PR番号が無効 | エラーメッセージを表示して終了 |
| Pending Review 作成失敗 | エラー内容を表示してユーザーに報告 |
| 全ツール失敗 | エラーサマリーを出力して終了 |

## 注意事項

### コスト管理

- 常設 3 ツール並列実行は合計コストが高い（cc-code-review / cc-security-review サブエージェント 2 つ + Codex CLI 1 つ）
- cc-code-review / cc-security-review はメインセッションのモデルを継承（`model: inherit`）。コストを抑えたい場合は Agent 呼び出し時に `model: "sonnet"` を指定、または個別スキル（`cc-code-review` 等）を直接使用する
- 動的 specialist は **マッチした言語のみ** spawn し、`model: sonnet`（エージェント frontmatter 固定）で動くため、的を絞った追加コストに留まる。非対象言語の PR では追加コストゼロ。なお cc-code-review / cc-security-review は `model: inherit`（呼び出し元モデルに依存、Opus セッションでは高コスト）なのに対し、specialist は frontmatter で sonnet に固定されるため相対的に安価
- **architecture-reviewer（#223）は最もコストが高い**（repo tree・既存モジュール・設計ドキュメントを横断スキャンするため）。これを毎 PR で走らせるのは高コストなので、**`--arch` opt-in または pr-workflow の large tier のときのみ** spawn する（デフォルトでは走らせない）。`model: sonnet` 固定で相対的に安価に抑えつつ、走らせる PR を絞ることでコストを管理する（＝ #223 の per-PR コスト方針）。

### jq の否定演算子

Claude Code の Bash ツールでは `!` が履歴展開として解釈されるため、jq の否定比較演算子は使用できない。代わりに `select(.user.login | startswith("coderabbitai") | not)` パターンを使用する。
