import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { DatabaseSync } from "node:sqlite";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  APPROVAL_PROMPT_TOOL,
  approvalServerDeclaration,
  probeApprovalServer,
  resolveApprovalServerCommand,
} from "../home/dot_local/lib/frontier-harness/approval-channel.mjs";
import { BLOCKED_PENDING_APPROVAL } from "../home/dot_local/lib/frontier-harness/exit-codes.mjs";
import { createChildRunner } from "../home/dot_local/lib/frontier-harness/child-runner.mjs";
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import {
  DEFAULT_CHECK_TIMEOUT_MS,
  MAX_CHECK_TIMEOUT_MS,
} from "../home/dot_local/lib/frontier-harness/check-runner.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  GATE_ENVIRONMENT_ALLOWLIST,
  MAX_SESSION_GATES,
  combineOutcome,
  gateEnvironment,
  gateTimeoutMs,
  gateVerdict,
  parseGateDeclaration,
  resolveGate,
} from "../home/dot_local/lib/frontier-harness/session-gate.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";

// `fh session launch|resume`（#537）専用のスイート。
//
// **実 provider を起動しない。** 子プロセスも承認 server の handshake も注入した fake で
// 観測する。ここで確かめたいのは「どんなときに子を起こさないか」であって、claude 本体の
// 挙動ではない（そちらは #526 の実測が担う）。

const CLAUDE_PATH = "/opt/frontier/bin/claude";
const CODEX_PATH = "/opt/frontier/bin/codex";
const HARNESS_PATH = "/opt/frontier/bin/frontier-harness";
const COMMAND_PATHS = Object.freeze({
  antigravity: null,
  claude: CLAUDE_PATH,
  codex: CODEX_PATH,
});
const VERIFIED_MODELS = Object.freeze({});
const SESSION_CAPABILITY = "session.child";
// tier 別 capability。既定より弱い（Opus @ high）ものを選ぶことが `fh session launch` の
// 目的なので、#604 の継承はこの「弱いほうを選んだ」意図が resume で残るかを問う。
const TIER_CAPABILITY = "session.child.standard";
const SESSION_ID = "11111111-2222-4333-8444-555555555555";
const RESUME_KEY = "99999999-8888-4777-8666-555555555555";
// 記録に混ざってはいけない「会話内容」。prompt 本文をこの文字列にして、保存先の全行を
// 走査して現れないことを表明する。
const PROMPT_BODY = "SECRET-PROMPT-BODY do not record this anywhere";

const baseConfigInput = {
  version: 1,
  rollout: "pilot",
  retention: { rawArtifactsDays: 30, aggregateTelemetryDays: 180 },
  capabilities: {
    "executor.default": {
      provider: "codex",
      model: "gpt-5.6-terra",
      effort: "xhigh",
    },
    "semantic.judge": {
      provider: "claude",
      model: "claude-opus-5",
      effort: "high",
    },
    [SESSION_CAPABILITY]: {
      provider: "claude",
      model: "claude-opus-5",
      effort: "xhigh",
    },
    [TIER_CAPABILITY]: {
      provider: "claude",
      model: "claude-opus-5",
      effort: "high",
    },
  },
  risk: { alwaysEscalate: ["merge"] },
};

const config = normalizeConfig(baseConfigInput);
const shadowConfig = normalizeConfig({ ...baseConfigInput, rollout: "shadow" });
// 既定（`DEFAULT_SESSION_CAPABILITY`）が registry 中で最も強い、という**現構成の性質**を
// 崩した registry。#604 の安全性がその性質に寄りかかっていないことを確かめるために使う。
const weakDefaultConfig = normalizeConfig({
  ...baseConfigInput,
  capabilities: {
    ...baseConfigInput.capabilities,
    [SESSION_CAPABILITY]: {
      provider: "claude",
      model: "claude-sonnet-5",
      effort: "low",
    },
  },
});

const PUBLIC_LOOKUP = () => [{ address: "93.184.216.34", family: 4 }];

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-session-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

// 承認境界は #494 / #556 で実効化されているため、子を起こすテストは先に manifest を承認する。
// 儀式は同一プロセスでのレビューと承認を拒否するので、実運用の 2 プロセスを pid の注入で模す。
async function approveCapabilities(
  directory,
  capabilities,
  statePath,
  // policy.json をどのツリーへ書くか。既定は `directory` だが、承認境界がワークツリーから
  // 解決されることを確かめるテストは、ここを子のワークツリーへ向ける。
  policyRoot = directory,
  // 完了条件（`--gate`）は command として承認される。既定は空 —— gate を宣言しない
  // セッションが今までどおり通ることも、このスイートが確かめる対象である。
  commands = [],
) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({ commands, domains: [], capabilities }),
  );
  const policyPath = path.join(policyRoot, ".harness", "policy.json");
  const base = {
    config,
    cwd: directory,
    statePath,
    policyPath,
    lookup: PUBLIC_LOOKUP,
    write: () => {},
  };
  const output = [];
  assert.equal(
    await runCli(["onboard", "--manifest", manifestPath, "--json"], {
      ...base,
      pid: 4242,
      write: (line) => output.push(line),
    }),
    2,
  );
  const { request } = JSON.parse(output.pop());
  assert.equal(
    await runCli(
      [
        "onboard",
        "--manifest",
        manifestPath,
        "--approve",
        "--request",
        request.id,
        "--json",
      ],
      { ...base, pid: 4243 },
    ),
    0,
  );
  return policyPath;
}

function initEvent(overrides = {}) {
  return {
    type: "system",
    subtype: "init",
    session_id: SESSION_ID,
    tools: ["Bash", "Read", "AskUserQuestion"],
    mcp_servers: [{ name: "frontier-harness-approver", status: "connected" }],
    ...overrides,
  };
}

function resultEvent(overrides = {}) {
  return {
    type: "result",
    subtype: "success",
    session_id: SESSION_ID,
    is_error: false,
    result: "done",
    ...overrides,
  };
}

// 子プロセスの fake。runner が listener を張ってから流したいので、行の送出は setImmediate で
// 遅らせる。kill は記録するだけにして、「起動時検査が子を終わらせたか」を観測できるようにする。
//
// `onSpawn` は spawn が呼ばれた**その瞬間**に走る（子が 1 行も出す前）。「完走前に観測できるか」
// を問うテストは、実行後の状態ではなくここで確かめないと、出力が終了後へ移動しても通ってしまう。
function createFakeSpawn({
  lines,
  exitCode = 0,
  chunks,
  trailingNewline = true,
  spawnError = null,
  ignoreTerm = false,
  onSpawn = () => {},
}) {
  const calls = [];
  const spawn = (executable, argv, options) => {
    const child = new EventEmitter();
    const stdout = new EventEmitter();
    stdout.setEncoding = () => {};
    child.stdout = stdout;
    const signals = [];
    child.kill = (signal) => signals.push(signal);
    const call = { executable, argv, options, signals };
    calls.push(call);
    onSpawn(call);

    if (spawnError) {
      setImmediate(() => child.emit("error", spawnError));
      return child;
    }

    // 明示された chunk 列があればそれを流す（行が chunk 境界をまたぐ経路の検証用）。
    const payload =
      chunks ??
      lines.map(
        (line, index) =>
          `${JSON.stringify(line)}${
            trailingNewline || index < lines.length - 1 ? "\n" : ""
          }`,
      );
    let index = 0;
    const step = () => {
      if (index < payload.length) {
        stdout.emit("data", payload[index]);
        index += 1;
        setImmediate(step);
        return;
      }
      // TERM を無視する子は close しない（SIGKILL への昇格を観測するため）。
      if (ignoreTerm && signals.includes("SIGTERM")) return;
      // 起動時検査で終わらせた子はシグナルで死ぬ（終了コードは無い）。
      child.emit("close", signals.length > 0 ? null : exitCode);
    };
    setImmediate(step);
    return child;
  };
  return { spawn, calls };
}

