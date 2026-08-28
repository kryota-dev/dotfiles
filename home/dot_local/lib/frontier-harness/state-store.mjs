import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import path from "node:path";

import { migrate, schemaVersion } from "./migrations.mjs";
import { assertNotSymlink } from "./paths.mjs";
import { newId } from "./record-validation.mjs";
import { evidenceContentHash, normalizeEvidence } from "./records.mjs";
import { createRecordAccessors } from "./state-records.mjs";
import { normalizeTask } from "./task.mjs";

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
    contentHash: row.content_hash,
    taskId: row.task_id,
    routeId: row.route_id,
  };
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

  const records = createRecordAccessors(database);

  const insertEvidence = database.prepare(`
    INSERT INTO evidence (
      id, kind, producer, created_at, command, exit_code, artifact_path,
      claims_supported, content_hash, task_id, route_id
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectEvidence = database.prepare(`
    SELECT id, kind, producer, created_at, command, exit_code, artifact_path,
           claims_supported, content_hash, task_id, route_id
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
      id, task_id, kind, capability, provider, reason, created_at,
      model, effort, reviewer_capability
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectRoutes = database.prepare(`
    SELECT id, task_id, kind, capability, provider, reason, created_at,
           model, effort, reviewer_capability
    FROM route_decisions
    ORDER BY created_at, id
  `);

  // 期限切れ evidence の artifact を、evidence root の中に限って削除する。
  // FS 操作は DB transaction の外で行い、書き込みロックの保持を最小化する。
  function removeExpiredArtifacts(cutoff, artifactRoot) {
    const skipped = [];
    if (!artifactRoot) return skipped;
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
    return skipped;
  }

  return {
    ...records,
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
        id: newId("task"),
        createdAt: new Date().toISOString(),
      };
      insertTask.run(stored.id, stored.goal, JSON.stringify(task), stored.createdAt);
      return stored;
    },
    // chooseRoute が返す model / effort / reviewerCapability も保存する。
    // 以前は捨てていたため、どの capability の「どの model を」選んだ route だったかを
    // 後から再現できなかった。escalation route はこれらを持たないので NULL になる。
    recordRoute(taskId, route) {
      const stored = {
        id: newId("route"),
        taskId,
        kind: route.kind,
        capability: route.capability,
        provider: route.provider,
        model: route.model ?? null,
        effort: route.effort ?? null,
        reviewerCapability: route.reviewerCapability ?? null,
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
        stored.model,
        stored.effort,
        stored.reviewerCapability,
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
        model: route.model,
        effort: route.effort,
        reviewerCapability: route.reviewer_capability,
        reason: route.reason,
        createdAt: route.created_at,
      }));
    },
    putEvidence(input) {
      const content = normalizeEvidence(input);
      const evidence = {
        id: newId("ev"),
        ...content,
        claimsSupported: [...content.claimsSupported],
        // hash は必ず store 側で導出する。呼び出し側の値を採用すると
        // 「保存された hash が内容と一致しない」状態を作れてしまう。
        contentHash: evidenceContentHash(content),
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
        evidence.contentHash,
        evidence.taskId,
        evidence.routeId,
      );
      return evidence;
    },
    listEvidence() {
      return selectEvidence.all().map(toEvidence);
    },
    // raw クラス（30 日）と集約テレメトリ（180 日）の件数を返す。
    // approvals は承認の監査証跡なのでどちらのクラスにも含めない。
    countExpired({ rawCutoff, telemetryCutoff }) {
      return {
        raw: {
          evidence: Number(countEvidenceBefore.get(rawCutoff).expired),
          ...records.countExpiredRecords(rawCutoff),
        },
        telemetry: records.countExpiredTelemetry(telemetryCutoff),
      };
    },
    pruneExpired({ rawCutoff, telemetryCutoff, artifactRoot }) {
      const skippedArtifacts = removeExpiredArtifacts(rawCutoff, artifactRoot);
      // 複数テーブルの削除は単一 transaction で行い、途中で失敗しても
      // 「一部だけ消えた」状態を残さない。
      database.exec("BEGIN IMMEDIATE");
      try {
        // 子 → 親の順。期限内の子が期限切れの親を参照していても
        // ON DELETE SET NULL が参照を外すため、FK 違反にはならない。
        const recordCounts = records.deleteExpiredRecords(rawCutoff);
        const evidence = Number(deleteEvidenceBefore.run(rawCutoff).changes);
        const telemetry = records.deleteExpiredTelemetry(telemetryCutoff);
        database.exec("COMMIT");
        return {
          raw: { evidence, ...recordCounts },
          telemetry,
          skippedArtifacts,
        };
      } catch (error) {
        database.exec("ROLLBACK");
        throw error;
      }
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
