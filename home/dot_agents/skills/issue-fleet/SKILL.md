---
name: issue-fleet
description: |
  複数の GitHub Issue を並列 worktree + サブエージェントで同時に実装し、それぞれ draft PR まで進める並列開発の司令塔。
  wtp で worktree を作成し、各サブエージェントへ実装 → 検証 → commit → push → draft PR 作成を委任する。
  トリガー: "issue-fleet", "並列で実装して", "issue をまとめて片付けて", "フリートで進めて"
  使用場面: trivial〜small 級の独立した Issue が複数溜まっているとき（コンテンツ修正・小規模バグ修正・文言変更など）。
argument-hint: "<issue 番号列 or 検索条件> [--max-parallel=N] [--repo=owner/name] [--dry-run]"
user-invocable: true
---

# issue-fleet

複数 Issue を **1 Issue = 1 worktree = 1 branch = 1 draft PR** の原則で並列処理する orchestrator。
自分（メインループ）は司令塔に徹し、実装はサブエージェントへ委任する。単一タスクの深い orchestration は `pr-workflow` の領分であり、本 skill は「浅く広く並列に」が領分。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<issue 番号列 or 検索条件>` | - | `123 124 125` / `#123,#124` / `label:content` / 自然文（例:「写真差し替え系を全部」） |
| `--max-parallel` | 4 | 同時に走らせるサブエージェント数の上限 |
| `--repo` | カレントリポジトリ | 対象リポジトリ（`owner/name`） |
| `--dry-run` | off | Phase 2 の dispatch 計画表を出して終了（worktree 作成・実装をしない） |

## 安全原則（絶対遵守）

- **自動マージ禁止**。作るのは draft PR まで。merge は user の明示操作。
- **main / master への直接 push 禁止**。必ず worktree 上の feature branch で作業する。
- **GATE（dispatch 承認）を通過するまで書き込み系操作をしない**。承認は「各 worktree 内での commit / push / draft PR 作成」を包括的に許可するものとし、以降 Issue ごとの個別確認はしない。
- standard 以上の tier と判定した Issue は fleet に入れず、`pr-workflow` での単独処理を推奨として報告する。

## Phase 0: 対象 Issue の収集

```bash
# 番号指定の場合
gh issue view <番号> --repo <owner/name> --json number,title,body,labels,assignees

# 検索条件の場合
gh issue list --repo <owner/name> --state open --label <label> \
  --json number,title,body,labels --limit 30
```

自然文で指定された場合は `gh issue list` の結果からタイトル・本文でフィルタし、**解釈した対象一覧を Phase 2 の計画表に含めて user に見せる**（勝手に対象を確定しない）。

## Phase 1: 事前分析（並列可否と tier）

各 Issue について軽量に判定する（ここで実装調査に深入りしない。1 Issue あたり数分以内）:

1. **tier 判定**: `pr-workflow` の基準を再利用。
   - `trivial`: 1〜数行、単一ファイル、振る舞い不変
   - `small`: 数ファイル、所有境界内、契約変更なし
   - `standard` 以上: **fleet 対象外**。計画表に「pr-workflow 単独処理推奨」として記載
2. **想定変更ファイルの推定**: Issue 本文・ラベル・過去の類似 PR から、触りそうなファイル/ディレクトリを推定
3. **競合検出**: 想定変更ファイルが重なる Issue ペアは**同一レーンに直列化**する（並列レーンを分けると conflict 地獄になる）

## Phase 2: dispatch 計画と GATE

以下の計画表を提示し、**user の承認を 1 回だけ**得る:

| Issue | tier | branch 名 | worktree | レーン | 備考 |
|-------|------|-----------|----------|--------|------|
| #491 | trivial | fix/491-photo-swap | (wtp が導出) | A（並列） | |
| #499 | small | feat/499-... | 〃 | B（並列） | |
| #503 | small | feat/503-... | 〃 | B の後（直列） | #499 と同一ファイル競合 |

- branch 名はリポジトリの既存規約（`git log` の直近ブランチ命名）に合わせる。
- `--dry-run` ならここで終了。
- **承認が得られなければ何も作らない**。

## Phase 3: worktree 作成

承認後、レーンごとに wtp で worktree を作成する:

```bash
wtp add -b <branch名>   # ベースは各リポジトリの default branch
wtp list                # 作成結果とパスの確認
```

`wtp` が使えないリポジトリでは `git worktree add` に fallback してよいが、パス規約は `wtp` の導出に揃える。

## Phase 4: サブエージェントへの並列委任

**1 メッセージ内で複数の Agent tool 呼び出しを同時に発行**し（`--max-parallel` を上限）、各サブエージェント（general-purpose）に以下のテンプレートで委任する:

```
あなたは worktree <絶対パス> で Issue #<番号> を実装する担当エージェントです。

## コンテキスト
- リポジトリ: <owner/name>（default branch: <name>）
- Issue 全文: <title / body / ラベルをここに展開>
- 作業ブランチ: <branch名>（作成済み。この worktree 内でのみ作業すること）

## 実行手順
1. cd <worktree絶対パス> し、以降すべての操作をこの worktree 内で行う
2. Issue の要求を実装する。既存コードの流儀（命名・構成・テスト規範）に合わせる
3. プロジェクトの lint / test があれば実行して通す
4. commit する（メッセージは英語・Conventional Commits。1Password 署名エラーが出たら
   commit を中断し、エラー内容をそのまま報告して終了する）
5. push し、draft PR を作成する:
   gh pr create --draft --title "<英語タイトル>" --body "<英語本文。Closes #<番号> を含める>"
6. **絶対にマージしない。main に push しない。**

## 返答形式（最終メッセージ）
- status: success / failed
- pr_url: <URL or なし>
- summary: 変更内容 1〜2 行
- blockers: 詰まった点（なければ「なし」）
```

- 直列レーンは前のエージェントの完了（成功）を確認してから次を発行する。
- サブエージェントが failed を返した場合、**自動リトライは 1 回まで**。それでも失敗したら worktree を残したまま報告に回す（人間が引き継げるように）。
- 1Password 署名エラーの報告を受けたら、`osascript` の通知（AGENTS.md 規定）で user に知らせる。

## Phase 5: 集約と報告

全エージェント完了後、以下を報告する:

| Issue | 結果 | PR | CI | 備考 |
|-------|------|----|----|------|

- CI 状態は `gh pr checks <PR番号>` で確認（watch までは不要。赤なら失敗ログの要点を添える）
- 成功した PR の一覧と、失敗分の引き継ぎ情報（worktree パス・詰まった理由）
- 後片付けの案内: マージ後は `wtp-cleanup` / `delete-merged-branches` を使う

## 他 skill との連携

- **入口**: `repo-radar` が「assign 済み Issue が N 件滞留」を検出したとき、本 skill へのハンドオフを提案する
- **単独処理**: standard 以上の Issue は `pr-workflow` へ
- **後始末**: `wtp-cleanup` / `delete-merged-branches`