function okProbe({ tools = [{ name: "approve" }] } = {}) {
  const calls = [];
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    return {
      status: 0,
      signal: null,
      error: null,
      stdout: [
        JSON.stringify({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-06-18" } }),
        JSON.stringify({ jsonrpc: "2.0", id: 2, result: { tools } }),
      ].join("\n"),
      stderr: "",
    };
  };
  return { spawn, calls };
}

async function launch({
  directory,
  statePath,
  policyPath,
  extraFlags = [],
  action = "launch",
  spawnFake,
  probeFake = okProbe(),
  sessionConfig = config,
  worktree: worktreeOverride,
  sessionIdFlag = SESSION_ID,
  promptBody = PROMPT_BODY,
  accountScope = "personal",
  // gate のチェックは実プロセスとして走るので、PATH に何が見えるかがそのまま結果になる。
  environment,
  // 子の spawn とは別の口。gate ごとに違う終了コードを与えたいテストが使う。
  gateSpawnFake,
}) {
  const worktree = worktreeOverride ?? path.join(directory, "worktree");
  mkdirSync(worktree, { recursive: true });
  const promptPath = path.join(directory, "prompt.txt");
  writeFileSync(promptPath, `${promptBody}\n`);
  const approvalsDir = path.join(directory, "approvals");

  const output = [];
  const stderr = [];
  const code = await runCli(
    [
      "session",
      action,
      "--worktree",
      worktree,
      "--prompt-file",
      promptPath,
      "--approvals-dir",
      approvalsDir,
      "--approval-server-command",
      HARNESS_PATH,
      ...(action === "resume"
        ? ["--resume-key", RESUME_KEY]
        : sessionIdFlag === null
          ? []
          : ["--session-id", sessionIdFlag]),
      ...extraFlags,
      "--json",
    ],
    {
      accountScope,
      ...(environment === undefined ? {} : { environment }),
      commandPaths: COMMAND_PATHS,
      config: sessionConfig,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      cwd: directory,
      policyPath,
      write: (line) => output.push(line),
      spawn: spawnFake?.spawn,
      ...(gateSpawnFake === undefined ? {} : { gateSpawn: gateSpawnFake.spawn }),
      probeSpawn: probeFake.spawn,
      sessionIo: { stderr: { write: (line) => stderr.push(line) } },
    },
  );
  return {
    code,
    output,
    stderr,
    worktree,
    report: output.length ? JSON.parse(output.at(-1)) : null,
  };
}

async function preparedDirectory(
  context,
  { commands = [], capabilities = [SESSION_CAPABILITY] } = {},
) {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const policyPath = await approveCapabilities(
    directory,
    capabilities,
    statePath,
    directory,
    commands,
  );
  return { directory, statePath, policyPath };
}

// PATH 上に置く偽の `npm`。`findCommand` は実行ビットを見るので、実体が要る
// （`frontier_harness_verify.test.mjs` と同じ形）。
function fakeBinDirectory(directory, { exitCode = 0, name = "npm" } = {}) {
  const bin = path.join(directory, `bin-${name}-${exitCode}`);
  mkdirSync(bin, { recursive: true });
  writeFileSync(path.join(bin, name), `#!/bin/sh\nexit ${exitCode}\n`, {
    mode: 0o755,
  });
  return bin;
}

// gate を宣言したセッションを 1 本起こす。gate のチェックは実プロセスとして走る。
async function launchWithGates(
  context,
  {
    gates,
    commands,
    gateExitCode = 0,
    binOnPath = true,
    spawnOverride,
    gateSpawnFake,
    extraFlags = [],
    action = "launch",
  },
) {
  const prepared = await preparedDirectory(context, { commands });
  const bin = fakeBinDirectory(prepared.directory, { exitCode: gateExitCode });
  const result = await launch({
    ...prepared,
    action,
    spawnFake: spawnOverride ?? createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
    ...(gateSpawnFake === undefined ? {} : { gateSpawnFake }),
    extraFlags: [...gates.flatMap((gate) => ["--gate", gate]), ...extraFlags],
    // PATH から `npm` を外すと、チェックは「起動できなかった」= errored になる。
    environment: {
      ...process.env,
      PATH: binOnPath ? bin : path.join(prepared.directory, "empty-bin"),
    },
  });
  return { ...prepared, ...result };
}

// ---------------------------------------------------------------------------
// 承認チャネルの宣言
// ---------------------------------------------------------------------------

test("the prompt tool name is derived from the approval server, not written twice", () => {
  assert.equal(APPROVAL_PROMPT_TOOL, "mcp__frontier-harness-approver__approve");
});

test("the approval server command must be an absolute path", () => {
  assert.throws(
    () => resolveApprovalServerCommand({ explicit: "frontier-harness" }),
    /absolute path/,
  );
});

test("an approval server that is not on PATH refuses instead of falling back", () => {
  assert.throws(
    () => resolveApprovalServerCommand({ environment: { PATH: "/nonexistent-frontier-bin" } }),
    /no approval channel/,
  );
});

test("the declaration carries no environment channel and no default timeouts", () => {
  const declaration = approvalServerDeclaration({
    command: HARNESS_PATH,
    sessionId: SESSION_ID,
    approvalsDirectory: "/tmp/approvals",
  });
  assert.deepEqual(Object.keys(declaration).sort(), ["args", "command", "key"]);
  assert.equal(declaration.args.includes("--timeout-ms"), false);
  assert.equal(declaration.args.includes("--progress-interval-ms"), false);
});

test("timeout flags are passed through only when the caller supplies them", () => {
  const declaration = approvalServerDeclaration({
    command: HARNESS_PATH,
    sessionId: SESSION_ID,
    approvalsDirectory: "/tmp/approvals",
    timeoutMs: 3600000,
    progressIntervalMs: 30000,
  });
  assert.equal(declaration.args.at(-3), "3600000");
  assert.equal(declaration.args.at(-1), "30000");
});

// ---------------------------------------------------------------------------
// 起動前 handshake
// ---------------------------------------------------------------------------

test("a probe that cannot start the server is not healthy", () => {
  const verdict = probeApprovalServer({
    command: HARNESS_PATH,
    args: [],
    spawn: () => ({ error: new Error("ENOENT"), status: null, signal: null, stdout: "" }),
  });
  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /could not be started/);
});

test("a probe that times out is not healthy", () => {
  const verdict = probeApprovalServer({
    command: HARNESS_PATH,
    args: [],
    spawn: () => ({ error: null, status: null, signal: "SIGTERM", stdout: "" }),
  });
  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /handshake/);
});

test("a probe whose output cannot be read is not healthy", () => {
  const verdict = probeApprovalServer({
    command: HARNESS_PATH,
    args: [],
    spawn: () => ({ error: null, status: 0, signal: null, stdout: "not json at all" }),
  });
  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /did not publish/);
});

test("a probe that publishes the approve tool is healthy", () => {
  assert.deepEqual(probeApprovalServer({ command: HARNESS_PATH, args: [], spawn: okProbe().spawn }), {
    ok: true,
    reason: null,
  });
});

// ---------------------------------------------------------------------------
// 子を起こさない条件
// ---------------------------------------------------------------------------

test("an unusable approval channel starts no child at all", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [] });
  const probeFake = {
    calls: [],
    spawn: () => ({ error: null, status: 1, signal: null, stdout: "" }),
  };

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    probeFake,
  });

  assert.equal(code, 1);
  assert.equal(report.executed, false);
  assert.match(report.executionReason, /approval channel is not usable/);
  assert.equal(spawnFake.calls.length, 0, "no child process may be started");
});

test("a capability the manifest does not approve starts no child and queues a gap", async (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  // 別の capability だけを承認する: session.child は未承認のまま。
  const policyPath = await approveCapabilities(directory, ["semantic.judge"], statePath);
  const spawnFake = createFakeSpawn({ lines: [] });
  const probeFake = okProbe();

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    probeFake,
  });

  assert.equal(code, 2);
  assert.equal(report.executed, false);
  assert.equal(report.gaps.length, 1);
  assert.equal(report.gaps[0].value, SESSION_CAPABILITY);
  assert.equal(spawnFake.calls.length, 0, "no child process may be started");
  assert.equal(probeFake.calls.length, 0, "the probe runs only when a child would run");
});

test("a shadow rollout records the route without starting a child", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [] });
  const probeFake = okProbe();

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    probeFake,
    sessionConfig: shadowConfig,
  });

  assert.equal(code, 0);
  assert.equal(report.executed, false);
  assert.match(report.executionReason, /shadow rollout/);
  assert.equal(spawnFake.calls.length, 0, "no child process may be started");
  assert.equal(probeFake.calls.length, 0, "the probe runs only when a child would run");
});

test("a capability outside the registry is refused before anything else happens", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  await assert.rejects(
    launch({
      directory,
      statePath,
      policyPath,
      spawnFake: createFakeSpawn({ lines: [] }),
      extraFlags: ["--capability", "constructor"],
    }),
    /not in the capability registry/,
  );
});

test("a capability whose provider cannot round-trip approvals is refused", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  await assert.rejects(
    launch({
      directory,
      statePath,
      policyPath,
      spawnFake: createFakeSpawn({ lines: [] }),
      extraFlags: ["--capability", "executor.default"],
    }),
    /round-trip approvals/,
  );
});

