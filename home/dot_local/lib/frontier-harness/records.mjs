import { SHA256_HEX_PATTERN, sha256Hex } from "./hash.mjs";
import {
  ADAPTER_RUN_STATUSES,
  APPROVAL_GRANTORS,
  APPROVAL_KINDS,
  REVIEW_SEVERITIES,
  REVIEW_UNCERTAINTIES,
  TELEMETRY_OUTCOMES,
  TELEMETRY_VERIFICATION_RESULTS,
  TERMINAL_ADAPTER_RUN_STATUSES,
  VERIFICATION_CHECK_KINDS,
  VERIFICATION_STATUSES,
  nowIso,
  optionalBoolean,
  optionalEnum,
  optionalInteger,
  optionalNonEmptyString,
  optionalNonNegativeInteger,
  optionalStringArray,
  optionalTimestamp,
  optionalToken,
  optionalTokenArray,
  optionalUnitInterval,
  rejectUnknownKeys,
  requireEnum,
  requireNonEmptyString,
  requireObject,
  requireTimestamp,
  requireToken,
} from "./record-validation.mjs";

// Evidence Bus の各レコードは adapter / reviewer が生成する未検証入力として扱い、
// task.mjs の normalizeTask と同じ規律で境界を守る。
// 未知キーは拒否し、列挙値はすべて名前付き Set と照合し、id は呼び出し側に決めさせない。

// ---------------------------------------------------------------------------
// evidence
// ---------------------------------------------------------------------------

const EVIDENCE_KEYS = new Set([
  "id",
  "contentHash",
  "kind",
  "producer",
  "createdAt",
  "command",
  "exitCode",
  "artifactPath",
  "claimsSupported",
  "taskId",
  "routeId",
]);

// 「evidence の内容とは何か」の唯一の定義。id と createdAt は内容ではないので含めない。
// putEvidence と migration の backfill が同じ規則で hash を導出するために共有する
// （2 箇所で別々に組み立てると、legacy 行と新規行の hash が静かに食い違う）。
export function evidenceContentHash(content) {
  return sha256Hex({
    kind: content.kind,
    producer: content.producer,
    command: content.command ?? null,
    exitCode: content.exitCode ?? null,
    artifactPath: content.artifactPath ?? null,
    claimsSupported: content.claimsSupported ?? [],
  });
}

// content_hash を内容フィールドから導出する以上、その内容自体が検証されていなければ
// hash は意味を持たない。id と contentHash は受け取っても捨てる（hash は store が必ず
// 自分で導出する。呼び出し側の値を採用すると「保存された hash が内容と一致しない」
// 状態を作れてしまう）。
export function normalizeEvidence(input) {
  requireObject(input, "evidence");
  rejectUnknownKeys(input, EVIDENCE_KEYS, "evidence");

  return Object.freeze({
    kind: requireNonEmptyString(input.kind, "evidence kind"),
    producer: requireNonEmptyString(input.producer, "evidence producer"),
    command: optionalNonEmptyString(input.command, "evidence command"),
    exitCode: optionalInteger(input.exitCode, "evidence exitCode"),
    artifactPath: optionalNonEmptyString(
      input.artifactPath,
      "evidence artifactPath",
    ),
    claimsSupported: Object.freeze(
      optionalStringArray(input.claimsSupported, "evidence claimsSupported"),
    ),
    taskId: optionalNonEmptyString(input.taskId, "evidence taskId"),
    routeId: optionalNonEmptyString(input.routeId, "evidence routeId"),
    createdAt:
      optionalTimestamp(input.createdAt, "evidence createdAt") ?? nowIso(),
  });
}

// ---------------------------------------------------------------------------
// adapter run
// ---------------------------------------------------------------------------

const ADAPTER_RUN_KEYS = new Set([
  "id",
  "taskId",
  "routeId",
  "capability",
  "provider",
  "model",
  "effort",
  "status",
  "startedAt",
  "finishedAt",
  "exitCode",
  "failureReason",
  "createdAt",
]);

