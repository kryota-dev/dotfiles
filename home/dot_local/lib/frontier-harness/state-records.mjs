import {
  normalizeAdapterRun,
  normalizeApproval,
  normalizeReviewFinding,
  normalizeTelemetryEvent,
  normalizeVerificationResult,
} from "./records.mjs";
import { newId } from "./record-validation.mjs";

// Evidence Bus の新規 5 テーブルの accessor。state-store.mjs から分離しているのは
// 責務のためだけで、DB ハンドルは共有する（state-store 側の transaction 内から呼べる）。
// SQL は生成せず明示的な prepared statement のまま書く。この state は
// 安全境界の記録を持つため、監査しやすさをコード量より優先する。

function toAdapterRun(row) {
  return {
    id: row.id,
    taskId: row.task_id,
    routeId: row.route_id,
    capability: row.capability,
    provider: row.provider,
    model: row.model,
    effort: row.effort,
    status: row.status,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
    exitCode: row.exit_code,
    failureReason: row.failure_reason,
    createdAt: row.created_at,
  };
}

function toVerificationResult(row) {
  return {
    id: row.id,
    taskId: row.task_id,
    adapterRunId: row.adapter_run_id,
    checkKind: row.check_kind,
    status: row.status,
    command: row.command,
    exitCode: row.exit_code,
    evidenceId: row.evidence_id,
    createdAt: row.created_at,
  };
}

function toReviewFinding(row) {
  return {
    id: row.id,
    taskId: row.task_id,
    adapterRunId: row.adapter_run_id,
    reviewerCapability: row.reviewer_capability,
    severity: row.severity,
    uncertainty: row.uncertainty,
    summary: row.summary,
    discriminatingExperiment: row.discriminating_experiment,
    evidenceId: row.evidence_id,
    createdAt: row.created_at,
  };
}

function toApproval(row) {
  return {
    id: row.id,
    kind: row.kind,
    subjectHash: row.subject_hash,
    scope: row.scope,
    taskId: row.task_id,
    grantedBy: row.granted_by,
    grantedAt: row.granted_at,
    expiresAt: row.expires_at,
    createdAt: row.created_at,
  };
}

function toTelemetryEvent(row) {
  return {
    id: row.id,
    taskId: row.task_id,
    category: row.category,
    scope: row.scope,
    risk: JSON.parse(row.risk),
    provider: row.provider,
    model: row.model,
    effort: row.effort,
    wallClockMs: row.wall_clock_ms,
    inputTokens: row.input_tokens,
    outputTokens: row.output_tokens,
    toolCalls: row.tool_calls,
    toolFailures: row.tool_failures,
    verificationResult: row.verification_result,
    reviewPrecision: row.review_precision,
    humanCorrections: row.human_corrections,
    // SQLite の STRICT には BOOLEAN が無いため 0/1 で持ち、境界で boolean に戻す。
    rollback: row.rollback === 1,
    outcome: row.outcome,
    createdAt: row.created_at,
  };
}

