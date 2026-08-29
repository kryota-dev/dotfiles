import path from "node:path";

import {
  APPROVAL_ANSWER_VERSION,
  approvalsDirectory,
  createApprovalQueue,
  normalizeAnswerRecord,
} from "./approval-queue.mjs";
import { loadApprovalRules } from "./approval-rules.mjs";
import {
  DEFAULT_ESCALATION_TIMEOUT_MS,
  DEFAULT_PROGRESS_INTERVAL_MS,
  MCP_STDIO_IDLE_TIMEOUT_MS,
  SERVER_NAME,
  clampEscalationTimeout,
  createApprovalServer,
  runStdioApprovalServer,
} from "./approval-server.mjs";
import { flagValue, optionalFlagValue, positiveIntegerFlag } from "./flags.mjs";
import { nowIso } from "./record-validation.mjs";

// 承認チャネルの CLI コマンド本体。cli.mjs は分岐だけを持ち、ここに委譲する。

// 承認 queue は既定で state root（検証済みの git common directory）配下に置く。
// state root の解決はディレクトリ作成を伴うため、明示指定があるときは呼ばない。
export function resolveApprovalsDirectory({ flags, stateDirectory }) {
  const override = optionalFlagValue(flags, "--approvals-dir");
  if (override) {
    if (!path.isAbsolute(override)) {
      throw new TypeError("--approvals-dir must be an absolute path");
    }
    return override;
  }
  return approvalsDirectory(stateDirectory());
}

// 一覧は responder（orchestrator or user）が判断するための材料をそのまま載せる。
// AskUserQuestion の要求は input.questions に問いと選択肢を持つ。
function summarizeRequest(request) {
  return {
    id: request.id,
    status: request.status,
    sessionId: request.sessionId,
    cwd: request.cwd,
    toolName: request.toolName,
    toolUseId: request.toolUseId,
    risk: request.escalation?.risk ?? null,
    ruleId: request.escalation?.ruleId ?? null,
    reason: request.escalation?.reason ?? null,
    input: request.input,
    createdAt: request.createdAt,
    timeoutAt: request.timeoutAt,
    decidedAt: request.decidedAt ?? null,
    decision: request.decision ?? null,
  };
}

export function runApprovalsCommand({ queue, emit, flags }) {
  // --purge は一覧ではなく後始末。要求 payload に残る質問文と選択肢（＝会話内容）を
  // wave の終了後に残さないための経路で、pending には触れない。
  if (flags.includes("--purge")) {
    emit(queue.purgeDecided());
    return 0;
  }
  const { requests, skipped } = queue.listRequests(
    flags.includes("--all") ? {} : { status: "pending" },
  );
  emit({ approvals: requests.map(summarizeRequest), skipped });
  return 0;
}

export function runApproveCommand({ queue, emit, flags }) {
  const requestId = flagValue(flags, "--request");
  const allow = flags.includes("--allow");
  const deny = flags.includes("--deny");
  if (allow === deny) {
    throw new TypeError("exactly one of --allow or --deny is required");
  }
  const request = queue.readRequest(requestId);
  if (request.status !== "pending") {
    throw new TypeError(`approval request is already ${request.status}`);
  }
  if (queue.hasAnswer(requestId)) {
    throw new TypeError(
      "approval request already has an answer; a request is answered once",
    );
  }
  const rawAnswers = optionalFlagValue(flags, "--answers");
  let answers = null;
  if (rawAnswers !== undefined) {
    try {
      answers = JSON.parse(rawAnswers);
    } catch (error) {
      throw new TypeError(`--answers must be valid JSON: ${error.message}`);
    }
  }
  // 書き込み側でも読み出し側と同じ検証を通す。片側だけにすると、
  // CLI を迂回した書き込みと CLI からの書き込みで規則が食い違う。
  const answer = normalizeAnswerRecord(
    {
      version: APPROVAL_ANSWER_VERSION,
      requestId,
      behavior: allow ? "allow" : "deny",
      message: optionalFlagValue(flags, "--message") ?? null,
      answers,
      answeredAt: nowIso(),
    },
    request,
  );
  queue.writeAnswer(requestId, answer);
  emit({
    requestId,
    behavior: answer.behavior,
    answers: answer.answers,
    toolName: request.toolName,
  });
  return 0;
}

// 起動に失敗したら黙って縮退せず throw する。エスカレートできない approver が
// 静かに立ち上がるより、子が prompt tool に接続できないほうが検出しやすい。
export function startApprovalServerCommand({
  flags,
  environment,
  cwd,
  directory,
  stdin = process.stdin,
  stdout = process.stdout,
  stderr = process.stderr,
  signals = process,
}) {
  // フラグの検証を先に済ませる。ファイル I/O より前に落としたほうが、
  // 誤りの指し先（打ち間違えたフラグ）がそのままエラーになる。
  const timeoutMs = clampEscalationTimeout(
    positiveIntegerFlag(flags, "--timeout-ms") ?? DEFAULT_ESCALATION_TIMEOUT_MS,
  );
  const progressIntervalMs =
    positiveIntegerFlag(flags, "--progress-interval-ms") ??
    DEFAULT_PROGRESS_INTERVAL_MS;
  // progress が idle timeout より疎だと、待機を延ばすという目的そのものが果たせない。
  if (progressIntervalMs >= MCP_STDIO_IDLE_TIMEOUT_MS) {
    throw new TypeError(
      `--progress-interval-ms must stay below the ${MCP_STDIO_IDLE_TIMEOUT_MS} ms stdio idle timeout`,
    );
  }
  const session = optionalFlagValue(flags, "--session") ?? null;
  const rules = loadApprovalRules(
    { rulesPath: optionalFlagValue(flags, "--rules") },
    environment,
  );
  const queue = createApprovalQueue({ directory });

  const transport = runStdioApprovalServer({
    input: stdin,
    output: stdout,
    errorOutput: stderr,
    createServer: (send) =>
      createApprovalServer({
        queue,
        rules,
        session,
        cwd,
        timeoutMs,
        progressIntervalMs,
        notify: send,
        log: (line) => stderr.write(`${SERVER_NAME}: ${line}\n`),
      }),
  });
  // signal を受けたら待機中の要求を aborted として保存したうえで**終了する**。
  // abort だけでは stdin を読み続けたままになり、プロセスが残る（要件 4-7）。
  for (const signal of ["SIGTERM", "SIGINT"]) {
    signals.on(signal, () => transport.shutdown(`received ${signal}`));
  }
  return transport.finished;
}
