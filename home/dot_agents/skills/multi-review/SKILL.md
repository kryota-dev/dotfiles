---
name: multi-review
description: |
  3つのレビューツール（Claude Code, Claude Code Security, Codex）を並列でバックグラウンド実行し、
  結果を統合サマリーにまとめた上で、GitHub PR に Pending Review としてインラインコメントを投稿する。
  PRの包括的レビューを一度に実行したい場合に使用する。
  トリガー: "multi-review", "マルチレビュー", "全レビュー", "並列レビュー", "フルレビュー", "3ツールレビュー"
  使用場面: PRのコードレビュー・セキュリティレビュー・Codexレビューを一括で実行したい場合
argument-hint: "<PR番号> (#付きまたは数字のみ)"
---

# Multi Review

3つのレビューツールを並列でバックグラウンド実行し、結果を統合サマリーにまとめる。
既存レビュー（CodeRabbit / Devin / claude[bot] / 人間レビュアー）と重複する指摘を除外したうえで、
統合結果をユーザーに提示し、承認があれば GitHub PR に Pending Review としてインラインコメントを投稿する。

```
引数解析 → 差分取得 → 既存レビュー取得 + 3ツール並列実行 → 結果収集 → 統合サマリー
  → 既存レビューとの重複除外 → ユーザー確認 → Pending Review 投稿
```

**重複除外の意義**: 既存レビュアーが既に同じ指摘をしている場合、再投稿は冗長でレビュアーの認知負荷を増やす。
重複を除外することで、新規視点・追加価値のある指摘のみが投稿される。

## 引数の解釈

以下の優先順で判定する:

1. **PR番号** (`^\d+$` または `^#\d+$`): `gh pr diff <番号>` で差分取得
2. **PR URL** (`github.com` を含む URL): URL から PR 番号を抽出し、`gh pr diff` で差分取得
3. **引数なし**: 現在のブランチに関連する PR を `gh pr view --json number --jq '.number'` で自動検出

## 各レビューツールの設定

| ツール | コマンド | 主要オプション | タイムアウト |
|--------|---------|---------------|------------|
| cc-review | `claude -p` | `--allowedTools "Read,Glob,Grep"`, `--max-turns 10`, `--effort max` | 300000ms |
| cc-security-review | `claude -p` | `--allowedTools "Read,Glob,Grep,Bash(grep *),..."`, `--max-turns 10`, `--effort max`, `--append-system-prompt-file` | 600000ms |
| codex | `codex exec` | `--sandbox read-only`（`--full-auto` は付けない） | 300000ms |

**注意**:
- `--bare` は使わない（OAuth 認証が通らなくなる）。`--model` はデフォルト（ユーザー設定を継承）。
- `--max-turns` は単体スキル（cc-review: 6, cc-security-review: 10）より cc-review 側を 10 まで上げる。並列レビューでは 1 ツールあたりの深掘り余地を取る。
- codex は `--full-auto` を **付けない**（`--sandbox workspace-write` のエイリアスで `--sandbox read-only` と意図が衝突）。レビュー用途では `--sandbox read-only` のみ指定する。

## 実行手順

### Phase 1: 準備

1. **引数を解析**してPR番号を特定する
2. **差分を取得**する: `gh pr diff <PR番号>` を実行。差分が空の場合は「レビュー対象の差分がありません」と報告して終了
3. **リポジトリ情報を取得**する: `gh repo view --json nameWithOwner --jq '.nameWithOwner'` で owner/repo を取得
4. **セキュリティチェックリストのパスを解決**する:
   ```bash
   CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"
   ```
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

3つのツールを **同一メッセージ内の独立した Bash ツール呼び出し** として、すべて `run_in_background: true` で並列発行する。

#### cc-review

