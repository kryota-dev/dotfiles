import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
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
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
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
  },
  risk: { alwaysEscalate: ["merge"] },
};

const config = normalizeConfig(baseConfigInput);
const shadowConfig = normalizeConfig({ ...baseConfigInput, rollout: "shadow" });

const PUBLIC_LOOKUP = () => [{ address: "93.184.216.34", family: 4 }];

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-session-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

// 承認境界は #494 / #556 で実効化されているため、子を起こすテストは先に manifest を承認する。
// 儀式は同一プロセスでのレビューと承認を拒否するので、実運用の 2 プロセスを pid の注入で模す。
async function approveCapabilities(directory, capabilities, statePath) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({ commands: [], domains: [], capabilities }),
  );
  const policyPath = path.join(directory, ".harness", "policy.json");
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
function createFakeSpawn({ lines, exitCode = 0 }) {
  const calls = [];
  const spawn = (executable, argv, options) => {
    const child = new EventEmitter();
    const stdout = new EventEmitter();
    stdout.setEncoding = () => {};
    child.stdout = stdout;
    const signals = [];
    child.kill = (signal) => signals.push(signal);
    calls.push({ executable, argv, options, signals });

    let index = 0;
    const step = () => {
      if (index < lines.length) {
        stdout.emit("data", `${JSON.stringify(lines[index])}\n`);
        index += 1;
        setImmediate(step);
        return;
      }
      // 起動時検査で終わらせた子はシグナルで死ぬ（終了コードは無い）。
      child.emit("close", signals.length > 0 ? null : exitCode);
    };
    setImmediate(step);
    return child;
  };
  return { spawn, calls };
}

function okProbe() {
  const calls = [];
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    return {
      status: 0,
      signal: null,
      error: null,
      stdout: [
        JSON.stringify({ jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-06-18" } }),
        JSON.stringify({ jsonrpc: "2.0", id: 2, result: { tools: [{ name: "approve" }] } }),
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
}) {
  const worktree = path.join(directory, "worktree");
  mkdirSync(worktree, { recursive: true });
  const promptPath = path.join(directory, "prompt.txt");
  writeFileSync(promptPath, `${PROMPT_BODY}\n`);
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
      ...(action === "launch" ? ["--session-id", SESSION_ID] : ["--resume-key", RESUME_KEY]),
      ...extraFlags,
      "--json",
    ],
    {
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config: sessionConfig,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      cwd: directory,
      policyPath,
      write: (line) => output.push(line),
      spawn: spawnFake?.spawn,
      probeSpawn: probeFake.spawn,
      sessionIo: { stderr: { write: (line) => stderr.push(line) } },
    },
  );
  return { code, output, stderr, report: output.length ? JSON.parse(output.at(-1)) : null };
}

async function preparedDirectory(context) {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const policyPath = await approveCapabilities(
    directory,
    [SESSION_CAPABILITY],
    statePath,
  );
  return { directory, statePath, policyPath };
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
