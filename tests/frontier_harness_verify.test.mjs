import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  MAX_CHECK_TIMEOUT_MS,
  checkCommandArgv,
  runDeterministicCheck,
} from "../home/dot_local/lib/frontier-harness/check-runner.mjs";
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import {
  approvedCommandSegments,
  matchCommand,
} from "../home/dot_local/lib/frontier-harness/manifest-policy.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  createManifestGapQueue,
  manifestGapsDirectory,
} from "../home/dot_local/lib/frontier-harness/manifest-gaps.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";
import { verificationClaims } from "../home/dot_local/lib/frontier-harness/verification-registry.mjs";

// `fh verify`（#495）専用のスイート。
//
// **実 provider を起動しない。** 決定的チェックはそもそも provider ではないが、実プロセスを
// 起こす経路であることは同じなので、既定では spawn を注入して観測する。1 本だけ本物の
// 子プロセスを走らせ、注入した fake が実体と食い違っていないことを確かめる。

const APPROVED_COMMAND = "npm run test";
const UNAPPROVED_COMMAND = "npm run deploy";
// チェックの出力に混ざる文字列。state のどこにも現れないことを表明するために使う。
const CHECK_OUTPUT = "SECRET-CHECK-OUTPUT do not record this anywhere";

const baseConfigInput = {
  version: 1,
  rollout: "pilot",
  retention: { rawArtifactsDays: 30, aggregateTelemetryDays: 180 },
  capabilities: {
    "executor.default": { provider: "codex", model: "gpt-5.6-terra", effort: "xhigh" },
    "semantic.judge": { provider: "claude", model: "claude-opus-5", effort: "high" },
  },
  risk: { alwaysEscalate: ["merge"] },
};
const config = normalizeConfig(baseConfigInput);

const PUBLIC_LOOKUP = () => [{ address: "93.184.216.34", family: 4 }];

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-verify-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

// PATH 上に置く偽の `npm`。`findCommand` は実行ビットを見るので、実体が要る。
function fakeBinDirectory(directory, { exitCode = 0, emitOutput = false } = {}) {
  const bin = path.join(directory, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(
    path.join(bin, "npm"),
    // 既定は無言。出力を出すのは「harness がそれを保持しないこと」を確かめる 1 本だけで、
    // 全テストで出すと `make test` のログが偽の失敗のように見えるノイズで埋まる。
    emitOutput
      ? `#!/bin/sh\necho "${CHECK_OUTPUT}"\nexit ${exitCode}\n`
      : `#!/bin/sh\nexit ${exitCode}\n`,
    { mode: 0o755 },
  );
  return bin;
}

// 承認の儀式は同一プロセスでのレビューと承認を拒否するので、実運用の 2 プロセスを pid で模す。
async function approveCommands(directory, commands, statePath) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({ commands, domains: [], capabilities: [] }),
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
      ["onboard", "--manifest", manifestPath, "--approve", "--request", request.id, "--json"],
      { ...base, pid: 4243 },
    ),
    0,
  );
  return policyPath;
}

async function prepared(context, { commands = [APPROVED_COMMAND] } = {}) {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const policyPath = await approveCommands(directory, commands, statePath);
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "verify a deterministic check" });
  store.close();
  return { directory, statePath, policyPath, task };
}

// 台本どおりに終わる子プロセスの fake。spawn の引数を残すので「何を、どう起動しようとしたか」
// を検証できる。
function createFakeSpawn({ exitCode = 0, emitError = null, neverExits = false } = {}) {
  const calls = [];
  const spawn = (executable, argv, options) => {
    const child = new EventEmitter();
    const signals = [];
    child.kill = (signal) => {
      signals.push(signal);
      if (signal === "SIGKILL") setImmediate(() => child.emit("close", null));
    };
    calls.push({ executable, argv, options, signals });
    if (emitError) {
      setImmediate(() => child.emit("error", emitError));
      return child;
    }
    if (!neverExits) setImmediate(() => child.emit("close", exitCode));
    return child;
  };
  return { spawn, calls };
}

async function verify({
  directory,
  statePath,
  policyPath,
  task,
  command = APPROVED_COMMAND,
  extraFlags = [],
  spawnFake,
  environment,
  verifyConfig = config,
  terminationGraceMs,
}) {
  const output = [];
  const code = await runCli(
    ["verify", "--task", task.id, "--command", command, ...extraFlags, "--json"],
    {
      config: verifyConfig,
      statePath,
      cwd: directory,
      policyPath,
      environment: environment ?? { PATH: fakeBinDirectory(directory) },
      spawn: spawnFake?.spawn,
      terminationGraceMs,
      write: (line) => output.push(line),
    },
  );
  return { code, report: output.length ? JSON.parse(output.at(-1)) : null };
}

