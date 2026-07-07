---
name: review-fleet
description: |
  自分のレビュー依頼が来ている複数の PR に対し、multi-review をバッチ適用する
  orchestrator。収集 → 分類 → 計画表 → 承認 GATE → 直列実行 → 報告。
  トリガー: "review-fleet", "レビュー依頼をまとめて処理して", "PR レビューをバッチで"。
  使用場面: レビュー依頼が複数溜まっていて 1 件ずつ /multi-review を回すのが重いとき。
argument-hint: "[PR URL | owner/repo#番号 | 番号 ...] [--limit=N] [--dry-run] [--post]"
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

引数形式（PR URL / `owner/repo#N` / bare number / auto-detect の 4-form パーサ）の妥当性検証は multi-review SSOT で定義される（review-fleet は Phase 4 で multi-review へ委譲し、そこで validate される）。

## 安全原則（絶対遵守）

- **Approve / Request Changes を自動で送らない**。`--post` 時も `event: "COMMENT"` 固定。
- **GATE（Phase 3 の承認）通過前に一切の書き込み操作をしない**。
- **署名・AI クレジット禁止**（PR コメント本文含む。`~/AGENTS.md` の global ルール準拠）。
- **silent truncation 禁止**。`--limit` に達して溢れた場合は、Phase 3 の計画表末尾に溢れ件数を明記する。

## Phase 1: 収集

引数で PR URL / 番号が明示された場合はそれを対象とする。**owner/repo を先に確定**するため、`--repo` を伴う `gh pr view` で個別に情報取得する:

```bash
# owner/repo#N 形式または PR URL の場合: owner/repo が引数から取れる
gh pr view <番号> --repo <owner/repo> \
  --json number,title,url,repository,isDraft,author,mergeable,mergeStateStatus,labels

# PR 番号のみの場合: 上記から --repo を省略（cwd の repo を暗黙で使う）
gh pr view <番号> \
  --json number,title,url,repository,isDraft,author,mergeable,mergeStateStatus,labels
```

引数明示の場合の draft 例外は下記 bullet を参照（コマンドブロックの外に集約）。

未指定時は横断検索する:

```bash
gh search prs --review-requested=@me --state=open --limit "${LIMIT:-30}" \
  --json number,title,url,repository,updatedAt,author,isDraft,labels
```

- **`gh search prs --json` は `mergeable` を受け付けない**（実機の Available fields に含まれず、指定すると `Unknown JSON field: "mergeable"` で exit 1）。search 段では `labels` のみを取り、`mergeable`/`mergeStateStatus` は Phase 2 の per-PR 追加取得で補う（次項参照）。
- **Phase 2 直前に per-PR で mergeable/mergeStateStatus を追加取得する**（search で拾えないため）:

  ```bash
  gh pr view <番号> --repo <owner/repo> --json mergeable,mergeStateStatus,labels,title
  ```

  `<owner/repo>` は Phase 1 の search 結果 `.repository.nameWithOwner` からそのまま渡す。
- **各フィールドの役割**:
  - `isDraft` — draft state（`gh pr ready` 前の draft PR）の判定
  - `labels` — `Draft` / `WIP` 等のテキストラベルによる WIP 判定（draft state とは別軸）
  - `mergeable` / `mergeStateStatus` — マージコンフリクト / 非同期チェック中（UNKNOWN）判定
- **draft PR は除外**する（`isDraft == true`）。**ただし引数で明示指定された PR は draft state（`isDraft == true`）でも `Draft`/`WIP` ラベルでも C に落とさない**（明示 = user が意図的に対象化していると解釈）。明示指定 PR は Phase 3 の計画表で `[draft]` / `[WIP]` タグを付けて可視化し、user が改めて対象化するか判断できるようにする（silent drop 禁止）。
- **自分が author の PR は除外**する（`author.login` が自分自身のもの。セルフレビュー依頼は対象外）。
- `--limit` に達して溢れている可能性がある場合（結果件数が limit と一致）、Phase 3 の計画表末尾に「上限 N 件に到達、さらに溢れがある可能性あり」と明記する。

## Phase 2: 分類

収集した各 PR を 3 段階に分類する。**判定に迷う場合は安全側の C に倒す**。

| 分類 | 条件 |
|------|------|
| **A（レビュー可）** | `gh pr diff --repo <owner/repo> <番号>` が正常に取得でき、diff サイズが妥当（通常規模） |
| **B（大規模）** | diff が大きい、または複数モジュールにまたがる。`/multi-review --arch` を推奨するが強制はしない（Phase 3 で user が選択） |
| **C（除外）** | `mergeStateStatus in {DIRTY, BLOCKED}`（コンフリクト / merge blocked）、WIP マーカー（タイトルの `[WIP]` / `WIP:`、または `Draft` ラベル）あり、または diff 取得不可。**分類が不確実な場合もここに倒す** |

