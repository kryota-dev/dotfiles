import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { antigravityAdapter } from "../home/dot_local/lib/frontier-harness/adapter-antigravity.mjs";
import { claudeAdapter } from "../home/dot_local/lib/frontier-harness/adapter-claude.mjs";
import { codexAdapter } from "../home/dot_local/lib/frontier-harness/adapter-codex.mjs";
import {
  adapterRunStatusFor,
  assertAdapterShape,
  toAdapterRunInput,
} from "../home/dot_local/lib/frontier-harness/adapter-contract.mjs";
import {
  createFakeAdapter,
  createFakeRunner,
} from "../home/dot_local/lib/frontier-harness/adapter-fake.mjs";
import {
  checkCapabilityExecutable,
  createAdapterExecutor,
  createAdapterRegistry,
} from "../home/dot_local/lib/frontier-harness/adapters.mjs";
import { normalizeAdapterRun } from "../home/dot_local/lib/frontier-harness/records.mjs";
import { runWithRolloutGuard } from "../home/dot_local/lib/frontier-harness/rollout.mjs";
import { SANDBOX_MODES } from "../home/dot_local/lib/frontier-harness/sandbox.mjs";

const LIB_DIR = fileURLToPath(
  new URL("../home/dot_local/lib/frontier-harness/", import.meta.url),
);

// 実 adapter に加えて fake も同じ契約を通す。契約が「実物にだけ通る」形になると、
// fake で書いたテストが実物の振る舞いを保証しなくなる。
const ADAPTERS = [
  antigravityAdapter,
  claudeAdapter,
  codexAdapter,
  createFakeAdapter(),
];

// adapter 層。ここに child_process が入ると「プロセスを起動しない」が規約だけの保証になる。
const ADAPTER_LAYER_FILES = [
  "adapter-antigravity.mjs",
  "adapter-claude.mjs",
  "adapter-codex.mjs",
  "adapter-contract.mjs",
  "adapter-fake.mjs",
  "adapters.mjs",
  "sandbox.mjs",
];

function readLibSource(fileName) {
  return readFileSync(path.join(LIB_DIR, fileName), "utf8");
}

// 書き込みを封じ込められない adapter には read-only しか要求できない。
function supportedModes(adapter) {
  return adapter.capabilities.writeAccess === "supported"
    ? [...SANDBOX_MODES]
    : ["read-only"];
}

function requestFor(adapter, mode, extra = {}) {
  return {
    prompt: "summarize the failing test",
    executable: `/usr/local/bin/${adapter.provider}`,
    model: "gpt-5.6-terra",
    effort: "xhigh",
    sandbox: { mode },
    ...extra,
  };
}

// ---------------------------------------------------------------------------
// 契約 conformance（全 adapter を同じ不変条件で回す）
// ---------------------------------------------------------------------------

test("every adapter satisfies the registry shape contract", () => {
  for (const adapter of ADAPTERS) {
    assert.doesNotThrow(() => assertAdapterShape(adapter), adapter.provider);
  }
});

test("launch and resume run under the same sandbox the caller asked for", () => {
  // #526 §7.2 要件 2: 「初回だけ pin して再開で弱まる」退行を塞ぐ不変条件。
  // sealInvocation が argv から実効値を読み戻すので、ここは読み戻しが要求と一致することを固定する。
  for (const adapter of ADAPTERS) {
    for (const mode of supportedModes(adapter)) {
      const launch = adapter.launch(requestFor(adapter, mode));
      const resume = adapter.resume(
        requestFor(adapter, mode, { resumeKey: "resume-key-1" }),
      );
      assert.deepEqual(
        adapter.readEffectiveSandbox(launch),
        { mode },
        `${adapter.provider} launch under ${mode}`,
      );
      assert.deepEqual(
        adapter.readEffectiveSandbox(resume),
        { mode },
        `${adapter.provider} resume under ${mode}`,
      );
    }
  }
});

test("no adapter can build a resume invocation without a sandbox policy", () => {
  for (const adapter of ADAPTERS) {
    const request = requestFor(adapter, "read-only", { resumeKey: "resume-key-1" });
    delete request.sandbox;
    assert.throws(() => adapter.resume(request), /sandbox/, adapter.provider);
  }
});

test("no adapter can resume without a resume key", () => {
  for (const adapter of ADAPTERS) {
    assert.throws(
      () => adapter.resume(requestFor(adapter, "read-only")),
      /resumeKey/,
      adapter.provider,
    );
  }
});

