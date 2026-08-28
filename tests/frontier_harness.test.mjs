import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import test from "node:test";

import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import { findCommand, runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { createDoctorReport } from "../home/dot_local/lib/frontier-harness/doctor.mjs";
import {
  loadVerifiedModels,
  probeAntigravity,
} from "../home/dot_local/lib/frontier-harness/readiness.mjs";
import { runWithRolloutGuard } from "../home/dot_local/lib/frontier-harness/rollout.mjs";
import { chooseRoute } from "../home/dot_local/lib/frontier-harness/router.mjs";
import { resolveGitCommonDirectory } from "../home/dot_local/lib/frontier-harness/state-root.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";
import { normalizeTask } from "../home/dot_local/lib/frontier-harness/task.mjs";

const CONFIGURED_FRONTEND_MODEL = "gemini-3.7-flash-high";

const baseConfigInput = {
  version: 1,
  rollout: "shadow",
  retention: {
    rawArtifactsDays: 30,
    aggregateTelemetryDays: 180,
  },
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
    "frontend.primary": {
      provider: "antigravity",
      model: CONFIGURED_FRONTEND_MODEL,
      effort: "high",
      accountScope: "personal",
    },
  },
  risk: {
    alwaysEscalate: ["merge"],
  },
};

const config = normalizeConfig(baseConfigInput);
const defaultRolloutConfig = normalizeConfig({
  ...baseConfigInput,
  rollout: "default",
});

const shippedConfig = normalizeConfig(
  JSON.parse(
    readFileSync(
      new URL("../home/dot_config/frontier-harness/config.json", import.meta.url),
      "utf8",
    ),
  ),
);

// frontend.primary の accountScope 制約を外した派生 config。
// 制約を残すと doctor が scope 不一致で先に unavailable を返し、
// readiness が scope ごとに分離されているかを分離して観測できない。
const scopeAgnosticConfig = normalizeConfig({
  ...baseConfigInput,
  capabilities: {
    ...baseConfigInput.capabilities,
    "frontend.primary": {
      provider: "antigravity",
      model: CONFIGURED_FRONTEND_MODEL,
      effort: "high",
    },
  },
});

const COMMAND_PATHS = {
  antigravity: "/opt/homebrew/bin/agy",
  claude: "/Users/example/.local/launchers/claude",
  codex: "/Users/example/.local/launchers/codex",
};

const VERIFIED_MODELS = { antigravity: [CONFIGURED_FRONTEND_MODEL] };

function availability({
  antigravity = true,
  claude = true,
  codex = true,
  antigravityModels = [CONFIGURED_FRONTEND_MODEL],
} = {}) {
  return {
    antigravity: {
      available: antigravity,
      models: antigravity ? antigravityModels : null,
    },
    claude: { available: claude, models: null },
    codex: { available: codex, models: null },
  };
}

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

// git fixture 用の共通設定。本リポジトリはコミット署名（1Password SSH）と gitleaks の
// pre-commit hook を使うため、明示的に無効化しないとテストが実行環境の設定に依存する。
const GIT_FIXTURE_FLAGS = Object.freeze([
  "-c",
  "user.email=frontier-harness@example.com",
  "-c",
  "user.name=frontier-harness test",
  "-c",
  "commit.gpgsign=false",
]);

function git(cwd, args) {
  return execFileSync("git", [...GIT_FIXTURE_FLAGS, ...args], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

// worktree を追加するには HEAD が要るため、空コミットを 1 つ置く。
function initRepository(directory) {
  mkdirSync(directory, { recursive: true });
  git(directory, ["init", "--quiet", directory]);
  git(directory, ["commit", "--quiet", "--allow-empty", "--no-verify", "-m", "init"]);
  return directory;
}

function writeTask(directory) {
  const taskPath = path.join(directory, "task.json");
  writeFileSync(
    taskPath,
    JSON.stringify({
      goal: "Record a shadow route",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
  );
  return taskPath;
}

test("normalizeConfig rejects an invalid rollout before an adapter runs", () => {
  assert.throws(
    () => normalizeConfig({ ...baseConfigInput, rollout: "unverified" }),
    /rollout/,
  );
});

test("normalizeConfig rejects a non-string alwaysEscalate entry", () => {
  assert.throws(
    () =>
      normalizeConfig({
        ...baseConfigInput,
        risk: { alwaysEscalate: ["merge", ""] },
      }),
    /alwaysEscalate/,
  );
});

test("shipped config escalates every risk name the skill tells agents to use", () => {
  for (const risk of [
    "credential",
    "data-migration",
    "deploy",
    "external-contract",
    "force-push",
    "merge",
    "migration",
    "release",
  ]) {
    assert.ok(
      shippedConfig.risk.alwaysEscalate.includes(risk),
      `${risk} must be escalated by the shipped config`,
    );
  }
});

test("router escalates the migration risk name used by the harness skill", () => {
  const decision = chooseRoute({
    task: normalizeTask({ goal: "apply a migration", risk: ["migration"] }),
    accountScope: "personal",
    availability: availability(),
    config: shippedConfig,
  });

  assert.equal(decision.kind, "escalation");
  assert.match(decision.reason, /migration/);
});

test("router chooses Antigravity for personal frontend work when available", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "browser work",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.capability, "frontend.primary");
  assert.equal(decision.provider, "antigravity");
  assert.equal(decision.kind, "single-worker");
});

test("router fails closed for an unavailable Antigravity account scope", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "browser work",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
    accountScope: "r06",
    availability: availability({ antigravity: false }),
    config,
  });

  assert.equal(decision.capability, "executor.default");
  assert.match(decision.reason, /unavailable/);
});

