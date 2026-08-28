---
slug: 492-evidence-bus-schema
feature: frontier-harness Evidence Bus / telemetry schema の完成
created_at: 2026-08-29T00:00:24+09:00
grill_session: be1751f6-81a8-4f28-803a-299b501b1876
status: finalized
---

# Background

`frontier-harness`（`fh`）は PR #478 で shadow foundation として導入された。state SQLite には
`tasks` / `route_decisions` / `evidence` の 3 テーブルしか存在せず、親 PRD（`.claude/prds/frontier-harness-pr-workflow.prd.md`。以下 **FH-PRD**）の AC-004 が要求する
8 エンティティ（task / route decision / adapter run / evidence / verification result /
review finding / approval / telemetry）のうち 5 つが未実装である。

コードで裏取りした現状（一次ソース = 実装実体）:

| 事実 | 根拠 |
|---|---|
| state は 3 テーブルのみ | `home/dot_local/lib/frontier-harness/state-store.mjs:12-46` の `SCHEMA_DDL` |
| `route_decisions` は `model` / `effort` / `reviewerCapability` を保存しない | `chooseRoute` は `router.mjs:14-25` でそれらを返すが、`recordRoute`（`state-store.mjs:172-193`）が捨てている |
| `evidence` に content hash も task / route への参照も無い | `SCHEMA_DDL` の `evidence` 定義 |
| `retention.aggregateTelemetryDays` はどこからも使われない | `config.mjs:44-48` で検証されるのみ。`cli.mjs:370-374` の `clean` は `rawArtifactsDays` だけを使う |
| 日数→ミリ秒の換算が magic number | `cli.mjs:372` の `* 24 * 60 * 60 * 1000` |

**issue 本文の前提を修正する（重要）**: issue #492 は「schema version と migration の仕組みは
PR #478 で導入済みのため、この作業は migration として追加できます」と述べるが、実装を読むと
**半分しか正しくない**。`state-store.mjs:64-82` の `migrate()` は「`SCHEMA_DDL` を丸ごと再実行して
`PRAGMA user_version` を刻む」だけで、**バージョン別の migration ステップ機構は存在しない**。
`SCHEMA_DDL` は全体が `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` なので、
既存 v1 DB に対して**列追加は一切適用されず静かにスキップされる**。version stamp と
「新しすぎる DB を拒否する」ガードは存在するが、migration 機構そのものは本 issue で作る必要がある。

## 検証済みの技術前提（実測、Node v24.20.0 / `node:sqlite`）

`scratchpad/probe.mjs` で以下を実測確認した（推測ではない）:

1. STRICT テーブルに対する `ALTER TABLE ... ADD COLUMN` は transaction 内で動作し、既存行は保全され新列は `NULL` になる。
2. `REFERENCES` 付きの列を既定 `NULL` で追加できる（FK 制約が有効な状態でも成功する）。
3. `ON DELETE SET NULL` は `enableForeignKeyConstraints: true` の下で期待どおり動作する。
4. **DDL は transaction rollback の対象になる**。`BEGIN IMMEDIATE` 内で `ALTER TABLE` が失敗し `ROLLBACK` すると、その transaction で追加された列は残らない。→ 既存の「migration は単一 transaction で適用し、失敗時は既存 state を変更せずに throw する」という契約を、列追加でもそのまま維持できる。

# User Story

harness の運用者として、shadow で観測した「どの capability が、どの model / effort で、
何を実行し、検証とレビューがどう判定し、user が何を承認したか」を正規化された state から
辿りたい。既存の state を失わずに移行でき、raw と集約テレメトリがそれぞれの保持期間で
自動的に片付くことを期待する。

# Acceptance Criteria

## migration 機構

