---
name: self-evaluate
description: GitHub上の開発実績を定量的・定性的に分析し、単価交渉に使える自己評価レポートを生成する。PRやIssue、Discussionのデータをgh cliで収集し、生産性・品質・市場価値を評価する。
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Glob
argument-hint: <repo1> [repo2] [--since YYYY-MM-DD]
---

# 自己評価レポート作成スキル

## 引数
- 対象リポジトリ: `$0` `$1` ...（スペース区切りで複数指定可能）
- `--since YYYY-MM-DD`（オプション）: 評価期間の開始日。省略時は全期間を対象とする

引数が不足している場合は、ユーザーに確認してから進めること。

## 事前準備

GitHubユーザー名は `gh api user --jq .login` で取得し、以降 `$USERNAME` として使用する。

## 実行手順

### Step 1: データ収集

指定された全リポジトリに対して、以下のghコマンドを実行し、生データをJSON形式で収集する。
リポジトリごとにデータを分けて保存し、最終的に統合分析する。

`--since` が指定されている場合、各クエリに `created:>=$SINCE_DATE` フィルタを適用すること。

各リポジトリについて以下を実行:

```bash
# 認証状態の確認
gh auth status

# マージ済みPR一覧
gh pr list --repo <repo> --author $USERNAME --state merged --limit 500 --json number,title,createdAt,mergedAt,additions,deletions,changedFiles,labels,reviewDecision,body,files

# クローズ済みIssue一覧
gh issue list --repo <repo> --assignee $USERNAME --state closed --limit 500 --json number,title,createdAt,closedAt,labels,body

# PRごとのレビュー情報（コメント数を含む）
gh pr list --repo <repo> --author $USERNAME --state merged --limit 500 --json number,reviews,comments,reviewDecision,reviewRequests

# レビュアーとして参加したPR
gh pr list --repo <repo> --state merged --limit 500 --search "reviewed-by:$USERNAME" --json number,title,createdAt,mergedAt

# コミット統計
gh api "repos/<repo>/stats/contributors" --jq ".[] | select(.author.login == \"$USERNAME\")"

# AI共著コミットの検出（Co-Authored-Byヘッダー解析用）
# 対象リポジトリをcloneまたはローカルにある場合:
git log --author="$USERNAME" --grep="Co-Authored-By" --oneline --since="$SINCE_DATE" | wc -l
git log --author="$USERNAME" --oneline --since="$SINCE_DATE" | wc -l

# GitHub Discussions データ（GraphQL API）
gh api graphql -f query='
  query($owner: String!, $repo: String!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      discussions(first: 100, after: $cursor) {
        nodes {
          number
          title
          author { login }
          category { name }
          createdAt
          comments(first: 100) {
            totalCount
            nodes {
              author { login }
              createdAt
              isAnswer
            }
          }
          labels(first: 10) { nodes { name } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
' -f owner=<owner> -f repo=<repo>
```

**注意:**
- `gh auth status` でログイン状態を事前確認すること
- APIレートリミットに注意し、必要に応じてsleepを挟むこと
- データが取得できなかったリポジトリはスキップし、レポートにその旨を記載すること
- Discussions機能が無効なリポジトリではGraphQLクエリがエラーになるため、エラー時はスキップすること

### Step 2: 定量分析

収集したデータから以下の指標を算出する。複数リポジトリの場合は、リポジトリ別と全体の両方を算出すること。

#### 生産性指標
- マージ済みPR総数（リポジトリ別 + 合計）
- 月あたりの平均PR数
- PR作成からマージまでの平均リードタイム（時間単位）
- 総追加行数 / 総削除行数 / 変更ファイル数
- 1PRあたりの平均変更規模（追加+削除行数）
- PR規模の分布:
  - Small: < 50行（追加+削除）
  - Medium: 50〜200行
  - Large: 200〜500行
  - XL: 500行以上
- 最も生産性が高かった月とその実績

#### 品質指標
- PRあたりのレビューコメント数（中央値・P90）
- 低コメントPR率: レビューコメント2件以下で承認されたPRの割合（コードの成熟度を示す）
- レビューイテレーション数: PRあたりのレビューコメント→修正コミットのサイクル数（中央値）
- バグ修正PR比率（タイトルやラベルに fix / bug / hotfix を含むPR）

#### レビュー貢献
- 他メンバーのPRをレビューした件数
- 自分のPR数に対するレビュー比率

#### コミット頻度
- 週あたりの平均コミット数
- アクティブ週の割合（1コミット以上ある週 / 全体の週数）

#### 貢献トレンド
- 月別のPR数・コミット数の推移（テキストベースのバーチャート）
- 直近3ヶ月 vs 前3ヶ月の生産性比較（成長率を算出）
- 生産性の推移が上昇・安定・下降のいずれかを判定

#### 知識共有・意思決定貢献（Discussion）
- 作成したDiscussion数（カテゴリ別分布）
- 他者のDiscussionへのコメント数
- Q&AカテゴリでのAccepted Answer数・採択率
- RFC/提案系Discussionの件数

