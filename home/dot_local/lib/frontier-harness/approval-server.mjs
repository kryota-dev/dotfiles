import { classifyToolCall } from "./approval-rules.mjs";
import { APPROVAL_ALLOWED_STATUS } from "./approval-queue.mjs";
import { requireObject } from "./record-validation.mjs";

// `claude -p --permission-prompt-tool` の受け口となる stdio MCP server。
//
// 承認要求も AskUserQuestion も同期的な MCP ツール呼び出しとして届く（#529 PRD §1.2.2 /
// §1.2.3 実測）。画面を読まず、キーを送らず、「今まさに未回答か」を推定しない
// —— 呼ばれた時点が未回答であり、返り値が回答である。

// escalation の待機上限。既定は 8 時間で、user が寝ているあいだも保持できる。
export const DEFAULT_ESCALATION_TIMEOUT_MS = 28800000;
// 上限。MCP_TOOL_TIMEOUT の既定 100000000 ms（約 28 時間）を必ず下回るようにする。
export const MAX_ESCALATION_TIMEOUT_MS = 86400000;
// progress 通知の間隔。CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT（stdio 既定 1800000 ms）を
// 大きく下回る必要がある。progress を送るたびに idle timeout はリセットされる。
export const DEFAULT_PROGRESS_INTERVAL_MS = 60000;
// 参照値。progress 間隔がこれを超えたら idle timeout に負ける。
export const MCP_STDIO_IDLE_TIMEOUT_MS = 1800000;
// answer ファイルの確認間隔。承認は人間の応答時間が支配的なので、これで十分細かい。
export const ANSWER_POLL_INTERVAL_MS = 1000;
// 改行を含まない入力でバッファが無制限に伸びるのを防ぐ。想定 client は Claude Code 本体
// だけだが、上限が無いこと自体が堅牢性の欠落なので防御的に置く。
export const MAX_JSONRPC_LINE_LENGTH = 4194304;

export const SERVER_NAME = "frontier-harness-approver";
export const SERVER_VERSION = "1.0.0";
export const APPROVE_TOOL_NAME = "approve";

export const LATEST_PROTOCOL_VERSION = "2025-06-18";
// MCP spec の version negotiation: client の要求値をサポートしていればそれを返し、
// していなければ server の最新版を返す（エラーにはしない）。実装しているのは
// initialize / tools/list / tools/call / ping / notifications だけで、
// これらは下記いずれの revision でも同じ形なので、echo ではなく明示集合で答える。
export const SUPPORTED_PROTOCOL_VERSIONS = Object.freeze(
  new Set([LATEST_PROTOCOL_VERSION, "2025-03-26", "2024-11-05"]),
);

const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603;

const DEFAULT_DENY_MESSAGE =
  "orchestrator policy: this action was not approved by the user";

const APPROVE_TOOL = Object.freeze({
  name: APPROVE_TOOL_NAME,
  description:
    "frontier-harness approval channel. Returns an allow/deny decision for a tool call, escalating to the user when an escalation rule matches.",
  inputSchema: {
    type: "object",
    properties: {
      tool_name: { type: "string" },
      input: { type: "object" },
      tool_use_id: { type: "string" },
    },
    required: ["tool_name", "input"],
  },
});

export function clampEscalationTimeout(value) {
  return Math.min(value, MAX_ESCALATION_TIMEOUT_MS);
}