// adapter の「起動方式」に属する情報（argv、sandbox 設定、profile path、
// 対話/非対話モード、conversation ID、作業ディレクトリ、環境変数）は意図的に持たない。
// 起動方式は #526 の調査結果で変わりうるため、焼き込むと migration をやり直すことになる。
export function normalizeAdapterRun(input) {
  requireObject(input, "adapter run");
  rejectUnknownKeys(input, ADAPTER_RUN_KEYS, "adapter run");

  const status = requireEnum(
    input.status,
    ADAPTER_RUN_STATUSES,
    "adapter run status",
  );
  const startedAt = requireTimestamp(input.startedAt, "adapter run startedAt");
  const finishedAt = optionalTimestamp(
    input.finishedAt,
    "adapter run finishedAt",
  );

  // 状態と時刻の食い違いを state に残さない。
  if (TERMINAL_ADAPTER_RUN_STATUSES.has(status) && finishedAt === null) {
    throw new TypeError(`adapter run in status ${status} requires finishedAt`);
  }
  if (!TERMINAL_ADAPTER_RUN_STATUSES.has(status) && finishedAt !== null) {
    throw new TypeError(
      `adapter run in status ${status} must not carry finishedAt`,
    );
  }
  if (finishedAt !== null && finishedAt < startedAt) {
    throw new TypeError("adapter run finishedAt must not precede startedAt");
  }

  return Object.freeze({
    taskId: requireNonEmptyString(input.taskId, "adapter run taskId"),
    routeId: requireNonEmptyString(input.routeId, "adapter run routeId"),
    capability: requireNonEmptyString(
      input.capability,
      "adapter run capability",
    ),
    provider: requireNonEmptyString(input.provider, "adapter run provider"),
    model: requireNonEmptyString(input.model, "adapter run model"),
    effort: requireNonEmptyString(input.effort, "adapter run effort"),
    status,
    startedAt,
    finishedAt,
    exitCode: optionalInteger(input.exitCode, "adapter run exitCode"),
    failureReason: optionalNonEmptyString(
      input.failureReason,
      "adapter run failureReason",
    ),
    createdAt:
      optionalTimestamp(input.createdAt, "adapter run createdAt") ?? nowIso(),
  });
}

// ---------------------------------------------------------------------------
// verification result
// ---------------------------------------------------------------------------

const VERIFICATION_RESULT_KEYS = new Set([
  "id",
  "taskId",
  "adapterRunId",
  "checkKind",
  "status",
  "command",
  "exitCode",
  "evidenceId",
  "createdAt",
]);

export function normalizeVerificationResult(input) {
  requireObject(input, "verification result");
  rejectUnknownKeys(input, VERIFICATION_RESULT_KEYS, "verification result");

  return Object.freeze({
    taskId: requireNonEmptyString(input.taskId, "verification result taskId"),
    adapterRunId: optionalNonEmptyString(
      input.adapterRunId,
      "verification result adapterRunId",
    ),
    checkKind: requireEnum(
      input.checkKind,
      VERIFICATION_CHECK_KINDS,
      "verification result checkKind",
    ),
    status: requireEnum(
      input.status,
      VERIFICATION_STATUSES,
      "verification result status",
    ),
    command: optionalNonEmptyString(
      input.command,
      "verification result command",
    ),
    exitCode: optionalInteger(input.exitCode, "verification result exitCode"),
    evidenceId: optionalNonEmptyString(
      input.evidenceId,
      "verification result evidenceId",
    ),
    createdAt:
      optionalTimestamp(input.createdAt, "verification result createdAt") ??
      nowIso(),
  });
}

// ---------------------------------------------------------------------------
// review finding
// ---------------------------------------------------------------------------

const REVIEW_FINDING_KEYS = new Set([
  "id",
  "taskId",
  "adapterRunId",
  "reviewerCapability",
  "severity",
  "uncertainty",
  "summary",
  "discriminatingExperiment",
  "evidenceId",
  "createdAt",
]);

// review finding は actionable evidence（evidenceId）・severity・uncertainty・
// discriminating experiment を持つ形に正規化する。writer の会話履歴や
// 自己正当化は受け取らない（Evidence Bus の契約）。
export function normalizeReviewFinding(input) {
  requireObject(input, "review finding");
  rejectUnknownKeys(input, REVIEW_FINDING_KEYS, "review finding");

  return Object.freeze({
    taskId: requireNonEmptyString(input.taskId, "review finding taskId"),
    adapterRunId: optionalNonEmptyString(
      input.adapterRunId,
      "review finding adapterRunId",
    ),
    reviewerCapability: requireNonEmptyString(
      input.reviewerCapability,
      "review finding reviewerCapability",
    ),
    severity: requireEnum(
      input.severity,
      REVIEW_SEVERITIES,
      "review finding severity",
    ),
    uncertainty: requireEnum(
      input.uncertainty,
      REVIEW_UNCERTAINTIES,
      "review finding uncertainty",
    ),
    summary: requireNonEmptyString(input.summary, "review finding summary"),
    discriminatingExperiment: optionalNonEmptyString(
      input.discriminatingExperiment,
      "review finding discriminatingExperiment",
    ),
    evidenceId: optionalNonEmptyString(
      input.evidenceId,
      "review finding evidenceId",
    ),
    createdAt:
      optionalTimestamp(input.createdAt, "review finding createdAt") ?? nowIso(),
  });
}

