---
name: renovate-sweep
description: |
  open な Renovate PR を一括トリアージする skill。CI 状態と更新種別でリスク分類し、
  要注意 PR は renovate-analyzer サブエージェントで並列深掘りし、user 承認後に安全な PR を一括マージする。
  トリガー: "renovate-sweep", "Renovate まとめて処理", "依存更新 PR を片付けて", "renovate 一括"
  使用場面: Renovate PR が複数溜まっているとき。単一 PR の深掘りだけなら `renovate-analyzer` を直接使う。
argument-hint: "[--repo=owner/name] [--all] [--limit=N]"
user-invocable: true
---

# renovate-sweep

Renovate（bot: `app/renovate`）の open PR を「**収集 → 機械的分類 → 深掘り（必要分のみ）→ 承認 → 一括マージ**」の流れで処理する。1 PR ずつ人間が開いて確認する作業を、承認 1 回のバッチ処理に置き換える。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--repo` | カレントリポジトリ | 対象リポジトリ（`owner/name`） |
| `--all` | off | 自分の owner 配下（kryota-dev / kryota-devs）を横断して収集 |
| `--limit` | 30 | 収集する PR 数の上限 |

## 安全原則（絶対遵守）

- **承認なしのマージは絶対にしない**。トリアージ表を提示し、user がマージ対象を明示承認した PR のみマージする。
- security advisory 付き・conflict 状態・CI 赤の PR は「マージ候補」に**決して入れない**（分析 or 人間対応へ回す）。
- マージ方式はリポジトリの慣習に従う（直近のマージ済み PR の方式を確認。不明なら squash）。

## Phase 1: 収集

```bash
# カレント or --repo 指定
gh pr list --repo <owner/name> --author app/renovate --state open --limit <N> \
  --json number,title,url,labels,mergeable,statusCheckRollup,createdAt

# --all の場合
gh search prs --author app/renovate --state open --owner kryota-dev --owner kryota-devs \
  --limit <N> --json number,title,url,repository
# → repo ごとに上の gh pr list で詳細を取り直す
```

## Phase 2: 機械的分類

各 PR を以下のルールで 3 分類する。判定材料は **タイトルの semver 種別**（Renovate のタイトル規約 `update dependency X to vY`）、**CI 状態**（statusCheckRollup）、**mergeable**、**ラベル**:

| 分類 | 条件 | 扱い |
|------|------|------|
| A: マージ候補 | patch / minor 更新、CI 全緑、mergeable、security advisory なし | 承認後そのままマージ |
| B: 要分析 | major 更新、または CI 赤、または grouped/monorepo 更新、または digest 以外で semver 判定不能 | renovate-analyzer へ委譲 |
| C: 要人間 | conflict、security advisory 付き、Renovate の rebase 停止など | 理由を添えて報告のみ |

- semver 種別はタイトルから `vX.Y.Z` の変化を抽出して判定する。抽出できなければ B に倒す（**安全側に倒す**）。
- CI が pending の PR は数分待って再取得し、それでも pending なら B に倒す。
- `mergeable` は GitHub が遅延計算するため **`UNKNOWN` が頻出する**。`UNKNOWN` は conflict 扱いにせず、一度再取得（`gh pr view <番号> --json mergeable`）してから判定する。再取得後も `UNKNOWN` なら他条件で分類を続行し、Phase 5 のマージ実行時のエラーで検知する（`CONFLICTING` のときだけ C に落とす）。

## Phase 3: 深掘り（B 分類のみ）

B 分類の各 PR について、`renovate-analyzer` サブエージェントを**並列で**起動する（1 メッセージ内で複数 Agent 呼び出し）。各エージェントには repo と PR 番号を渡し、以下を返させる:

- Breaking Changes の有無と影響範囲
- アップデート可否の判定（マージ可 / 修正必要 / 保留推奨）
- 修正が必要な場合の方針

分析結果「マージ可」の PR は A 相当に格上げしてよい（ただしトリアージ表にその旨を明記する）。

## Phase 4: トリアージ表と GATE

全分類・分析が終わったら、以下の表を提示して **user の承認を得る**:

| # | repo | PR | 更新内容 | semver | CI | 分類 | 判定 | 提案 |
|---|------|----|---------|--------|----|------|------|------|

- 「A + 格上げ分をすべてマージ」「番号指定でマージ」「マージしない」を選べる形で提示する。
- **承認された PR 以外には一切の書き込み操作をしない**。

## Phase 5: 一括マージと報告

承認された PR を順次マージする:

```bash
# base が古い場合は先に更新（update-branch 後は CI 完了を待ってからマージ）
gh pr update-branch <番号> --repo <owner/name>
gh pr checks <番号> --repo <owner/name> --watch

gh pr merge <番号> --repo <owner/name> --squash   # 方式はリポジトリ慣習に従う
```

- 同一 repo 内では 1 件マージするたびに残りの mergeable を再確認する（conflict の連鎖を避ける）。
- 失敗した PR は理由（rebase 必要 / CI 赤化など）を添えて報告する。

最終報告:

| 結果 | 件数 | 詳細 |
|------|------|------|
| マージ済み | | PR リンク |
| 修正必要（B） | | 分析サマリと修正方針 |
| 人間対応（C） | | 理由 |

## 他 skill との連携

- **入口**: `repo-radar` が Renovate 滞留を検出したとき、本 skill へのハンドオフを提案する
- **単一 PR の深掘り**: `renovate-analyzer`（Phase 3 が委譲するのと同じサブエージェント）
- **修正が必要な B 分類**: 修正タスク化して `pr-workflow` へ
