import { evidenceContentHash } from "./records.mjs";

// state schema の順序付き migration。
//
// PR #478 は schema version stamp（PRAGMA user_version）と「新しすぎる DB を拒否する」
// ガードを入れたが、migration 本体は「SCHEMA_DDL を丸ごと再実行する」だけだった。
// SCHEMA_DDL は全体が CREATE TABLE IF NOT EXISTS なので、既存 DB に対しては no-op になり、
// 列の追加が静かに無視される（新規 DB でしか新しい列が存在しない、という二重の data model が
// できてしまう）。ここではバージョン単位のステップを順に適用する形へ置き換える。

// v1: PR #478 の baseline。定義は当時のまま変えない（過去のバージョンを書き換えない）。
const BASELINE_DDL = `
  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    task_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS route_decisions (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    kind TEXT NOT NULL,
    capability TEXT,
    provider TEXT,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS evidence (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    producer TEXT NOT NULL,
    created_at TEXT NOT NULL,
    command TEXT,
    exit_code INTEGER,
    artifact_path TEXT,
    claims_supported TEXT NOT NULL
  ) STRICT;

  CREATE INDEX IF NOT EXISTS evidence_created_at_id_idx
    ON evidence (created_at, id);
  CREATE INDEX IF NOT EXISTS route_decisions_created_at_id_idx
    ON route_decisions (created_at, id);
`;

// v2: Evidence Bus と telemetry の正規化（kryota-dev/dotfiles#492）。
//
// content_hash を DB レベルの NOT NULL にはしない。SQLite で既存テーブルへ NOT NULL 列を
// 足すには非 NULL の既定値が要り、空文字を入れるのは「hash がある」という嘘になる。
// 代わりに ADD COLUMN + backfill + 書き込み境界での必須化で同じ不変条件を得る。
// テーブル再構築（12-step rebuild）は DROP TABLE を含むため、既存 evidence を失う経路を
// 作ることになり採らない。
//
// adapter_runs には adapter の「起動方式」に属する列を置かない（argv、sandbox 設定、
// profile path、対話/非対話モード、conversation ID、作業ディレクトリ、環境変数）。
// 起動方式は #526 の調査結果で変わりうるため、焼き込むと migration をやり直すことになる。
const EVIDENCE_BUS_DDL = `
  ALTER TABLE route_decisions ADD COLUMN model TEXT;
  ALTER TABLE route_decisions ADD COLUMN effort TEXT;
  ALTER TABLE route_decisions ADD COLUMN reviewer_capability TEXT;

  ALTER TABLE evidence ADD COLUMN content_hash TEXT;
  ALTER TABLE evidence ADD COLUMN task_id TEXT
    REFERENCES tasks(id) ON DELETE SET NULL;
  ALTER TABLE evidence ADD COLUMN route_id TEXT
    REFERENCES route_decisions(id) ON DELETE SET NULL;

  CREATE TABLE IF NOT EXISTS adapter_runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    route_id TEXT NOT NULL REFERENCES route_decisions(id),
    capability TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    effort TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    exit_code INTEGER,
    failure_reason TEXT,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS verification_results (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    adapter_run_id TEXT REFERENCES adapter_runs(id) ON DELETE SET NULL,
    check_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    command TEXT,
    exit_code INTEGER,
    evidence_id TEXT REFERENCES evidence(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS review_findings (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    adapter_run_id TEXT REFERENCES adapter_runs(id) ON DELETE SET NULL,
    reviewer_capability TEXT NOT NULL,
    severity TEXT NOT NULL,
    uncertainty TEXT NOT NULL,
    summary TEXT NOT NULL,
    discriminating_experiment TEXT,
    evidence_id TEXT REFERENCES evidence(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS approvals (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    subject_hash TEXT NOT NULL,
    scope TEXT NOT NULL,
    task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
    granted_by TEXT NOT NULL,
    granted_at TEXT NOT NULL,
    expires_at TEXT,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS telemetry_events (
    id TEXT PRIMARY KEY,
    task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
    category TEXT NOT NULL,
    scope TEXT,
    risk TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    effort TEXT NOT NULL,
    wall_clock_ms INTEGER,
    input_tokens INTEGER,
    output_tokens INTEGER,
    tool_calls INTEGER,
    tool_failures INTEGER,
    verification_result TEXT,
    review_precision REAL,
    human_corrections INTEGER,
    rollback INTEGER NOT NULL,
    outcome TEXT,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE INDEX IF NOT EXISTS adapter_runs_created_at_id_idx
    ON adapter_runs (created_at, id);
  CREATE INDEX IF NOT EXISTS verification_results_created_at_id_idx
    ON verification_results (created_at, id);
  CREATE INDEX IF NOT EXISTS review_findings_created_at_id_idx
    ON review_findings (created_at, id);
  CREATE INDEX IF NOT EXISTS approvals_created_at_id_idx
    ON approvals (created_at, id);
  CREATE INDEX IF NOT EXISTS telemetry_events_created_at_id_idx
    ON telemetry_events (created_at, id);

  -- ON DELETE SET NULL は retention の prune で必ず発火する。
  -- 子側に index が無いと、親 1 行の削除ごとに子テーブルを全走査することになる。
  CREATE INDEX IF NOT EXISTS verification_results_evidence_id_idx
    ON verification_results (evidence_id);
  CREATE INDEX IF NOT EXISTS verification_results_adapter_run_id_idx
    ON verification_results (adapter_run_id);
  CREATE INDEX IF NOT EXISTS review_findings_evidence_id_idx
    ON review_findings (evidence_id);
  CREATE INDEX IF NOT EXISTS review_findings_adapter_run_id_idx
    ON review_findings (adapter_run_id);
`;