test("an invocation carries no environment or credential channel", () => {
  // credential とプロファイルパスは各 CLI のランチャーと keychain が持つ。
  // adapter が env を運べる形にすると、そこへ載せる経路が後から生える。
  for (const adapter of ADAPTERS) {
    const invocation = adapter.launch(requestFor(adapter, "read-only"));
    assert.deepEqual(
      Object.keys(invocation).sort(),
      ["argv", "executable", "phase", "provider", "stdin"],
      adapter.provider,
    );
  }
});

test("no adapter emits a flag that removes the permission boundary", () => {
  const forbidden = [
    "--dangerously-skip-permissions",
    "--dangerously-bypass-approvals-and-sandbox",
  ];
  for (const adapter of ADAPTERS) {
    for (const mode of supportedModes(adapter)) {
      for (const invocation of [
        adapter.launch(requestFor(adapter, mode)),
        adapter.resume(requestFor(adapter, mode, { resumeKey: "resume-key-1" })),
      ]) {
        for (const flag of forbidden) {
          assert.ok(
            !invocation.argv.includes(flag),
            `${adapter.provider} ${invocation.phase} emitted ${flag}`,
          );
        }
      }
    }
  }
});

test("an invocation refuses a relative executable path", () => {
  assert.throws(
    () =>
      claudeAdapter.launch(
        requestFor(claudeAdapter, "read-only", { executable: "claude" }),
      ),
    /absolute path/,
  );
});

// ---------------------------------------------------------------------------
// 「provider プロセスを起動しない」を構造で担保する
// ---------------------------------------------------------------------------

test("the adapter layer never imports a process spawner", () => {
  // 完了条件が「provider プロセスを起動せずにテストされる」なので、規約ではなく構造で担保する。
  // 実起動の runner は呼び出し側が注入し、その配線は rollout 昇格（#502）が持つ。
  for (const fileName of ADAPTER_LAYER_FILES) {
    assert.ok(
      !readLibSource(fileName).includes("child_process"),
      `${fileName} must not reach for a process spawner`,
    );
  }
});

test("creating an executor without an injected runner fails loudly", () => {
  assert.throws(
    () =>
      createAdapterExecutor({
        availability: { codex: { available: true, models: null } },
        capability: { provider: "codex", model: "gpt-5.6-terra", effort: "xhigh" },
        capabilityName: "executor.default",
        request: {
          prompt: "go",
          executable: "/usr/local/bin/codex",
          sandbox: { mode: "workspace-write" },
        },
      }),
    /injected runner/,
  );
});

// ---------------------------------------------------------------------------
// Codex: 起動時と再開時でサンドボックス指定の形が違う（#526 §2.3 実測）
// ---------------------------------------------------------------------------

test("codex pins the sandbox with a flag on launch and a config override on resume", () => {
  const launch = codexAdapter.launch(requestFor(codexAdapter, "workspace-write"));
  assert.deepEqual(launch.argv.slice(0, 4), [
    "exec",
    "--sandbox",
    "workspace-write",
    "--json",
  ]);

  const resume = codexAdapter.resume(
    requestFor(codexAdapter, "workspace-write", { resumeKey: "thread-1" }),
  );
  // `codex exec resume` はこれらを受け付けない。出せば起動しないか、設定既定へ戻る。
  for (const flag of ["-s", "--sandbox", "-C", "--cd"]) {
    assert.ok(!resume.argv.includes(flag), `resume emitted ${flag}`);
  }
  // 調査文書のシェル表記 `-c sandbox_mode='"read-only"'` は、argv では二重引用符を値に含む。
  assert.ok(resume.argv.includes('sandbox_mode="workspace-write"'));
  assert.equal(resume.argv[1], "resume");
  assert.equal(resume.argv[2], "thread-1");
});

test("codex reads back no sandbox when a resume invocation would weaken it", () => {
  const readBack = (argv) => codexAdapter.readEffectiveSandbox({ argv });

  // config override が無い再開形は「設定既定へ戻る」ので、読み戻せない = 一致しない。
  assert.equal(readBack(["exec", "resume", "t1", "--json", "go"]), null);
  // 再開で受け付けられないフラグを出している形も一致させない。
  assert.equal(
    readBack(["exec", "resume", "t1", "--sandbox", "read-only", "go"]),
    null,
  );
  // 承認とサンドボックスを丸ごと外すフラグが混ざった形も同様。
  assert.equal(
    readBack([
      "exec",
      "--sandbox",
      "read-only",
      "--dangerously-bypass-approvals-and-sandbox",
      "go",
    ]),
    null,
  );
  assert.deepEqual(readBack(["exec", "--sandbox", "read-only", "--json", "go"]), {
    mode: "read-only",
  });
});