```bash
gh pr diff <PR番号> | claude -p \
  --allowedTools "Read,Glob,Grep" \
  --max-turns 10 \
  --effort max \
  --output-format text \
  "$(cat <<'PROMPT'
あなたはシニアソフトウェアエンジニアです。以下のコード差分をレビューしてください。

## レビュー観点

1. バグ・論理エラー: 明らかなバグ、エッジケースの未処理、オフバイワンエラー
2. 設計・アーキテクチャ: 既存パターンとの一貫性、適切な抽象化、責務の分離
3. 可読性・保守性: 命名の適切さ、コメントの過不足、コード複雑度
4. エラーハンドリング: 例外処理の網羅性、エラーメッセージの適切さ
5. パフォーマンス: N+1問題、不要な計算・再描画、メモリリーク
6. テスト: テストの有無、カバレッジ、エッジケースのテスト

## 出力形式

各指摘を以下のカテゴリで分類:
- [MUST] 修正必須（バグ、セキュリティ、設計違反）
- [SHOULD] 修正推奨（品質向上、可読性改善）
- [NITS] 軽微な提案（命名、フォーマット）
- [GOOD] 良い実装（称賛すべき点）

各指摘に、ファイル名:行番号、問題の説明、具体的な修正案を含めてください。
最後にレビューサマリー（カテゴリ別件数 + 総合評価）を付けてください。

## 重要: 技術的主張の確実性

ライブラリ・フレームワーク・言語仕様について断定する場合（例: 「X は Y をサポートしていない」「API Z は deprecated」）、確信が持てないなら必ず本文に **「（未確認）」** または **「（要検証）」** と明示してください。学習データのカットオフ後の変更を見落とすリスクがあるため、自信満々に誤情報を出力するのは避けてください。

確認や質問は不要です。具体的な指摘と修正案を自主的に出力してください。
PROMPT
)"
```

#### cc-security-review

```bash
CHECKLIST="$HOME/.agents/skills/cc-security-review/references/security-checklist.md"

if [ -f "$CHECKLIST" ]; then
  gh pr diff <PR番号> | claude -p \
    --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
    --max-turns 10 \
    --effort max \
    --output-format text \
    --append-system-prompt-file "$CHECKLIST" \
    "$(cat <<'PROMPT'
あなたはセキュリティエンジニアです。以下のコードをセキュリティ観点でレビューしてください。
システムプロンプトで提供されたセキュリティチェックリストに基づいて網羅的に分析してください。

## 分析の進め方

1. まず差分を読み、変更の全体像を把握する
2. セキュリティ上重要な変更を特定する（認証、認可、入力処理、機密情報、外部通信）
3. 必要に応じて Read ツールで周辺コードを参照し、コンテキストを補完する
4. 各脆弱性について、実際の攻撃経路が存在するかを評価する

## 出力形式

### セキュリティサマリー
- 総合リスクレベル: Critical / High / Medium / Low
- 検出された脆弱性数: N件（重大度別）

### 脆弱性一覧
（チェックリストの出力フォーマットに従う）

### 良い実装
セキュリティ上、適切に実装されている点を列挙

### 推奨事項
追加で検討すべきセキュリティ改善策

## 重要: 技術的主張の確実性

ライブラリ・脆弱性 CVE・セキュリティ機能の有無について断定する場合、確信が持てないなら必ず本文に **「（未確認）」** または **「（要検証）」** と明示してください。

確認や質問は不要です。具体的な分析結果と修正案を自主的に出力してください。
PROMPT
)"
else
  gh pr diff <PR番号> | claude -p \
    --allowedTools "Read,Glob,Grep,Bash(grep *),Bash(find *),Bash(git log *),Bash(cat *)" \
    --max-turns 10 \
    --effort max \
    --output-format text \
    "$(cat <<'PROMPT'
あなたはセキュリティエンジニアです。以下のコードをセキュリティ観点でレビューしてください。
OWASP Top 10 を含む包括的なセキュリティ観点で分析してください。
（上記と同じ分析の進め方・出力形式）
確認や質問は不要です。具体的な分析結果と修正案を自主的に出力してください。
PROMPT
)"
fi
```

#### codex

```bash
cat <<'PROMPT' | codex exec --sandbox read-only --cd "$(pwd)" -
PR #<PR番号> のコード差分をレビューしてください。
まず `gh pr diff <PR番号>` で差分を取得し、以下の観点で分析してください。

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

## 重要: 技術的主張の確実性

ライブラリ・フレームワーク・言語仕様について断定する場合、確信が持てないなら必ず本文に **「（未確認）」** または **「（要検証）」** と明示してください。

確認や質問は不要です。具体的な提案・修正案・コード例まで自主的に出力してください。
PROMPT
```

**重要**: 引数に prompt を渡し `"$(cat <<EOF ...)"` で組み立てると、`run_in_background: true` 環境では Bash ツールが stdin をパイプ open 状態で渡すため、`codex exec` は stdin を `<stdin>` ブロックとして読もうとし「Reading additional input from stdin...」のメッセージのみで早期終了する（exit 0、実質 0 行の出力）。stdin から prompt を渡し、引数末尾に `-` を明示することでこの問題を回避する。

