import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import path from "node:path";

import { assertNotSymlink } from "./paths.mjs";
import { normalizeTask } from "./task.mjs";

// schema を変更したらこの値を上げ、migration を追加する。
const SCHEMA_VERSION = 1;

const SCHEMA_DDL = `
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

function toEvidence(row) {
  return {
    id: row.id,
    kind: row.kind,
    producer: row.producer,
    createdAt: row.created_at,
    command: row.command,
    exitCode: row.exit_code,
    artifactPath: row.artifact_path,
    claimsSupported: JSON.parse(row.claims_supported),
  };
}

export function schemaVersion(database) {
  return Number(database.prepare("PRAGMA user_version").get().user_version);
}

// migration は単一 transaction で適用し、失敗時は既存 state を変更せずに throw する。
function migrate(database) {
  const current = schemaVersion(database);
  if (current === SCHEMA_VERSION) return;
  if (current > SCHEMA_VERSION) {
    throw new Error(
      `state database schema version ${current} is newer than supported version ${SCHEMA_VERSION}`,
    );
  }
  database.exec("BEGIN IMMEDIATE");
  try {
    database.exec(SCHEMA_DDL);
    // PRAGMA はプレースホルダを取れないため、検証済みの定数のみを埋め込む。
    database.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

export function createStateStore(databasePath) {
  if (databasePath !== ":memory:") {
    // DatabaseSync は symlink を解決して開く（= 先に target を作ってしまう）ため、
    // 開く「前」に最終パスと親ディレクトリを検査する。
    assertNotSymlink(path.dirname(databasePath), "state database directory");
    assertNotSymlink(databasePath, "state database");
  }
  const database = new DatabaseSync(databasePath, {
    enableForeignKeyConstraints: true,
  });
  if (databasePath !== ":memory:") {
    chmodSync(databasePath, 0o600);
  }
  database.exec("PRAGMA busy_timeout = 5000");
  if (databasePath !== ":memory:") {
    database.exec("PRAGMA journal_mode = WAL");
  }
  migrate(database);

  const insertEvidence = database.prepare(`
    INSERT INTO evidence (
      id, kind, producer, created_at, command, exit_code, artifact_path, claims_supported
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectEvidence = database.prepare(`
    SELECT id, kind, producer, created_at, command, exit_code, artifact_path, claims_supported
    FROM evidence
    ORDER BY created_at, id
  `);
  const countEvidenceBefore = database.prepare(`
    SELECT COUNT(*) AS expired FROM evidence WHERE created_at < ?
  `);
  const deleteEvidenceBefore = database.prepare(`
    DELETE FROM evidence WHERE created_at < ?
  `);
  const selectEvidenceBefore = database.prepare(`
    SELECT artifact_path FROM evidence WHERE created_at < ?
  `);
  const insertTask = database.prepare(`
    INSERT INTO tasks (id, goal, task_json, created_at) VALUES (?, ?, ?, ?)
  `);
  const insertRoute = database.prepare(`
    INSERT INTO route_decisions (
      id, task_id, kind, capability, provider, reason, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  const selectRoutes = database.prepare(`
    SELECT id, task_id, kind, capability, provider, reason, created_at
    FROM route_decisions
    ORDER BY created_at, id
  `);

  return {
    schemaVersion() {
      return schemaVersion(database);
    },
    storageInfo() {
      const busyTimeout = Number(
        database.prepare("PRAGMA busy_timeout").get().timeout,
      );
      const journalMode = String(
        database.prepare("PRAGMA journal_mode").get().journal_mode,
      );
      return { busyTimeout, journalMode };
    },
    withTransaction(callback) {
      database.exec("BEGIN IMMEDIATE");
      try {
        const result = callback();
        database.exec("COMMIT");
        return result;
      } catch (error) {
        database.exec("ROLLBACK");
        throw error;
      }
    },
    createTask(input) {
      // 境界で正規化し、呼び出し側が渡した id や未知フィールドを持ち込ませない。
      const task = normalizeTask(input);
      const stored = {
        ...task,
        id: `task_${randomUUID().replaceAll("-", "")}`,
        createdAt: new Date().toISOString(),
      };
      insertTask.run(stored.id, stored.goal, JSON.stringify(task), stored.createdAt);
      return stored;
    },
    recordRoute(taskId, route) {
      const stored = {
        id: `route_${randomUUID().replaceAll("-", "")}`,
        taskId,
        kind: route.kind,
        capability: route.capability,
        provider: route.provider,
        reason: route.reason,
        createdAt: new Date().toISOString(),
      };
      insertRoute.run(
        stored.id,
        stored.taskId,
        stored.kind,
        stored.capability,
        stored.provider,
        stored.reason,
        stored.createdAt,
      );
      return stored;
    },
    listRoutes() {
      return selectRoutes.all().map((route) => ({
        id: route.id,
        taskId: route.task_id,
        kind: route.kind,
        capability: route.capability,
        provider: route.provider,
        reason: route.reason,
        createdAt: route.created_at,
      }));
    },
    putEvidence(input) {
      const evidence = {
        id: `ev_${randomUUID().replaceAll("-", "")}`,
        kind: input.kind,
        producer: input.producer,
        createdAt: input.createdAt ?? new Date().toISOString(),
        command: input.command ?? null,
        exitCode: input.exitCode ?? null,
        artifactPath: input.artifactPath ?? null,
        claimsSupported: input.claimsSupported ?? [],
      };
      insertEvidence.run(
        evidence.id,
        evidence.kind,
        evidence.producer,
        evidence.createdAt,
        evidence.command,
        evidence.exitCode,
        evidence.artifactPath,
        JSON.stringify(evidence.claimsSupported),
      );
      return evidence;
    },
    listEvidence() {
      return selectEvidence.all().map(toEvidence);
    },
    countEvidenceBefore(cutoff) {
      return Number(countEvidenceBefore.get(cutoff).expired);
    },
    pruneEvidenceBefore(cutoff, artifactRoot) {
      const skipped = [];
      if (artifactRoot) {
        // 中間ディレクトリの symlink も解決したうえで containment を判定する。
        // path.resolve は symlink を解決しないため、文字列比較だけでは root 外へ出られる。
        const root = realpathOrNull(artifactRoot) ?? path.resolve(artifactRoot);
        for (const row of selectEvidenceBefore.all(cutoff)) {
          if (!row.artifact_path) continue;
          try {
            removeContainedArtifact(root, row.artifact_path);
          } catch (error) {
            // 1 件の不正 path で retention 全体を止めない。個別に隔離して継続する。
            skipped.push({ artifactPath: row.artifact_path, reason: error.message });
          }
        }
      }
      const prunedEvidence = Number(deleteEvidenceBefore.run(cutoff).changes);
      return { prunedEvidence, skippedArtifacts: skipped };
    },
    close() {
      database.close();
    },
  };
}

function realpathOrNull(target) {
  try {
    return path.resolve(target);
  } catch {
    return null;
  }
}

function removeContainedArtifact(root, artifactPath) {
  const target = path.resolve(root, artifactPath);
  if (target === root || !target.startsWith(`${root}${path.sep}`)) {
    throw new Error("artifact path is outside the evidence root");
  }
  // 途中の各コンポーネントが symlink でないことを確認してから unlink する。
  let current = root;
  for (const segment of path.relative(root, target).split(path.sep)) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = lstatSync(current);
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    if (stat.isSymbolicLink()) {
      throw new Error("artifact path must not traverse a symbolic link");
    }
  }
  try {
    unlinkSync(target);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}