// ---------------------------------------------------------------------------
// 起動時検査
// ---------------------------------------------------------------------------

test("the launched argv carries every pre-emptive isolation flag", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 0);
  const [call] = spawnFake.calls;
  assert.equal(call.executable, CLAUDE_PATH);
  for (const flag of [
    "--setting-sources",
    "--strict-mcp-config",
    "--mcp-config",
    "--permission-prompt-tool",
  ]) {
    assert.ok(call.argv.includes(flag), `argv must carry ${flag}`);
  }
  assert.equal(call.argv[call.argv.indexOf("--setting-sources") + 1], "user");
  assert.equal(
    call.argv[call.argv.indexOf("--permission-prompt-tool") + 1],
    APPROVAL_PROMPT_TOOL,
  );
  assert.equal(call.argv[call.argv.indexOf("--session-id") + 1], SESSION_ID);
});

test("the child is told what the sandbox denies before it hits the wall", async (context) => {
  // 実運用で 2 セッションとも、作業を終えてから commit で初めて「署名 socket が塞がれている」
  // ことを知り、そこで止まった。制約を各 prompt に書かせる運用ルールにすると必ず書き漏れるので、
  // sandbox を課している側（fh）が prompt の先頭で構造的に伝える。
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 0);
  const [call] = spawnFake.calls;
  const prompt = call.argv[call.argv.indexOf("-p") + 1];
  // 塞がれている点が、失敗する前に読める形で入っていること。
  //
  // **許可ドメインの一覧そのものは検査しない。** 一覧は adapter が持つので、文面に埋め込むと
  // 二重管理になり drift する（実際、一覧を広げたときに文面だけが古くなった）。ここで確かめる
  // のは「制約の存在が伝わるか」であって、許可の中身ではない。
  assert.match(prompt, /許可リスト/);
  assert.match(prompt, /commit\.gpgsign=false/);
  assert.match(prompt, /dangerouslyDisableSandbox/);
  assert.match(prompt, /secure-transport/);
  // 呼び出し側の prompt は落とさない。
  assert.ok(prompt.includes(PROMPT_BODY));
});

test("an unresolved account scope starts no child at all", async (context) => {
  // `CLAUDE_CONFIG_DIR` はランチャーが呼び出しごとに設定するもので、シェルには export されない。
  // 素の tmux ペイン（skill が起動場所として指示している場所）にはこの変数が無く、
  // accountScope は `unknown` になる。それでも子が起動できると、account に紐づくパスが
  // 解決できないまま **外形上は正常な起動**として走り続ける（実際に wave 1 本分をこの状態で
  // 走らせ、codex が動かない理由が argv を見るまで分からなかった）。
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    accountScope: "unknown",
  });

  assert.equal(code, BLOCKED_PENDING_APPROVAL);
  // プロセスを 1 つも起こしていないこと（起動してから気づくのでは遅い）。
  assert.equal(spawnFake.calls.length, 0);
  assert.equal(report.executed, false);
  // 直し方が出力から読めること。
  assert.match(report.executionReason, /CLAUDE_CONFIG_DIR/);
});

test("the child git uses a TLS backend that works inside the sandbox", async (context) => {
  // ［実測］sandbox はプロキシ経由の egress を課すため、git は OpenSSL 系バックエンドに落ちて
  // CA バンドルを読もうとし、その読み取りが sandbox に塞がれて失敗する。secure-transport
  // バックエンドは CA ファイルを読まず macOS の trust 評価を使うので通る（実測で ls-remote 成功）。
  //
  // 各コマンドに `-c` を付ける運用ルールにすると付け忘れるので、環境変数で全 git 呼び出しへ
  // 効かせる。利用者側の設定には一切触れない。
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 0);
  const [call] = spawnFake.calls;
  const env = call.options.env;
  const count = Number(env.GIT_CONFIG_COUNT);
  assert.ok(count >= 1, "GIT_CONFIG_COUNT must cover the injected entry");
  const entries = [];
  for (let index = 0; index < count; index += 1) {
    entries.push([env[`GIT_CONFIG_KEY_${index}`], env[`GIT_CONFIG_VALUE_${index}`]]);
  }
  assert.ok(
    entries.some(([key, value]) => key === "http.sslBackend" && value === "secure-transport"),
    "the child must inherit an http.sslBackend override",
  );
});

test("a child without AskUserQuestion is terminated instead of left running", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [initEvent({ tools: ["Bash", "Read"] }), resultEvent()],
  });

  const { code, report } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.status, "failed");
  assert.equal(report.initHealth.healthy, false);
  assert.ok(
    report.initHealth.problems.some((problem) => problem.includes("AskUserQuestion")),
  );
  assert.deepEqual(spawnFake.calls[0].signals, ["SIGTERM"]);
});

test("a child whose approval server never connects is terminated", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [initEvent({ mcp_servers: [] }), resultEvent()],
  });

  const { code, report } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.initHealth.healthy, false);
  assert.deepEqual(spawnFake.calls[0].signals, ["SIGTERM"]);
});

test("mcp server errors in the init event are treated as unhealthy", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [initEvent({ mcp_server_errors: { approver: "boom" } }), resultEvent()],
  });

  const { code, report } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.initHealth.healthy, false);
});

test("a run that never emits an init event is not read as healthy", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [resultEvent()] });

  const { code, report } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.status, "failed");
  assert.equal(report.initHealth.healthy, false);
});

// ---------------------------------------------------------------------------
// 記録
// ---------------------------------------------------------------------------

test("a healthy run records the adapter run and evidence without conversation content", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [
      initEvent(),
      { type: "assistant", message: { content: PROMPT_BODY } },
      resultEvent({ permission_denials: [{ tool_name: "Bash", tool_input: { command: PROMPT_BODY } }] }),
    ],
  });

  const { code, report, stderr } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    extraFlags: ["--label", "feat-537-child"],
  });

  assert.equal(code, 0);
  assert.equal(report.status, "succeeded");
  assert.equal(report.resumeKey, SESSION_ID);
  assert.deepEqual(report.denials, ["Bash"]);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const runs = store.listAdapterRuns();
  assert.equal(runs.length, 1);
  assert.equal(runs[0].capability, SESSION_CAPABILITY);
  assert.equal(runs[0].status, "succeeded");

  const evidence = store.listEvidence().filter((row) => row.kind === "child_session");
  assert.equal(evidence.length, 1);
  assert.ok(
    evidence[0].claimsSupported.some((claim) => claim.includes(SESSION_ID)),
    "the resume key belongs in the evidence so the session can be resumed",
  );

  // 会話内容が state のどこにも現れないこと。tasks / routes / adapter_runs / evidence を
  // まとめて走査する（列を 1 つ足したときに検査から漏れないよう、行ごと文字列化する）。
  const persisted = JSON.stringify([
    store.listRoutes(),
    store.listEvidence(),
    store.listAdapterRuns(),
  ]);
  assert.equal(persisted.includes(PROMPT_BODY), false, "state must not hold the prompt body");
  assert.equal(
    stderr.join("").includes(PROMPT_BODY),
    false,
    "the heartbeat must carry event names only",
  );
});

test("the session id reaches stderr before the run finishes", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { stderr } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.ok(
    stderr.some((line) => line.includes(SESSION_ID)),
    "the ledger needs the session id even when the child is interrupted",
  );
});

test("resume launches with the resume flag and reuses the session for approvals", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [initEvent({ session_id: RESUME_KEY }), resultEvent({ session_id: RESUME_KEY })],
  });
  const probeFake = okProbe();

  const { code } = await launch({
    directory,
    statePath,
    policyPath,
    action: "resume",
    spawnFake,
    probeFake,
  });

  assert.equal(code, 0);
  const [call] = spawnFake.calls;
  assert.equal(call.argv.includes("--session-id"), false);
  assert.equal(call.argv[call.argv.indexOf("--resume") + 1], RESUME_KEY);
  // 承認 server の --session も同じ値でなければ、`fh approvals` からどの子の問いか引けない。
  const [probeCall] = probeFake.calls;
  assert.equal(probeCall.args[probeCall.args.indexOf("--session") + 1], RESUME_KEY);
});

test("an unknown session action is refused", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  await assert.rejects(
    launch({ directory, statePath, policyPath, action: "restart" }),
    /launch or resume/,
  );
});

// ---------------------------------------------------------------------------
// 承認境界はワークツリーから解決する（cross-repo での gate 迂回の回帰）
// ---------------------------------------------------------------------------

