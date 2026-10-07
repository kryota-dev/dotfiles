---
name: repo-radar
description: |
  自分が関わる全リポジトリを横断スイープし、要対応事項（レビュー依頼・自分の PR の CI 失敗 /
  未解決コメント・Renovate 滞留・assign 済み Issue）を優先度付きの単一レポートにまとめる skill。
  トリガー: "repo-radar", "レーダー", "今日やることある？", "状況スイープ", "横断チェック"
  使用場面: 作業開始時の状況把握、離席後のキャッチアップ。
argument-hint: "[--owners=a,b] [--days=N]"
user-invocable: true
---

# repo-radar

「今、自分の対応を待っているものは何か」を GitHub 横断で 1 コマンドで可視化する。
読み取り専用で、GitHub には何も書き込まない。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--owners` | ログイン中のユーザー（`gh api user --jq .login`） | スイープ対象の owner / org（involves 検索は owner 外もヒットする） |
| `--days` | 14 | 「滞留」と見なす経過日数の閾値 |

## 安全原則

- **GitHub への書き込みを一切しない**（すべて read-only の `gh` 検索・参照）。

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
# OWNER_FLAGS は --owners の各値を `--owner <値>` に展開したもの
gh search prs --author=app/renovate --state=open "${OWNER_FLAGS[@]}" \
  --limit 50 --json number,title,url,repository,createdAt

# 5. 自分が involves の直近更新（メンション・コメント返信待ちの取りこぼし防止）
gh search prs --involves=@me --state=open --limit 30 --json number,title,url,repository,updatedAt

# 6. 定点観測 watchlist: 1〜5 は全て @me スコープのため、
#    誰にも assign されていない issue はここでしか可視化されない。対象 repo は
#    ローカル設定 ~/.config/repo-radar/watchlist（1 行 1 owner/repo、# コメント可。
#    クライアント固有名を含み得るためコミット禁止のローカル専用ファイル）で定義する。
#    ファイルが無い / 空の場合は本検索をスキップし、レポートにその旨を明記する。
while IFS= read -r repo; do
  gh issue list -R "$repo" --state open --limit 50 --json number,title,labels,updatedAt
done < <(grep -vE '^\s*(#|$)' ~/.config/repo-radar/watchlist 2>/dev/null)
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
| P4 | watchlist repo の open issue（定点観測、assign 不問） | 着手待ち。**2 件以上でレポート冒頭に昇格**（backlog #12 コンテンツ修正 SOP テンプレの再開トリガー） |

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

## 定点観測: watchlist open issue <N> 件
（2 件以上のときはレポート冒頭に 1 行で明記する。
watchlist 未設定時は「未設定」と明記）

## 推奨ネクストアクション
1. <最もレバレッジの高い 1 手>
```

**推奨ネクストアクション**では、該当があれば他 skill へのハンドオフを具体的に提案する:

- assign Issue が 2 件以上 → 「依存の少ないものから `pr-workflow` で順に、または subagent で並列に進められます」
- レビュー指摘が溜まった自分の PR → 「`review-resolve-loop` で対応できます」
- **レビュー依頼された他人の PR がある** → 「`multi-review` でレビューできます」

## 運用メモ

- 検索 limit（30/50）を超えて溢れた場合は、溢れた旨をレポート末尾に必ず明記する（silent truncation 禁止）。
