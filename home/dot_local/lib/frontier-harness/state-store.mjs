import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";

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

export function createStateStore(databasePath) {
  const database = new DatabaseSync(databasePath, {
    enableForeignKeyConstraints: true,
  });
  database.exec(`
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
  `);

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
  const deleteEvidenceBefore = database.prepare(`
    DELETE FROM evidence WHERE created_at < ?
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
    createTask(input) {
      if (typeof input.goal !== "string" || input.goal.length === 0) {
        throw new TypeError("task.goal must be a non-empty string");
      }
      const task = {
        id: `task_${randomUUID().replaceAll("-", "")}`,
        ...input,
        createdAt: new Date().toISOString(),
      };
      insertTask.run(task.id, task.goal, JSON.stringify(input), task.createdAt);
      return task;
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
    pruneEvidenceBefore(cutoff) {
      return Number(deleteEvidenceBefore.run(cutoff).changes);
    },
    close() {
      database.close();
    },
  };
}