### Step 3: 定性分析

#### 対応領域の分析
PRタイトル・ラベル・変更ファイルのパスから、以下の領域への貢献分布を分析:
- フロントエンド（*.tsx, *.jsx, *.vue, *.css, components/, pages/ 等）
- バックエンド（*.go, *.py, *.rs, api/, server/, services/ 等）
- インフラ・DevOps（Dockerfile, *.yml, .github/, terraform/ 等）
- テスト（*_test.*, *.spec.*, __tests__/ 等）
- ドキュメント（*.md, docs/ 等）
- データベース（migration*, schema*, *.sql 等）
- AI/エージェント（agents/, skills/, .claude/, tools/, mcp/ 等）

フルスタックとしての貢献度を、領域カバー率として数値化すること。
4領域以上をカバーしている場合、フルスタックエンジニアとして高い希少性があると評価する。

#### 技術的インパクト
- 大規模変更PR（追加行数上位5件）のタイトルと概要
- アーキテクチャ変更・基盤改善に関わるPRの特定と評価

#### AI活用の分析
- AI共著コミットの割合（Co-Authored-Byヘッダーから検出）
- AI共著PRの生産性指標（変更行数/リードタイム）を通常PRと比較
- AI活用による生産性向上の定量評価

### Step 4: 市場価値の推定

以下の観点で市場価値を推定する:

1. **生産性の水準**: 月あたりPR数・リードタイム等が、AI活用時代のシニアエンジニアの水準（月15-25PR程度）と比較してどうか
2. **品質の水準**: 低コメントPR率が70%以上なら高品質、50%以下なら改善余地あり
3. **フルスタックの希少性**: 4領域以上をカバーしている場合、市場での希少性が高い
4. **AI活用の成熟度**: AI共著率が高く、かつ品質指標が維持されている場合、AI活用スキルのプレミアム（+20-40%）を加味
5. **知識共有・技術リーダーシップ**: Discussion活動、レビュー貢献から技術リーダーとしての市場価値を評価
6. **BtoB SaaS / エンタープライズ開発の経験値**
7. **成長トレンド**: 直近の生産性が上昇傾向であれば、将来価値を加味

現在の時給4,500円（税抜。税込4,950円 / 月額約72万円）に対して、推定される市場相場レンジを提示すること。

### Step 5: レポート出力

以下の構成で `self-evaluation-report.md` を作成する。

```markdown
# エンジニア自己評価レポート

**対象者:** $USERNAME
**評価期間:** YYYY/MM/DD 〜 YYYY/MM/DD
**対象リポジトリ:** (リポジトリ一覧)
**レポート生成日:** YYYY/MM/DD

---

## 1. エグゼクティブサマリー
（3〜5行で成果を要約。最もインパクトのある数字を含める）

## 2. 定量実績

### 2.1 生産性
（表形式で指標を一覧表示。リポジトリが複数の場合はリポジトリ別 + 合計）
（PR規模の分布を含める）

### 2.2 品質
（低コメントPR率、レビューイテレーション数等を表形式で）

### 2.3 レビュー貢献
（レビュー件数と比率）

### 2.4 コミット頻度
（週あたりのコミット数とアクティブ率）

### 2.5 貢献トレンド
（月別推移のテキストバーチャート）
（直近3ヶ月 vs 前3ヶ月の成長率）

## 3. 対応領域と技術スタック
（領域カバー率を可視化。フルスタック度を評価）

## 4. 特筆すべき貢献
（大規模PR、アーキテクチャ改善等のハイライト。上位5件を詳述）

## 5. 知識共有・技術リーダーシップ
（Discussion活動: 作成数、コメント数、Accepted Answer数）
（RFC/提案系の貢献）
（レビュー貢献の再掲と評価）

## 6. AI活用・開発生産性
（AI共著コミット/PR比率）
（AI活用PRの生産性比較）
（エージェントスキル・ツール開発の実績: agents/, skills/, .claude/ 等の変更PRリスト）
（CI/CD・DevOps改善の実績: .github/, Dockerfile 等の変更PRリスト）

## 7. リポジトリ別分析
（複数リポジトリの場合、それぞれの貢献度を個別分析）

## 8. 市場価値の推定
（現在の時給 税抜4,500円/税込4,950円 と市場相場の比較。推奨単価レンジを提示）
（各評価観点のスコアと根拠）

## 9. 総合評価
（全体を通じた評価コメントと、単価交渉における推奨アクション）
```

### 注意事項
- 数値は正確にデータから算出し、推測の場合はその旨を明記すること
- 単価交渉の資料として使うため、客観的かつ説得力のある表現を使うこと
- 過度な自画自賛は避け、データに基づいた評価とすること
- データが不足している項目は「データ不足」と記載し、推測で埋めないこと
- 最終的なレポートファイルのパスをユーザーに伝えること
