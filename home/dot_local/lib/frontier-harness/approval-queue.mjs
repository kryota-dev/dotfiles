import { linkSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

import { ensureDirectory, writeJsonAtomic } from "./paths.mjs";
import { newId, nowIso, rejectUnknownKeys, requireObject } from "./record-validation.mjs";

// 承認要求の永続化。1 要求 1 ファイルで、各ファイルの writer はちょうど 1 つに保つ。
//
//   <id>.request.json  writer: approve-server（作成と outcome の記録）
//   <id>.answer.json   writer: responder（orchestrator or user の `fh approve`）
//
// 単一の state ファイルに全 pending を詰めると writer が競合して lost update を生む。
// wave の実運用では 4 セッション並列時に複数が同時停止した実績があり、
// 1 要求 1 ファイルなら lock 無しで N 並列を扱え、任意の順に解決できる。

export const APPROVAL_REQUEST_VERSION = 1;
export const APPROVAL_ANSWER_VERSION = 1;
export const APPROVAL_REQUEST_ID_PATTERN = /^appreq_[0-9a-f]{32}$/;
const REQUEST_SUFFIX = ".request.json";
const ANSWER_SUFFIX = ".answer.json";

export const APPROVAL_STATUSES = Object.freeze(
  new Set(["pending", "allowed", "denied", "timed_out", "aborted"]),
);

// 「allow を返してよい」唯一の終端状態。ここを 1 か所に固定しておくことで、
// 新しい終端状態を足したときに黙って allow 側へ倒れることを防ぐ。
export const APPROVAL_ALLOWED_STATUS = "allowed";

const ANSWER_KEYS = new Set([
  "version",
  "requestId",
  "behavior",
  "message",
  "answers",
  "answeredAt",
]);

export function approvalsDirectory(stateDirectory) {
  return path.join(stateDirectory, "approvals");
}

// CLI から来る要求 ID をそのままファイル名に連結するため、形式を先に固定する。
// `../` を含む値でパスを組み立てさせない。
export function assertApprovalRequestId(id) {
  if (typeof id !== "string" || !APPROVAL_REQUEST_ID_PATTERN.test(id)) {
    throw new TypeError(
      "approval request id must match appreq_ followed by 32 hex characters",
    );
  }
  return id;
}

function requireOptionalString(value, label) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} must be a non-empty string`);
  }
  return value;
}

// AskUserQuestion の回答検証。書き込み側（fh approve）と読み出し側（approve-server）が
// 同じ関数を使う。片側だけの検証にすると、CLI を迂回した書き込みが素通りする。
export function normalizeQuestionAnswers(answers, request) {
  const questions = request?.input?.questions;
  if (request?.toolName !== "AskUserQuestion" || !Array.isArray(questions)) {
    if (answers !== undefined && answers !== null) {
      throw new TypeError(
        "approval answer answers is only meaningful for AskUserQuestion",
      );
    }
    return null;
  }
  requireObject(answers, "approval answer answers");
  const expected = new Map();
  for (const question of questions) {
    // questions は子セッションが組み立てた未検証入力として扱う。
    requireObject(question, "AskUserQuestion question");
    if (typeof question.question !== "string" || question.question.length === 0) {
      throw new TypeError("AskUserQuestion question text is missing");
    }
    const labels = Array.isArray(question.options)
      ? question.options
          .map((option) => option?.label)
          .filter((label) => typeof label === "string" && label.length > 0)
      : [];
    if (labels.length === 0) {
      throw new TypeError("AskUserQuestion question offers no option labels");
    }
    expected.set(question.question, {
      labels,
      multiSelect: question.multiSelect === true,
    });
  }
  const provided = Object.keys(answers);
  if (
    provided.length !== expected.size ||
    provided.some((question) => !expected.has(question))
  ) {
    throw new TypeError(
      "approval answer must answer exactly the questions that were asked",
    );
  }
  const normalized = {};
  for (const [question, { labels, multiSelect }] of expected) {
    const value = answers[question];
    if (!multiSelect && Array.isArray(value)) {
      throw new TypeError(
        "approval answer supplies multiple labels for a single-select question",
      );
    }
    const chosen = Array.isArray(value) ? value : [value];
    if (chosen.length === 0) {
      throw new TypeError("approval answer must choose at least one label");
    }
    for (const label of chosen) {
      if (typeof label !== "string" || !labels.includes(label)) {
        throw new TypeError(
          "approval answer contains a label that was not offered",
        );
      }
    }
    normalized[question] = multiSelect ? [...chosen] : chosen[0];
  }
  return normalized;
}

export function normalizeAnswerRecord(input, request) {
  requireObject(input, "approval answer");
  rejectUnknownKeys(input, ANSWER_KEYS, "approval answer");
  if (input.version !== APPROVAL_ANSWER_VERSION) {
    throw new TypeError("approval answer version must be 1");
  }
  if (input.requestId !== request.id) {
    throw new TypeError("approval answer does not belong to this request");
  }
  if (input.behavior !== "allow" && input.behavior !== "deny") {
    throw new TypeError("approval answer behavior must be allow or deny");
  }
  return Object.freeze({
    version: APPROVAL_ANSWER_VERSION,
    requestId: request.id,
    behavior: input.behavior,
    message: requireOptionalString(input.message, "approval answer message"),
    // deny のとき answers は意味を持たない。allow のときだけ検証して採用する。
    answers:
      input.behavior === "allow"
        ? normalizeQuestionAnswers(input.answers, request)
        : null,
    answeredAt:
      requireOptionalString(input.answeredAt, "approval answer answeredAt") ??
      nowIso(),
  });
}

function assertStoredRequest(record) {
  requireObject(record, "approval request");
  if (!APPROVAL_REQUEST_ID_PATTERN.test(record.id ?? "")) {
    throw new TypeError("approval request record has no valid id");
  }
  if (!APPROVAL_STATUSES.has(record.status)) {
    throw new TypeError("approval request record has an unknown status");
  }
  return record;
}

export function createApprovalQueue({ directory }) {
  ensureDirectory(directory, "approval queue directory");
  const requestPath = (id) =>
    path.join(directory, `${assertApprovalRequestId(id)}${REQUEST_SUFFIX}`);
  const answerPath = (id) =>
    path.join(directory, `${assertApprovalRequestId(id)}${ANSWER_SUFFIX}`);

  function readJsonOrNull(target, label) {
    let raw;
    try {
      raw = readFileSync(target, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
    try {
      return JSON.parse(raw);
    } catch (error) {
      throw new TypeError(`${label} is not valid JSON: ${error.message}`);
    }
  }

  function readRequest(id) {
    const record = readJsonOrNull(requestPath(id), "approval request");
    if (record === null) {
      throw new TypeError("approval request does not exist");
    }
    return assertStoredRequest(record);
  }

  return {
    directory,

    // writer: server。escalation が起きた時点で 1 度だけ書く。
    createRequest({
      sessionId = null,
      cwd,
      toolName,
      toolUseId = null,
      input,
      escalation,
      timeoutAt,
    }) {
      const record = {
        version: APPROVAL_REQUEST_VERSION,
        id: newId("appreq"),
        sessionId,
        pid: process.pid,
        cwd,
        toolName,
        toolUseId,
        input,
        escalation,
        createdAt: nowIso(),
        timeoutAt,
        status: "pending",
        decidedAt: null,
        decision: null,
      };
      writeJsonAtomic(requestPath(record.id), record, "approval request");
      return record;
    },

    // writer: server。同じファイルを書き換えるが、writer は server だけなので競合しない。
    recordOutcome(id, { status, behavior, message = null, answers = null, decidedBy }) {
      if (!APPROVAL_STATUSES.has(status)) {
        throw new TypeError("approval outcome status is not a known status");
      }
      const updated = {
        ...readRequest(id),
        status,
        decidedAt: nowIso(),
        decision: { behavior, message, answers, decidedBy },
      };
      writeJsonAtomic(requestPath(id), updated, "approval request");
      return updated;
    },

    readRequest,

    // 1 件の破損で pending 一覧全体が読めなくなることを避け、壊れた要求は skipped に隔離する
    // （state-store の skippedArtifacts と同じ姿勢）。
    listRequests({ status } = {}) {
      const requests = [];
      const skipped = [];
      let entries;
      try {
        entries = readdirSync(directory);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
        entries = [];
      }
      for (const entry of entries) {
        if (!entry.endsWith(REQUEST_SUFFIX)) continue;
        const id = entry.slice(0, -REQUEST_SUFFIX.length);
        if (!APPROVAL_REQUEST_ID_PATTERN.test(id)) {
          skipped.push({ entry, reason: "unrecognized approval request file name" });
          continue;
        }
        try {
          const record = readRequest(id);
          if (!status || record.status === status) requests.push(record);
        } catch (error) {
          skipped.push({ entry, reason: error.message });
        }
      }
      requests.sort((left, right) => {
        if (left.createdAt !== right.createdAt) {
          return left.createdAt < right.createdAt ? -1 : 1;
        }
        return left.id < right.id ? -1 : 1;
      });
      return { requests, skipped };
    },

    hasAnswer(id) {
      return readJsonOrNull(answerPath(id), "approval answer") !== null;
    },

    // 読み出し側の検証。壊れた answer は null ではなく例外にする
    // （「読めなかったので allow」に倒れる経路を作らない）。
    readAnswer(id, request) {
      const record = readJsonOrNull(answerPath(id), "approval answer");
      if (record === null) return null;
      return normalizeAnswerRecord(record, request);
    },

    // writer: responder。first-write-wins。
    // 一時ファイルを O_EXCL で作り link(2) で公開する。link は対象が既存ファイルでも
    // 既存 symlink でも EEXIST で失敗するので、rename（上書きする）とは違い
    // 「後着が黙って先着を上書きする」が起こりえない。
    writeAnswer(id, answer) {
      const target = answerPath(id);
      const temporaryPath = path.join(directory, `.${randomUUID()}${ANSWER_SUFFIX}.tmp`);
      writeFileSync(temporaryPath, `${JSON.stringify(answer, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
        flag: "wx",
      });
      try {
        linkSync(temporaryPath, target);
      } catch (error) {
        if (error?.code === "EEXIST") {
          throw new TypeError(
            "approval request already has an answer; a request is answered once",
          );
        }
        throw error;
      } finally {
        unlinkSync(temporaryPath);
      }
      return target;
    },
  };
}
