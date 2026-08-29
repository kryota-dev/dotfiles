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
async function approveCapabilities(
  directory,
  capabilities,
  statePath,
  // policy.json をどのツリーへ書くか。既定は `directory` だが、承認境界がワークツリーから
  // 解決されることを確かめるテストは、ここを子のワークツリーへ向ける。
  policyRoot = directory,
) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({ commands: [], domains: [], capabilities }),
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
  return {
    code,
    output,
    stderr,
    worktree,
    report: output.length ? JSON.parse(output.at(-1)) : null,
  };
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
