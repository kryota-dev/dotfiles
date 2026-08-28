import {
  parseJsonLines,
  requireInvocationRequest,
  sealInvocation,
} from "./adapter-contract.mjs";

// Antigravity CLI（`agy`）の headless 実行。
//
// この adapter は **read-only 用途に限定**する。#526 §3.3［実測］が、`--sandbox` を付けても
// workspace 外へのファイル書き込みが成功すること（複数回再現）と、逆に `run_command` が
// サンドボックス設定エラーで使用不能になることを確認している。守りたい側を素通しし、
// 壊れて困る側を止めるので、書き込みを伴う実行の封じ込めには使えない。
const PROVIDER = "antigravity";

// #526 §3.1: envelope の status は SUCCESS / ERROR / CANCELED / INTERRUPTED / INVALID /
// WAITING / RUNNING。**失敗は判定できるが、成功は判定できない**（§3.2）。
const FAILURE_STATUSES = new Set(["ERROR", "CANCELED", "INTERRUPTED", "INVALID"]);

// #526 §3.2［実測］: 承認できないツール呼び出しはソフト拒否され、exit 0 / status SUCCESS /
// response 空文字が返る。応答本文の非空判定と標準エラーの走査による成功判定は #536 の範囲なので、
// この adapter は「成功と判定できない」を返すに留める。exit 0 を成功として記録しない。
const INDETERMINATE_REASON =
  "Antigravity cannot be judged successful from its exit code and status alone (see #536)";

// この 2 つは決して出さない。
// - `--sandbox`: 書き込みを止めず、シェルを使用不能にする（#526 §3.3 実測）。
// - `--dangerously-skip-permissions`: 封じ込めは OS 強制ではなく権限ポリシー層にしかないので、
//   このフラグはその唯一の境界を丸ごと外す（同 §3.3）。
const FORBIDDEN_FLAGS = Object.freeze([
  "--sandbox",
  "--dangerously-skip-permissions",
]);

function readEffectiveSandbox(invocation) {
  const { argv } = invocation;
  if (FORBIDDEN_FLAGS.some((flag) => argv.includes(flag))) return null;
  // 封じ込めは既定の権限ポリシー層だけであり、それが成立するのは read-only 用途に限る。
  return { mode: "read-only" };
}

function requireReadOnly(sandbox, phase) {
  if (sandbox.mode === "workspace-write") {
    throw new TypeError(
      `${PROVIDER} ${phase} refuses a write-capable invocation: its sandbox does not stop file writes`,
    );
  }
}

function buildArgv({ prompt, model, effort, conversationId }) {
  const argv = [
    "-p",
    prompt,
    "--output-format",
    "json",
    "--model",
    model,
    "--effort",
    effort,
  ];
  if (conversationId) argv.push("--conversation", conversationId);
  return argv;
}

function seal({ request, phase, conversationId }) {
  const { prompt, model, effort, sandbox } = requireInvocationRequest(
    request,
    `${PROVIDER} ${phase} request`,
  );
  requireReadOnly(sandbox, phase);
  return sealInvocation({
    provider: PROVIDER,
    executable: request.executable,
    argv: buildArgv({ prompt, model, effort, conversationId }),
    phase,
    sandbox,
    readEffectiveSandbox,
  });
}

function launch(request) {
  return seal({ request, phase: "launch", conversationId: null });
}

function resume(request) {
  if (!request?.resumeKey) {
    throw new TypeError(`${PROVIDER} resume requires a resumeKey`);
  }
  return seal({ request, phase: "resume", conversationId: request.resumeKey });
}

// #526 §3.1: envelope は conversation_id / status / response / error / usage を持つ。
function readEnvelope(stdout) {
  const { events } = parseJsonLines(stdout);
  return events.filter((event) => typeof event.status === "string").at(-1) ?? null;
}

function interpret(processResult) {
  const exitCode = processResult?.exitCode ?? null;
  const envelope = readEnvelope(processResult?.stdout);
  const resumeKey =
    typeof envelope?.conversation_id === "string" ? envelope.conversation_id : null;

  if (exitCode !== null && exitCode !== 0) {
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason: `run exited with code ${exitCode}`,
    };
  }
  if (envelope && FAILURE_STATUSES.has(envelope.status)) {
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason: `run reported status ${envelope.status}`,
    };
  }
  if (!envelope) {
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason: "structured output carried no status envelope",
    };
  }
  // status が SUCCESS でも、WAITING / RUNNING のまま終了していても、成功とは言えない。
  return {
    outcome: "indeterminate",
    exitCode,
    resumeKey,
    denials: [],
    failureReason: INDETERMINATE_REASON,
  };
}

export const antigravityAdapter = Object.freeze({
  provider: PROVIDER,
  capabilities: Object.freeze({
    // #526 §3.2: control_request を送るとセッションが ERROR で終わる。承認を外部へ往復させる
    // チャネルが構造的に存在しない。
    approvalChannel: "none",
    // 封じ込めは OS 強制ではなく権限ポリシー層にしかない（#526 §3.3 実測）。
    sandboxEnforcement: "policy",
    // 書き込みの封じ込めを保証できない。route 段階で弾く仕組みは #536 が capability registry 側に足す。
    writeAccess: "unenforceable",
    resumeKey: "conversation-id",
  }),
  launch,
  resume,
  readEffectiveSandbox,
  interpret,
});