test("router fails closed when the configured frontend model was not discovered", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "browser work",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability({ antigravityModels: ["gemini-3.7-pro"] }),
    config,
  });

  assert.equal(decision.capability, "executor.default");
});

test("router ignores inherited Object.prototype keys when checking availability", () => {
  const decision = chooseRoute({
    task: normalizeTask({ goal: "text work", hasDeterministicOracle: true }),
    accountScope: "personal",
    // codex エントリ自体が無い availability。継承プロパティを可用性として拾わないこと。
    availability: { claude: { available: true, models: null } },
    config,
  });

  assert.equal(decision.kind, "escalation");
});

test("router escalates a task without a deterministic oracle to independent review", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "text work",
      modality: ["text"],
      hasDeterministicOracle: false,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.kind, "writer-plus-reviewer");
  assert.equal(decision.reviewerCapability, "semantic.judge");
});

test("router treats a missing oracle field as no oracle (fail closed)", () => {
  const decision = chooseRoute({
    task: normalizeTask({ goal: "text work", modality: ["text"] }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.kind, "writer-plus-reviewer");
});

test("normalizeTask rejects a non-boolean oracle flag and unknown array shapes", () => {
  assert.throws(
    () => normalizeTask({ goal: "g", hasDeterministicOracle: "false" }),
    /hasDeterministicOracle/,
  );
  assert.throws(() => normalizeTask({ goal: "g", risk: "merge" }), /risk/);
  assert.throws(() => normalizeTask({ goal: "" }), /goal/);
});

test("state store records evidence without a transcript field", () => {
  const store = createStateStore(":memory:");
  const evidence = store.putEvidence({
    kind: "test_failure",
    producer: "codex:gpt-5.6-terra",
    command: "node --test",
    exitCode: 1,
    artifactPath: "old.log",
    claimsSupported: ["regression reproducible"],
  });

  assert.match(evidence.id, /^ev_/);
  assert.equal(evidence.transcript, undefined);
  assert.deepEqual(store.listEvidence(), [evidence]);
  store.close();
});

test("state store ignores a caller supplied task id", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ id: "../../evil", goal: "injected id" });

  assert.match(task.id, /^task_[0-9a-f]{32}$/);
  assert.equal(task.hasDeterministicOracle, false);
  store.close();
});

test("state store keeps persistent evidence database private", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const store = createStateStore(statePath);
  store.close();
  assert.equal(statSync(statePath).mode & 0o777, 0o600);
});

test("state store enables concurrent-safe SQLite pragmas", (context) => {
  const directory = temporaryDirectory(context);
  const store = createStateStore(path.join(directory, "state.db"));
  assert.deepEqual(store.storageInfo(), { busyTimeout: 5000, journalMode: "wal" });
  store.close();
});

test("state store stamps a schema version and refuses a newer one", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const store = createStateStore(statePath);
  assert.equal(store.schemaVersion(), 1);
  store.close();

  const raw = new DatabaseSync(statePath);
  raw.exec("PRAGMA user_version = 99");
  raw.close();

  assert.throws(() => createStateStore(statePath), /newer than supported/);
});

test("state store rejects a symlinked database before opening it", (context) => {
  const directory = temporaryDirectory(context);
  const target = path.join(directory, "target.db");
  const link = path.join(directory, "state.db");
  symlinkSync(target, link);

  assert.throws(() => createStateStore(link), /symbolic link/);
  // 拒否より先に symlink 先へファイルを作らないこと。
  assert.equal(existsSync(target), false);
});