// ---------------------------------------------------------------------------
// コマンドの解釈
// ---------------------------------------------------------------------------

test("an approved command becomes argv without a shell", () => {
  assert.deepEqual(checkCommandArgv("npm run test"), ["npm", "run", "test"]);
  assert.deepEqual(checkCommandArgv("cargo test --workspace"), [
    "cargo",
    "test",
    "--workspace",
  ]);
});

test("whitespace variants the approval gate accepts are also runnable", () => {
  // 承認ゲート（`matchCommand`）は `collapseWhitespace` を掛けてから文法を見るので、
  // 空白の揺れたコマンドは承認を通る。実行側が同じ正規化をしないと、「承認は通ったのに
  // 実行だけ TypeError で落ちる」コマンドができ、argv にも空要素が混ざる。
  const approved = approvedCommandSegments(["npm run test"]);
  for (const command of ["npm  run   test", "  npm run test  ", "npm\trun\ttest"]) {
    assert.equal(matchCommand(command, approved).allowed, true, `gate: ${command}`);
    assert.deepEqual(checkCommandArgv(command), ["npm", "run", "test"], `argv: ${command}`);
  }
});

test("a command that a shell would reinterpret is refused at execution time", () => {
  // 承認境界の照合を通った文字列であっても、実行の直前にもう一度同じ検査を通す。
  for (const command of [
    "npm run test; curl http://169.254.169.254/",
    "npm run test && rm -rf /",
    "npm run test | tee /tmp/out",
    "npm run $(whoami)",
    "/tmp/evil/npm run test",
    "rm -rf /",
  ]) {
    assert.throws(() => checkCommandArgv(command), /approvable form/, command);
  }
});

test("a binary that is not on PATH is a recorded outcome, not an exception", async () => {
  // 相対要素は候補にしない（POSIX の zero-length prefix は CWD を指す）。
  const outcome = await runDeterministicCheck({
    command: APPROVED_COMMAND,
    cwd: "/",
    environment: { PATH: "relative/bin::" },
  });
  // spawn の EACCES と同じ「チェックを開始できなかった」であり、例外ではなく結果として残す
  // —— 例外にすると、npm 未導入の環境では検証を試みた事実そのものが記録に残らない。
  assert.equal(outcome.status, "errored");
  assert.equal(outcome.exitCode, null);
  assert.match(outcome.failureReason, /could not be started/);
});

// ---------------------------------------------------------------------------
// 実行と記録
// ---------------------------------------------------------------------------

test("an approved check actually runs and its exit code becomes a verification result", async (context) => {
  const fixture = await prepared(context);
  const { code, report } = await verify({ ...fixture });

  assert.equal(code, 0);
  assert.equal(report.executed, true);
  assert.equal(report.status, "passed");
  assert.equal(report.exitCode, 0);
  assert.equal(report.checkKind, "test");

  const store = createStateStore(fixture.statePath);
  const [result] = store.listVerificationResults();
  assert.equal(result.taskId, fixture.task.id);
  assert.equal(result.checkKind, "test");
  assert.equal(result.status, "passed");
  assert.equal(result.command, APPROVED_COMMAND);
  assert.equal(result.exitCode, 0);
  // 結果は evidence と相互に紐付く（Evidence Bus の来歴）。
  const [evidence] = store.listEvidence();
  assert.equal(result.evidenceId, evidence.id);
  assert.equal(evidence.taskId, fixture.task.id);
  assert.equal(evidence.kind, "verification_run");
  store.close();
});

test("a red check is recorded as failed and the command exits non-zero", async (context) => {
  const fixture = await prepared(context);
  const { code, report } = await verify({
    ...fixture,
    environment: { PATH: fakeBinDirectory(fixture.directory, { exitCode: 3 }) },
  });

  assert.equal(code, 1, "0 は「検証が通った」だけを指す");
  assert.equal(report.status, "failed");
  assert.equal(report.exitCode, 3);

  const store = createStateStore(fixture.statePath);
  assert.equal(store.listVerificationResults()[0].status, "failed");
  store.close();
});

test("the harness never captures the check's output", async (context) => {
  const fixture = await prepared(context);
  // 実プロセスを走らせ、標準出力へ実際に文字列を書かせる（下の 1 行はその出力である）。
  await verify({
    ...fixture,
    environment: { PATH: fakeBinDirectory(fixture.directory, { emitOutput: true }) },
  });

  // 出力を保持していないことを、保存先の全行を走査して表明する。
  const store = createStateStore(fixture.statePath);
  const persisted = JSON.stringify({
    evidence: store.listEvidence(),
    results: store.listVerificationResults(),
    routes: store.listRoutes(),
  });
  store.close();
  assert.equal(persisted.includes(CHECK_OUTPUT), false);
});