test("codex refuses a positional prompt that would parse as a flag", () => {
  assert.throws(
    () =>
      codexAdapter.launch(
        requestFor(codexAdapter, "read-only", { prompt: "--help me" }),
      ),
    /begins with/,
  );
});

test("codex interprets its structured output rather than its exit code alone", () => {
  const stdout = [
    JSON.stringify({ type: "thread.started", thread_id: "thread-9" }),
    JSON.stringify({ type: "turn.completed" }),
  ].join("\n");
  const succeeded = codexAdapter.interpret({ exitCode: 0, stdout, stderr: "" });
  assert.equal(succeeded.outcome, "succeeded");
  assert.equal(succeeded.resumeKey, "thread-9");

  const errored = codexAdapter.interpret({
    exitCode: 0,
    stdout: JSON.stringify({ type: "error", message: "sandbox denied the write" }),
    stderr: "",
  });
  assert.equal(errored.outcome, "failed");
  assert.match(errored.failureReason, /sandbox denied the write/);

  // 終端イベントが無い出力は、終了コードが 0 でも「完了した」と読まない。
  const truncated = codexAdapter.interpret({
    exitCode: 0,
    stdout: '{"type":"turn.started"}\nnot json',
    stderr: "",
  });
  assert.equal(truncated.outcome, "failed");
  assert.match(truncated.failureReason, /no turn completion \(1 unparsable/);
});

// ---------------------------------------------------------------------------
// Claude: サンドボックスは設定 JSON なので、再開形が設定を落とすと弱まる
// ---------------------------------------------------------------------------

test("claude carries the identical sandbox settings into a resumed run", () => {
  const launch = claudeAdapter.launch(
    requestFor(claudeAdapter, "workspace-write", { sessionId: "session-1" }),
  );
  const resume = claudeAdapter.resume(
    requestFor(claudeAdapter, "workspace-write", { resumeKey: "session-1" }),
  );
  const settingsOf = (invocation) =>
    invocation.argv[invocation.argv.indexOf("--settings") + 1];

  assert.equal(settingsOf(launch), settingsOf(resume));
  assert.deepEqual(JSON.parse(settingsOf(launch)).sandbox.failIfUnavailable, true);
  // 呼び出し側が採番したときは --session-id、再開は --resume。
  assert.ok(launch.argv.includes("--session-id"));
  assert.ok(!launch.argv.includes("--resume"));
  assert.ok(resume.argv.includes("--resume"));
  assert.ok(!resume.argv.includes("--session-id"));
});

test("claude never emits a sandbox flag that does not exist", () => {
  // #526 §1.1［実測］: `claude -p --sandbox` は unknown option になる。
  // 存在しないフラグを出す adapter は、設定 JSON 側が効いていると誤認している。
  const invocation = claudeAdapter.launch(requestFor(claudeAdapter, "read-only"));
  assert.ok(!invocation.argv.includes("--sandbox"));
  // repository 由来の hooks / MCP は起動フラグで事前に遮断する（#526 R2）。
  assert.ok(invocation.argv.includes("--strict-mcp-config"));
  assert.deepEqual(
    invocation.argv.slice(
      invocation.argv.indexOf("--setting-sources"),
      invocation.argv.indexOf("--setting-sources") + 2,
    ),
    ["--setting-sources", "user"],
  );
});

test("claude distinguishes read-only from workspace-write by permission mode", () => {
  // サンドボックスが包むのは Bash だけで、ファイル系ツールは権限システム側にある。
  const readOnly = claudeAdapter.launch(requestFor(claudeAdapter, "read-only"));
  const writable = claudeAdapter.launch(requestFor(claudeAdapter, "workspace-write"));
  assert.ok(readOnly.argv.includes("--permission-mode"));
  assert.ok(!writable.argv.includes("--permission-mode"));
});

test("claude wires the permission prompt tool only when one is supplied", () => {
  // 承認チャネルそのものは #533、route を塞ぐ判断は #534。adapter は配線の要否を決めない。
  const without = claudeAdapter.launch(requestFor(claudeAdapter, "read-only"));
  assert.ok(!without.argv.includes("--permission-prompt-tool"));

  const withTool = claudeAdapter.launch(
    requestFor(claudeAdapter, "read-only", { permissionPromptTool: "mcp__fh__approve" }),
  );
  assert.deepEqual(
    withTool.argv.slice(
      withTool.argv.indexOf("--permission-prompt-tool"),
      withTool.argv.indexOf("--permission-prompt-tool") + 2,
    ),
    ["--permission-prompt-tool", "mcp__fh__approve"],
  );
});

test("claude reads back no sandbox when the settings blob is weakened", () => {
  const weakened = JSON.stringify({
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      autoAllowBashIfSandboxed: true,
      // 失敗コマンドの sandbox 外リトライを許すと、境界は境界でなくなる。
      allowUnsandboxedCommands: true,
      network: { strictAllowlist: true },
    },
  });
  assert.equal(
    claudeAdapter.readEffectiveSandbox({ argv: ["-p", "go", "--settings", weakened] }),
    null,
  );
  assert.equal(claudeAdapter.readEffectiveSandbox({ argv: ["-p", "go"] }), null);
});

