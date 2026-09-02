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
    -- normalizer を通さない直接書き込み（sqlite3 CLI 等）に対するガードレール。
    -- 同一 UID のプロセスは DB ファイルごと差し替えられるので「境界」ではなく、
    -- 事故と手抜きを弾くための多層防御として置く。
    granted_by TEXT NOT NULL CHECK (granted_by = 'user'),
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
    wall_clock_ms INTEGER CHECK (wall_clock_ms IS NULL OR wall_clock_ms >= 0),
    input_tokens INTEGER CHECK (input_tokens IS NULL OR input_tokens >= 0),
    output_tokens INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
    tool_calls INTEGER CHECK (tool_calls IS NULL OR tool_calls >= 0),
    tool_failures INTEGER CHECK (tool_failures IS NULL OR tool_failures >= 0),
    verification_result TEXT,
    review_precision REAL
      CHECK (review_precision IS NULL OR (review_precision >= 0.0 AND review_precision <= 1.0)),
    human_corrections INTEGER
      CHECK (human_corrections IS NULL OR human_corrections >= 0),
    -- STRICT は storage class しか強制しない。accessor を迂回した書き込みで 2 のような値が
    -- 入ると、読み出し時に静かに false へ潰れる。真偽の domain は SQL 側でも縛る。
    rollback INTEGER NOT NULL CHECK (rollback IN (0, 1)),
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

// v3: 検証結果を「どのツリーを検証したか」に結び付ける（#495 のレビュー指摘）。
//
// v2 までの `verification_results` は task_id と created_at しか持たず、`fh candidate adopt` は
// 「この task の、candidate 作成以降の結果がすべて passed」だけで取り込みを判断していた。これは
// 同じ task に複数の candidate がある場合に破れる —— C1 を検証した合格が、一度も検証していない
// C2 の取り込み根拠として流用できてしまう（C2 の作成後に記録されてさえいれば条件を満たすため）。
//
// `candidate_id` は「どの candidate のツリーで走ったか」、`tree_hash` は「そのとき何が入っていたか」
// を固定する。前者が別ツリーの合格の借用を塞ぎ、後者が「合格したあとにツリーを書き換えて
// 取り込む」経路を塞ぐ。どちらも nullable —— 主ワークツリーに対する検証（candidate 無し）は
// 引き続き正当で、その行は candidate の取り込み根拠にはならない。
const VERIFICATION_PROVENANCE_DDL = `
  ALTER TABLE verification_results ADD COLUMN candidate_id TEXT;
  ALTER TABLE verification_results ADD COLUMN tree_hash TEXT;

  CREATE INDEX IF NOT EXISTS verification_results_candidate_id_idx
    ON verification_results (candidate_id);
`;

// v4: 子セッションが走った capability を、その session id から引けるようにする（#604）。
//
// `fh session resume` は launch 時の capability を継承できず、`--capability` を省くたびに
// 既定へ戻っていた（tier 別 capability を選んだ意図が resume のたびに静かに取り消される）。
// 継承するには「この session id はどの capability で走ったか」を後から引ける必要がある。
//
// 置き場所を **route_decisions** にしたのは、次の 3 つが同時に効くため:
//
//   - **`adapter_runs` には置けない。** v2 の但し書きどおり、そちらには adapter の「起動方式」に
//     属する列（conversation ID を含む）を置かない。加えて `adapter_runs` は retention の
//     prune 対象なので、`rawArtifactsDays` を過ぎたセッションは継承できなくなる。
//     `route_decisions` と `tasks` は prune の対象外である（state-records.mjs の
//     `deleteExpiredRecords` が消すのは adapter_runs / verification_results /
//     review_findings / telemetry_events と evidence だけ）
//   - **capability の写しを作らずに済む。** `route_decisions` は既に「解決後の」
//     capability / model / effort を持っているので、足すのは相関キー 1 本だけでよい。
//     別テーブルへ capability を複製すると、2 つの記録が食い違いうる経路を新設することになる
//   - **子を起こす前に書かれる。** したがって子が異常終了しても capability は残る。
//     「落ちた子を resume する」という、この issue が扱う当のユースケースで引ける
//
// session id は会話内容ではない（`requireSafeArgumentValue` を通した識別子であり、
// prompt 本文はここにも tasks にも流れない）。
// index は **partial かつ covering** にする。`route_decisions` は prune されない（それが保存先に
// 選んだ理由でもある）ので、index は消えずに増え続ける。一方、継承元になりうる行は
// 「session_id を持ち、かつ capability が解決済み」のものだけで、`fh session` 以外の route
// （session_id が NULL）も escalation route（capability が NULL）も対象外である。
//
// ［実測］`WHERE session_id = ? AND capability IS NOT NULL ORDER BY created_at DESC, id DESC LIMIT 1`
// に対し、SQLite はこの partial index の述語を含意と認識して `SEARCH ... USING COVERING INDEX`
// を選ぶ（`session_id = ?` が `session_id IS NOT NULL` を含意し、`capability IS NOT NULL` は
// 述語そのもの）。covering なので lookup でテーブル本体を引かない。
const SESSION_ROUTE_DDL = `
  ALTER TABLE route_decisions ADD COLUMN session_id TEXT;

  CREATE INDEX IF NOT EXISTS route_decisions_session_capability_latest_idx
    ON route_decisions (session_id, created_at DESC, id DESC, capability)
    WHERE session_id IS NOT NULL AND capability IS NOT NULL;
`;

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
  function applyVerificationProvenance(database) {
    database.exec(VERIFICATION_PROVENANCE_DDL);
  },
  function applySessionRouteCorrelation(database) {
    database.exec(SESSION_ROUTE_DDL);
  },
];

export const SCHEMA_VERSION = MIGRATIONS.length;

export function schemaVersion(database) {
  return Number(database.prepare("PRAGMA user_version").get().user_version);
}

function unsupportedVersionError(version) {
  return new Error(
    `state database schema version ${version} is newer than supported version ${SCHEMA_VERSION}`,
  );
}

// migration は単一 transaction で適用し、失敗時は既存 state を変更せずに throw する。
// SQLite では DDL も PRAGMA user_version も transaction の対象なので、ROLLBACK すれば
// 列構成とバージョンの両方が移行前へ戻る。
export function migrate(database) {
  // ロックを取る前の版数は「migration が要るか」の早期判定にだけ使う。
  // これを適用範囲の根拠にしてはならない（下記の再読を参照）。
  const observed = schemaVersion(database);
  if (observed === SCHEMA_VERSION) return;
  if (observed > SCHEMA_VERSION) throw unsupportedVersionError(observed);

  database.exec("BEGIN IMMEDIATE");
  try {
    // 書き込みロックを取ってから user_version を読み直す。state は Git common directory に
    // 置かれ複数の worktree / 並列セッションで共有されるため、BEGIN より前に読んだ版数は
    // 「別プロセスが同じ DB を同時に開いて先に migration を終えた」場合に stale になる。
    // stale な版数を適用範囲の根拠にすると、適用済みのステップを再実行して
    // duplicate column で起動そのものが落ちる。
    const current = schemaVersion(database);
    if (current > SCHEMA_VERSION) throw unsupportedVersionError(current);
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