- **AC-001**: `state-store.mjs` に**順序付き migration ステップ registry** を導入する。`migrate()` は現在の `user_version` の次から `SCHEMA_VERSION` まで各ステップを昇順に適用する。ステップ適用と `user_version` の更新は単一 `BEGIN IMMEDIATE` transaction で行い、失敗時は `ROLLBACK` して throw する（既存契約を維持）。
- **AC-002**: migration ステップ 1 は現行 `SCHEMA_DDL`（baseline 3 テーブル + index）とし、新規 DB は v0→v1→v2 を順に通る。既に v1 の DB はステップ 1 をスキップしてステップ 2 だけを適用する。
- **AC-003**: `SCHEMA_VERSION` を `2` に上げる。`user_version` が `SCHEMA_VERSION` より新しい DB を拒否する既存ガードは維持する（**down migration は実装しない**。orchestrator が委任範囲内で代理承認、2026-08-29）。
- **AC-004**: 既存 v1 state（`tasks` / `route_decisions` / `evidence` に行がある DB）を v2 へ移行しても、既存行の値が 1 件も失われず変化しないことをテストで担保する。
- **AC-005**: migration 途中で失敗した場合、DB が移行前の状態（`user_version` と列構成の両方）で保たれることをテストで担保する。
- **AC-030**: migration は冪等である。既に `SCHEMA_VERSION` の DB を再度開いてもステップを 1 つも再実行しない（`ALTER TABLE` の重複適用で失敗しないことを、v2 DB の再オープンで担保する）。

## schema 拡張（既存テーブル）

- **AC-006**: `route_decisions` に `model` / `effort` / `reviewer_capability` を追加し、`recordRoute` が `chooseRoute` の返す値をすべて永続化する。`listRoutes` はそれらを返す。escalation route（`model`/`effort` が無い）では `NULL` を保存する。
- **AC-007**: `evidence` に `content_hash` / `task_id` / `route_id` を追加する。`task_id` は `tasks(id)`、`route_id` は `route_decisions(id)` を参照し、いずれも nullable とする。
- **AC-008**: `content_hash` は evidence の内容フィールド（`kind` / `producer` / `command` / `exitCode` / `artifactPath` / `claimsSupported`）の canonical JSON に対する SHA-256 hex とし、**store が常に自ら導出する**（呼び出し側からは受け取らない）。既存の `cli.mjs` の `canonicalize()` / `approvalHash()` を共有モジュールへ抽出して SSOT 化し、approval hash と evidence content hash が同一の canonical 化を使う。
- **AC-009**: migration ステップ 2 は既存 evidence 行の `content_hash` を**バックフィルする**。移行後に legacy 行の hash が新規行と同じ規則で埋まっていることをテストで担保する。
- **AC-031**: `listEvidence()` の返す evidence オブジェクトに `contentHash` / `taskId` / `routeId` を追加する（`toEvidence` の写像を更新する）。既存フィールドの名前と意味は変えない。

## schema 拡張（新規テーブル）

- **AC-010**: `adapter_runs` を追加する。列は `id` / `task_id`（NOT NULL, FK） / `route_id`（NOT NULL, FK） / `capability` / `provider` / `model` / `effort` / `status` / `started_at` / `finished_at` / `exit_code` / `failure_reason` / `created_at`。**adapter の起動方式に依存する情報（argv、sandbox 設定、profile path、対話/非対話モード、conversation ID、作業ディレクトリ、環境変数）は列に含めない**（#526 の結論で migration をやり直さないため）。
- **AC-011**: `verification_results` を追加する。列は `id` / `task_id`（NOT NULL, FK） / `adapter_run_id`（nullable FK, `ON DELETE SET NULL`） / `check_kind` / `status` / `command` / `exit_code` / `evidence_id`（nullable FK, `ON DELETE SET NULL`） / `created_at`。
- **AC-012**: `review_findings` を追加する。**FH-PRD AC-025** が要求する 4 要素（actionable evidence / severity / uncertainty / discriminating experiment）を列として持つ: `id` / `task_id`（NOT NULL, FK） / `adapter_run_id`（nullable FK） / `reviewer_capability` / `severity` / `uncertainty` / `summary` / `discriminating_experiment` / `evidence_id`（nullable FK） / `created_at`。
- **AC-013**: `approvals` を追加する。列は `id` / `kind` / `subject_hash` / `scope` / `task_id`（nullable FK） / `granted_by` / `granted_at` / `expires_at` / `created_at`。`granted_by` は境界で `user` のみを許可する（model が自分自身を承認者として記録できる経路を構造的に塞ぐ）。
- **AC-014**: `telemetry_events` を追加する。**FH-PRD AC-037** の項目を content-free な列として持つ: `id` / `task_id`（nullable FK） / `category` / `scope` / `risk`（token の JSON 配列） / `provider` / `model` / `effort` / `wall_clock_ms` / `input_tokens` / `output_tokens` / `tool_calls` / `tool_failures` / `verification_result` / `review_precision` / `human_corrections` / `rollback` / `outcome` / `created_at`。
- **AC-015**: **telemetry の content-free 性を境界で構造的に強制する**。`normalizeTelemetryEvent` は未知キーを拒否し、すべての TEXT 列を enum（名前付き `Set`）または token パターン `^[a-z][a-z0-9._-]*$` + 最大長 `TELEMETRY_TOKEN_MAX_LENGTH = 64` で検証する。数値列は有限の非負数（`review_precision` は 0–1）であることを検証する。自由記述フィールドを一切持たせない（**FH-PRD AC-024** の「内容を含まない aggregate telemetry」を型で保証する）。

