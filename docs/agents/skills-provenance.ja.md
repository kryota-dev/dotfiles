# スキルプロベナンス

🌐 English (canonical): [skills-provenance.md](skills-provenance.md)

← [ドキュメント目次](../README.ja.md)

`~/.agents/skills/` 配下のすべてのスキルは、5 つのプロベナンス（出自）カテゴリのうち必ず 1 つに属します。
分類基準は作者ではなく**管理方法**です — `.chezmoiexternal.toml` で宣言された公式 Anthropic スキルは `system` ではなく `external` になります。

---

## 5 つのカテゴリ

| カテゴリ | 定義 | 物理的な場所 |
|---|---|---|
| `curated` | chezmoi SSOT — 自作またはフォーク、このリポジトリにチェックイン済み | `home/dot_agents/skills/<name>/` → `~/.agents/skills/<name>/` |
| `external` | `.chezmoiexternal.toml` で宣言され、SHA ピン付きで GitHub tarball からフェッチ | `~/.agents/skills/<name>/`（chezmoi ソースには含まれない） |
| `system` | Anthropic 配布のシステムスキル；このリポジトリでは管理しない | `~/.agents/skills/.system/<name>/` |
| `evolved` | CLV2 の `/evolve` フローによってレビュー済みインスティンクトクラスターから生成 | `$CLV2_HOMUNCULUS_DIR/evolved/skills/<name>/` — `~/.agents/skills/` の**外** |
| `unmanaged` | 上記のいずれにも該当しない — **ポリシー違反** | — |

`evolved` スキルは意図的に `~/.agents/skills/` の外に置かれており、標準的なスキル探索パスにシンボリックリンクされません。CLV2 継続学習システムが管理する homunculus ディレクトリに存在します。

`unmanaged` スキルは `tests/skill_provenance.bats`（情報提供のみのランタイムチェック）で検出され、削除するか `curated` または `external` に取り込む必要があります。

---

## キュレーテッドスキルの追加方法

1. chezmoi ソースにスキルディレクトリを作成します。

   ```
   home/dot_agents/skills/<name>/
   ```

2. 少なくとも `SKILL.md`（とスキルに必要なスクリプト）を追加します。ソースは `chezmoi apply` によって `~/.agents/skills/<name>/` にデプロイされます。

3. スキルが `external` としても宣言されていないことを確認します — 重複禁止ルールは `tests/skill_provenance.bats` で強制されます。

---

## 外部スキルの追加方法（ECC / Anthropic）

外部スキルはリポジトリのソースにはチェックインされません。`chezmoi apply` 時に GitHub アーカイブ tarball からフェッチされます。

**ECC スキルの場合**: `home/.chezmoidata.toml` の `[ecc].skills` 配列にスキル名を追加します。

```toml
[ecc]
  commit = "<ピン留めされたコミット SHA>"
  skills = [
    # ... 既存のエントリ ...
    "your-new-skill",
  ]
```

`home/.chezmoiexternal.toml` の `{{ range $skill := .ecc.skills }}` ブロックが要素ごとに 1 つの external エントリを生成し、すべてが `[ecc].commit` にバージョンロックされます。ECC tarball は 1 回だけダウンロードされて chezmoi にキャッシュされるため、エントリを追加しても追加ダウンロードは発生しません。

**Anthropic システムスキルの場合**: 既存の 17 エントリで使われている `stripComponents = 3` パターンに従い、`home/.chezmoiexternal.toml` にリテラルの `[".agents/skills/<name>"]` エントリを追加します。

### 重複禁止ルール

スキル名は `home/dot_agents/skills/<name>/`（curated）と external 宣言の**両方**に同時に存在してはなりません。chezmoi がソースからのディレクトリデプロイと同じパスへの external フェッチを同時に試み、コンフリクトが発生します。プロベナンス bats テストは、すべての curated スキルについてリテラルの external ヘッダーと `[ecc].skills` の全要素に対してこれを検証します。

---

## キュレーテッドスキルインベントリ（38 スキル）