function successResponse(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function errorResponse(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function decisionContent(decision) {
  // 実測プロトコル: 判断は content[0].text に JSON 文字列として載せる。
  return { content: [{ type: "text", text: JSON.stringify(decision) }] };
}

// permission prompt tool の引数。未知キーは拒否しない —— この payload の形は
// client（Claude Code）が決めるものであり、将来のフィールド追加で承認チャネルが
// 落ちると gate ごと失われる。読むのは必要な 3 つだけに留める。
//
// ただし欠落は補完しない。`input` を空オブジェクトへ補うと、どのルールにも一致せず
// allow が返る（fail-open）。tools/list の inputSchema でも required と宣言している。
export function normalizeApprovalCall(input) {
  requireObject(input, "approval call arguments");
  if (typeof input.tool_name !== "string" || input.tool_name.length === 0) {
    throw new TypeError("approval call tool_name must be a non-empty string");
  }
  const toolInput = input.input;
  requireObject(toolInput, "approval call input");
  if (input.tool_use_id !== undefined && typeof input.tool_use_id !== "string") {
    throw new TypeError("approval call tool_use_id must be a string");
  }
  return {
    toolName: input.tool_name,
    input: toolInput,
    toolUseId: input.tool_use_id ?? null,
  };
}

export function createApprovalServer({
  queue,
  rules,
  session = null,
  cwd = process.cwd(),
  timeoutMs = DEFAULT_ESCALATION_TIMEOUT_MS,
  progressIntervalMs = DEFAULT_PROGRESS_INTERVAL_MS,
  pollIntervalMs = ANSWER_POLL_INTERVAL_MS,
  notify = () => {},
  log = () => {},
  now = () => Date.now(),
  wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  let abortReason = null;
  const cancelled = new Set();
  const pending = new Set();

  function initializeResult(params) {
    const requested = params?.protocolVersion;
    const protocolVersion =
      typeof requested === "string" && SUPPORTED_PROTOCOL_VERSIONS.has(requested)
        ? requested
        : LATEST_PROTOCOL_VERSION;
    return {
      protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions:
        "Escalations are answered by the user through `fh approvals` and `fh approve`.",
    };
  }

  function nextWaitMs(current, deadline, nextProgressAt, hasProgressToken) {
    const untilDeadline = deadline - current;
    const untilProgress = hasProgressToken
      ? nextProgressAt - current
      : Number.POSITIVE_INFINITY;
    return Math.max(1, Math.min(pollIntervalMs, untilDeadline, untilProgress));
  }

  async function waitForDecision(request, jsonRpcId, progressToken) {
    const hasProgressToken =
      progressToken !== undefined && progressToken !== null;
    const deadline = now() + timeoutMs;
    let progress = 0;
    let nextProgressAt = now() + progressIntervalMs;
    pending.add(request.id);
    try {
      for (;;) {
        // 記録済みの user の判断は、abort / cancel / timeout のどれよりも優先する。
        // 先に打ち切り条件を見ると、shutdown と入れ違いに届いた回答が deny に化け、
        // 監査記録も「user は答えなかった」と嘘をつく。
        let answer;
        try {
          answer = queue.readAnswer(request.id, request);
        } catch (error) {
          // 読めない・検証を通らない回答で allow へ倒れる経路を作らない。
          return {
            status: "denied",
            behavior: "deny",
            decidedBy: "validation",
            message: `approval answer rejected: ${error.message}`,
          };
        }
        if (!answer && abortReason !== null) {
          return {
            status: "aborted",
            behavior: "deny",
            decidedBy: "shutdown",
            message: `the approval channel closed before a decision (${abortReason})`,
          };
        }
        if (!answer && cancelled.has(jsonRpcId)) {
          return {
            status: "aborted",
            behavior: "deny",
            decidedBy: "cancelled",
            message: "the client cancelled this permission request",
          };
        }
        if (answer) {
          if (answer.behavior === "allow") {
            return {
              status: APPROVAL_ALLOWED_STATUS,
              behavior: "allow",
              answers: answer.answers,
              message: answer.message,
              decidedBy: "user",
            };
          }
          return {
            status: "denied",
            behavior: "deny",
            decidedBy: "user",
            message: answer.message ?? DEFAULT_DENY_MESSAGE,
          };
        }
        const current = now();
        if (current >= deadline) {
          return {
            status: "timed_out",
            behavior: "deny",
            decidedBy: "timeout",
            message: `no user decision within ${timeoutMs} ms; denied automatically`,
          };
        }
        if (hasProgressToken && current >= nextProgressAt) {
          // progress は単調増加でなければならない（MCP spec）。
          progress += 1;
          notify({
            jsonrpc: "2.0",
            method: "notifications/progress",
            params: {
              progressToken,
              progress,
              message: `waiting for a user decision on ${request.escalation.risk} (${request.id})`,
            },
          });
          nextProgressAt = current + progressIntervalMs;
        }
        await wait(
          nextWaitMs(current, deadline, nextProgressAt, hasProgressToken),
        );
      }
    } finally {
      pending.delete(request.id);
    }
  }

  function behaviorFor(call, stored) {
    // allow を返す唯一の経路は「検証を通った回答が allowed を記録したとき」。
    // behavior ではなく status で判定することで、終端状態を足したときに
    // 黙って allow 側へ倒れることを防ぐ。
    if (stored.status !== APPROVAL_ALLOWED_STATUS) {
      return {
        behavior: "deny",
        message: stored.decision?.message ?? DEFAULT_DENY_MESSAGE,
      };
    }
    const answers = stored.decision?.answers;
    return {
      behavior: "allow",
      updatedInput: answers ? { ...call.input, answers } : call.input,
    };
  }

  async function handleToolCall(id, params) {
    if (params?.name !== APPROVE_TOOL_NAME) {
      return errorResponse(id, INVALID_PARAMS, "unknown tool");
    }
    let call;
    try {
      call = normalizeApprovalCall(params.arguments);
    } catch (error) {
      return errorResponse(id, INVALID_PARAMS, error.message);
    }

    const verdict = classifyToolCall(call, rules);
    if (verdict.decision === "allow") {
      return successResponse(
        id,
        decisionContent({ behavior: "allow", updatedInput: call.input }),
      );
    }

    const request = queue.createRequest({
      sessionId: session,
      cwd,
      toolName: call.toolName,
      toolUseId: call.toolUseId,
      input: call.input,
      escalation: {
        ruleId: verdict.rule.id,
        risk: verdict.rule.risk,
        reason: verdict.rule.reason,
      },
      timeoutAt: new Date(now() + timeoutMs).toISOString(),
    });
    log(
      `escalating ${request.id}: ${call.toolName} matched ${verdict.rule.id} (${verdict.rule.risk})`,
    );
    const outcome = await waitForDecision(request, id, params?._meta?.progressToken);
    const stored = queue.recordOutcome(request.id, outcome);
    log(`resolved ${request.id}: ${stored.status} by ${outcome.decidedBy}`);
    return successResponse(id, decisionContent(behaviorFor(call, stored)));
  }

  async function handleMessage(message) {
    if (message === null || typeof message !== "object" || Array.isArray(message)) {
      return errorResponse(null, INVALID_REQUEST, "message must be a JSON-RPC object");
    }
    const isRequest = Object.hasOwn(message, "id") && message.id !== null;
    const id = isRequest ? message.id : null;
    if (typeof message.method !== "string") {
      return isRequest
        ? errorResponse(id, INVALID_REQUEST, "method must be a string")
        : null;
    }
    switch (message.method) {
      case "initialize":
        return isRequest
          ? successResponse(id, initializeResult(message.params))
          : null;
      case "notifications/initialized":
        return null;
      case "notifications/cancelled": {
        const target = message.params?.requestId;
        if (target !== undefined && target !== null) cancelled.add(target);
        return null;
      }
      case "ping":
        return isRequest ? successResponse(id, {}) : null;
      case "tools/list":
        return isRequest ? successResponse(id, { tools: [APPROVE_TOOL] }) : null;
      case "tools/call":
        return isRequest ? await handleToolCall(id, message.params) : null;
      default:
        return isRequest
          ? errorResponse(id, METHOD_NOT_FOUND, `unsupported method: ${message.method}`)
          : null;
    }
  }

  return {
    handleMessage,
    // 待機中の要求をすべて終わらせる。stdin EOF / SIGTERM / SIGINT から呼ぶ。
    abort(reason) {
      abortReason = reason;
    },
    pendingCount() {
      return pending.size;
    },
  };
}

// 改行区切りの JSON-RPC を stdin/stdout でやりとりする（MCP stdio transport）。
// stdout には JSON-RPC メッセージ以外を書かない。診断は errorOutput（stderr）へ出す。
export function runStdioApprovalServer({
  input,
  output,
  errorOutput = null,
  createServer,
}) {
  const send = (message) => {
    try {
      output.write(`${JSON.stringify(message)}\n`);
    } catch {
      // client が既に切断している。判断そのものは queue のファイルが保持する。
    }
  };
  const server = createServer(send);
  const inFlight = new Set();
  let ended = false;
  let buffer = "";
  let resolveFinished;
  const finished = new Promise((resolve) => {
    resolveFinished = resolve;
  });

  const settle = () => {
    if (ended && inFlight.size === 0) resolveFinished(0);
  };

  // stdin EOF と signal の共通の終わらせ方。abort だけでは足りない ——
  // Node は signal listener を登録すると既定の終了動作を外すため、stdin を読み続けて
  // いる限り event loop が解放されず、要求を aborted にしてもプロセスが残り続ける。
  const shutdown = (reason) => {
    if (ended) return;
    ended = true;
    input.pause();
    server.abort(reason);
    settle();
  };

  const dispatch = (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      send(errorResponse(null, PARSE_ERROR, "parse error"));
      return;
    }
    const task = Promise.resolve()
      .then(() => server.handleMessage(message))
      .then((response) => {
        if (response) send(response);
      })
      .catch((error) => {
        errorOutput?.write(`${SERVER_NAME}: ${error.message}\n`);
        if (Object.hasOwn(message ?? {}, "id") && message.id !== null) {
          send(errorResponse(message.id, INTERNAL_ERROR, error.message));
        }
      })
      .finally(() => {
        inFlight.delete(task);
        settle();
      });
    inFlight.add(task);
  };

  input.setEncoding("utf8");
  input.on("data", (chunk) => {
    buffer += chunk;
    let index = buffer.indexOf("\n");
    while (index !== -1) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (line) dispatch(line);
      index = buffer.indexOf("\n");
    }
    if (buffer.length > MAX_JSONRPC_LINE_LENGTH) {
      buffer = "";
      send(errorResponse(null, PARSE_ERROR, "message exceeds the maximum line length"));
    }
  });
  // MCP の stdio shutdown は client が stdin を閉じることで始まる。
  input.on("end", () => shutdown("the client closed its side of the connection"));

  return { finished, shutdown };
}
