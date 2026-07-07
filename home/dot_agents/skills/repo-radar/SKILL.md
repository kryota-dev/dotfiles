---
name: repo-radar
description: |
  自分が関わる全リポジトリを横断スイープし、要対応事項（レビュー依頼・自分の PR の CI 失敗 /
  未解決コメント・Renovate 滞留・assign 済み Issue）を優先度付きの単一レポートにまとめる skill。
  トリガー: "repo-radar", "レーダー", "今日やることある？", "状況スイープ", "横断チェック"
  使用場面: 作業開始時の状況把握、離席後のキャッチアップ、issue-fleet / renovate-sweep の起点。
argument-hint: "[--owners=a,b] [--days=N] [--post]"
user-invocable: true
---

# repo-radar

「今、自分の対応を待っているものは何か」を GitHub 横断で 1 コマンドで可視化する。
読み取り専用が既定であり、`--post` を付けたときだけ（承認後に）Discussion へ投稿する。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--owners` | kryota-dev,kryota-devs | スイープ対象の owner / org（involves 検索は owner 外もヒットする） |
| `--days` | 14 | 「滞留」と見なす経過日数の閾値 |
| `--post` | off | レポートを daily-planning の Discussion にコメント投稿する（投稿前に承認必須） |

## 安全原則

- 既定では **GitHub への書き込みを一切しない**（すべて read-only の `gh` 検索・参照）。
- `--post` 時も、投稿本文を提示して user 承認を得てからコメントする。

## Phase 1: 収集（並列実行）

以下の検索を**並列の Bash 呼び出し**で一気に取得する（`@me` は gh が解決する）:

```bash
# 1. 自分にレビュー依頼が来ている open PR
gh search prs --review-requested=@me --state=open --limit 30 \
  --json number,title,url,repository,updatedAt,author

# 2. 自分が author の open PR（CI・レビュー状態は後段で詳細取得）
gh search prs --author=@me --state=open --limit 30 \
  --json number,title,url,repository,updatedAt,isDraft

# 3. 自分に assign された open Issue
gh search issues --assignee=@me --state=open --limit 30 \
  --json number,title,url,repository,updatedAt,labels

# 4. Renovate 滞留（owner 横断）
gh search prs --author=app/renovate --state=open --owner kryota-dev --owner kryota-devs \
  --limit 50 --json number,title,url,repository,createdAt

# 5. 自分が involves の直近更新（メンション・コメント返信待ちの取りこぼし防止）
gh search prs --involves=@me --state=open --limit 30 --json number,title,url,repository,updatedAt
```

自分が author の PR（2 の結果）については、repo ごとに詳細を取り直す:

```bash
gh pr view <番号> --repo <owner/name> \
  --json number,title,url,statusCheckRollup,reviewDecision,mergeable,isDraft
# 未解決レビュースレッド数（GraphQL）
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){pullRequest(number:$n){
    reviewThreads(first:50){nodes{isResolved}}}}}' \
  -f o=<owner> -f r=<repo> -F n=<番号> \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved|not)]|length'
```

## Phase 2: 優先度付け

収集結果を以下のルールで格付けする:

| 優先度 | 条件 | 理由 |
|--------|------|------|
| P1 | 自分の PR の CI 赤 / changes_requested、自分へのレビュー依頼 | 他人 or パイプラインをブロックしている |
| P2 | 自分の PR の未解決レビュースレッド、mergeable=CONFLICTING | マージへの直接障害 |
| P3 | Renovate 滞留（`--days` 超過分を強調） | 溜まるほど conflict 率が上がる |
| P4 | assign 済み Issue（更新が古い順） | 着手待ちのバックログ |

## Phase 3: レポート出力

以下の形式で出力する（空のセクションは「なし ✅」と明記して省略しない）:

```markdown
# Repo Radar — <日付 JST>

## P1: 今すぐ（ブロッカー）
| 種別 | repo | 対象 | 状態 | リンク |

## P2: 今日中（自分の PR の障害）
...

## P3: Renovate 滞留 <N> 件
（repo ごとの件数サマリ + 最古の滞留日数）

## P4: バックログ（assign 済み Issue <N> 件）
...

## 推奨ネクストアクション
1. <最もレバレッジの高い 1 手>
```

**推奨ネクストアクション**では、該当があれば他 skill へのハンドオフを具体的に提案する:

- Renovate が 3 件以上 → 「`renovate-sweep --all` で一括処理できます」
- trivial/small 級の assign Issue が 2 件以上 → 「`issue-fleet <番号列>` で並列処理できます」
- レビュー指摘が溜まった自分の PR → 「`review-resolve-loop` で対応できます」
- **レビュー依頼された他人の PR が 2 件以上** → 「`review-fleet` で収集→分類→計画表→バッチ実行できます」（cross-repo でも 1 コマンド）
- **レビュー依頼された他人の PR が 1 件だけ** → 「`multi-review` / `cc-code-review` でレビューできます」

## Phase 4: 投稿（`--post` 時のみ）

`daily-planning` skill の手順で今月分の Daily planning Discussion を特定し、レポートをコメントとして投稿する。**投稿本文を提示して user 承認を得てから実行する**。

## 運用メモ

- 毎朝の定例にする場合は、このレポート生成だけなら read-only なので、Claude Code のスケジュール実行（cron / routine）に載せられる。その設定は本 skill の範囲外とし、user の明示依頼で行う。
- 検索 limit（30/50）を超えて溢れた場合は、溢れた旨をレポート末尾に必ず明記する（silent truncation 禁止）。