test("claude records which tools were denied without their inputs", () => {
  // tool_input はコマンド文字列やファイル内容を含みうるので運ばない。
  const result = claudeAdapter.interpret({
    exitCode: 0,
    stdout: JSON.stringify({
      type: "result",
      is_error: false,
      session_id: "session-2",
      permission_denials: [
        { tool_name: "Bash", tool_input: { command: "curl https://example.com/?k=secret" } },
      ],
    }),
    stderr: "",
  });
  assert.equal(result.outcome, "succeeded");
  assert.deepEqual(result.denials, ["Bash"]);
  assert.equal(result.resumeKey, "session-2");
});

test("claude treats a run without a result event as failed", () => {
  // SIGTERM は exit 143 で、進行中のターンは未完了のまま残る（#526 §1.3）。
  const result = claudeAdapter.interpret({
    exitCode: 143,
    stdout: JSON.stringify({ type: "system", subtype: "init" }),
    stderr: "",
  });
  assert.equal(result.outcome, "failed");
  assert.match(result.failureReason, /no result event/);
});

// ---------------------------------------------------------------------------
// Antigravity: 失敗は判定できるが、成功は判定できない（#526 §3.2 実測）
// ---------------------------------------------------------------------------

test("antigravity never reports success from an exit code and status alone", () => {
  // ソフト拒否は exit 0 / status SUCCESS / response 空で返る。応答本文と標準エラーによる
  // 成功判定の実装は #536 なので、ここでは「判定できない」に留める。
  const softDenied = antigravityAdapter.interpret({
    exitCode: 0,
    stdout: JSON.stringify({
      conversation_id: "conv-1",
      status: "SUCCESS",
      response: "",
    }),
    stderr: 'jetski: no output produced — a tool required the "unsandboxed" permission',
  });
  assert.equal(softDenied.outcome, "indeterminate");
  assert.equal(softDenied.resumeKey, "conv-1");

  // 応答本文があっても、この adapter は成功と断定しない（判定の実装は #536）。
  const withResponse = antigravityAdapter.interpret({
    exitCode: 0,
    stdout: JSON.stringify({
      conversation_id: "conv-2",
      status: "SUCCESS",
      response: "done",
    }),
    stderr: "",
  });
  assert.equal(withResponse.outcome, "indeterminate");

  // 判定不能は state へ fail-closed に写像する（成功として記録しない）。
  assert.equal(adapterRunStatusFor("indeterminate"), "failed");
});

test("antigravity still reports the failures it can determine", () => {
  const errored = antigravityAdapter.interpret({
    exitCode: 0,
    stdout: JSON.stringify({ conversation_id: "conv-3", status: "ERROR" }),
    stderr: "",
  });
  assert.equal(errored.outcome, "failed");

  const exited = antigravityAdapter.interpret({
    exitCode: 2,
    stdout: JSON.stringify({ conversation_id: "conv-4", status: "SUCCESS" }),
    stderr: "",
  });
  assert.equal(exited.outcome, "failed");
});

test("antigravity refuses a write-capable invocation", () => {
  // `--sandbox` はファイル書き込みを止めない（#526 §3.3 実測）。
  for (const build of ["launch", "resume"]) {
    assert.throws(
      () =>
        antigravityAdapter[build](
          requestFor(antigravityAdapter, "workspace-write", { resumeKey: "conv-1" }),
        ),
      /does not stop file writes/,
      build,
    );
  }
});