// ---------------------------------------------------------------------------
// approval
// ---------------------------------------------------------------------------

const APPROVAL_KEYS = new Set([
  "id",
  "kind",
  "subjectHash",
  "scope",
  "taskId",
  "grantedBy",
  "grantedAt",
  "expiresAt",
  "createdAt",
]);

export function normalizeApproval(input) {
  requireObject(input, "approval");
  rejectUnknownKeys(input, APPROVAL_KEYS, "approval");

  const subjectHash = requireNonEmptyString(
    input.subjectHash,
    "approval subjectHash",
  );
  if (!SHA256_HEX_PATTERN.test(subjectHash)) {
    throw new TypeError("approval subjectHash must be a SHA-256 hex digest");
  }

  const grantedAt = requireTimestamp(input.grantedAt, "approval grantedAt");
  const expiresAt = optionalTimestamp(input.expiresAt, "approval expiresAt");
  if (expiresAt !== null && expiresAt < grantedAt) {
    throw new TypeError("approval expiresAt must not precede grantedAt");
  }

  return Object.freeze({
    kind: requireEnum(input.kind, APPROVAL_KINDS, "approval kind"),
    subjectHash,
    scope: requireNonEmptyString(input.scope, "approval scope"),
    taskId: optionalNonEmptyString(input.taskId, "approval taskId"),
    grantedBy: requireEnum(
      input.grantedBy,
      APPROVAL_GRANTORS,
      "approval grantedBy",
    ),
    grantedAt,
    expiresAt,
    createdAt:
      optionalTimestamp(input.createdAt, "approval createdAt") ?? nowIso(),
  });
}

// ---------------------------------------------------------------------------
// telemetry event
// ---------------------------------------------------------------------------

const TELEMETRY_EVENT_KEYS = new Set([
  "id",
  "taskId",
  "category",
  "scope",
  "risk",
  "provider",
  "model",
  "effort",
  "wallClockMs",
  "inputTokens",
  "outputTokens",
  "toolCalls",
  "toolFailures",
  "verificationResult",
  "reviewPrecision",
  "humanCorrections",
  "rollback",
  "outcome",
  "createdAt",
]);

// 集約テレメトリは raw evidence より長く（180 日）保持されるため、
// 内容を持たないことが保持期間の前提そのものになる。自由記述列を作らず、
// TEXT はすべて enum か token に閉じることで、その性質を型で保証する。
export function normalizeTelemetryEvent(input) {
  requireObject(input, "telemetry event");
  rejectUnknownKeys(input, TELEMETRY_EVENT_KEYS, "telemetry event");

  return Object.freeze({
    taskId: optionalNonEmptyString(input.taskId, "telemetry event taskId"),
    category: requireToken(input.category, "telemetry event category"),
    scope: optionalToken(input.scope, "telemetry event scope"),
    risk: Object.freeze(optionalTokenArray(input.risk, "telemetry event risk")),
    provider: requireToken(input.provider, "telemetry event provider"),
    model: requireToken(input.model, "telemetry event model"),
    effort: requireToken(input.effort, "telemetry event effort"),
    wallClockMs: optionalNonNegativeInteger(
      input.wallClockMs,
      "telemetry event wallClockMs",
    ),
    inputTokens: optionalNonNegativeInteger(
      input.inputTokens,
      "telemetry event inputTokens",
    ),
    outputTokens: optionalNonNegativeInteger(
      input.outputTokens,
      "telemetry event outputTokens",
    ),
    toolCalls: optionalNonNegativeInteger(
      input.toolCalls,
      "telemetry event toolCalls",
    ),
    toolFailures: optionalNonNegativeInteger(
      input.toolFailures,
      "telemetry event toolFailures",
    ),
    verificationResult: optionalEnum(
      input.verificationResult,
      TELEMETRY_VERIFICATION_RESULTS,
      "telemetry event verificationResult",
    ),
    reviewPrecision: optionalUnitInterval(
      input.reviewPrecision,
      "telemetry event reviewPrecision",
    ),
    humanCorrections: optionalNonNegativeInteger(
      input.humanCorrections,
      "telemetry event humanCorrections",
    ),
    rollback: optionalBoolean(input.rollback, "telemetry event rollback"),
    outcome: optionalEnum(
      input.outcome,
      TELEMETRY_OUTCOMES,
      "telemetry event outcome",
    ),
    createdAt:
      optionalTimestamp(input.createdAt, "telemetry event createdAt") ??
      nowIso(),
  });
}