test("the manifest is read from the worktree, not from the caller's directory", async (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const worktree = path.join(directory, "worktree");
  mkdirSync(worktree, { recursive: true });
  // policy をワークツリー側へ承認する。policyPath は注入しない（解決規則そのものを見る）。
  await approveCapabilities(directory, [SESSION_CAPABILITY], statePath, worktree);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code } = await launch({
    directory,
    statePath,
    policyPath: undefined,
    worktree,
    spawnFake,
  });

  assert.equal(code, 0, "a worktree whose own policy approves the capability may run");
  assert.equal(spawnFake.calls.length, 1);
});

test("a worktree outside the approved repository is blocked even when the caller's directory is approved", async (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  // 呼び出し元のディレクトリ側だけを承認する。
  await approveCapabilities(directory, [SESSION_CAPABILITY], statePath);
  const foreign = path.join(temporaryDirectory(context), "other-repo");
  mkdirSync(foreign, { recursive: true });
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath: undefined,
    worktree: foreign,
    spawnFake,
  });

  // 承認済みリポジトリの中から `--worktree` で別リポジトリを指すだけで gate を
  // 迂回できてはならない（manifest は cwd 側、実行は worktree 側になる経路）。
  assert.equal(code, 2);
  assert.equal(report.gaps.length, 1);
  assert.equal(spawnFake.calls.length, 0, "no child process may be started");
});

// ---------------------------------------------------------------------------
// セッション識別子は副作用の前に検証する
// ---------------------------------------------------------------------------

test("an unsafe session id is refused before anything is written or announced", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [] });

  await assert.rejects(
    launch({
      directory,
      statePath,
      policyPath,
      spawnFake,
      sessionIdFlag: "not a safe value",
    }),
    /--session-id/,
  );

  // 起動失敗にもかかわらず state に残る、という形にしない。
  const store = createStateStore(statePath);
  context.after(() => store.close());
  assert.equal(store.listRoutes().length, 0);
  assert.equal(spawnFake.calls.length, 0);
});

test("fh generates a session id when the caller does not supply one", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  let announced = null;
  const spawnFake = createFakeSpawn({
    lines: [initEvent(), resultEvent()],
    onSpawn: () => {},
  });

  const { code, report, stderr } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    sessionIdFlag: null,
  });

  assert.equal(code, 0);
  const match = /child session ([0-9a-f-]{36})/.exec(stderr.join(""));
  assert.ok(match, "the generated id must reach stderr");
  announced = match[1];
  assert.equal(report.sessionId, announced, "the JSON report carries the same id");
  const argv = spawnFake.calls[0].argv;
  assert.equal(
    argv[argv.indexOf("--session-id") + 1],
    announced,
    "the child is launched with the same id",
  );
});

// ---------------------------------------------------------------------------
// 起動前 handshake の中身
// ---------------------------------------------------------------------------

test("the probe speaks a real MCP handshake, not just any three bytes", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const probeFake = okProbe();

  await launch({
    directory,
    statePath,
    policyPath,
    spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
    probeFake,
  });

  const [probeCall] = probeFake.calls;
  const sent = probeCall.options.input
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    sent.map((message) => message.method),
    ["initialize", "notifications/initialized", "tools/list"],
  );
  assert.equal(sent[0].id, 1);
  assert.equal(sent[1].id, undefined, "a notification carries no id");
  assert.equal(sent[2].id, 2);
  assert.equal(typeof sent[0].params.protocolVersion, "string");
  // stdio server は stdin の EOF で終わるので、handshake は同期に完結する。
  assert.equal(typeof probeCall.options.timeout, "number");
});

test("a server that answers but does not publish approve starts no child", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    // 応答は返るが `approve` を公開していない（status 0 なので終了コードでは見抜けない）。
    probeFake: okProbe({ tools: [{ name: "something-else" }] }),
  });

  assert.equal(code, 1);
  assert.match(report.executionReason, /approval channel is not usable/);
  assert.equal(spawnFake.calls.length, 0);
});

// ---------------------------------------------------------------------------
// runner の境界
// ---------------------------------------------------------------------------

test("the child is escalated to SIGKILL when it ignores SIGTERM", async () => {
  const spawnFake = createFakeSpawn({
    // 承認チャネルが消えた子。TERM を無視するので、猶予後に SIGKILL へ昇格するはず。
    lines: [initEvent({ tools: ["Bash"] })],
    ignoreTerm: true,
  });
  const runner = createChildRunner({
    cwd: "/tmp",
    permissionPromptTool: APPROVAL_PROMPT_TOOL,
    terminationGraceMs: 1,
    stderr: { write: () => {} },
    spawn: spawnFake.spawn,
  });

  runner.run({ executable: CLAUDE_PATH, argv: ["-p", "x"] });
  // 猶予タイマーの発火を待つ。**SIGTERM の記録だけで満足しない** —— TERM を無視する子は
  // 昇格が無ければ生き残り、gate を失ったまま作業を続けることになる。
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.deepEqual(
    spawnFake.calls[0].signals,
    ["SIGTERM", "SIGKILL"],
    "a child that ignores SIGTERM must not be left running",
  );
  assert.equal(runner.initHealth().healthy, false);
});

test("the runner reassembles events split across chunks and a missing final newline", async () => {
  const lines = [JSON.stringify(initEvent()), JSON.stringify(resultEvent())];
  const joined = `${lines[0]}\n${lines[1]}`;
  const runner = createChildRunner({
    cwd: "/tmp",
    permissionPromptTool: APPROVAL_PROMPT_TOOL,
    stderr: { write: () => {} },
    spawn: createFakeSpawn({
      lines: [],
      // 1 行が chunk 境界をまたぎ、最終行に改行が無い。
      chunks: [joined.slice(0, 20), joined.slice(20, 90), joined.slice(90)],
    }).spawn,
  });

  const result = await runner.run({ executable: CLAUDE_PATH, argv: ["-p", "x"] });
  assert.equal(runner.initHealth().healthy, true, "init must survive chunk splitting");
  assert.ok(
    result.stdout.includes(lines[1]),
    "the terminal result line must survive the missing newline",
  );
});

test("a child that fails to spawn is recorded as a failed run, not an unhandled rejection", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({
    lines: [],
    spawnError: Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }),
  });

  const { code, report } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.status, "failed");
  assert.match(report.failureReason, /could not be run/);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const runs = store.listAdapterRuns();
  assert.equal(runs.length, 1, "the attempt must leave an audit trail");
  assert.equal(runs[0].status, "failed");
});

// ---------------------------------------------------------------------------
// 観測できる時点と、記録に残らないもの
// ---------------------------------------------------------------------------

test("the session id is on stderr before the child is even spawned", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const stderrAtSpawn = [];
  const stderr = [];
  const spawnFake = createFakeSpawn({
    lines: [initEvent(), resultEvent()],
    onSpawn: () => stderrAtSpawn.push(...stderr),
  });

  // launch ヘルパーの stderr 収集と同じ配列を fake へ渡すため、ここは直接呼ぶ。
  const worktree = path.join(directory, "worktree");
  mkdirSync(worktree, { recursive: true });
  const promptPath = path.join(directory, "prompt.txt");
  writeFileSync(promptPath, `${PROMPT_BODY}\n`);
  await runCli(
    [
      "session",
      "launch",
      "--worktree",
      worktree,
      "--prompt-file",
      promptPath,
      "--approvals-dir",
      path.join(directory, "approvals"),
      "--approval-server-command",
      HARNESS_PATH,
      "--session-id",
      SESSION_ID,
      "--json",
    ],
    {
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      cwd: directory,
      policyPath,
      write: () => {},
      spawn: spawnFake.spawn,
      probeSpawn: okProbe().spawn,
      sessionIo: { stderr: { write: (line) => stderr.push(line) } },
    },
  );

  // 停止したら `ps` の argv という情報源が消えるので、完走を待って出すのでは遅い。
  assert.ok(
    stderrAtSpawn.join("").includes(SESSION_ID),
    "the ledger must be able to record the id before the child runs",
  );
});