`home/dot_agents/skills/` の 38 スキルをテーマ別にグループ化しています。

### Git、PR、GitHub ワークフロー（13 スキル）

日常的な開発サイクルの自動化の中核。2026-07-06 の棚卸しで並列開発トライアド（`repo-radar` → `issue-fleet` / `renovate-sweep`）が追加されました。

`commit`、`create-pr`、`create-issue`、`pr-draft-summary`、`github-pr-comments`、`github-projects`、`github-sub-issues`、`monitor-ci`、`renovate-analyzer`、`renovate-sweep`、`issue-fleet`、`repo-radar`、`delete-merged-branches`

### コードレビューとマルチエージェントオーケストレーション（5 スキル）

サブエージェントをスポーンしたり複数のレビュアーを調整するレビューパイプライン。

`cc-code-review`、`cc-security-review`、`multi-review`、`codex`、`review-resolve-loop`

### 計画とスペック駆動開発（5 スキル）

構造化されたタスク分解、要件分析、エンドツーエンドのデリバリーフロー。

`planning`、`sdd`、`grill-me`、`prompt-conform`、`pr-workflow`

### セッションとコンテキスト管理（5 スキル）

会話状態の管理、トランスクリプトのコンパクト化、セッション後のキャプチャ。`session-summary` は軽量デフォルトモードと、廃止された `save-session` から取り込んだ `--archive` 深掘りモード（JSONL アーカイブ + サブエージェントサマリー）の両方を持ちます。

`session-summary`、`prune-session-transcript`、`compact-docs`、`cleanup-plan`、`retrospective-codify`

### ワークツリーと dotfiles ツール（4 スキル）

`wtp`（worktree-plus）ワークフローと chezmoi/git リポジトリツール。

`wtp`、`wtp-cleanup`、`chezmoi`、`git-filter-path`

### ドメイン、データベース、メディア、生産性ユーティリティ（6 スキル）

データベース、メディア変換、日々の生産性にまたがる各種機能スキル。

`fix-migration-leftover`、`webp-convert`、`agent-browser`、`daily-planning`、`sync-daily-planning-calendar`、`empirical-prompt-tuning`

---

## 外部スキルインベントリ

| ソース | 件数 | バージョンピン |
|---|---|---|
| ECC（`affaan-m/ECC`） | <!-- FACT:ecc-skill-count -->126<!-- /FACT --> スキル | `.chezmoidata.toml` の `[ecc].commit` |
| Anthropic システムスキル | 17 スキル | `.chezmoidata.toml` の `[skills].anthropic_commit` |
| jgraph/drawio-mcp（`drawio`） | 1 スキル | `.chezmoidata.toml` の `[skills].drawio_mcp_commit` |
| supabase/agent-skills（`supabase`、`supabase-postgres-best-practices`） | 2 スキル | `.chezmoidata.toml` の `[skills].supabase_agent_skills_commit` |
| ECC フックランタイム（`ecc/scripts`） | 1 エントリ（スキルではない） | 同じ `[ecc].commit` |
| ECC `aside` コマンド | 1 エントリ（コマンド、スキルではない） | 同じ `[ecc].commit` |

すべてのバージョン定義インプットは `home/.chezmoidata.toml` に集約されています。`.chezmoiexternal.toml` の external 宣言はテンプレート変数としてこれらを参照します — コミット SHA が `.chezmoiexternal.toml` に直接ハードコードされることはありません。Renovate が ECC のリリースタグを追跡し、`[ecc].version` と `[ecc].commit` を同時にバンプします；ECC の更新は自動マージされません。

---

## `agent-browser` ディスカバリースタブパターン

`agent-browser` は**ディスカバリースタブのみ**として curated されています（`home/dot_agents/skills/agent-browser/SKILL.md`）。その特化スキル（electron、slack、dogfood）はこのリポジトリには**ベンダリングされていません**。すぐに陳腐化するため、代わりに agent-browser CLI がランタイムで提供します。

```
agent-browser skills get <name>
```

以前デプロイされた特化スキルのコピーは `home/.chezmoiremove` で強制削除されます。