test("antigravity emits neither its ineffective sandbox flag nor a permission bypass", () => {
  const invocation = antigravityAdapter.launch(
    requestFor(antigravityAdapter, "read-only"),
  );
  assert.ok(!invocation.argv.includes("--sandbox"));
  assert.ok(!invocation.argv.includes("--dangerously-skip-permissions"));
  assert.ok(invocation.argv.includes("--output-format"));
});

// ---------------------------------------------------------------------------
// capability registry との接続（実行前検査）
// ---------------------------------------------------------------------------

const CODEX_CAPABILITY = Object.freeze({
  provider: "codex",
  model: "gpt-5.6-terra",
  effort: "xhigh",
});

function check(overrides = {}) {
  return checkCapabilityExecutable({
    adapter: codexAdapter,
    availability: { codex: { available: true, models: null } },
    capability: CODEX_CAPABILITY,
    executablePath: "/usr/local/bin/codex",
    sandbox: { mode: "workspace-write" },
    ...overrides,
  });
}

test("the pre-flight check mirrors the router's exact model ID rule", () => {
  // readiness キャッシュは route 決定と実行の間に TTL 失効しうるので、実行直前に再検査する。
  assert.equal(check().executable, true);
  assert.equal(
    check({ availability: { codex: { available: true, models: ["gpt-5.6-sol"] } } })
      .executable,
    false,
  );
  // discovery 一覧が無いときは model を理由に拒否しない（router と同じ規則）。
  assert.equal(
    check({ availability: { codex: { available: true, models: null } } }).executable,
    true,
  );
  assert.equal(
    check({ availability: { codex: { available: false, models: null } } }).executable,
    false,
  );
  assert.equal(check({ availability: {} }).executable, false);
});

test("the pre-flight check rejects values that would inject a config override", () => {
  // Codex は effort と model を `-c key=value` の値へ埋め込むため、区切り文字を含む値は
  // 別の設定キー（たとえば sandbox_mode）を注入しうる。
  const injected = check({
    capability: {
      ...CODEX_CAPABILITY,
      effort: 'xhigh" sandbox_mode="danger-full-access',
    },
  });
  assert.equal(injected.executable, false);
  assert.match(injected.reason, /effort/);

  const injectedModel = check({
    capability: {
      ...CODEX_CAPABILITY,
      model: 'gpt-5.6-terra" sandbox_mode="danger-full-access',
    },
  });
  assert.equal(injectedModel.executable, false);
  assert.match(injectedModel.reason, /model/);

  // 形は正しいが語彙に無い effort も通さない。
  assert.equal(
    check({ capability: { ...CODEX_CAPABILITY, effort: "extreme" } }).executable,
    false,
  );
});

test("the pre-flight check refuses a provider mismatch and a relative executable", () => {
  assert.equal(
    check({ capability: { ...CODEX_CAPABILITY, provider: "claude" } }).executable,
    false,
  );
  assert.equal(check({ executablePath: "codex" }).executable, false);
});

test("the pre-flight check keeps write-capable work away from an unenforceable sandbox", () => {
  const verdict = checkCapabilityExecutable({
    adapter: antigravityAdapter,
    availability: {
      antigravity: { available: true, models: ["gemini-3.7-flash-high"] },
    },
    capability: {
      provider: "antigravity",
      model: "gemini-3.7-flash-high",
      effort: "high",
    },
    executablePath: "/usr/local/bin/agy",
    sandbox: { mode: "workspace-write" },
  });
  assert.equal(verdict.executable, false);
  assert.match(verdict.reason, /write-capable/);
});

// ---------------------------------------------------------------------------
// registry と executor
// ---------------------------------------------------------------------------

test("the default registry ships the three real providers and no fake", () => {
  const registry = createAdapterRegistry();
  assert.deepEqual(registry.providers(), ["antigravity", "claude", "codex"]);
  assert.equal(registry.get("fake"), null);
  // provider 名は設定由来なので、継承プロパティを adapter として拾わせない。
  assert.equal(registry.get("constructor"), null);
});

test("the registry refuses two adapters for one provider", () => {
  assert.throws(
    () =>
      createAdapterRegistry({
        adapters: [createFakeAdapter(), createFakeAdapter()],
      }),
    /two adapters/,
  );
});