// v1 で記録済みの evidence にも content_hash を与える。
// 新規行と同じ evidenceContentHash を使うため、legacy 行と新規行の hash 規則は一致する。
function backfillEvidenceContentHash(database) {
  const expired = database.prepare(`
    SELECT id, kind, producer, command, exit_code, artifact_path, claims_supported
    FROM evidence
    WHERE content_hash IS NULL
  `);
  const update = database.prepare(`
    UPDATE evidence SET content_hash = ? WHERE id = ?
  `);
  for (const row of expired.all()) {
    update.run(
      evidenceContentHash({
        kind: row.kind,
        producer: row.producer,
        command: row.command,
        exitCode: row.exit_code,
        artifactPath: row.artifact_path,
        claimsSupported: JSON.parse(row.claims_supported),
      }),
      row.id,
    );
  }
}

// 配列の添字 + 1 がそのまま user_version になる。末尾に足すだけで版が上がるため、
// 「定数を上げ忘れる / ステップを足し忘れる」という drift が起こらない。
const MIGRATIONS = [
  function applyBaselineSchema(database) {
    database.exec(BASELINE_DDL);
  },
  function applyEvidenceBusSchema(database) {
    database.exec(EVIDENCE_BUS_DDL);
    backfillEvidenceContentHash(database);
  },
];

export const SCHEMA_VERSION = MIGRATIONS.length;

export function schemaVersion(database) {
  return Number(database.prepare("PRAGMA user_version").get().user_version);
}

// migration は単一 transaction で適用し、失敗時は既存 state を変更せずに throw する。
// SQLite では DDL も PRAGMA user_version も transaction の対象なので、ROLLBACK すれば
// 列構成とバージョンの両方が移行前へ戻る。
export function migrate(database) {
  const current = schemaVersion(database);
  if (current === SCHEMA_VERSION) return;
  if (current > SCHEMA_VERSION) {
    throw new Error(
      `state database schema version ${current} is newer than supported version ${SCHEMA_VERSION}`,
    );
  }
  database.exec("BEGIN IMMEDIATE");
  try {
    for (let version = current + 1; version <= SCHEMA_VERSION; version += 1) {
      MIGRATIONS[version - 1](database);
    }
    // PRAGMA はプレースホルダを取れないため、検証済みの定数のみを埋め込む。
    database.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}