test("no conversation value reaches any persisted table", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  // 流出経路ごとに別の sentinel を使う。1 つに束ねると、どの経路が漏れたか分からないし、
  // 片方だけ漏れているときに検出できない。
  const promptSentinel = "SENTINEL-PROMPT-BODY";
  const questionSentinel = "SENTINEL-QUESTION-TEXT";
  const answerSentinel = "SENTINEL-FREE-TEXT-ANSWER";
  const assistantSentinel = "SENTINEL-ASSISTANT-OUTPUT";
  const spawnFake = createFakeSpawn({
    lines: [
      initEvent(),
      {
        type: "assistant",
        message: { content: [{ type: "text", text: assistantSentinel }] },
      },
      {
        type: "user",
        message: { content: [{ type: "text", text: answerSentinel }] },
      },
      resultEvent({
        result: assistantSentinel,
        permission_denials: [
          {
            tool_name: "AskUserQuestion",
            tool_input: { questions: [{ question: questionSentinel }] },
          },
        ],
      }),
    ],
  });

  const { code, stderr, output } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    promptBody: promptSentinel,
    extraFlags: ["--label", "feat-537-child"],
  });
  assert.equal(code, 0);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const database = new DatabaseSync(statePath);
  context.after(() => database.close());
  // 列を 1 つ足したときに検査から漏れないよう、行ごと文字列化して全テーブルを走査する。
  const persisted = JSON.stringify([
    database.prepare("SELECT * FROM tasks").all(),
    database.prepare("SELECT * FROM route_decisions").all(),
    database.prepare("SELECT * FROM adapter_runs").all(),
    database.prepare("SELECT * FROM evidence").all(),
    store.listTelemetryEvents(),
  ]);
  const observable = `${persisted}${stderr.join("")}${output.join("")}`;
  for (const [label, sentinel] of [
    ["prompt body", promptSentinel],
    ["question text", questionSentinel],
    ["free-text answer", answerSentinel],
    ["assistant output", assistantSentinel],
  ]) {
    assert.equal(
      observable.includes(sentinel),
      false,
      `${label} must not reach the state, the heartbeat, or the report`,
    );
  }
  // 拒否されたツールは**名前だけ**なら残ってよい（これが残らないと監査が成立しない）。
  assert.ok(persisted.includes("AskUserQuestion"));
});

test("the child runs in the worktree it was given", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { worktree } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(spawnFake.calls[0].options.cwd, worktree);
});

test("the provider runs outside the write transaction", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  let writeDuringRun = null;
  const spawnFake = createFakeSpawn({
    lines: [initEvent(), resultEvent()],
    // 子が走っている最中に別接続から書けること = 書き込みロックを握っていないこと。
    // 握っていれば SQLITE_BUSY で落ちる（子は数時間走りうるので、これは実運用の要件）。
    onSpawn: () => {
      const other = createStateStore(statePath);
      try {
        other.createTask({ goal: "concurrent probe" });
        writeDuringRun = true;
      } catch (error) {
        writeDuringRun = error.message;
      } finally {
        other.close();
      }
    },
  });

  const { code } = await launch({ directory, statePath, policyPath, spawnFake });

  assert.equal(code, 0);
  assert.equal(writeDuringRun, true, "a concurrent write must not be blocked");
});

// ---------------------------------------------------------------------------
// 完了条件（`--gate`）と session 結果への連結（#573）
// ---------------------------------------------------------------------------

test("a gate declaration reads its check kind only from the closed vocabulary", () => {
  assert.deepEqual(parseGateDeclaration("npm run test"), {
    kind: "test",
    command: "npm run test",
  });
  assert.deepEqual(parseGateDeclaration("lint:npm run lint"), {
    kind: "lint",
    command: "npm run lint",
  });
  // 引数に `:` を含むコマンドを kind 付きと読み違えない。承認できるコマンドは必ず
  // タスクランナー名で始まるので、手前が kind の語彙に一致することはありえない。
  assert.deepEqual(parseGateDeclaration("npm run test -- --grep=a:b"), {
    kind: "test",
    command: "npm run test -- --grep=a:b",
  });
  // 承認ゲートと同じ正規化（空白の畳み込み）を通す。通さないと「承認は通ったのに
  // 実行できない」宣言ができてしまう。
  assert.deepEqual(parseGateDeclaration("npm  run   test"), {
    kind: "test",
    command: "npm run test",
  });
  assert.throws(() => parseGateDeclaration("lint:"), /no command/);
  assert.throws(() => parseGateDeclaration("  "), /requires an approved command/);
});

test("the gate verdict never turns a red check into a pass", () => {
  assert.equal(gateVerdict([]), null);
  assert.equal(gateVerdict([{ status: "passed" }]), "passed");
  assert.equal(gateVerdict([{ status: "passed" }, { status: "failed" }]), "failed");
  assert.equal(gateVerdict([{ status: "errored" }]), "errored");
  // 確定した赤は「起動できなかった」に薄まらない。次に取る行動は赤で決まる。
  assert.equal(gateVerdict([{ status: "errored" }, { status: "failed" }]), "failed");
});

test("the gate moves the outcome downward only, and keeps the three-value contract", () => {
  // 宣言が無ければ子の結果はそのまま。`--gate` を渡していない呼び出しを一律で
  // 落とさない（gate 未通過は outcome ではなく連結件数から読む）。
  assert.equal(combineOutcome("succeeded", null), "succeeded");
  assert.equal(combineOutcome("succeeded", "passed"), "succeeded");
  assert.equal(combineOutcome("succeeded", "failed"), "failed");
  // 「判定できないなら成功と言わない」。起動できなかった gate は indeterminate。
  assert.equal(combineOutcome("succeeded", "errored"), "indeterminate");
  // gate は結果を良くしない。
  assert.equal(combineOutcome("failed", "passed"), "failed");
  assert.equal(combineOutcome("indeterminate", "passed"), "indeterminate");
});

test("a passing gate is linked to the adapter run it verified", async (context) => {
  const { code, report, statePath } = await launchWithGates(context, {
    gates: ["npm run test", "lint:npm run lint"],
    commands: ["npm run test", "npm run lint"],
  });

  assert.equal(code, 0);
  assert.equal(report.status, "succeeded");
  assert.equal(report.outcome, "succeeded");
  assert.equal(report.gate.status, "passed");
  assert.deepEqual(
    report.gate.results.map((result) => [result.kind, result.status, result.exitCode]),
    [
      ["test", "passed", 0],
      ["lint", "passed", 0],
    ],
  );

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  const linked = store.listVerificationResultsForAdapterRun(run.id);
  // **これが #573 の中身。** 列は前からあったが、書く実装が無かった。
  assert.equal(linked.length, 2);
  // 行の並びは主張しない。同一トランザクションで書くので created_at が同値になりえ、
  // そのときの順序は id 依存（乱数）になる。宣言順は emit 側の `gate.results` が持つ。
  assert.deepEqual(
    linked.map((result) => `${result.checkKind}:${result.status}:${result.command}`).sort(),
    ["lint:passed:npm run lint", "test:passed:npm run test"],
  );
  for (const result of linked) {
    assert.equal(result.adapterRunId, run.id);
    assert.equal(result.taskId, run.taskId);
    assert.ok(result.evidenceId, "each check keeps its own evidence row");
  }
});

test("a failing gate keeps a turn that ended cleanly out of succeeded", async (context) => {
  const { code, report, statePath } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    gateExitCode: 1,
  });

  // 子はエラーなく終わっている。区別できるのは gate を走らせたからである。
  assert.equal(report.childOutcome, "succeeded");
  assert.equal(report.exitCode, 0);
  assert.equal(report.outcome, "failed");
  assert.equal(report.status, "failed");
  assert.equal(code, 1);
  assert.equal(report.gate.status, "failed");
  assert.match(report.failureReason, /completion gate did not pass: 1 of 1/);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  assert.equal(run.status, "failed");
  assert.deepEqual(
    store.listVerificationResultsForAdapterRun(run.id).map((result) => result.status),
    ["failed"],
  );
});

test("a gate that cannot be started is indeterminate, not a pass", async (context) => {
  const { code, report, statePath } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    binOnPath: false,
  });

  assert.equal(report.childOutcome, "succeeded");
  assert.equal(report.outcome, "indeterminate");
  // adapter_runs の語彙は増やさない。indeterminate は failed として記録される。
  assert.equal(report.status, "failed");
  assert.equal(code, 1);
  assert.equal(report.gate.status, "errored");

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  assert.deepEqual(
    store.listVerificationResultsForAdapterRun(run.id).map((result) => result.status),
    ["errored"],
  );
});

test("a gate the manifest does not approve starts no child at all", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    extraFlags: ["--gate", "npm run deploy"],
  });

  assert.equal(code, BLOCKED_PENDING_APPROVAL);
  assert.equal(report.executed, false);
  assert.match(report.executionReason, /completion gate command/);
  assert.deepEqual(
    report.gaps.map((gap) => [gap.kind, gap.value]),
    [["command", "npm run deploy"]],
  );
  // 数時間走ったあとで「その gate は承認されていない」と分かる形にしない。
  assert.equal(spawnFake.calls.length, 0);
});