`--full-auto` は `--sandbox workspace-write` のエイリアスでレビュー用途では不要なため付けない。詳細は `codex` スキルの「stdin パイプ問題」「`--full-auto` と `--sandbox` の関係」節を参照。

### Phase 3: 結果収集と統合

1. 各バックグラウンドタスクの完了通知を待つ
2. 完了したタスクの出力ファイルを Read で読み取る
3. **失敗したツールがあればリトライ**（最大1回）。リトライも失敗した場合は該当ツールをスキップ
4. 全ツールの結果を統合サマリーにまとめる

#### 統合サマリーのフォーマット

```markdown
## PR #<番号> 統合レビュー結果

### 総合評価

| カテゴリ | cc-review | cc-security-review | codex |
|---------|-----------|-------------------|-------|
| MUST    | N件       | N件               | N件   |
| SHOULD  | N件       | N件               | N件   |
| NITS    | N件       | N件               | N件   |
| GOOD    | N件       | N件               | N件   |

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

レビューツール（cc-review / cc-security-review / codex）が出力する **断定的な主張** は、親 Claude（multi-review 実行者）が必ず一次情報で検証する。サブセッション（`claude -p` / `codex exec`）は **PR 差分しか見ていない・MCP 利用不可** という制約があるため、**検証責務は親側に集約** する。誤情報を自信満々に PR コメントとして投稿してしまうリスクを防ぐ。

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
| <指摘要約 1> | sasamuku (self-review) | Fixed in c6c81c4 | cc-review SHOULD #1 と同趣旨 | 除外 |
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
2. **ユーザーに確認する**: 「Pending Review としてインラインコメントを投稿しますか？投稿対象は重複除外後の N 件です」
   - `notify` コマンドで通知音を鳴らす（コマンドが存在しない環境ではスキップ）
3. **承認された場合**: Pending Review を作成してインラインコメントを投稿する（下記「PR コメント投稿手順」に従う）
4. **拒否された場合**: 統合サマリーの表示のみで終了

## PR コメント投稿手順

### 署名ルール

Claude がレビューコメントを作成する際は、コメント末尾に必ず署名を付与する:

```
コメント本文

---
*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*
```

`<モデル名>` には現在実行中のモデルを入れる（例: `Opus 4.7 (1M context)`、`Sonnet 4.6`）。Claude Code が起動時に `claude-code-version` 等から取得した既知の値を文字列として埋める。動的取得が困難な場合は、ユーザー設定または会話冒頭のシステム情報に記載のモデル名を採用する。`<モデル名>` プレースホルダーをそのまま残してはならない。

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
      "body": "[SHOULD] コメント本文\n\n---\n*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*"
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
      "body": "[SHOULD] コメント本文\n\n---\n*Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>*"
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

**注意**: Conventional Comments 記法の `[imo]` `[ask]` `[fyi]` 等は multi-review では **使わない**。`[MUST]/[SHOULD]/[NITS]/[GOOD]` の 4 種に統一する。プロジェクト独自の prefix ルールがある場合はユーザーに確認する。

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| `claude` コマンド未発見 | Claude Code CLI のインストールを案内して終了 |
| `codex` コマンド未発見 | 警告を出力し、残り2ツール（cc-review, cc-security-review）のみで続行 |
| 個別ツールのタイムアウト | 1回リトライ。2回目も失敗なら該当ツールをスキップ |
| 空の差分 | 「レビュー対象の差分がありません」と報告して終了 |
| PR番号が無効 | エラーメッセージを表示して終了 |
| `Reached max turns` エラー | `--max-turns` を増やしてリトライ |
| Pending Review 作成失敗 | エラー内容を表示してユーザーに報告 |
| 全ツール失敗 | エラーサマリーを出力して終了 |

## 注意事項

### コスト管理

- 3ツール並列実行は合計コストが高い（Claude Code 2セッション + Codex 1セッション）
- コストを抑えたい場合は個別スキル（`cc-review` 等）を直接使用することを推奨

### jq の否定演算子

Claude Code の Bash ツールでは `!` が履歴展開として解釈されるため、jq の否定比較演算子は使用できない。代わりに `select(.user.login | startswith("coderabbitai") | not)` パターンを使用する。

### セキュリティチェックリスト

`$HOME/.agents/skills/cc-security-review/references/security-checklist.md` を参照する。ファイルが存在しない場合はチェックリストなしでレビューを続行する。