test("state store prunes only evidence older than the raw retention cutoff", () => {
  const store = createStateStore(":memory:");
  store.putEvidence({
    kind: "test_failure",
    producer: "codex:gpt-5.6-terra",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  store.putEvidence({
    kind: "test_pass",
    producer: "codex:gpt-5.6-terra",
    createdAt: "2026-08-27T00:00:00.000Z",
  });

  assert.equal(store.countEvidenceBefore("2026-08-01T00:00:00.000Z"), 1);
  assert.deepEqual(store.pruneEvidenceBefore("2026-08-01T00:00:00.000Z"), {
    prunedEvidence: 1,
    skippedArtifacts: [],
  });
  assert.equal(store.listEvidence().length, 1);
  assert.equal(store.listEvidence()[0].kind, "test_pass");
  store.close();
});

test("state store prunes expired artifact files only inside the artifact root", (context) => {
  const directory = temporaryDirectory(context);
  const artifactRoot = path.join(directory, "evidence");
  mkdirSync(artifactRoot);
  const artifactPath = path.join(artifactRoot, "old.log");
  writeFileSync(artifactPath, "old evidence");
  const store = createStateStore(path.join(directory, "state.db"));
  store.putEvidence({
    kind: "old_log",
    producer: "fake",
    createdAt: "2026-01-01T00:00:00.000Z",
    artifactPath,
  });
  store.close();

  const reopened = createStateStore(path.join(directory, "state.db"));
  const pruned = reopened.pruneEvidenceBefore("2026-08-01T00:00:00.000Z", artifactRoot);
  assert.equal(pruned.prunedEvidence, 1);
  assert.deepEqual(pruned.skippedArtifacts, []);
  assert.equal(existsSync(artifactPath), false);
  reopened.close();
});

test("artifact pruning refuses to traverse a symlink out of the evidence root", (context) => {
  const directory = temporaryDirectory(context);
  const artifactRoot = path.join(directory, "evidence");
  const outside = path.join(directory, "outside");
  mkdirSync(artifactRoot);
  mkdirSync(outside);
  const protectedFile = path.join(outside, "keep.txt");
  writeFileSync(protectedFile, "must survive");
  symlinkSync(outside, path.join(artifactRoot, "link"));

  const store = createStateStore(path.join(directory, "state.db"));
  store.putEvidence({
    kind: "old_log",
    producer: "fake",
    createdAt: "2026-01-01T00:00:00.000Z",
    artifactPath: "link/keep.txt",
  });
  const pruned = store.pruneEvidenceBefore("2026-08-01T00:00:00.000Z", artifactRoot);
  store.close();

  assert.equal(existsSync(protectedFile), true);
  assert.equal(pruned.skippedArtifacts.length, 1);
  assert.match(pruned.skippedArtifacts[0].reason, /symbolic link/);
  // 1 件の不正 path で retention 全体を止めない。
  assert.equal(pruned.prunedEvidence, 1);
});

test("doctor reports Antigravity as unavailable instead of crossing into r06", () => {
  const report = createDoctorReport({
    accountScope: "r06",
    commandPaths: COMMAND_PATHS,
    config,
    verifiedModels: VERIFIED_MODELS,
  });

  assert.equal(report.capabilities["executor.default"].status, "available");
  assert.equal(report.capabilities["frontend.primary"].status, "unavailable");
  assert.match(
    report.capabilities["frontend.primary"].reason,
    /account scope r06/,
  );
});

test("doctor marks an unprobed Antigravity executable as unverified", () => {
  const report = createDoctorReport({
    accountScope: "personal",
    commandPaths: COMMAND_PATHS,
    config,
  });

  assert.equal(report.capabilities["frontend.primary"].status, "unverified");
  assert.match(report.capabilities["frontend.primary"].reason, /authentication/);
});

test("doctor marks a probed Antigravity without the configured model as unverified", () => {
  const report = createDoctorReport({
    accountScope: "personal",
    commandPaths: COMMAND_PATHS,
    config,
    verifiedModels: { antigravity: ["gemini-3.7-pro"] },
  });

  assert.equal(report.capabilities["frontend.primary"].status, "unverified");
  assert.match(
    report.capabilities["frontend.primary"].reason,
    new RegExp(CONFIGURED_FRONTEND_MODEL.replaceAll(".", "\\.")),
  );
});

test("doctor names the executable operators actually have to install", () => {
  const report = createDoctorReport({
    accountScope: "personal",
    commandPaths: { claude: COMMAND_PATHS.claude, codex: COMMAND_PATHS.codex },
    config,
    verifiedModels: {},
  });

  assert.equal(report.capabilities["frontend.primary"].status, "unavailable");
  assert.match(report.capabilities["frontend.primary"].reason, /agy executable/);
});

test("Antigravity probe accepts only a successful structured model response", () => {
  const successful = probeAntigravity(COMMAND_PATHS.antigravity, () => ({
    status: 0,
    stdout: JSON.stringify({ models: [{ slug: CONFIGURED_FRONTEND_MODEL }] }),
    stderr: "",
  }));
  assert.equal(successful.verified, true);
  assert.deepEqual(successful.models, [CONFIGURED_FRONTEND_MODEL]);

  const failed = probeAntigravity(COMMAND_PATHS.antigravity, () => ({
    status: 1,
    stdout: "",
    stderr: "authentication required",
  }));
  assert.equal(failed.verified, false);
  assert.match(failed.reason, /authentication/);
});

test("Antigravity probe refuses to spawn a relative executable path", () => {
  const probe = probeAntigravity("agy", () => {
    throw new Error("the probe must not spawn a relative path");
  });

  assert.equal(probe.verified, false);
  assert.match(probe.reason, /absolute/);
});

test("findCommand ignores empty PATH entries that resolve to the working directory", (context) => {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-path-"));
  const executable = path.join(directory, "agy");
  writeFileSync(executable, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const previousCwd = process.cwd();
  process.chdir(directory);
  context.after(() => {
    process.chdir(previousCwd);
    rmSync(directory, { force: true, recursive: true });
  });

  // 末尾コロン = POSIX の zero-length prefix（CWD）。ここを候補にしない。
  assert.equal(findCommand("agy", "/nonexistent-frontier-bin:"), null);
  // 絶対パスの要素は従来どおり解決する。
  assert.equal(
    findCommand("agy", `/nonexistent-frontier-bin:${directory}`),
    executable,
  );
});

test("a future-dated readiness cache stays unverified", (context) => {
  const directory = temporaryDirectory(context);
  const readinessPath = path.join(directory, "readiness.json");
  writeFileSync(
    readinessPath,
    JSON.stringify({
      version: 1,
      antigravity: {
        verified: true,
        verifiedAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        models: [CONFIGURED_FRONTEND_MODEL],
      },
    }),
  );

  assert.deepEqual(loadVerifiedModels(readinessPath, Date.now()), {});
});

test("a fresh readiness cache keeps the discovered model list", (context) => {
  const directory = temporaryDirectory(context);
  const readinessPath = path.join(directory, "readiness.json");
  writeFileSync(
    readinessPath,
    JSON.stringify({
      version: 1,
      antigravity: {
        verified: true,
        verifiedAt: new Date().toISOString(),
        models: [CONFIGURED_FRONTEND_MODEL],
      },
    }),
  );

  assert.deepEqual(loadVerifiedModels(readinessPath, Date.now()), {
    antigravity: [CONFIGURED_FRONTEND_MODEL],
  });
});

test("the rollout guard never calls the executor while the rollout is shadow", () => {
  let calls = 0;
  const shadow = runWithRolloutGuard(config, "route", () => {
    calls += 1;
    return "executed";
  });
  assert.equal(calls, 0);
  assert.equal(shadow.executed, false);
  assert.match(shadow.reason, /shadow/);

  const promoted = runWithRolloutGuard(defaultRolloutConfig, "route", () => {
    calls += 1;
    return "executed";
  });
  assert.equal(calls, 1);
  assert.equal(promoted.executed, true);
});

test("fh doctor emits machine-readable capability readiness", () => {
  const output = [];
  const exitCode = runCli(["doctor", "--json"], {
    accountScope: "personal",
    commandPaths: COMMAND_PATHS,
    config,
    verifiedModels: VERIFIED_MODELS,
    write: (line) => output.push(line),
  });

  assert.equal(exitCode, 0);
  const report = JSON.parse(output.join("\n"));
  assert.equal(report.capabilities["frontend.primary"].status, "available");
  assert.equal(report.capabilities["semantic.judge"].model, "claude-opus-5");
});

test("fh doctor --probe persists readiness without persisting credentials", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const readinessPath = path.join(directory, "readiness.json");
  const output = [];
  assert.equal(
    runCli(["doctor", "--probe", "--json"], {
      // accountScope を注入しないと process.env 依存になる。判定材料が無い環境では
      // "unknown" に倒れ、personal 限定の frontend.primary が unavailable になる。
      accountScope: "personal",
      config,
      statePath,
      readinessPath,
      commandPaths: COMMAND_PATHS,
      probeProvider: () => ({
        verified: true,
        models: [CONFIGURED_FRONTEND_MODEL],
      }),
      write: (line) => output.push(line),
    }),
    0,
  );
  const report = JSON.parse(output.pop());
  assert.equal(report.capabilities["frontend.primary"].status, "available");
  assert.equal(readFileSync(readinessPath, "utf8").includes("credential"), false);
});

test("fh doctor --probe persists readiness through the default state root", (context) => {
  const directory = temporaryDirectory(context);
  execFileSync("git", ["init", "--quiet", directory]);
  const output = [];

  // 実 CLI と同じく statePath / readinessPath を注入しない経路を検証する。
  assert.equal(
    runCli(["doctor", "--probe", "--json"], {
      cwd: directory,
      accountScope: "personal",
      config,
      commandPaths: COMMAND_PATHS,
      probeProvider: () => ({
        verified: true,
        models: [CONFIGURED_FRONTEND_MODEL],
      }),
      write: (line) => output.push(line),
    }),
    0,
  );

  // readiness は account scope ごとに分かれる（共有ファイルは作らない）。
  const readinessPath = path.join(
    directory,
    ".git",
    "frontier-harness",
    "readiness.personal.json",
  );
  assert.equal(existsSync(readinessPath), true);
  assert.equal(
    existsSync(path.join(directory, ".git", "frontier-harness", "readiness.json")),
    false,
  );

  // 続く run が同じ state root の readiness を読み、frontend.primary を選べる。
  const taskPath = path.join(directory, "task.json");
  writeFileSync(
    taskPath,
    JSON.stringify({
      goal: "Add a responsive browser interaction",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
  );
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      cwd: directory,
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(JSON.parse(output.pop()).decision.capability, "frontend.primary");
});

test("fh run records a shadow route without starting a provider", (context) => {
  const directory = temporaryDirectory(context);
  const taskPath = path.join(directory, "task.json");
  const statePath = path.join(directory, "state.db");
  writeFileSync(
    taskPath,
    JSON.stringify({
      goal: "Add a responsive browser interaction",
      modality: ["browser"],
      risk: [],
      hasDeterministicOracle: true,
    }),
  );

  const output = [];
  let executorCalls = 0;
  const commonOptions = {
    accountScope: "personal",
    commandPaths: COMMAND_PATHS,
    config,
    verifiedModels: VERIFIED_MODELS,
    statePath,
    // shadow の間は executor が渡されていても呼ばれないこと。
    executor: () => {
      executorCalls += 1;
      return "executed";
    },
    write: (line) => output.push(line),
  };
  assert.equal(runCli(["run", "--task", taskPath, "--json"], commonOptions), 0);
  const run = JSON.parse(output.pop());
  assert.equal(run.executed, false);
  assert.equal(executorCalls, 0);
  assert.match(run.executionReason, /shadow/);
  assert.equal(run.decision.capability, "frontend.primary");

  assert.equal(runCli(["status", "--json"], commonOptions), 0);
  const status = JSON.parse(output.pop());
  assert.equal(status.routes.length, 1);
  assert.equal(status.routes[0].capability, "frontend.primary");
});

test("fh run treats a Codex-only r06 environment as r06 for account safety", (context) => {
  const directory = temporaryDirectory(context);
  const taskPath = path.join(directory, "task.json");
  writeFileSync(
    taskPath,
    JSON.stringify({
      goal: "Implement a browser task",
      modality: ["browser"],
      risk: [],
      hasDeterministicOracle: true,
    }),
  );
  const output = [];
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      environment: {
        CODEX_HOME: "/Users/example/.codex-r06",
        PATH: "",
      },
      commandPaths: COMMAND_PATHS,
      verifiedModels: VERIFIED_MODELS,
      config,
      statePath: path.join(directory, "state.db"),
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(JSON.parse(output.pop()).decision.provider, "codex");
});

test("fh run rejects a flag used as another flag's value", (context) => {
  const directory = temporaryDirectory(context);
  assert.throws(
    () =>
      runCli(["run", "--task", "--json"], {
        config,
        statePath: path.join(directory, "state.db"),
        write: () => {},
      }),
    /--task requires a value/,
  );
});

test("fh onboard writes one approved repository capability manifest", (context) => {
  const directory = temporaryDirectory(context);
  const manifestPath = path.join(directory, "candidate.json");
  const policyPath = path.join(directory, ".harness", "policy.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({
      commands: ["npm run test"],
      domains: ["localhost"],
      capabilities: ["frontend.primary"],
    }),
  );

  const output = [];
  const exitCode = runCli(["onboard", "--manifest", manifestPath, "--approve", "--json"], {
    config,
    policyPath,
    write: (line) => output.push(line),
  });

  assert.equal(exitCode, 0);
  assert.equal(existsSync(policyPath), true);
  const policy = JSON.parse(readFileSync(policyPath, "utf8"));
  assert.match(policy.approvalHash, /^[a-f0-9]{64}$/);
  assert.deepEqual(policy.manifest.commands, ["npm run test"]);
  assert.equal(statSync(policyPath).mode & 0o777, 0o600);
  assert.equal(JSON.parse(output.pop()).policyPath, policyPath);
});

test("fh onboard refuses to write through a symlinked .harness directory", (context) => {
  const directory = temporaryDirectory(context);
  const repository = path.join(directory, "repo");
  const outside = path.join(directory, "outside");
  mkdirSync(repository);
  mkdirSync(outside);
  symlinkSync(outside, path.join(repository, ".harness"));
  const manifestPath = path.join(directory, "candidate.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({
      commands: ["npm run test"],
      domains: ["localhost"],
      capabilities: ["frontend.primary"],
    }),
  );

  assert.throws(
    () =>
      runCli(["onboard", "--manifest", manifestPath, "--approve", "--json"], {
        config,
        policyPath: path.join(repository, ".harness", "policy.json"),
        write: () => {},
      }),
    /symbolic link/,
  );
  assert.equal(existsSync(path.join(outside, "policy.json")), false);
});