test("a child that failed runs no gate check and says so", async (context) => {
  const { code, report, statePath } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    spawnOverride: createFakeSpawn({
      lines: [initEvent(), resultEvent({ is_error: true, subtype: "error_max_turns" })],
      exitCode: 1,
    }),
  });

  assert.equal(code, 1);
  assert.equal(report.outcome, "failed");
  assert.equal(report.gate.status, "not-run");
  assert.match(report.gate.reason, /did not succeed/);
  assert.deepEqual(report.gate.results, []);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  assert.deepEqual(store.listVerificationResultsForAdapterRun(run.id), []);
});

test("a session that declared no gate is not silently read as verified", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);

  const { code, report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
  });

  // 既存の呼び出しは今までどおり 0 で終わる。区別できるのは gate 欄と連結件数からである。
  assert.equal(code, 0);
  assert.equal(report.outcome, "succeeded");
  assert.equal(report.gate.status, "not-declared");
  assert.deepEqual(report.gate.declared, []);

  const output = [];
  assert.equal(
    runCli(["runs", "--json"], { config, statePath, cwd: directory, write: (line) => output.push(line) }),
    0,
  );
  const { runs } = JSON.parse(output.at(-1));
  assert.deepEqual(runs[0].verification, {
    total: 0,
    passed: 0,
    failed: 0,
    errored: 0,
    skipped: 0,
  });
});

test("fh runs reports how many checks each run is linked to", async (context) => {
  const { statePath, directory } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
  });

  const listed = [];
  assert.equal(
    runCli(["runs", "--json"], { config, statePath, cwd: directory, write: (line) => listed.push(line) }),
    0,
  );
  const { runs } = JSON.parse(listed.at(-1));
  assert.deepEqual(runs[0].verification, {
    total: 1,
    passed: 1,
    failed: 0,
    errored: 0,
    skipped: 0,
  });

  // 1 件を引くときは、何を通したのかまで返る。
  const single = [];
  assert.equal(
    runCli(["runs", "--run", runs[0].id, "--json"], {
      config,
      statePath,
      cwd: directory,
      write: (line) => single.push(line),
    }),
    0,
  );
  const detail = JSON.parse(single.at(-1));
  assert.deepEqual(
    detail.verifications.map((result) => [result.checkKind, result.status, result.command]),
    [["test", "passed", "npm run test"]],
  );
});

test("the child is told the completion condition it will be measured by", async (context) => {
  const prepared = await preparedDirectory(context, { commands: ["npm run test"] });
  const bin = fakeBinDirectory(prepared.directory);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  await launch({
    ...prepared,
    spawnFake,
    extraFlags: ["--gate", "npm run test"],
    environment: { ...process.env, PATH: bin },
  });

  const { argv } = spawnFake.calls[0];
  const prompt = argv[argv.indexOf("-p") + 1];
  assert.match(prompt, /<completion-gate>/);
  assert.match(prompt, /npm run test/);
  // 呼び出し側の prompt はそのまま後ろに続く（説明が本文を置き換えない）。
  assert.match(prompt, new RegExp(PROMPT_BODY));
});

test("a gate leaves the command and the exit code in the record, and nothing else", async (context) => {
  const { statePath } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    gateExitCode: 1,
    spawnOverride: createFakeSpawn({
      lines: [
        initEvent(),
        { type: "assistant", message: { content: PROMPT_BODY } },
        resultEvent(),
      ],
    }),
  });

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const persisted = JSON.stringify([
    store.listEvidence(),
    store.listAdapterRuns(),
    store.listVerificationResults(),
  ]);
  assert.equal(persisted.includes(PROMPT_BODY), false);
  // 承認済み manifest と完全一致した文字列と終了コードは残ってよい（残らないと
  // 「何が赤だったのか」を後から引けない）。
  assert.ok(persisted.includes("npm run test"));
  assert.ok(
    store
      .listEvidence()
      .some((row) =>
        row.claimsSupported.some((claim) => claim === "the deterministic test check failed"),
      ),
    "each gate check keeps a verification_run evidence row of its own",
  );
});

test("a gate that was declared but never measured is not a pass", () => {
  // 条件を課したうえで測れなかったのだから、通ったとは言えない（rollout guard 等で
  // チェックが 1 本も走らなかった経路）。宣言していない場合と扱いを分ける。
  assert.equal(combineOutcome("succeeded", null, { declared: true }), "indeterminate");
  assert.equal(combineOutcome("succeeded", null, { declared: false }), "succeeded");

  assert.deepEqual(
    resolveGate({
      gates: [{ kind: "test", command: "npm run test" }],
      results: [],
      notRunReason: "shadow rollout records session completion gate checks without provider execution",
      childOutcome: "succeeded",
    }),
    {
      verdict: null,
      status: "not-run",
      outcome: "indeterminate",
      failureReason:
        "shadow rollout records session completion gate checks without provider execution",
    },
  );
  // 子がそもそも失敗しているなら、gate が走らなかった理由は失敗の説明にならない。
  assert.equal(
    resolveGate({
      gates: [{ kind: "test", command: "npm run test" }],
      results: [],
      notRunReason: "the child session did not succeed, so no gate check was run",
      childOutcome: "failed",
    }).failureReason,
    null,
  );
});

// ---------------------------------------------------------------------------
// レビュー指摘への回帰テスト（PR #613）
// ---------------------------------------------------------------------------

// gate ごとに違う終了コードを返す fake。`options.gateSpawn` の注入口を通る唯一の経路で、
// 実プロセスに依存する `launchWithGates` では作れない「一方 pass・一方 fail」を作る。
function createGateSpawn(exitCodes) {
  const calls = [];
  const spawn = (executable, argv, options) => {
    const child = new EventEmitter();
    child.kill = () => {};
    calls.push({ executable, argv, options });
    const code = exitCodes[calls.length - 1];
    setImmediate(() => child.emit("close", code));
    return child;
  };
  return { spawn, calls };
}

test("an invalid --gate-timeout-ms is refused before the child is started", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context, {
    commands: ["npm run test"],
  });
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  await assert.rejects(
    launch({
      directory,
      statePath,
      policyPath,
      spawnFake,
      extraFlags: ["--gate", "npm run test", "--gate-timeout-ms", "0"],
    }),
    /--gate-timeout-ms must be a positive integer/,
  );

  // **子を起こす前に落ちること。** 以前は gate 実行の直前で初めて評価していたため、
  // 例外は子が走り終わったあとに投げられ、adapter_runs も evidence も残らないまま
  // 抜けていた（記録を残さずにクラッシュする、この設計が最も嫌う失敗）。
  assert.equal(spawnFake.calls.length, 0);
  const store = createStateStore(statePath);
  context.after(() => store.close());
  assert.deepEqual(store.listAdapterRuns(), []);
});

test("an invalid --gate-timeout-ms is refused even when no gate is declared", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);

  // gate を宣言していないからといって、打ち間違えたフラグを黙って捨てない。
  await assert.rejects(
    launch({
      directory,
      statePath,
      policyPath,
      spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
      extraFlags: ["--gate-timeout-ms", "not-a-number"],
    }),
    /--gate-timeout-ms must be a positive integer/,
  );
});

test("the gate timeout is clamped to the same ceiling as fh verify", () => {
  assert.equal(gateTimeoutMs(undefined), DEFAULT_CHECK_TIMEOUT_MS);
  assert.equal(gateTimeoutMs(1_000), 1_000);
  // 上限を超える指定は黙って通さずクランプする。`fh verify --timeout-ms` と同じ値であること
  // （`check-runner.mjs` が両方の唯一の出どころ）。
  assert.equal(gateTimeoutMs(MAX_CHECK_TIMEOUT_MS * 10), MAX_CHECK_TIMEOUT_MS);
});

test("more gates than the cap are refused instead of occupying the harness", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context, {
    commands: ["npm run test"],
  });
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });
  const tooMany = Array.from({ length: MAX_SESSION_GATES + 1 }, () => [
    "--gate",
    "npm run test",
  ]).flat();

  await assert.rejects(
    launch({ directory, statePath, policyPath, spawnFake, extraFlags: tooMany }),
    new RegExp(`--gate may be declared at most ${MAX_SESSION_GATES} times`),
  );
  assert.equal(spawnFake.calls.length, 0);
});