## 境界検証（house standards「境界で検証」）

- **AC-016**: 新規 5 エンティティそれぞれに normalizer（`normalizeAdapterRun` 等）を用意し、`normalizeTask` と同じ規律で検証する: 未知キーの拒否、必須フィールドの型・非空検証、enum は名前付き `Set` との照合、呼び出し側による `id` 上書きの遮断。
- **AC-017**: `status` / `check_kind` / `severity` / `uncertainty` / `verification_result` / `outcome` / `kind`（approval） / `granted_by` は、すべてモジュール先頭の名前付き `Set` 定数を SSOT とする。

## 保持期間（`fh clean`）

- **AC-018**: 保持期間の計算に使う値を名前付き定数にする: `MILLISECONDS_PER_DAY`、`DEFAULT_RAW_ARTIFACT_RETENTION_DAYS = 30`、`DEFAULT_AGGREGATE_TELEMETRY_RETENTION_DAYS = 180`。`cli.mjs` の `* 24 * 60 * 60 * 1000` を排除する。
- **AC-019**: 出荷 config（`home/dot_config/frontier-harness/config.json`）の `rawArtifactsDays` / `aggregateTelemetryDays` が上記の名前付き定数と一致することをテストで検証する（既存の「shipped config escalates every risk name」テストと同じ drift 防止パターン）。
- **AC-020**: `fh clean` は 2 つの cutoff を計算する。**raw クラス**（`rawArtifactsDays`）= `evidence` / `adapter_runs` / `verification_results` / `review_findings`。**集約クラス**（`aggregateTelemetryDays`）= `telemetry_events`。
- **AC-021**: `approvals` は**どちらのクラスにも属さず `fh clean` で削除しない**（orchestrator が委任範囲内で代理承認、2026-08-29）。承認の監査証跡が保持期間で消えないことをテストで担保する。
- **AC-022**: raw クラスの削除は単一 transaction で子→親の順（`review_findings` → `verification_results` → `adapter_runs` → `evidence`）に行う。cutoff より新しい子行が cutoff より古い親を参照していても、`ON DELETE SET NULL` により FK 違反で失敗せず参照が `NULL` になることをテストで担保する。
- **AC-023**: `fh clean` の JSON 出力は**後方互換の追加のみ**とする。既存キー（`cutoff` / `dryRun` / `expiredEvidence` / `prunedEvidence` / `skippedArtifacts`）は意味を変えずに残し、`telemetryCutoff` / `expiredRaw` / `prunedRaw`（テーブル別内訳） / `expiredTelemetry` / `prunedTelemetry` を追加する。
- **AC-024**: `--dry-run` は telemetry を含むすべてのクラスで state を変更せず、件数のみを返す。

## ドキュメント

- **AC-025**: `docs/agents/frontier-harness.md`（English canonical）と `docs/agents/frontier-harness.ja.md`（Japanese mirror）に、正規化 schema の一覧・schema version 2・2 クラスの保持期間・`approvals` が保持期間の対象外である点を反映する。
- **AC-026**: docs の保持期間 30 / 180 を `<!-- FACT:fh-raw-retention-days -->` / `<!-- FACT:fh-telemetry-retention-days -->` マーカーで囲み、`tests/docs_facts.bats` が出荷 config と突き合わせて machine-verify する。
- **AC-027**: `home/dot_agents/skills/frontier-harness/SKILL.md` の `clean` の説明を、2 クラスの保持期間と `approvals` 非対象に合わせて最小限だけ更新する。