- **mergeable の UNKNOWN 扱い**: `mergeable` は非同期チェック中に `"UNKNOWN"` を返す（GraphQL `MergeableState` enum: `MERGEABLE` / `CONFLICTING` / `UNKNOWN`）。UNKNOWN を C に倒すと push 直後の健全な PR まで silent 除外されるため、**主判定は `mergeStateStatus`** を使う（`CLEAN`/`HAS_HOOKS`/`UNSTABLE` → A/B 側、`DIRTY`/`BLOCKED` → C、それ以外は明示保留として計画表で理由を出す）。`mergeable` は補助情報として計画表に記載する。
- 分類根拠（`mergeStateStatus` / `labels` / diff サイズ の値と、それが A/B/C 判定にどう作用したか）は Phase 3 の計画表に一言添える。
- **draft の扱い**: 引数で明示指定された PR は `isDraft == true`（draft state）でも `Draft`/`WIP` ラベルでも C に倒さず、通常の A/B 判定を行う（`[draft]` / `[WIP]` タグは計画表に付けて可視化）。自動収集分の draft は Phase 1 の `isDraft` フィルタで除外済みのためここには来ない。

## Phase 3: 計画表 + 承認 GATE（1 回の包括承認）

以下の計画表を提示する:

| repo | PR | tier | reviewer 構成 | 備考 |
|------|----|----|--------------|------|
| owner/repo-a | #123 | A | cc-code-review + cc-security-review + codex + (自動検出 specialist) | |
| owner/repo-b | #456 | B | 同上（`--arch` 推奨） | 大規模diff |
| owner/repo-c | #789 | C（除外） | - | WIP ラベルあり |

- **コスト警告を必ず明示する**: `multi-review` は Opus ベースのレビュアー（cc-code-review / cc-security-review、`model: inherit`）を含むため、総コストは **PR 件数 × reviewer 構成**で積み上がる。計画表の直後にこの旨を一文で明記する。
- reviewer 構成は `multi-review` の動的 specialist roster（言語/ドメイン検出）を踏襲し、diff の変更ファイルから自動検出したものを表示する。
- **B 分類 PR に `--arch` を付けるかは Phase 3 の追加質問で確定する**（B が 0 件のときはこの質問を省略）。B が 1 件以上あれば下記の 2 問目を提示する。

**AskUserQuestion で対象を確認する**（house 規約: 自由入力は auto-provided Other に任せ、選択肢には free-form の受け皿を置かない）:

| 選択肢 | 内容 |
|--------|------|
| 全部（表示の全 PR） (Recommended) | 分類 A・B のすべてを Phase 4 で処理する |
| しない | 何もせず終了 |

- 「一部の PR だけ」対応したい場合、user は **Other（自動提供）** に対象 PR 番号を空白区切りで入力する。skill 側の選択肢に「番号指定」を独自に置かない。
- **B 分類が 1 件以上あるとき**は 2 問目で `--arch` の適用範囲を訊く:

  | 選択肢 | 内容 |
  |--------|------|
  | B 分類にのみ `--arch` を付ける (Recommended) | 大規模 diff だけ architecture-reviewer を追加する |
  | 全 PR に `--arch` を付ける | A・B すべてで aggregate-view レビュアーを走らせる（コスト増を許容） |
  | どの PR にも `--arch` を付けない | 通常の常設 3 ツール（+ 動的 specialist）だけで処理する |

- `--dry-run` は**この計画表提示までで終了**し、Phase 4 には進まない（AskUserQuestion も呼ばない）。
- 承認が得られなければ Phase 4 に進まない。

## Phase 4: バッチ実行（PR 単位は直列）

承認された PR を **1 件ずつ直列**で処理する。並列にしない理由は明確: `/multi-review` は 1 PR あたり
すでに 3〜5 個のサブエージェント（常設 3 ツール + 動的 specialist、`--arch` 時はさらに 1 つ）を
**並列**起動する。PR 単位まで並列化すると同時実行エージェント数が N 倍に膨れ上がり、
ワークフローの並行数上限とコストの両方を超過する。したがって review-fleet は「PR は直列、
reviewer は `/multi-review` 内で並列」という 2 層構造を維持する。

各承認済み PR について:

1. Skill ツールで `multi-review` を呼び出す。**引数は必ず `owner/repo#PR番号` 形式（または PR URL）で渡す**（PR 番号だけ渡すと multi-review が cwd を repo に解決してしまい、cross-repo バッチで他 repo の同番号 PR にヒットする事故が起きる）。Phase 1 の `--json` で取得した `repository.nameWithOwner` を owner/repo としてそのまま使う。
2. Phase 3 の 2 問目で `--arch` を適用すると決めた PR（B 分類のみ / 全 PR / どれにも付けない、のいずれか）については、`multi-review` 呼び出し時に `--arch` を付与する。
3. `multi-review` 内の Phase 5（投稿確認）は本 skill の Phase 5 方針（下記）に委ねる形で処理する。
4. 1 PR の完了（投稿またはサマリー確定）を待ってから次の PR に進む。
5. 失敗した PR は 1 回までリトライ。再失敗ならスキップし、Phase 5 の報告に「失敗」として記載する。

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