test("gates run serially in declaration order and every result is linked", async (context) => {
  // 1 本目 pass・2 本目 fail。実プロセス経由の helper では作れない組み合わせで、
  // 「確定した赤が判定を決める」ことと「両方の結果が記録される」ことを同時に固定する。
  const gateSpawnFake = createGateSpawn([0, 1]);
  const { code, report, statePath } = await launchWithGates(context, {
    gates: ["npm run test", "lint:npm run lint"],
    commands: ["npm run test", "npm run lint"],
    gateSpawnFake,
  });

  assert.equal(gateSpawnFake.calls.length, 2);
  // 宣言順に、直列で走る（同じ作業ツリーを取り合わせない）。
  assert.deepEqual(
    gateSpawnFake.calls.map((call) => call.argv),
    [
      ["run", "test"],
      ["run", "lint"],
    ],
  );
  assert.equal(report.childOutcome, "succeeded");
  assert.equal(report.outcome, "failed");
  assert.equal(report.gate.status, "failed");
  assert.equal(code, 1);
  assert.match(report.failureReason, /1 of 2 declared check\(s\) did not pass/);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  assert.deepEqual(
    store
      .listVerificationResultsForAdapterRun(run.id)
      .map((result) => `${result.checkKind}:${result.status}`)
      .sort(),
    ["lint:failed", "test:passed"],
  );
});

test("fh runs breaks the linked checks down by status, not just by count", async (context) => {
  const { statePath, directory } = await launchWithGates(context, {
    gates: ["npm run test", "lint:npm run lint"],
    commands: ["npm run test", "npm run lint"],
    gateSpawnFake: createGateSpawn([0, 1]),
  });

  const listed = [];
  assert.equal(
    runCli(["runs", "--json"], {
      config,
      statePath,
      cwd: directory,
      write: (line) => listed.push(line),
    }),
    0,
  );
  const { runs } = JSON.parse(listed.at(-1));
  // 内訳が status ごとに分かれていること。`total` だけを見ていると、赤（failed）と
  // 判定不能（errored）で次の行動が違うことが読めない。
  assert.deepEqual(runs[0].verification, {
    total: 2,
    passed: 1,
    failed: 1,
    errored: 0,
    skipped: 0,
  });
});

test("fh runs counts a check that could not be started as errored", async (context) => {
  const { statePath, directory } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    binOnPath: false,
  });

  const listed = [];
  assert.equal(
    runCli(["runs", "--json"], {
      config,
      statePath,
      cwd: directory,
      write: (line) => listed.push(line),
    }),
    0,
  );
  const { runs } = JSON.parse(listed.at(-1));
  assert.deepEqual(runs[0].verification, {
    total: 1,
    passed: 0,
    failed: 0,
    errored: 1,
    skipped: 0,
  });
});

test("resume declares and runs its gates the same way launch does", async (context) => {
  // `--gate` は session 共通フラグなので resume にも渡せる。解析・manifest 照合・実行・
  // adapter_run への連結が resume 経路でも維持されることを固定する。
  const gateSpawnFake = createGateSpawn([0]);
  const { code, report, statePath } = await launchWithGates(context, {
    action: "resume",
    gates: ["npm run test"],
    commands: ["npm run test"],
    gateSpawnFake,
  });

  assert.equal(code, 0);
  assert.equal(report.action, "resume");
  assert.equal(report.gate.status, "passed");
  assert.deepEqual(gateSpawnFake.calls[0].argv, ["run", "test"]);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const [run] = store.listAdapterRuns();
  assert.deepEqual(
    store.listVerificationResultsForAdapterRun(run.id).map((result) => result.status),
    ["passed"],
  );
});

test("the gate check does not inherit the caller's credentials", async (context) => {
  // 呼び出し元 `fh` の環境には token 類が載りうる。gate は sandbox の外で走るので、
  // それをそのまま渡すと「子は outbound を禁じられているのに、gate 経由で持ち出せる」
  // 経路になる。許可リストに無い名前が 1 つも渡らないことを実際の spawn 引数で確かめる。
  const gateSpawnFake = createGateSpawn([0]);
  const prepared = await preparedDirectory(context, { commands: ["npm run test"] });
  const bin = fakeBinDirectory(prepared.directory);
  await launch({
    ...prepared,
    spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
    gateSpawnFake,
    extraFlags: ["--gate", "npm run test"],
    environment: {
      ...process.env,
      PATH: bin,
      GITHUB_TOKEN: PROMPT_BODY,
      ANTHROPIC_API_KEY: PROMPT_BODY,
      SOME_VENDOR_SECRET: PROMPT_BODY,
    },
  });

  const passed = gateSpawnFake.calls[0].options.env;
  assert.equal(passed.GITHUB_TOKEN, undefined);
  assert.equal(passed.ANTHROPIC_API_KEY, undefined);
  assert.equal(passed.SOME_VENDOR_SECRET, undefined);
  // 値そのものが 1 つも漏れていないこと（名前だけを列挙して満足しない）。
  assert.equal(Object.values(passed).includes(PROMPT_BODY), false);
  // チェックを走らせるのに要るものは残る。
  assert.equal(passed.PATH, bin);
  assert.deepEqual(
    Object.keys(passed).filter((name) => !GATE_ENVIRONMENT_ALLOWLIST.includes(name)),
    [],
  );
});

test("the allowlist keeps what a task runner needs to start at all", () => {
  // PATH が落ちると `resolveCheckExecutable` が実行ファイルを解決できず、
  // すべての gate が errored になる（機能が丸ごと死ぬ）。HOME はツールチェインの
  // 既定パスの起点なので、両方が許可リストにあることを固定する。
  for (const name of ["PATH", "HOME", "TMPDIR"]) {
    assert.ok(GATE_ENVIRONMENT_ALLOWLIST.includes(name), `${name} must stay`);
  }
  const reduced = gateEnvironment({ PATH: "/bin", GITHUB_TOKEN: "t", HOME: "/h" });
  assert.deepEqual({ ...reduced }, { PATH: "/bin", HOME: "/h" });
});

test("fh runs accounts for every verification status, including skipped", async (context) => {
  const { statePath, directory } = await launchWithGates(context, {
    gates: ["npm run test"],
    commands: ["npm run test"],
    gateSpawnFake: createGateSpawn([0]),
  });

  // `skipped` を書く producer はまだ無いが、列としては存在する。内訳が `total` を
  // 説明しなくなる状態（合計が合わないのに読み手が気づけない）を作らないため、
  // 4 値すべてが数えられていることを、行を直接足して確かめる。
  const store = createStateStore(statePath);
  const [run] = store.listAdapterRuns();
  store.recordVerificationResult({
    taskId: run.taskId,
    adapterRunId: run.id,
    checkKind: "lint",
    status: "skipped",
    command: "npm run lint",
  });
  store.close();

  const listed = [];
  assert.equal(
    runCli(["runs", "--json"], {
      config,
      statePath,
      cwd: directory,
      write: (line) => listed.push(line),
    }),
    0,
  );
  const { runs } = JSON.parse(listed.at(-1));
  assert.deepEqual(runs[0].verification, {
    total: 2,
    passed: 1,
    failed: 0,
    errored: 0,
    skipped: 1,
  });
  // 内訳の合計が total を説明すること。これが崩れると読み手は差の存在に気づけない。
  const { total, ...breakdown } = runs[0].verification;
  assert.equal(
    Object.values(breakdown).reduce((sum, count) => sum + count, 0),
    total,
  );
});

// ---------------------------------------------------------------------------
// resume は launch 時の capability を継承する（#604）
// ---------------------------------------------------------------------------

// launch → resume を同じ state に対して通す。`--session-id` に採番した値をそのまま
// `--resume-key` へ渡すのは wave-orchestrator の運用そのもの（Leader が採番し、停止後に
// 同じ値で起こし直す）で、継承の相関キーもその値である。
async function launchThenResume(
  context,
  {
    launchFlags = [],
    resumeFlags = [],
    capabilities = [SESSION_CAPABILITY, TIER_CAPABILITY],
    sessionConfig = config,
    resumeConfig,
    beforeResume = () => {},
    childSessionId = RESUME_KEY,
  } = {},
) {
  const prepared = await preparedDirectory(context, { capabilities });
  const events = [
    initEvent({ session_id: childSessionId }),
    resultEvent({ session_id: childSessionId }),
  ];
  const launched = await launch({
    ...prepared,
    sessionConfig,
    spawnFake: createFakeSpawn({ lines: events }),
    sessionIdFlag: RESUME_KEY,
    extraFlags: launchFlags,
  });
  await beforeResume(prepared);
  const resumed = await launch({
    ...prepared,
    sessionConfig: resumeConfig ?? sessionConfig,
    spawnFake: createFakeSpawn({ lines: events }),
    action: "resume",
    extraFlags: resumeFlags,
  });
  return { ...prepared, launched, resumed };
}

test("resume inherits the capability the session was launched with", async (context) => {
  const { launched, resumed } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
  });

  assert.equal(launched.code, 0);
  assert.equal(launched.report.capability, TIER_CAPABILITY);
  assert.equal(launched.report.capabilitySource, "explicit");

  // ここが #604 そのもの。`--capability` を省いた resume が既定へ戻ってはならない。
  assert.equal(resumed.code, 0);
  assert.equal(resumed.report.capability, TIER_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "inherited");
  // 記録側も同じでなければ、`fh runs` から見た tier 選択は消えたままになる。
  assert.equal(resumed.report.effort, "high");
});