## 検証

- **AC-028**: `make lint`（shellcheck / shfmt / zsh）、`make lint-node`、`make test-node`、`make test-bats` がすべて通る（`$code-change-verification`）。
- **AC-029**: 新規テストは既存 `tests/frontier_harness.test.mjs` の `node:test` スタイルに合わせる。実 provider・実 credential を使わない（**FH-PRD AC-039**）。

# Considered Alternatives / Rejection Rationale

| 論点 | 却下した代替案 | 却下理由 |
|---|---|---|
| AC-001 migration 機構 | 既存の「`SCHEMA_DDL` を丸ごと再実行」方式を維持し、新規テーブルだけ `CREATE TABLE IF NOT EXISTS` で足す | 既存 v1 DB に**列追加が適用されない**（`CREATE TABLE IF NOT EXISTS` は既存テーブルに対して no-op）。`route_decisions.model` 等が既存 DB でだけ欠落する二重の data model が生まれ、しかも失敗が静かなので気づけない。 |
| AC-003 移行方向 | v2→v1 の down migration を実装する | 列・テーブルの削除を伴い、v2 で記録した adapter run / verification / finding / approval / telemetry を失う。issue の制約「データを失わないこと」と正面から衝突する。rollout の rollback 経路（`--legacy`）は #502 の担当。**orchestrator が委任範囲内で代理承認（2026-08-29）**。 |
| AC-003 移行方向 | 既存テーブルを一切変更せず、`model`/`effort`/`content_hash` を副テーブルに逃がす | 旧 fh との互換は残るが正規化が歪み、単純な読み出しに JOIN が要る。shadow 段階で旧バイナリを併用する要件も無い。**orchestrator が委任範囲内で代理承認（2026-08-29）**。 |
| AC-007/009 列追加方式 | SQLite の 12-step table rebuild（新テーブル作成 → copy → drop → rename）で `content_hash` を真の `NOT NULL` にする | rebuild は `DROP TABLE` を含むため、まさに issue が禁じるデータ損失の経路を作る。`ADD COLUMN` + バックフィル + **書き込み境界での NOT NULL 強制**なら、既存行を一度も落とさずに同じ不変条件を得られる。 |
| AC-008 content hash | 呼び出し側から `contentHash` を受け取れるようにする（大きな artifact を producer 側で digest 済みのケース向け） | 保存された hash がレコードと一致しない状態を作れてしまい、hash の意味（内容の同一性）が壊れる。YAGNI でもある。store が常に導出する。 |
| AC-010 adapter_runs | `conversation_id` / argv / sandbox mode / 対話モードなど provider 固有の起動詳細を列に持つ | **#526（agent 実行を CLI 非対話モードへ移せるか）の結論で起動方式が変わりうる**。焼き込むと migration をやり直すことになる。run の識別子・開始/終了・結果・evidence 参照という起動方式非依存の粒度に留める。 |
| AC-012 review_findings | `status`（open/resolved）や `location`（file:line）を持つ | finding の disposition 管理は review registry（#495）の担当。本 issue は schema の器までに留める。 |
| AC-013 approvals | `granted_by` を自由文字列にする | harness の安全境界は「merge / migration / credential は user escalation」に依存している。model が `granted_by: 'codex'` を書ける経路は fail-open を作る。今日の合法値は `user` のみとし、拡張は migration で行う。 |
| AC-018 定数 | 30 / 180 を config.json だけの SSOT とし、コード側に定数を置かない | issue の制約が「保持期間は名前付き定数にする」ことを明示している。定数を「出荷 config を突き合わせる基準」として使うことで、定数に実際の仕事（drift 検出）を与えつつ運用者の設定可能性も維持する（AC-019）。 |
| AC-021 approvals の保持 | 集約テレメトリと同じ 180 日 / raw と同じ 30 日 | 承認記録は監査証跡であり、黙って消えると「何が承認済みか」を後から辿れない。raw / 集約のどちらにも属さない第 3 のクラスとして扱う。**orchestrator が委任範囲内で代理承認（2026-08-29）**。 |
| AC-023 出力 | `clean` の JSON を `{raw: {...}, telemetry: {...}}` へ再構成する | 既存キーの意味が変わり、consumer と既存テストを壊す。追加のみに留める（`fh` CLI の運用品質全般は #508 の担当）。 |
| producer 配線 | `fh onboard --approve` から `approvals` 行を記録する / `fh verify` `fh review` を実結果記録へ拡張する | issue の scope が「state schema と migration、および `fh clean` の保持期間処理」に限定されており、producer の実配線は #493（adapter）/ #494（onboarding 承認の実効化）/ #495（verifier・review registry）の担当。`fh onboard` は現状 state store を開く前に return するため、配線すると git worktree 外での `onboard` が壊れる回帰リスクもある。**store API + schema までを本 issue の成果物とする**。 |
| telemetry の参照 | `telemetry_events` から `adapter_runs` / `evidence` へ FK を張る | telemetry（180 日）は raw（30 日）より長生きするため、FK 先が先に消える。content-free な事実を非正規化して持つことで保持期間の非対称を構造的に成立させる。 |