test("fh onboard rejects unknown manifest keys and unsafe commands", () => {
  const output = [];
  assert.throws(
    () =>
      runCli(["onboard", "--manifest", "/tmp/unused", "--approve", "--json"], {
        config,
        readManifest: () => ({ commands: ["npm run test"], token: "secret" }),
        write: (line) => output.push(line),
      }),
    /manifest/,
  );
});

test("fh clean applies the configured raw evidence retention window", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const store = createStateStore(statePath);
  store.putEvidence({
    kind: "old_log",
    producer: "fake",
    createdAt: "2026-07-01T00:00:00.000Z",
  });
  store.close();

  const output = [];
  assert.equal(
    runCli(["clean", "--dry-run", "--now", "2026-08-31T00:00:00.000Z", "--json"], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  const dryRun = JSON.parse(output.pop());
  assert.equal(dryRun.expiredEvidence, 1);
  assert.equal(dryRun.prunedEvidence, 0);

  assert.equal(
    runCli(["clean", "--now", "2026-08-31T00:00:00.000Z", "--json"], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(JSON.parse(output.pop()).prunedEvidence, 1);
});

test("fh verify and review record shadow plans without running a shell command", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const output = [];
  let executorCalls = 0;
  const options = {
    config,
    statePath,
    executor: () => {
      executorCalls += 1;
      return "executed";
    },
    write: (line) => output.push(line),
  };

  assert.equal(
    runCli(["verify", "--command", "npm run test", "--json"], options),
    0,
  );
  assert.equal(JSON.parse(output.pop()).executed, false);
  assert.equal(
    runCli(["review", "--task", "task_example", "--json"], options),
    0,
  );
  assert.equal(JSON.parse(output.pop()).executed, false);
  assert.equal(executorCalls, 0);

  const store = createStateStore(statePath);
  assert.deepEqual(
    store
      .listEvidence()
      .map((evidence) => evidence.kind)
      .sort(),
    ["review_plan", "verification_plan"],
  );
  store.close();
});

test("fh resolves the account scope from the launcher suffix convention", () => {
  const cases = [
    [{ CLAUDE_CONFIG_DIR: "/Users/example/.claude" }, "personal"],
    [{ CODEX_HOME: "/Users/example/.codex" }, "personal"],
    [{ CLAUDE_CONFIG_DIR: "/Users/example/.claude-r06" }, "r06"],
    [{ CODEX_HOME: "/Users/example/.codex-r06" }, "r06"],
    // 想定外の値は「不明」に倒す（既存の fail-closed 挙動を固定する）。
    [{ CLAUDE_CONFIG_DIR: "/Users/example/.claude-experimental" }, "unknown"],
    // 2 つの変数が食い違うときも「不明」に倒す（既存の fail-closed 挙動を固定する）。
    [
      {
        CLAUDE_CONFIG_DIR: "/Users/example/.claude",
        CODEX_HOME: "/Users/example/.codex-r06",
      },
      "unknown",
    ],
    // 判定材料がまったく無いときも「不明」に倒す。
    // 以前はここだけ personal に倒れており、他の分岐と非対称だった。
    [{}, "unknown"],
  ];

  for (const [environment, expected] of cases) {
    const output = [];
    assert.equal(
      runCli(["doctor", "--json"], {
        environment: { ...environment, PATH: "" },
        commandPaths: COMMAND_PATHS,
        config,
        verifiedModels: VERIFIED_MODELS,
        write: (line) => output.push(line),
      }),
      0,
    );
    assert.equal(JSON.parse(output.pop()).accountScope, expected);
  }
});

test("fh keeps a personal-only capability unavailable without a resolved account", () => {
  const output = [];
  assert.equal(
    runCli(["doctor", "--json"], {
      environment: { PATH: "" },
      commandPaths: COMMAND_PATHS,
      config,
      verifiedModels: VERIFIED_MODELS,
      write: (line) => output.push(line),
    }),
    0,
  );
  const report = JSON.parse(output.pop());
  assert.equal(report.accountScope, "unknown");
  assert.equal(report.capabilities["frontend.primary"].status, "unavailable");
  // doctor の出力キーは機械可読の契約なので壊さない。
  assert.deepEqual(Object.keys(report).sort(), [
    "accountScope",
    "capabilities",
    "rollout",
  ]);
});

test("readiness verified under one account scope is not reused by another", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const output = [];
  const doctorOptions = {
    config: scopeAgnosticConfig,
    statePath,
    commandPaths: COMMAND_PATHS,
    write: (line) => output.push(line),
  };

  assert.equal(
    runCli(["doctor", "--probe", "--json"], {
      ...doctorOptions,
      accountScope: "personal",
      probeProvider: () => ({
        verified: true,
        models: [CONFIGURED_FRONTEND_MODEL],
      }),
    }),
    0,
  );
  assert.equal(
    JSON.parse(output.pop()).capabilities["frontend.primary"].status,
    "available",
  );

  // 同じ scope なら自分の readiness を再利用する。
  assert.equal(
    runCli(["doctor", "--json"], { ...doctorOptions, accountScope: "personal" }),
    0,
  );
  assert.equal(
    JSON.parse(output.pop()).capabilities["frontend.primary"].status,
    "available",
  );

  // 別 scope は personal の readiness を流用しない。
  assert.equal(
    runCli(["doctor", "--json"], { ...doctorOptions, accountScope: "r06" }),
    0,
  );
  assert.equal(
    JSON.parse(output.pop()).capabilities["frontend.primary"].status,
    "unverified",
  );

  assert.equal(existsSync(path.join(directory, "readiness.personal.json")), true);
  assert.equal(existsSync(path.join(directory, "readiness.r06.json")), false);
  // scope の区別を持たない共有キャッシュを残さない。
  assert.equal(existsSync(path.join(directory, "readiness.json")), false);
});

test("fh refuses to build a readiness path from an unsafe account scope", (context) => {
  const directory = temporaryDirectory(context);
  assert.throws(
    () =>
      runCli(["doctor", "--json"], {
        accountScope: "../../escape",
        config,
        statePath: path.join(directory, "state.db"),
        commandPaths: COMMAND_PATHS,
        write: () => {},
      }),
    /account scope/,
  );
});

test("fh refuses to resolve the config path from the working directory", () => {
  // HOME が無いと path.join("", ...) が cwd 相対になり、untrusted repository 同梱の
  // config が escalation 方針を差し替えうる。
  assert.throws(
    () => runCli(["doctor", "--json"], { environment: { PATH: "" }, write: () => {} }),
    /HOME/,
  );
  assert.throws(
    () =>
      runCli(["doctor", "--json"], {
        environment: { HOME: "relative/home", PATH: "" },
        write: () => {},
      }),
    /HOME/,
  );
  assert.throws(
    () =>
      runCli(["doctor", "--json"], {
        environment: {
          HOME: "/Users/example",
          FH_CONFIG_PATH: ".harness/config.json",
          PATH: "",
        },
        write: () => {},
      }),
    /FH_CONFIG_PATH/,
  );
});

test("fh loads the config named by an absolute FH_CONFIG_PATH", (context) => {
  const directory = temporaryDirectory(context);
  const configPath = path.join(directory, "config.json");
  writeFileSync(configPath, JSON.stringify(baseConfigInput));
  const output = [];
  assert.equal(
    runCli(["doctor", "--json"], {
      environment: { HOME: "/Users/example", FH_CONFIG_PATH: configPath, PATH: "" },
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      verifiedModels: VERIFIED_MODELS,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(
    JSON.parse(output.pop()).capabilities["frontend.primary"].status,
    "available",
  );
});

test("fh refuses a git common directory the working tree does not own", (context) => {
  const directory = temporaryDirectory(context);
  const untrusted = initRepository(path.join(directory, "untrusted"));
  const other = initRepository(path.join(directory, "other"));
  // untrusted repository が同梱した `.git` ファイルで、別リポジトリの metadata を指す。
  const nested = path.join(untrusted, "sub");
  mkdirSync(nested);
  writeFileSync(path.join(nested, ".git"), `gitdir: ${path.join(other, ".git")}\n`);

  assert.throws(
    () =>
      runCli(["run", "--task", writeTask(directory), "--json"], {
        cwd: nested,
        accountScope: "personal",
        commandPaths: COMMAND_PATHS,
        config,
        write: () => {},
      }),
    /not owned by the current working tree/,
  );
  // 誘導先に state ディレクトリを作らせない。
  assert.equal(existsSync(path.join(other, ".git", "frontier-harness")), false);
});

test("fh resolves the state root through a linked worktree", (context) => {
  const directory = temporaryDirectory(context);
  const main = initRepository(path.join(directory, "main"));
  const linked = path.join(directory, "linked");
  git(main, ["worktree", "add", "--quiet", linked, "-b", "linked-branch"]);

  const output = [];
  assert.equal(
    runCli(["run", "--task", writeTask(directory), "--json"], {
      cwd: linked,
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      write: (line) => output.push(line),
    }),
    0,
  );
  // linked worktree では common dir が作業ツリーの外を指すのが正常。
  assert.equal(
    existsSync(path.join(main, ".git", "frontier-harness", "state.db")),
    true,
  );
});

test("fh resolves the state root inside a submodule working tree", (context) => {
  const directory = temporaryDirectory(context);
  const parent = initRepository(path.join(directory, "parent"));
  const child = initRepository(path.join(directory, "child"));
  // git 2.38 以降はローカル clone に file protocol の明示許可が要る。
  git(parent, [
    "-c",
    "protocol.file.allow=always",
    "submodule",
    "add",
    "--quiet",
    child,
    "sub",
  ]);

  const output = [];
  assert.equal(
    runCli(["run", "--task", writeTask(directory), "--json"], {
      cwd: path.join(parent, "sub"),
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(
    existsSync(
      path.join(parent, ".git", "modules", "sub", "frontier-harness", "state.db"),
    ),
    true,
  );
});

test("fh doctor still reports outside a git working tree", (context) => {
  const directory = temporaryDirectory(context);
  const output = [];
  assert.equal(
    runCli(["doctor", "--json"], {
      cwd: directory,
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      write: (line) => output.push(line),
    }),
    0,
  );
  // state root が無いので readiness は永続化されず unverified に留まる。
  assert.equal(
    JSON.parse(output.pop()).capabilities["frontend.primary"].status,
    "unverified",
  );
});

// 実 git は相対パスも symlink も返さない（`--path-format=absolute` を付け、symlink は
// realpath に解決される）。これらの分岐は runGit を差し替えて直接検証する。
function stubGit({ commonDirectory, gitDirectory, topLevel, superproject = "" }) {
  return (cwd, args) => {
    if (args.includes("--show-superproject-working-tree")) {
      return `${superproject}\n`;
    }
    if (superproject && cwd === superproject) {
      return `${path.join(superproject, ".git")}\n`;
    }
    return `${commonDirectory}\n${gitDirectory}\n${topLevel}\n`;
  };
}

test("state root resolution rejects a relative git common directory", (context) => {
  const directory = temporaryDirectory(context);
  assert.throws(
    () =>
      resolveGitCommonDirectory(
        directory,
        stubGit({
          commonDirectory: ".git",
          gitDirectory: ".git",
          topLevel: directory,
        }),
      ),
    /must be an absolute path/,
  );
});

test("state root resolution rejects a symlinked git common directory", (context) => {
  const directory = temporaryDirectory(context);
  const real = path.join(directory, "real.git");
  mkdirSync(real);
  writeFileSync(path.join(real, "HEAD"), "ref: refs/heads/main\n");
  const link = path.join(directory, ".git");
  symlinkSync(real, link);
  assert.throws(
    () =>
      resolveGitCommonDirectory(
        directory,
        stubGit({
          commonDirectory: link,
          gitDirectory: link,
          topLevel: directory,
        }),
      ),
    /must not be a symbolic link/,
  );
});

test("state root resolution rejects a directory that is not git metadata", (context) => {
  const directory = temporaryDirectory(context);
  const notGit = path.join(directory, ".git");
  mkdirSync(notGit);
  assert.throws(
    () =>
      resolveGitCommonDirectory(
        directory,
        stubGit({
          commonDirectory: notGit,
          gitDirectory: notGit,
          topLevel: directory,
        }),
      ),
    /not a git metadata directory/,
  );
});

test("state root resolution reports a missing git working tree distinctly", (context) => {
  const directory = temporaryDirectory(context);
  assert.throws(
    () =>
      resolveGitCommonDirectory(directory, () => {
        throw new Error("fatal: this operation must be run in a work tree");
      }),
    /requires a git working tree/,
  );
});