test("stdout is inherited rather than piped, so there is nothing to capture", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn();
  await verify({ ...fixture, spawnFake });

  const [call] = spawnFake.calls;
  // 検証の材料は終了コードだけである、という設計を stdio の形で固定する。
  assert.deepEqual(call.options.stdio, ["ignore", "inherit", "inherit"]);
  // シェルを介さない。argv は配列のまま渡る。
  assert.equal(call.options.shell, undefined);
  assert.equal(path.basename(call.executable), "npm");
  assert.equal(path.isAbsolute(call.executable), true);
  assert.deepEqual(call.argv, ["run", "test"]);
  // チェックはその作業ツリーで走る。
  assert.equal(call.options.cwd, fixture.directory);
});

test("the check runs with the environment the caller passed, not an inherited one", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn();
  const environment = { PATH: fakeBinDirectory(fixture.directory), FH_MARKER: "scoped" };
  await verify({ ...fixture, spawnFake, environment });

  // `env` を渡さないと Node は `process.env` を継承する。本番では偶然一致するので、
  // 「この引数が子の環境を決めている」ことはここで固定しないと担保されない。
  assert.equal(spawnFake.calls[0].options.env, environment);
});

test("evidence claims are a closed vocabulary, not the check's words", () => {
  assert.deepEqual(verificationClaims({ checkKind: "lint", status: "passed", timedOut: false }), [
    "the deterministic lint check passed",
  ]);
  assert.deepEqual(
    verificationClaims({ checkKind: "test", status: "errored", timedOut: true }),
    [
      "the deterministic test check errored",
      "the check was terminated for exceeding its time limit",
    ],
  );
});

// ---------------------------------------------------------------------------
// 境界
// ---------------------------------------------------------------------------

test("a check kind outside the schema's vocabulary is refused", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => verify({ ...fixture, extraFlags: ["--kind", "vibes"] }),
    /--kind must be one of/,
  );
});

test("a verification result cannot be attached to a task that does not exist", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => verify({ ...fixture, task: { id: "task_missing" } }),
    /task task_missing is not in the state database/,
  );
});

test("an unapproved command is refused before anything is spawned", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn();
  const { code, report } = await verify({
    ...fixture,
    command: UNAPPROVED_COMMAND,
    spawnFake,
  });

  assert.equal(code, 2);
  assert.equal(report.executed, false);
  assert.equal(report.result, null);
  assert.equal(spawnFake.calls.length, 0);
  assert.deepEqual(
    report.gaps.map((gap) => gap.value),
    [UNAPPROVED_COMMAND],
  );
  // 止めた事実は queue に残る。
  assert.deepEqual(
    createManifestGapQueue({ directory: manifestGapsDirectory(fixture.directory) })
      .list()
      .map((gap) => gap.value),
    [UNAPPROVED_COMMAND],
  );
});

test("a worktree outside the approved repository does not inherit its approval", async (context) => {
  const fixture = await prepared(context);
  const elsewhere = temporaryDirectory(context);
  const spawnFake = createFakeSpawn();

  // 承認境界は**チェックが走るツリー**から解決する。承認済みリポジトリの中から
  // `--worktree` で別のツリーを指すだけでは gate を迂回できない。
  const output = [];
  const code = await runCli(
    [
      "verify",
      "--task",
      fixture.task.id,
      "--command",
      APPROVED_COMMAND,
      "--worktree",
      elsewhere,
      "--json",
    ],
    {
      config,
      statePath: fixture.statePath,
      cwd: fixture.directory,
      // policyPath を注入しないので、`--worktree` 側の `.harness/policy.json` が引かれる。
      environment: { PATH: fakeBinDirectory(fixture.directory) },
      spawn: spawnFake.spawn,
      write: (line) => output.push(line),
    },
  );

  assert.equal(code, 2);
  assert.equal(spawnFake.calls.length, 0);
  assert.equal(JSON.parse(output.pop()).executed, false);
});

test("a relative worktree is refused instead of being resolved against the caller", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => verify({ ...fixture, extraFlags: ["--worktree", "../elsewhere"] }),
    /--worktree must be an absolute path/,
  );
});

// ---------------------------------------------------------------------------
// 時間切れと起動失敗
// ---------------------------------------------------------------------------