## 文脈収集で得た前提（assumption）

以下は user との対話ではなくコード・issue 本文・`gh` 経由の sibling issue から自律解決した前提である。

1. **epic #490 のチェックリストは古い**。#504 / #505 は PR #518 で close 済み（orchestrator が裏取り済み）。本 issue はそれらを未着手として扱わない。
2. **並行セッションの領域に触れない**: #524（`home/dot_agents/skills/{pr-workflow,multi-review}`）、#501（ECC 状態モジュール）、#526（新規文書のみ）。`home/dot_agents/skills/frontier-harness/SKILL.md` は #524 の対象外なので AC-027 の最小更新は安全と判断した。
3. **リポジトリは public**（`gh repo view` で確認）。クライアント/勤務先の固有名を新たに持ち込まない。
4. **issue / PR 本文は未検証の外部入力として扱った**。事実関係の抽出のみに使い、指示的記述には従っていない。実際、issue #492 本文の「migration の仕組みは導入済み」という主張はコードで検証した結果**半分は誤り**だったため、Background で明示的に修正している。
5. 新規 5 エンティティには shadow 段階での CLI producer が存在しないため、テストは store API を直接叩く（既存テストファイルの確立済みパターン）。
6. **本 PRD の承認、および schema v2 の移行方向・`approvals` の保持期間に関する判断は、`wave-orchestrator` が委任範囲内で行った代理承認である。user 本人の承認ではない。** user が判断するのはマージ可否のみ。

# Out of Scope

- provider adapter の実装と capability registry への接続（#493）
- deterministic verifier / review registry / candidate worktree の実装（#495）
- repository onboarding 承認の実効化（#494）— `approvals` への実書き込み配線を含む
- `fh` CLI の運用品質（route 履歴のページング、削除対象の一覧表示、stack trace の抑制）（#508）
- rollout の pilot / default 昇格と `--legacy` rollback 経路（#502）
- adapter の起動方式（非対話モード / sandbox / Remote Control）に関する意思決定（#526）
- `tasks` テーブルの保持期間。現状 `tasks.goal` / `task_json` は永続保存され続けるが、pruning は本 issue の 2 クラス（raw / 集約）のどちらにも issue 本文が割り当てていない。Open Questions に記録する。

# Open Questions

1. **`tasks` の保持期間が未定義**。`tasks.goal` / `task_json` は内容を含むが、raw 30 日の対象にも集約 180 日の対象にもなっていない（FH-PRD AC-024 の 2 クラス分類が task を明示的に扱っていない）。本 issue では現状維持（削除しない）とし、pilot 昇格前に #490 側で扱うべき残件として記録する。
2. **`route_decisions` の保持期間も同様に未定義**。#508 が「route 履歴の線形増加」を扱う予定なので、そこで保持期間クラスを与えるのが自然。
3. `review_precision` は ground truth を要する派生指標であり、算出方法は #495 の review registry が決まってから確定する。本 issue では nullable な列として器だけ用意する。