```
.agents/skills/electron
.agents/skills/slack
.agents/skills/dogfood
```

chezmoi ソースからファイルを削除しても既にデプロイされたコピーは削除されません。`.chezmoiremove` が、`chezmoi apply` のたびにそれらのパスが存在しないことを保証するよう chezmoi に指示します。

---

## 機械的強制：`tests/skill_provenance.bats`

`tests/skill_provenance.bats` はプロベナンスポリシーの CI ゲートです。すべての CI パイプラインで実行されます（bats のみのジョブ、chezmoi 不要）。アサーションは 2 層に分かれています。

**決定論的なソース側アサーション**（違反時は CI を必ず失敗させる）：

- `agent-browser` がディスカバリースタブのみをベンダリングしており、`electron`/`slack`/`dogfood` がソースに存在せず `.chezmoiremove` に記載されている。
- ソース内のすべての curated スキルディレクトリが空でない（深さ ≤ 2 に少なくとも 1 つの通常ファイルを含む）。
- `.chezmoiexternal.toml` が少なくとも 1 つの `[".agents/skills/..."]` external エントリを宣言し、`[ecc].commit` に紐付けられた ECC range ブロックを含む。
- どのスキル名も curated ソースツリーと external 宣言の両方に同時に現れない（重複禁止ルール）。
- `home/AGENTS.md.tmpl` が 5 つのプロベナンスカテゴリすべてを記載している。
- 廃止された unmanaged スキル（`agentcore`、`vercel-sandbox`、`patch-remote-control`、`find-skills`）がソースに存在しない。
- 孤立した `sdd-*` サブエージェントが `home/dot_claude/agents/` に存在しない。
- `.chezmoiexternal.toml` の ECC スキル range ブロックが正しく設定されており（url、include glob、`stripComponents = 3`）、100 件以上のエントリを含み、重複がない。
- ECC スキル名が同名の curated スキルと衝突しない。

**情報提供のみのランタイムチェック**（常に exit 0 を返す）：

- `~/.agents/skills/` をスキャンし、curated（chezmoi ソースに存在）でも external（`.chezmoiexternal.toml` または `[ecc].skills` で宣言）でも `.system/` 配下でもないスキルを検索。発見した場合は bats タップ出力に `unmanaged` として報告しますが、CI は失敗しません。

### テストが chezmoi なしで ECC スキル名を解決する方法

`.chezmoidata.toml` の `[ecc].skills` 配列が採用済み ECC スキル名の真実の源です（正規カウントは上記の外部スキルインベントリテーブルを参照）。`.chezmoiexternal.toml` の range ブロックにはリテラルのテンプレート変数 `{{ $skill }}` のみが含まれ、external ファイルの単純な `grep` では展開された名前が見えません。

テストは `.chezmoidata.toml` から直接リストを抽出するために chezmoi を使わない `awk` スコープを使用します。

```bash
awk '
  /^\[ecc\]$/        { in_ecc = 1; next }
  /^\[/              { in_ecc = 0; in_list = 0 }
  in_ecc && /^[[:space:]]*skills[[:space:]]*=[[:space:]]*\[/ { in_list = 1; next }
  in_ecc && in_list && /^[[:space:]]*\]/ { in_list = 0; next }
  in_ecc && in_list  { print }
' "${HOME_DIR}/.chezmoidata.toml" | grep -oE '"[^"]+"' | tr -d '"'
```

スコープ（`in_ecc && in_list`）により、別の TOML セクションに追加された無関係な `skills` キーが結果を乱すことがありません。

---

## 関連ドキュメント

- [overview.ja.md](overview.ja.md) — デュアルハーネス、デュアルアカウントアーキテクチャ
- [externals-and-pinning.ja.md](../architecture/externals-and-pinning.ja.md) — chezmoi externals がリモートコンテンツをフェッチ・キャッシュする方法
- [contributing/local-dev.ja.md](../contributing/local-dev.ja.md) — `tests/skill_provenance.bats` をローカルで実行する方法
