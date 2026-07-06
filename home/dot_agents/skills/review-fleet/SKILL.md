---
name: review-fleet
description: |
  自分のレビュー依頼が来ている複数の PR に対し、multi-review をバッチ適用する
  orchestrator。収集 → 分類 → 計画表 → 承認 GATE → 直列実行 → 報告。
  トリガー: "review-fleet", "レビュー依頼をまとめて処理して", "PR レビューをバッチで"。
  使用場面: レビュー依頼が複数溜まっていて 1 件ずつ /multi-review を回すのが重いとき。
argument-hint: "[PR URL/番号列] [--limit=N] [--dry-run] [--post]"
user-invocable: true
---

# review-fleet

複数 PR のレビュー依頼を **収集 → 分類 → 計画表 + 1 回の承認 GATE → 直列実行 → 報告** で処理する
orchestrator。自分（メインループ）は司令塔に徹し、レビューの実体は `multi-review` へ委任する。
本 skill は `multi-review` を置き換えない——単一 PR の深いレビューロジック（reviewer roster・重複除外・
投稿手順）はすべて `multi-review` が SSOT のまま。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `[PR URL/番号列]` | - | 明示指定時はこれを対象にする（`gh search prs` による自動収集より優先） |
| `--limit` | 30 | Phase 1 の `gh search prs` 取得件数上限 |
| `--dry-run` | off | Phase 3 の計画表を出して終了（Phase 4 の実行に進まない） |
| `--post` | off | Phase 5 で `event: "COMMENT"` として即時投稿する。既定は Pending Review |

**`--post` と `--dry-run` は併用不可**（`--dry-run` はそもそも Phase 4/5 に進まないため矛盾する）。両方指定された場合はエラーを報告して終了する。

## 安全原則（絶対遵守）

- **Approve / Request Changes を自動で送らない**。`--post` 時も `event: "COMMENT"` 固定。
- **GATE（Phase 3 の承認）通過前に一切の書き込み操作をしない**。
- **署名・AI クレジット禁止**（PR コメント本文含む。`~/AGENTS.md` の global ルール準拠）。
- **silent truncation 禁止**。`--limit` に達して溢れた場合は、Phase 3 の計画表末尾に溢れ件数を明記する。

## Phase 1: 収集

引数で PR URL/番号が明示された場合はそれを対象とする（`gh pr view <番号> --json number,title,url,repository,isDraft,author` で個別に情報取得）。

未指定時は横断検索する:

```bash
gh search prs --review-requested=@me --state=open --limit ${LIMIT:-30} \
  --json number,title,url,repository,updatedAt,author,isDraft
```

- **draft PR は除外**する（`isDraft == true`）。
- **自分が author の PR は除外**する（`author.login` が自分自身のもの。セルフレビュー依頼は対象外）。
- `--limit` に達して溢れている可能性がある場合（結果件数が limit と一致）、Phase 3 の計画表末尾に「上限 N 件に到達、さらに溢れがある可能性あり」と明記する。

## Phase 2: 分類

収集した各 PR を 3 段階に分類する。**判定に迷う場合は安全側の C に倒す**。

| 分類 | 条件 |
|------|------|
| **A（レビュー可）** | `gh pr diff` が正常に取得でき、diff サイズが妥当（通常規模） |
| **B（大規模）** | diff が大きい、または複数モジュールにまたがる。`/multi-review --arch` を推奨するが強制はしない（Phase 3 で user が選択） |
| **C（除外）** | マージ間近、マージコンフリクトあり、WIP マーカー（タイトルの `[WIP]` / `WIP:`、または `Draft` ラベル）あり、または diff 取得不可。**分類が不確実な場合もここに倒す** |

分類根拠（何を見て A/B/C と判定したか）は Phase 3 の計画表に一言添える。

## Phase 3: 計画表 + 承認 GATE（1 回の包括承認）

以下の計画表を提示する:

| repo | PR | tier | reviewer 構成 | 備考 |
|------|----|----|--------------|------|
| owner/repo-a | #123 | A | cc-code-review + cc-security-review + codex + (自動検出 specialist) | |
| owner/repo-b | #456 | B | 同上（`--arch` 推奨） | 大規模diff |
| owner/repo-c | #789 | C（除外） | - | WIP ラベルあり |

