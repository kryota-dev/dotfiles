import { spawnSync } from "node:child_process";
import path from "node:path";

import {
  APPROVE_TOOL_NAME,
  LATEST_PROTOCOL_VERSION,
  SERVER_NAME,
} from "./approval-server.mjs";
import { findCommand } from "./command-paths.mjs";
import { PROVIDER_COMMANDS } from "./providers.mjs";

// 子セッションへ渡す承認 server の宣言と、その server が本当に喋ることの起動前確認。
//
// `approval-server.mjs` が受け口（子から呼ばれる側）であるのに対し、こちらは宣言する側である。
// 分けているのは、宣言の誤りが「承認できない子が黙って走り出す」という**沈黙する故障**になる
// からで、宣言の組み立てと実証をまとめて 1 か所に閉じ込めておきたい。

// 自分自身の実行ファイル名。承認 server は `frontier-harness approve-server` として起動する。
const HARNESS_COMMAND = "frontier-harness";

// `--permission-prompt-tool` に渡すツール名。**リテラルで書かない** ——
// server 名とツール名の SSOT は approval-server.mjs 側にあり、そこから導出しないと
// 片方を変えたときに配線だけが静かに外れる（adapter 側の allowlist は形しか見ない）。
export const APPROVAL_PROMPT_TOOL = `mcp__${SERVER_NAME}__${APPROVE_TOOL_NAME}`;

// handshake の待ち上限。子が承認 server へ接続するのを待つ `MCP_TIMEOUT` の既定
// （30000 ms、#526 §1.2.4）と同じ budget を置く。ここで喋れない server は、子の側でも
// 接続に失敗する。承認の待機時間（DEFAULT_ESCALATION_TIMEOUT_MS 等）とは別物なので、
// あちらの定数を流用しない。
export const APPROVAL_PROBE_TIMEOUT_MS = 30000;
// handshake の応答は 2 行しかない。上限は事故（別プログラムを指した等）の受け皿。
const PROBE_MAX_BUFFER_BYTES = 1048576;

const INITIALIZE_ID = 1;
const TOOLS_LIST_ID = 2;

// 承認 server の実行ファイルを解決する。
//
// 相対パスを認めないのは sealInvocation が executable に課すのと同じ理由である:
// 相対パスは子の CWD（＝作業ツリー）基準で解決され、untrusted repository が同梱した
// 実行ファイルを承認 server に据えられる。
export function resolveApprovalServerCommand({ explicit, environment = {} } = {}) {
  if (explicit !== undefined && explicit !== null) {
    if (typeof explicit !== "string" || !path.isAbsolute(explicit)) {
      throw new TypeError(
        "--approval-server-command must be an absolute path to the frontier-harness executable",
      );
    }
    return explicit;
  }
  const resolved = findCommand(HARNESS_COMMAND, environment.PATH ?? "");
  if (resolved === null) {
    throw new Error(
      `${HARNESS_COMMAND} is not on PATH as an absolute entry; the child would have no approval channel`,
    );
  }
  return resolved;
}

// 子の `--mcp-config` に載せる宣言。adapter 側（approvalServerConfig）が key と中身を
// 検証するので、ここでは形を組み立てるだけにする。
//
// **timeout の既定値をここに持たない。** 渡されたときだけフラグを足し、既定は
// approval-server.mjs 側の定数に委ねる（同じ既定を 2 か所に置くと必ず drift する）。
export function approvalServerDeclaration({
  command,
  sessionId,
  approvalsDirectory,
  timeoutMs,
  progressIntervalMs,
}) {
  const args = [
    "approve-server",
    "--session",
    sessionId,
    "--approvals-dir",
    approvalsDirectory,
  ];
  if (timeoutMs !== undefined) args.push("--timeout-ms", String(timeoutMs));
  if (progressIntervalMs !== undefined) {
    args.push("--progress-interval-ms", String(progressIntervalMs));
  }
  return { key: SERVER_NAME, command, args };
}

function handshakeRequest() {
  return `${[
    {
      jsonrpc: "2.0",
      id: INITIALIZE_ID,
      method: "initialize",
      params: {
        protocolVersion: LATEST_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: HARNESS_COMMAND, version: "1.0.0" },
      },
    },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: TOOLS_LIST_ID, method: "tools/list" },
  ]
    .map((message) => JSON.stringify(message))
    .join("\n")}\n`;
}

function publishesApproveTool(stdout) {
  for (const line of String(stdout ?? "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      // handshake 以外の出力が混ざっても 1 行で打ち切らない。判定は「approve が
      // 見つかったか」だけなので、読めない行は単に材料にならない。
      continue;
    }
    if (message?.id !== TOOLS_LIST_ID) continue;
    const tools = message?.result?.tools;
    if (!Array.isArray(tools)) continue;
    if (tools.some((tool) => tool?.name === APPROVE_TOOL_NAME)) return true;
  }
  return false;
}

// 宣言した承認 server を 1 度起こし、MCP handshake が成立することを確かめる。
//
// **これは事後検査ではなく事前検査である。** 子を起こしてから `system/init` を見るのでは、
// 承認できない子が既に走り出している。stdio server は stdin の EOF で終了するので、
// 2 つの要求を `input` に流し込むだけで handshake が完結し、同期に判定できる。
//
// 判定できない結果（spawn 失敗・非 0 終了・タイムアウト・応答が読めない）はすべて
// 「健全ではない」へ倒す（読み取れないことは、繋がっていることの証拠ではない）。
export function probeApprovalServer({
  command,
  args,
  spawn = spawnSync,
  timeoutMs = APPROVAL_PROBE_TIMEOUT_MS,
}) {
  let result;
  try {
    result = spawn(command, args, {
      input: handshakeRequest(),
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: PROBE_MAX_BUFFER_BYTES,
    });
  } catch (error) {
    return { ok: false, reason: `the approval server could not be started: ${error.message}` };
  }
  if (!result) {
    return { ok: false, reason: "the approval server probe returned no result" };
  }
  if (result.error) {
    return {
      ok: false,
      reason: `the approval server could not be started: ${result.error.message}`,
    };
  }
  if (result.signal) {
    return {
      ok: false,
      reason: `the approval server did not complete the handshake within ${timeoutMs} ms`,
    };
  }
  if (result.status !== 0) {
    return {
      ok: false,
      reason: `the approval server exited with status ${result.status}`,
    };
  }
  if (!publishesApproveTool(result.stdout)) {
    return {
      ok: false,
      reason: `the approval server did not publish the ${APPROVE_TOOL_NAME} tool`,
    };
  }
  return { ok: true, reason: null };
}

// 子セッションを走らせる provider。承認チャネルを外部へ往復できるのは claude だけなので
// （#526 §7.2 / provider-capabilities.mjs の approvalChannel 軸）、他 provider の capability を
// 子セッションとして起動しない。
export const SESSION_PROVIDER = "claude";

export function assertSessionProvider(provider) {
  if (provider !== SESSION_PROVIDER) {
    throw new TypeError(
      `a child session requires the ${PROVIDER_COMMANDS[SESSION_PROVIDER]} provider ` +
        `(it is the only one that can round-trip approvals to the user), but the capability declares ${provider}`,
    );
  }
}