function fakeExecutor({ availability, sandboxMode = "read-only", results, request = {} }) {
  const adapter = createFakeAdapter();
  const runner = createFakeRunner(results);
  const executor = createAdapterExecutor({
    registry: createAdapterRegistry({ adapters: [adapter] }),
    availability,
    capability: { provider: "fake", model: "gpt-5.6-terra", effort: "xhigh" },
    capabilityName: "executor.default",
    request: {
      prompt: "run the suite",
      executable: "/usr/local/bin/fake",
      sandbox: { mode: sandboxMode },
      ...request,
    },
    runner,
  });
  return { executor, runner };
}

test("the executor interprets structured output without starting a provider", () => {
  const { executor, runner } = fakeExecutor({
    availability: { fake: { available: true, models: ["gpt-5.6-terra"] } },
    results: [
      {
        exitCode: 0,
        stdout: JSON.stringify({
          outcome: "succeeded",
          resumeKey: "fake-1",
          denials: ["Bash"],
        }),
        stderr: "",
      },
    ],
  });
  const execution = executor();
  assert.equal(execution.ranProvider, true);
  assert.equal(execution.outcome, "succeeded");
  assert.equal(execution.status, "succeeded");
  assert.equal(execution.resumeKey, "fake-1");
  assert.deepEqual(execution.denials, ["Bash"]);
  assert.deepEqual(execution.sandbox, { mode: "read-only" });
  assert.equal(execution.phase, "launch");
  assert.equal(runner.calls.length, 1);
});

test("the executor resumes when the request carries a resume key", () => {
  const { executor, runner } = fakeExecutor({
    availability: { fake: { available: true, models: null } },
    request: { resumeKey: "fake-1" },
    results: [{ exitCode: 0, stdout: "", stderr: "" }],
  });
  assert.equal(executor().phase, "resume");
  assert.equal(runner.calls[0].phase, "resume");
});

test("an unavailable capability is refused without calling the runner", () => {
  // 「利用不可時のフォールバック」= adapter は拒否し、route の選び直しは呼び出し側が決める。
  const { executor, runner } = fakeExecutor({
    availability: { fake: { available: false, models: null } },
    results: [{ exitCode: 0, stdout: "", stderr: "" }],
  });
  const execution = executor();
  assert.equal(execution.outcome, "refused");
  assert.equal(execution.ranProvider, false);
  assert.match(execution.reason, /unavailable/);
  assert.equal(runner.calls.length, 0);
});

test("the shadow rollout guard never lets the executor reach the runner", () => {
  const { executor, runner } = fakeExecutor({
    availability: { fake: { available: true, models: null } },
    results: [{ exitCode: 0, stdout: "", stderr: "" }],
  });
  const guarded = runWithRolloutGuard({ rollout: "shadow" }, "route single-worker", executor);
  assert.equal(guarded.executed, false);
  assert.equal(runner.calls.length, 0);
});

// ---------------------------------------------------------------------------
// state への写像（起動方式を schema へ持ち込まない）
// ---------------------------------------------------------------------------

test("an adapter run record keeps no launch-mechanism detail", () => {
  const { executor } = fakeExecutor({
    availability: { fake: { available: true, models: null } },
    results: [
      { exitCode: 0, stdout: JSON.stringify({ outcome: "succeeded" }), stderr: "" },
    ],
  });
  const input = toAdapterRunInput(executor(), { taskId: "task_1", routeId: "route_1" });
  for (const key of ["argv", "sandbox", "conversationId", "resumeKey", "cwd", "env"]) {
    assert.ok(!Object.hasOwn(input, key), `adapter run input leaked ${key}`);
  }
  assert.doesNotThrow(() => normalizeAdapterRun(input));
});

test("a refused execution produces no adapter run to record", () => {
  const { executor } = fakeExecutor({
    availability: { fake: { available: false, models: null } },
    results: [],
  });
  assert.throws(
    () => toAdapterRunInput(executor(), { taskId: "task_1", routeId: "route_1" }),
    /no adapter run/,
  );
});

// ---------------------------------------------------------------------------
// issue #493 の完了条件: router が vendor 固有を持たない
// ---------------------------------------------------------------------------

test("the router holds no vendor command name or provider literal", () => {
  const source = readLibSource("router.mjs");
  for (const literal of ["claude", "codex", "antigravity"]) {
    assert.ok(!source.includes(literal), `router.mjs mentions ${literal}`);
  }
  assert.ok(!/\bagy\b/.test(source), "router.mjs mentions the agy executable");
});