export function createRecordAccessors(database) {
  const insertAdapterRun = database.prepare(`
    INSERT INTO adapter_runs (
      id, task_id, route_id, capability, provider, model, effort,
      status, started_at, finished_at, exit_code, failure_reason, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectAdapterRuns = database.prepare(`
    SELECT id, task_id, route_id, capability, provider, model, effort,
           status, started_at, finished_at, exit_code, failure_reason, created_at
    FROM adapter_runs
    ORDER BY created_at, id
  `);

  const insertVerificationResult = database.prepare(`
    INSERT INTO verification_results (
      id, task_id, adapter_run_id, check_kind, status,
      command, exit_code, evidence_id, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectVerificationResults = database.prepare(`
    SELECT id, task_id, adapter_run_id, check_kind, status,
           command, exit_code, evidence_id, created_at
    FROM verification_results
    ORDER BY created_at, id
  `);

  const insertReviewFinding = database.prepare(`
    INSERT INTO review_findings (
      id, task_id, adapter_run_id, reviewer_capability, severity, uncertainty,
      summary, discriminating_experiment, evidence_id, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectReviewFindings = database.prepare(`
    SELECT id, task_id, adapter_run_id, reviewer_capability, severity, uncertainty,
           summary, discriminating_experiment, evidence_id, created_at
    FROM review_findings
    ORDER BY created_at, id
  `);

  const insertApproval = database.prepare(`
    INSERT INTO approvals (
      id, kind, subject_hash, scope, task_id,
      granted_by, granted_at, expires_at, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectApprovals = database.prepare(`
    SELECT id, kind, subject_hash, scope, task_id,
           granted_by, granted_at, expires_at, created_at
    FROM approvals
    ORDER BY created_at, id
  `);

  const insertTelemetryEvent = database.prepare(`
    INSERT INTO telemetry_events (
      id, task_id, category, scope, risk, provider, model, effort,
      wall_clock_ms, input_tokens, output_tokens, tool_calls, tool_failures,
      verification_result, review_precision, human_corrections, rollback,
      outcome, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const selectTelemetryEvents = database.prepare(`
    SELECT id, task_id, category, scope, risk, provider, model, effort,
           wall_clock_ms, input_tokens, output_tokens, tool_calls, tool_failures,
           verification_result, review_precision, human_corrections, rollback,
           outcome, created_at
    FROM telemetry_events
    ORDER BY created_at, id
  `);

  // retention（raw クラス）。approvals は承認の監査証跡なのでここに含めない。
  const countAdapterRunsBefore = database.prepare(
    "SELECT COUNT(*) AS expired FROM adapter_runs WHERE created_at < ?",
  );
  const countVerificationResultsBefore = database.prepare(
    "SELECT COUNT(*) AS expired FROM verification_results WHERE created_at < ?",
  );
  const countReviewFindingsBefore = database.prepare(
    "SELECT COUNT(*) AS expired FROM review_findings WHERE created_at < ?",
  );
  const deleteAdapterRunsBefore = database.prepare(
    "DELETE FROM adapter_runs WHERE created_at < ?",
  );
  const deleteVerificationResultsBefore = database.prepare(
    "DELETE FROM verification_results WHERE created_at < ?",
  );
  const deleteReviewFindingsBefore = database.prepare(
    "DELETE FROM review_findings WHERE created_at < ?",
  );

  // retention（集約クラス）。raw より長く保持するため、raw 側の行を参照しない。
  const countTelemetryBefore = database.prepare(
    "SELECT COUNT(*) AS expired FROM telemetry_events WHERE created_at < ?",
  );
  const deleteTelemetryBefore = database.prepare(
    "DELETE FROM telemetry_events WHERE created_at < ?",
  );

  return {
    recordAdapterRun(input) {
      const run = { id: newId("arun"), ...normalizeAdapterRun(input) };
      insertAdapterRun.run(
        run.id,
        run.taskId,
        run.routeId,
        run.capability,
        run.provider,
        run.model,
        run.effort,
        run.status,
        run.startedAt,
        run.finishedAt,
        run.exitCode,
        run.failureReason,
        run.createdAt,
      );
      return run;
    },
    listAdapterRuns() {
      return selectAdapterRuns.all().map(toAdapterRun);
    },

    recordVerificationResult(input) {
      const result = {
        id: newId("vres"),
        ...normalizeVerificationResult(input),
      };
      insertVerificationResult.run(
        result.id,
        result.taskId,
        result.adapterRunId,
        result.checkKind,
        result.status,
        result.command,
        result.exitCode,
        result.evidenceId,
        result.createdAt,
      );
      return result;
    },
    listVerificationResults() {
      return selectVerificationResults.all().map(toVerificationResult);
    },

    recordReviewFinding(input) {
      const finding = { id: newId("rfind"), ...normalizeReviewFinding(input) };
      insertReviewFinding.run(
        finding.id,
        finding.taskId,
        finding.adapterRunId,
        finding.reviewerCapability,
        finding.severity,
        finding.uncertainty,
        finding.summary,
        finding.discriminatingExperiment,
        finding.evidenceId,
        finding.createdAt,
      );
      return finding;
    },
    listReviewFindings() {
      return selectReviewFindings.all().map(toReviewFinding);
    },

    recordApproval(input) {
      const approval = { id: newId("appr"), ...normalizeApproval(input) };
      insertApproval.run(
        approval.id,
        approval.kind,
        approval.subjectHash,
        approval.scope,
        approval.taskId,
        approval.grantedBy,
        approval.grantedAt,
        approval.expiresAt,
        approval.createdAt,
      );
      return approval;
    },
    listApprovals() {
      return selectApprovals.all().map(toApproval);
    },

    recordTelemetryEvent(input) {
      const event = { id: newId("tel"), ...normalizeTelemetryEvent(input) };
      insertTelemetryEvent.run(
        event.id,
        event.taskId,
        event.category,
        event.scope,
        JSON.stringify(event.risk),
        event.provider,
        event.model,
        event.effort,
        event.wallClockMs,
        event.inputTokens,
        event.outputTokens,
        event.toolCalls,
        event.toolFailures,
        event.verificationResult,
        event.reviewPrecision,
        event.humanCorrections,
        event.rollback ? 1 : 0,
        event.outcome,
        event.createdAt,
      );
      return event;
    },
    listTelemetryEvents() {
      return selectTelemetryEvents.all().map(toTelemetryEvent);
    },

    countExpiredRecords(cutoff) {
      return {
        adapterRuns: Number(countAdapterRunsBefore.get(cutoff).expired),
        verificationResults: Number(
          countVerificationResultsBefore.get(cutoff).expired,
        ),
        reviewFindings: Number(countReviewFindingsBefore.get(cutoff).expired),
      };
    },
    // 子 → 親の順に削除する。期限内の子が期限切れの親を参照していても
    // ON DELETE SET NULL が参照を外すため、FK 違反で retention 全体は止まらない。
    deleteExpiredRecords(cutoff) {
      const reviewFindings = Number(deleteReviewFindingsBefore.run(cutoff).changes);
      const verificationResults = Number(
        deleteVerificationResultsBefore.run(cutoff).changes,
      );
      const adapterRuns = Number(deleteAdapterRunsBefore.run(cutoff).changes);
      return { adapterRuns, verificationResults, reviewFindings };
    },
    countExpiredTelemetry(cutoff) {
      return Number(countTelemetryBefore.get(cutoff).expired);
    },
    deleteExpiredTelemetry(cutoff) {
      return Number(deleteTelemetryBefore.run(cutoff).changes);
    },
  };
}