- **コスト警告を必ず明示する**: `multi-review` は Opus ベースのレビュアー（cc-code-review / cc-security-review、`model: inherit`）を含むため、総コストは **PR 件数 × reviewer 構成**で積み上がる。計画表の直後にこの旨を一文で明記する。
- reviewer 構成は `multi-review` の動的 specialist roster（言語/ドメイン検出）を踏襲し、diff の変更ファイルから自動検出したものを表示する。

**AskUserQuestion で 3 択を提示する**:

| 選択肢 | 内容 |
|--------|------|
| 全部（表示の全 PR） | 分類 A・B のすべてを Phase 4 で処理する |
| 番号指定 | Other で対象 PR 番号のみを数字で入力してもらう |
| しない | 何もせず終了 |

- `--dry-run` は**この計画表提示までで終了**し、Phase 4 には進まない（AskUserQuestion も呼ばない）。
- 承認が得られなければ Phase 4 に進まない。

## Phase 4: バッチ実行（PR 単位は直列）

承認された PR を **1 件ずつ直列**で処理する。並列にしない理由は明確: `/multi-review` は 1 PR あたり
すでに 3〜5 個のサブエージェント（常設 3 ツール + 動的 specialist、`--arch` 時はさらに 1 つ）を
**並列**起動する。PR 単位まで並列化すると同時実行エージェント数が N 倍に膨れ上がり、
ワークフローの並行数上限とコストの両方を超過する。したがって review-fleet は「PR は直列、
reviewer は `/multi-review` 内で並列」という 2 層構造を維持する。

各承認済み PR について:

1. Skill ツールで `multi-review` を呼び出す（対象は当該 PR 番号 / URL）。分類 B で user が `--arch` を選んだ場合はその旨を渡す。
2. `multi-review` 内の Phase 5（投稿確認）は本 skill の Phase 5 方針（下記）に委ねる形で処理する。
3. 1 PR の完了（投稿またはサマリー確定）を待ってから次の PR に進む。
4. 失敗した PR は 1 回までリトライ。再失敗ならスキップし、Phase 5 の報告に「失敗」として記載する。

## Phase 5: 投稿

- **既定（`--post` なし）**: Pending Review として保存する。user が GitHub UI 上でレビュー内容を確認し、自分で submit する。outward action は保守的側に倒すのが既定方針。
- **`--post` 指定時**: `event: "COMMENT"` で即時投稿する。**`APPROVE` / `REQUEST_CHANGES` は絶対に使わない**（安全原則）。

全 PR の処理完了後、最終報告を提示する:

| repo | PR | 判定サマリー | 投稿状態 | リンク |
|------|----|------|--------|------|
| owner/repo-a | #123 | MUST 1 / SHOULD 2 / NITS 1 | Pending（要 submit） | URL |
| owner/repo-b | #456 | MUST 0 / SHOULD 0 | 投稿済み（COMMENT） | URL |

分類 C（除外）で処理しなかった PR も一覧に含め、除外理由を明記する。Phase 1 で `--limit` 溢れがあった場合は、この報告の末尾にも再掲する。

## 他 skill との連携

- **入口**: `repo-radar` が「自分へのレビュー依頼」を P1 として検出したとき、複数件溜まっていれば本 skill へのハンドオフを提案する。
- **単一 PR**: 1 件だけなら `multi-review` を直接使う方が軽い。
- **指摘対応**: レビュー後の指摘反映は `review-resolve-loop` に委ねる（本 skill の範囲外）。

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| `--post` と `--dry-run` の同時指定 | エラーを報告して終了（Phase 1 に進まない） |
| Phase 1 の `gh search prs` が 0 件 | 「レビュー依頼はありません」と報告して終了 |
| 個別 PR の diff 取得失敗 | 分類 C（除外）に倒し、報告に理由を記載 |
| `multi-review` 呼び出しの失敗 | 1 回リトライ。再失敗なら当該 PR をスキップして次に進み、最終報告に「失敗」と記載 |
| 全 PR が分類 C | Phase 3 の計画表に「処理可能な PR がありません」と明記し、承認 GATE を出さずに終了 |