test("an explicit --capability on resume still wins, so a deliberate change is not undone", async (context) => {
  // 中断の理由が model 不足だった、という運用は正当なので、継承が明示を上書きしてはならない。
  const { resumed } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
    resumeFlags: ["--capability", SESSION_CAPABILITY],
  });

  assert.equal(resumed.code, 0);
  assert.equal(resumed.report.capability, SESSION_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "explicit");
  assert.equal(resumed.report.effort, "xhigh");
});

test("a resume with nothing recorded falls back to the default and names the source", async (context) => {
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { code, report, stderr } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    action: "resume",
  });

  // 引けなかったことを理由に `--capability` を要求はしない —— 引けない以上、launch が
  // 明示だったのかも分からないため、選択していない呼び出し側に選択を強いることになる。
  // 代わりに `default` と告げて、呼び出し側が機械的に gate できる形にする。
  assert.equal(code, 0);
  assert.equal(report.capability, SESSION_CAPABILITY);
  assert.equal(report.capabilitySource, "default");
  assert.ok(
    stderr.some((line) => line.includes(`capability ${SESSION_CAPABILITY} (default)`)),
    "the source belongs on stderr as well, for the pane that has no JSON",
  );
});

test("launch reports the source it used, and never inherits", async (context) => {
  // launch は新しいセッションの開始なので、たとえ同じ id を再利用しても継承の対象にしない。
  const { launched } = await launchThenResume(context, {});

  assert.equal(launched.report.capabilitySource, "default");
  assert.equal(launched.report.capability, SESSION_CAPABILITY);
});

test("inheritance keys off the identifier the caller assigned, not the one the child echoed", async (context) => {
  // 相関キーは Leader が採番して `--resume-key` に渡す値である。子が構造化出力へ載せる
  // session_id を鍵にすると、両者がずれた瞬間に継承が静かに外れる。
  const { resumed, launched } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
    childSessionId: SESSION_ID,
  });

  assert.equal(launched.report.resumeKey, SESSION_ID, "the child echoed a different id");
  assert.equal(resumed.report.capability, TIER_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "inherited");
});

test("a second resume keeps carrying the capability forward", async (context) => {
  const prepared = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
  });
  assert.equal(prepared.resumed.report.capabilitySource, "inherited");

  const again = await launch({
    directory: prepared.directory,
    statePath: prepared.statePath,
    policyPath: prepared.policyPath,
    spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
    action: "resume",
  });

  // 2 回目は 1 回目の resume が書いた route から引く。継承した値を継承し直せないと、
  // 長い wave では 2 回目の中断で選択が消えることになる。
  assert.equal(again.report.capability, TIER_CAPABILITY);
  assert.equal(again.report.capabilitySource, "inherited");
});

test("a launch the manifest blocked does not become an inheritance source", async (context) => {
  // escalation route は capability を持たない（何で走るはずだったかは記録していない）。
  // それを継承元に採ると、承認されなかった選択が resume 側で復活しうる。
  const { directory, statePath, policyPath } = await preparedDirectory(context, {
    capabilities: [SESSION_CAPABILITY],
  });
  const spawnFake = createFakeSpawn({ lines: [] });

  const blocked = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    sessionIdFlag: RESUME_KEY,
    extraFlags: ["--capability", TIER_CAPABILITY],
  });
  assert.equal(blocked.code, 2);
  assert.equal(blocked.report.executed, false);

  const resumed = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake: createFakeSpawn({ lines: [initEvent(), resultEvent()] }),
    action: "resume",
  });

  assert.equal(resumed.report.capability, SESSION_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "default");
});

test("a recorded capability that left the registry falls back loudly instead of stranding the session", async (context) => {
  // capability の改名や整理で、過去に起こした子を二度と再開できなくする理由は無い。
  // ただし黙って落とすと #604 の「静かに取り消される」を別の形で再演することになる。
  const withoutTier = normalizeConfig({
    ...baseConfigInput,
    capabilities: Object.fromEntries(
      Object.entries(baseConfigInput.capabilities).filter(
        ([name]) => name !== TIER_CAPABILITY,
      ),
    ),
  });
  const { resumed } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
    resumeConfig: withoutTier,
  });

  assert.equal(resumed.code, 0);
  assert.equal(resumed.report.capability, SESSION_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "default");
  assert.ok(
    resumed.stderr.some(
      (line) =>
        line.includes(TIER_CAPABILITY) && line.includes("no longer usable"),
    ),
    "dropping a recorded capability must be said out loud",
  );
});

test("the inheritance source survives retention pruning", async (context) => {
  // 保存先を `adapter_runs` ではなく `route_decisions` にした理由の回帰。`fh clean` の
  // prune は adapter_runs を消すので、そちらに持たせると rawArtifactsDays を過ぎた
  // セッションが継承できなくなる（中断が長引くほど効かなくなる、という最悪の壊れ方をする）。
  const { resumed } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
    beforeResume: ({ directory, statePath }) => {
      const store = createStateStore(statePath);
      const future = new Date(Date.now() + 86_400_000).toISOString();
      store.pruneExpired({
        rawCutoff: future,
        telemetryCutoff: future,
        artifactRoot: directory,
      });
      assert.equal(
        store.listAdapterRuns().length,
        0,
        "the run record must actually be prunable for this test to mean anything",
      );
      assert.equal(store.findSessionCapability(RESUME_KEY).capability, TIER_CAPABILITY);
      store.close();
    },
  });

  assert.equal(resumed.report.capability, TIER_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "inherited");
});

test("the correlation key is on the route, and carries no conversation content", async (context) => {
  const { statePath } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
  });

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const routes = store.listRoutes();
  assert.equal(routes.length, 2, "launch and resume each record one route");
  for (const route of routes) {
    assert.equal(route.sessionId, RESUME_KEY);
    assert.equal(route.capability, TIER_CAPABILITY);
  }
  // 相関キーは `requireSafeArgumentValue` を通した識別子であって、prompt 本文ではない。
  const raw = new DatabaseSync(statePath, { readOnly: true });
  context.after(() => raw.close());
  for (const row of raw.prepare("SELECT * FROM route_decisions").all()) {
    assert.ok(
      !JSON.stringify(row).includes(PROMPT_BODY),
      "no route row may carry the prompt body",
    );
  }
});

// ---------------------------------------------------------------------------
// 「既定が registry 中で最も強い」に寄りかからない（#604 の前提固定）
// ---------------------------------------------------------------------------

test("a weaker default no longer decides what a resume runs on", async (context) => {
  // 現構成では既定（session.child）が最も強いので、省略時のフォールバックは常に上振れする。
  // その性質が崩れた registry で、**継承が効くかぎり** resume は launch の選択を保つ
  // ——「既定が最強」という前提に安全性が寄りかからないことを、ここで固定する。
  const { resumed } = await launchThenResume(context, {
    launchFlags: ["--capability", TIER_CAPABILITY],
    sessionConfig: weakDefaultConfig,
  });

  assert.equal(resumed.report.capability, TIER_CAPABILITY);
  assert.equal(resumed.report.capabilitySource, "inherited");
  assert.equal(resumed.report.model, "claude-opus-5");
  assert.equal(resumed.report.effort, "high");
});

test("a weaker default is what an uninheritable resume falls back to, and the report says so", async (context) => {
  // 残余条件を明文化する。継承元が引けないときのフォールバックは**依然として既定**なので、
  // 既定が弱くなれば resume は弱いほうで走る。#604 が消せるのは「静かであること」までで、
  // 上振れ／下振れそのものではない。だからこそ `capabilitySource` が要る —— 呼び出し側は
  // `default` を見て、自分で `--capability` を渡し直すか止まるかを決められる。
  const { directory, statePath, policyPath } = await preparedDirectory(context);
  const spawnFake = createFakeSpawn({ lines: [initEvent(), resultEvent()] });

  const { report } = await launch({
    directory,
    statePath,
    policyPath,
    spawnFake,
    action: "resume",
    sessionConfig: weakDefaultConfig,
  });

  assert.equal(report.capability, SESSION_CAPABILITY);
  assert.equal(report.capabilitySource, "default");
  // 既定が弱いまま黙って走った、という形にしない。値そのものを固定して、既定を弱くした
  // 変更がこのテストを踏むようにする。
  assert.equal(report.model, "claude-sonnet-5");
  assert.equal(report.effort, "low");
});
