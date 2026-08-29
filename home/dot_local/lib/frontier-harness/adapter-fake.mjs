import {
  requireInvocationRequest,
  requireSafeArgumentValue,
  sealInvocation,
  walkFlagPairs,
} from "./adapter-contract.mjs";

// 実 credential・実クォータを使わない adapter と runner。
//
// 出荷はするが**既定 registry には登録しない**（adapters.mjs）。登録すると、設定の取り違えで
// 本物の route が fake に落ちても誰も気づかない。テストと開発時に明示的に注入して使う。

const DEFAULT_CAPABILITIES = Object.freeze({
  approvalChannel: "none",
  sandboxEnforcement: "policy",
  writeAccess: "supported",
  resumeKey: "fake-session",
});

function readEffectiveSandbox(invocation) {
  const index = invocation.argv.indexOf("--sandbox");
  if (index === -1) return null;
  const mode = invocation.argv[index + 1];
  return typeof mode === "string" ? { mode } : null;
}

// fake も実 adapter と同じ契約を通す。ここだけ素通りにすると、契約テストが fake で緑になっても
// 実物の保証にならない（この考え方は DEFAULT_CAPABILITIES 上のコメントと同じ）。
const FAKE_FLAGS = Object.freeze({
  "-p": true,
  "--phase": true,
  "--sandbox": true,
  "--model": true,
  "--effort": true,
  "--resume": true,
});

function readEffectiveConfigIsolation(invocation) {
  return walkFlagPairs(invocation?.argv, FAKE_FLAGS) !== null;
}

// 既定の結果解釈: stdout が正規化済みの結果 JSON なら採用し、そうでなければ終了コードで決める。
// テストが「構造化出力の解釈」と「終了コードだけの解釈」の両方を駆動できるようにするため。
function defaultInterpret(processResult) {
  const exitCode = processResult?.exitCode ?? null;
  try {
    const parsed = JSON.parse(String(processResult?.stdout ?? ""));
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return { exitCode, denials: [], ...parsed };
    }
  } catch {
    // 構造化出力が無い実行として扱う。
  }
  return {
    outcome: exitCode === 0 ? "succeeded" : "failed",
    exitCode,
    resumeKey: null,
    denials: [],
    failureReason: exitCode === 0 ? null : `run exited with code ${exitCode}`,
  };
}

export function createFakeAdapter({
  provider = "fake",
  capabilities = DEFAULT_CAPABILITIES,
  interpret = defaultInterpret,
} = {}) {
  function buildArgv({ prompt, model, effort, sandbox, phase, resumeKey }) {
    const argv = [
      "--phase",
      phase,
      "--sandbox",
      sandbox.mode,
      "--model",
      model,
      "--effort",
      effort,
    ];
    if (resumeKey) argv.push("--resume", resumeKey);
    argv.push("-p", prompt);
    return argv;
  }

  function seal({ request, phase, resumeKey }) {
    const { prompt, model, effort, sandbox } = requireInvocationRequest(
      request,
      `${provider} ${phase} request`,
    );
    return sealInvocation({
      provider,
      executable: request.executable,
      argv: buildArgv({ prompt, model, effort, sandbox, phase, resumeKey }),
      phase,
      sandbox,
      readEffectiveSandbox,
      readEffectiveConfigIsolation,
    });
  }

  return Object.freeze({
    provider,
    capabilities: Object.freeze({ ...capabilities }),
    launch(request) {
      return seal({ request, phase: "launch", resumeKey: null });
    },
    resume(request) {
      if (!request?.resumeKey) {
        throw new TypeError(`${provider} resume requires a resumeKey`);
      }
      // 実 adapter と同じ検証水準にしておく（fake だけ緩いと契約テストが素通りする）。
      return seal({
        request,
        phase: "resume",
        resumeKey: requireSafeArgumentValue(request.resumeKey, `${provider} resumeKey`),
      });
    },
    readEffectiveSandbox,
    readEffectiveConfigIsolation,
    interpret,
  });
}

// 台本どおりのプロセス結果を順に返す runner。**プロセスを起動しない。**
// 受け取った invocation を `calls` に残すので、「何を起動しようとしたか」を検証できる。
export function createFakeRunner(results = []) {
  const queue = [...results];
  const calls = [];
  function runner(invocation) {
    calls.push(invocation);
    if (queue.length === 0) {
      throw new Error(
        `fake runner has no scripted result for call ${calls.length}`,
      );
    }
    return queue.shift();
  }
  runner.calls = calls;
  return runner;
}