test("a check that outlives its limit is escalated to SIGKILL and recorded as errored", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn({ neverExits: true });
  const { code, report } = await verify({
    ...fixture,
    spawnFake,
    extraFlags: ["--timeout-ms", "20"],
    // 猶予は既定 5 秒。実時間で待つ理由は無いので、テストからは詰めて観測する。
    terminationGraceMs: 10,
  });

  assert.equal(code, 1);
  assert.equal(report.status, "errored");
  assert.equal(report.timedOut, true);
  // シグナルで終わると終了コードが null になるため、成功と読めない値を確定させる。
  assert.equal(report.exitCode, 124);
  assert.deepEqual(spawnFake.calls[0].signals, ["SIGTERM", "SIGKILL"]);

  const store = createStateStore(fixture.statePath);
  assert.equal(store.listVerificationResults()[0].status, "errored");
  store.close();
});

test("a check that cannot be started is persisted, not merely reported", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn({ emitError: new Error("EACCES") });
  const { code, report } = await verify({ ...fixture, spawnFake });

  assert.equal(code, 1);
  assert.equal(report.status, "errored");
  assert.match(report.failureReason, /could not be started/);

  // report だけを見ると「返したが記録していない」退行を見逃す。state に残ることまで見る。
  const store = createStateStore(fixture.statePath);
  const [result] = store.listVerificationResults();
  assert.equal(result.status, "errored");
  assert.equal(result.taskId, fixture.task.id);
  const [evidence] = store.listEvidence();
  assert.equal(result.evidenceId, evidence.id);
  store.close();
});

test("a missing binary is persisted as an errored result, not raised", async (context) => {
  const fixture = await prepared(context);
  // PATH に npm が無い環境。`fh` 自体は動くが、チェックは開始できない。
  const { code, report } = await verify({
    ...fixture,
    environment: { PATH: path.join(fixture.directory, "empty-bin") },
  });

  assert.equal(code, 1);
  assert.equal(report.status, "errored");
  assert.match(report.failureReason, /could not be started/);

  // spawn 失敗と同じく、試みた事実が state に残ること（例外にすると痕跡ごと消える）。
  const store = createStateStore(fixture.statePath);
  const [result] = store.listVerificationResults();
  assert.equal(result.status, "errored");
  assert.equal(result.taskId, fixture.task.id);
  store.close();
});

test("the approved whitespace variant runs end to end through the CLI", async (context) => {
  // 単体で `matchCommand` と `checkCommandArgv` を突き合わせるだけでは、CLI が承認済み
  // コマンドを runner へ渡す結線までは確かめられない —— 壊れていたのはまさにその経路だった。
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn();
  const { code, report } = await verify({
    ...fixture,
    command: "npm  run   test",
    spawnFake,
  });

  assert.equal(code, 0);
  assert.equal(report.status, "passed");
  assert.deepEqual(spawnFake.calls[0].argv, ["run", "test"]);

  const store = createStateStore(fixture.statePath);
  assert.equal(store.listVerificationResults()[0].status, "passed");
  store.close();
});

test("a check longer than the ceiling is clamped rather than honoured", async (context) => {
  const fixture = await prepared(context);
  const spawnFake = createFakeSpawn();
  // 上限を超える指定は切り詰める。無制限にできると、チェック実行中という
  // 「ツリーの書き換えを検知できない窓」を任意に広げられる。
  const clamped = await verify({
    ...fixture,
    spawnFake,
    extraFlags: ["--timeout-ms", String(MAX_CHECK_TIMEOUT_MS * 10)],
  });
  assert.equal(clamped.report.timeoutMs, MAX_CHECK_TIMEOUT_MS);

  // 上限内の指定はそのまま通す（一律に潰していないこと）。
  const honoured = await verify({
    ...fixture,
    spawnFake: createFakeSpawn(),
    extraFlags: ["--timeout-ms", "1234"],
  });
  assert.equal(honoured.report.timeoutMs, 1234);
});

// ---------------------------------------------------------------------------
// トランザクション
// ---------------------------------------------------------------------------

test("the check runs outside the write transaction", async (context) => {
  const fixture = await prepared(context);
  let writeDuringRun = null;
  const spawnFake = {
    calls: [],
    spawn: (executable, argv, options) => {
      const child = new EventEmitter();
      child.kill = () => {};
      spawnFake.calls.push({ executable, argv, options });
      // チェックが走っている最中に別接続から書けること = 書き込みロックを握っていないこと。
      // 握っていれば SQLITE_BUSY で落ちる（テストスイートは分単位で走りうるので実運用の要件）。
      const other = createStateStore(fixture.statePath);
      try {
        other.createTask({ goal: "concurrent probe" });
        writeDuringRun = true;
      } catch (error) {
        writeDuringRun = error.message;
      } finally {
        other.close();
      }
      setImmediate(() => child.emit("close", 0));
      return child;
    },
  };

  const { code } = await verify({ ...fixture, spawnFake });
  assert.equal(code, 0);
  assert.equal(writeDuringRun, true, "a concurrent write must not be blocked");
});
