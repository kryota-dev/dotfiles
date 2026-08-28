import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
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
  SCHEMA_VERSION,
  migrate,
} from "../home/dot_local/lib/frontier-harness/migrations.mjs";
import {
  TELEMETRY_RISK_MAX_ENTRIES,
  TELEMETRY_TOKEN_MAX_LENGTH,
} from "../home/dot_local/lib/frontier-harness/record-validation.mjs";
import {
  evidenceContentHash,
  normalizeAdapterRun,
  normalizeApproval,
  normalizeReviewFinding,
  normalizeTelemetryEvent,
  normalizeVerificationResult,
} from "../home/dot_local/lib/frontier-harness/records.mjs";
import {
  ensureDirectory,
  ensureStateFile,
  ensureStateFileMode,
  writeJsonAtomic,
} from "../home/dot_local/lib/frontier-harness/paths.mjs";
import {
  DEFAULT_AGGREGATE_TELEMETRY_RETENTION_DAYS,
  DEFAULT_RAW_ARTIFACT_RETENTION_DAYS,
  retentionCutoffs,
} from "../home/dot_local/lib/frontier-harness/retention.mjs";
import {
  loadVerifiedModels,
  probeAntigravity,
} from "../home/dot_local/lib/frontier-harness/readiness.mjs";
import { runWithRolloutGuard } from "../home/dot_local/lib/frontier-harness/rollout.mjs";
import { chooseRoute } from "../home/dot_local/lib/frontier-harness/router.mjs";
import {
  GitWorktreeUnavailableError,
  resolveGitCommonDirectory,
} from "../home/dot_local/lib/frontier-harness/state-root.mjs";
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

// retention は raw / 集約の 2 クラスを取るようになった。片方だけを対象にしたい
// テストでは、もう一方に「誰も期限切れにならない」値を渡す。
const NEVER_EXPIRES_CUTOFF = "1970-01-01T00:00:00.000Z";
const NO_EXPIRED_RAW_RECORDS = {
  evidence: 0,
  adapterRuns: 0,
  verificationResults: 0,
  reviewFindings: 0,
};

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
  assert.equal(store.schemaVersion(), SCHEMA_VERSION);
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

  const cutoffs = {
    rawCutoff: "2026-08-01T00:00:00.000Z",
    telemetryCutoff: NEVER_EXPIRES_CUTOFF,
  };
  assert.equal(store.countExpired(cutoffs).raw.evidence, 1);
  assert.deepEqual(store.pruneExpired(cutoffs), {
    raw: { ...NO_EXPIRED_RAW_RECORDS, evidence: 1 },
    telemetry: 0,
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
  const pruned = reopened.pruneExpired({
    rawCutoff: "2026-08-01T00:00:00.000Z",
    telemetryCutoff: NEVER_EXPIRES_CUTOFF,
    artifactRoot,
  });
  assert.equal(pruned.raw.evidence, 1);
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
  const pruned = store.pruneExpired({
    rawCutoff: "2026-08-01T00:00:00.000Z",
    telemetryCutoff: NEVER_EXPIRES_CUTOFF,
    artifactRoot,
  });
  store.close();

  assert.equal(existsSync(protectedFile), true);
  assert.equal(pruned.skippedArtifacts.length, 1);
  assert.match(pruned.skippedArtifacts[0].reason, /symbolic link/);
  // 1 件の不正 path で retention 全体を止めない。
  assert.equal(pruned.raw.evidence, 1);
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
        // 実 git は working tree が無いとき status 128 で終了する。
        const error = new Error("fatal: this operation must be run in a work tree");
        error.status = 128;
        throw error;
      }),
    /requires a git working tree/,
  );
});

test("state root resolution propagates a git that could not be executed", (context) => {
  const directory = temporaryDirectory(context);
  // spawn 自体の失敗（git 不在・権限）は「working tree が無い」ではないため、
  // doctor に握り潰させず原因を保ったまま伝播させる。
  assert.throws(
    () =>
      resolveGitCommonDirectory(directory, () => {
        const error = new Error("spawn git ENOENT");
        error.code = "ENOENT";
        throw error;
      }),
    (error) =>
      error instanceof GitWorktreeUnavailableError === false &&
      error.code === "ENOENT",
  );
});

test("state root resolution rejects a worktrees path that only shares a prefix", (context) => {
  const directory = temporaryDirectory(context);
  const commonDirectory = path.join(directory, "common.git");
  mkdirSync(commonDirectory);
  writeFileSync(path.join(commonDirectory, "HEAD"), "ref: refs/heads/main\n");
  const topLevel = path.join(directory, "tree");
  mkdirSync(topLevel);
  const gitDirectory = path.join(commonDirectory, "worktrees-evil", "child");
  mkdirSync(gitDirectory, { recursive: true });
  // forward link は成立させ、`worktrees` の prefix 判定だけを切り出して検証する。
  writeFileSync(path.join(topLevel, ".git"), `gitdir: ${gitDirectory}\n`);
  assert.throws(
    () =>
      resolveGitCommonDirectory(
        topLevel,
        stubGit({ commonDirectory, gitDirectory, topLevel }),
      ),
    /not owned by the current working tree/,
  );
});

test("fh refuses a state root reached through an injected GIT_DIR", (context) => {
  const directory = temporaryDirectory(context);
  const victim = initRepository(path.join(directory, "victim"));
  const victimWorktree = path.join(directory, "victim-wt");
  git(victim, ["worktree", "add", "--quiet", victimWorktree, "-b", "victim-branch"]);
  const untrusted = path.join(directory, "untrusted");
  mkdirSync(untrusted);

  // victim の「正当な」worktree admin dir を指すため、パスは本当に
  // <commonDir>/worktrees/ 配下にある。攻撃者が握るのは topLevel だけ。
  // node --test はファイル内のテストを直列実行するため、process.env の一時変更は安全。
  const previous = process.env.GIT_DIR;
  process.env.GIT_DIR = path.join(victim, ".git", "worktrees", "victim-wt");
  context.after(() => {
    if (previous === undefined) delete process.env.GIT_DIR;
    else process.env.GIT_DIR = previous;
  });

  assert.throws(
    () =>
      runCli(["run", "--task", writeTask(directory), "--json"], {
        cwd: untrusted,
        accountScope: "personal",
        commandPaths: COMMAND_PATHS,
        config,
        write: () => {},
      }),
    /not owned by the current working tree/,
  );
  assert.equal(existsSync(path.join(victim, ".git", "frontier-harness")), false);
});

test("fh doctor propagates an unowned state root instead of swallowing it", (context) => {
  const directory = temporaryDirectory(context);
  const untrusted = initRepository(path.join(directory, "untrusted"));
  const other = initRepository(path.join(directory, "other"));
  const nested = path.join(untrusted, "sub");
  mkdirSync(nested);
  writeFileSync(path.join(nested, ".git"), `gitdir: ${path.join(other, ".git")}\n`);

  // 要件 5-5: 信頼できない state root の検出は doctor 経路でも握り潰さない。
  for (const flags of [
    ["doctor", "--json"],
    ["doctor", "--probe", "--json"],
  ]) {
    assert.throws(
      () =>
        runCli(flags, {
          cwd: nested,
          accountScope: "personal",
          commandPaths: COMMAND_PATHS,
          config,
          probeProvider: () => ({
            verified: true,
            models: [CONFIGURED_FRONTEND_MODEL],
          }),
          write: () => {},
        }),
      /not owned by the current working tree/,
    );
  }
  assert.equal(existsSync(path.join(other, ".git", "frontier-harness")), false);
});

test("a run under another account scope does not reuse verified readiness", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const output = [];
  assert.equal(
    runCli(["doctor", "--probe", "--json"], {
      accountScope: "personal",
      config: scopeAgnosticConfig,
      statePath,
      commandPaths: COMMAND_PATHS,
      probeProvider: () => ({
        verified: true,
        models: [CONFIGURED_FRONTEND_MODEL],
      }),
      write: (line) => output.push(line),
    }),
    0,
  );
  output.pop();

  const taskPath = writeTask(directory);
  // 同一 scope の run は自分の readiness を再利用する。
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      accountScope: "personal",
      config: scopeAgnosticConfig,
      statePath,
      commandPaths: COMMAND_PATHS,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(JSON.parse(output.pop()).decision.capability, "frontend.primary");

  // 別 scope の run は personal の readiness を流用しない（要件 2-2 の run 経路）。
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      accountScope: "r06",
      config: scopeAgnosticConfig,
      statePath,
      commandPaths: COMMAND_PATHS,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(JSON.parse(output.pop()).decision.capability, "executor.default");
});

// ---------------------------------------------------------------------------
// schema v2: migration（kryota-dev/dotfiles#492）
// ---------------------------------------------------------------------------

// PR #478 時点（schema v1）の DB を、当時の DDL literal で作る。
// 現行コードの DDL を流用すると「移行前の姿」が実装へ追随してしまい、
// migration を検証したことにならない。
const LEGACY_V1_DDL = `
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    task_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE route_decisions (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    kind TEXT NOT NULL,
    capability TEXT,
    provider TEXT,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE evidence (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    producer TEXT NOT NULL,
    created_at TEXT NOT NULL,
    command TEXT,
    exit_code INTEGER,
    artifact_path TEXT,
    claims_supported TEXT NOT NULL
  ) STRICT;

  CREATE INDEX evidence_created_at_id_idx ON evidence (created_at, id);
  CREATE INDEX route_decisions_created_at_id_idx ON route_decisions (created_at, id);
`;

const LEGACY_EVIDENCE_CONTENT = {
  kind: "test_pass",
  producer: "codex:gpt-5.6-terra",
  command: "make test",
  exitCode: 0,
  artifactPath: null,
  claimsSupported: ["the suite passed"],
};

// v1 の DB を作り、3 テーブルそれぞれに 1 行ずつ入れる。
function seedLegacyV1Database(statePath) {
  const raw = new DatabaseSync(statePath);
  raw.exec(LEGACY_V1_DDL);
  raw
    .prepare("INSERT INTO tasks VALUES (?, ?, ?, ?)")
    .run("task_legacy", "legacy goal", '{"goal":"legacy goal"}', "2026-01-01T00:00:00.000Z");
  raw
    .prepare("INSERT INTO route_decisions VALUES (?, ?, ?, ?, ?, ?, ?)")
    .run(
      "route_legacy",
      "task_legacy",
      "single-worker",
      "executor.default",
      "codex",
      "default executor is available",
      "2026-01-01T00:00:00.000Z",
    );
  raw
    .prepare("INSERT INTO evidence VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    .run(
      "ev_legacy",
      LEGACY_EVIDENCE_CONTENT.kind,
      LEGACY_EVIDENCE_CONTENT.producer,
      "2026-01-01T00:00:00.000Z",
      LEGACY_EVIDENCE_CONTENT.command,
      LEGACY_EVIDENCE_CONTENT.exitCode,
      LEGACY_EVIDENCE_CONTENT.artifactPath,
      JSON.stringify(LEGACY_EVIDENCE_CONTENT.claimsSupported),
    );
  raw.exec("PRAGMA user_version = 1");
  raw.close();
}

function columnNames(database, table) {
  return database
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .map((column) => column.name);
}

function tableExists(database, table) {
  return (
    Number(
      database
        .prepare(
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = ?",
        )
        .get(table).n,
    ) === 1
  );
}

test("a v1 state database migrates to v2 without losing any recorded row", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);

  const store = createStateStore(statePath);
  assert.equal(store.schemaVersion(), SCHEMA_VERSION);

  // 既存 evidence は値を変えずに残り、新しい列だけが足されている。
  const evidence = store.listEvidence();
  assert.equal(evidence.length, 1);
  assert.deepEqual(
    {
      id: evidence[0].id,
      kind: evidence[0].kind,
      producer: evidence[0].producer,
      createdAt: evidence[0].createdAt,
      command: evidence[0].command,
      exitCode: evidence[0].exitCode,
      artifactPath: evidence[0].artifactPath,
      claimsSupported: evidence[0].claimsSupported,
    },
    {
      id: "ev_legacy",
      kind: LEGACY_EVIDENCE_CONTENT.kind,
      producer: LEGACY_EVIDENCE_CONTENT.producer,
      createdAt: "2026-01-01T00:00:00.000Z",
      command: LEGACY_EVIDENCE_CONTENT.command,
      exitCode: LEGACY_EVIDENCE_CONTENT.exitCode,
      artifactPath: LEGACY_EVIDENCE_CONTENT.artifactPath,
      claimsSupported: LEGACY_EVIDENCE_CONTENT.claimsSupported,
    },
  );
  // backfill された hash は、新規行と同じ規則で導出されている。
  assert.equal(
    evidence[0].contentHash,
    evidenceContentHash(LEGACY_EVIDENCE_CONTENT),
  );
  // 値を捏造せず、参照は NULL のまま。
  assert.equal(evidence[0].taskId, null);
  assert.equal(evidence[0].routeId, null);

  const routes = store.listRoutes();
  assert.equal(routes.length, 1);
  assert.equal(routes[0].id, "route_legacy");
  assert.equal(routes[0].reason, "default executor is available");
  assert.equal(routes[0].model, null);
  assert.equal(routes[0].effort, null);
  assert.equal(routes[0].reviewerCapability, null);

  // 新しいテーブルは作られ、空である。
  assert.deepEqual(store.listAdapterRuns(), []);
  assert.deepEqual(store.listVerificationResults(), []);
  assert.deepEqual(store.listReviewFindings(), []);
  assert.deepEqual(store.listApprovals(), []);
  assert.deepEqual(store.listTelemetryEvents(), []);
  store.close();

  const raw = new DatabaseSync(statePath);
  // node:sqlite の行は null プロトタイプで返るため、素のオブジェクトへ写してから比べる。
  assert.deepEqual(
    raw.prepare("SELECT * FROM tasks").all().map((row) => ({ ...row })),
    [
      {
        id: "task_legacy",
        goal: "legacy goal",
        task_json: '{"goal":"legacy goal"}',
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ],
  );
  raw.close();
});

test("a failed migration step leaves the v1 database exactly as it was", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);

  // v2 の後半の ALTER と衝突する列を先に作る。route_decisions への 3 列は成功し、
  // evidence への content_hash 追加で失敗するため、「途中まで進んだ migration が
  // 巻き戻るか」を検証できる。
  const seeded = new DatabaseSync(statePath);
  seeded.exec("ALTER TABLE evidence ADD COLUMN content_hash TEXT");
  seeded.exec("PRAGMA user_version = 1");
  seeded.close();

  assert.throws(() => createStateStore(statePath), /duplicate column name/);

  const raw = new DatabaseSync(statePath);
  assert.equal(Number(raw.prepare("PRAGMA user_version").get().user_version), 1);
  // 先に成功していた route_decisions への列追加も巻き戻っている。
  const routeColumns = columnNames(raw, "route_decisions");
  for (const column of ["model", "effort", "reviewer_capability"]) {
    assert.ok(
      !routeColumns.includes(column),
      `${column} must not survive a rolled back migration`,
    );
  }
  assert.equal(tableExists(raw, "adapter_runs"), false);
  assert.equal(tableExists(raw, "telemetry_events"), false);
  // 既存データは失われていない。
  assert.equal(Number(raw.prepare("SELECT COUNT(*) AS n FROM evidence").get().n), 1);
  assert.equal(Number(raw.prepare("SELECT COUNT(*) AS n FROM tasks").get().n), 1);
  raw.close();
});

test("re-opening a migrated database does not re-run migration steps", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);

  const first = createStateStore(statePath);
  first.close();
  // 冪等でなければ ALTER TABLE が duplicate column で落ちる。
  const second = createStateStore(statePath);
  assert.equal(second.schemaVersion(), SCHEMA_VERSION);
  assert.equal(second.listEvidence().length, 1);
  second.close();
});

// ---------------------------------------------------------------------------
// route decision の完全な永続化
// ---------------------------------------------------------------------------

test("state store records the model and effort a route selected", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ goal: "record a route" });
  store.recordRoute(task.id, {
    kind: "writer-plus-reviewer",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reviewerCapability: "semantic.judge",
    reason: "no deterministic oracle requires independent review",
  });

  const [route] = store.listRoutes();
  assert.equal(route.model, "gpt-5.6-terra");
  assert.equal(route.effort, "xhigh");
  assert.equal(route.reviewerCapability, "semantic.judge");
  store.close();
});

test("an escalation route stores no model, effort, or reviewer", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ goal: "escalate" });
  store.recordRoute(task.id, {
    kind: "escalation",
    capability: null,
    provider: null,
    reason: "risk migration requires user escalation",
  });

  const [route] = store.listRoutes();
  assert.equal(route.model, null);
  assert.equal(route.effort, null);
  assert.equal(route.reviewerCapability, null);
  store.close();
});

test("fh status reports the model and effort the route selected", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const taskPath = path.join(directory, "task.json");
  writeFileSync(taskPath, JSON.stringify({ goal: "ship", hasDeterministicOracle: true }));

  const output = [];
  const options = {
    config,
    statePath,
    commandPaths: COMMAND_PATHS,
    accountScope: "personal",
    verifiedModels: {},
    write: (line) => output.push(line),
  };
  assert.equal(runCli(["run", "--task", taskPath, "--json"], options), 0);
  output.pop();
  assert.equal(runCli(["status", "--json"], options), 0);

  const [route] = JSON.parse(output.pop()).routes;
  assert.equal(route.provider, "codex");
  assert.equal(route.model, "gpt-5.6-terra");
  assert.equal(route.effort, "xhigh");
});

// ---------------------------------------------------------------------------
// evidence の content hash と参照
// ---------------------------------------------------------------------------

test("evidence content hash is derived by the store, not by the caller", () => {
  const store = createStateStore(":memory:");
  const forged = "f".repeat(64);
  const evidence = store.putEvidence({
    kind: "test_failure",
    producer: "codex:gpt-5.6-terra",
    command: "make test",
    exitCode: 1,
    claimsSupported: ["the suite failed"],
    contentHash: forged,
  });

  const expected = evidenceContentHash({
    kind: "test_failure",
    producer: "codex:gpt-5.6-terra",
    command: "make test",
    exitCode: 1,
    artifactPath: null,
    claimsSupported: ["the suite failed"],
  });
  assert.equal(evidence.contentHash, expected);
  assert.notEqual(evidence.contentHash, forged);
  assert.equal(store.listEvidence()[0].contentHash, expected);
  store.close();
});

test("evidence links back to the task and route it belongs to", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ goal: "link evidence" });
  const route = store.recordRoute(task.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: "default executor is available",
  });
  store.putEvidence({
    kind: "verification_plan",
    producer: "frontier-harness",
    taskId: task.id,
    routeId: route.id,
  });

  const [evidence] = store.listEvidence();
  assert.equal(evidence.taskId, task.id);
  assert.equal(evidence.routeId, route.id);
  store.close();
});

test("evidence rejects an unknown field instead of silently dropping it", () => {
  const store = createStateStore(":memory:");
  assert.throws(
    () =>
      store.putEvidence({
        kind: "test_pass",
        producer: "fake",
        transcript: "the writer's hidden reasoning",
      }),
    /unsupported key: transcript/,
  );
  store.close();
});

// ---------------------------------------------------------------------------
// 境界検証（新規 5 エンティティ）
// ---------------------------------------------------------------------------

const APPROVAL_INPUT = {
  kind: "repository_manifest",
  subjectHash: "a".repeat(64),
  scope: "kryota-dev/dotfiles",
  grantedBy: "user",
  grantedAt: "2026-08-01T00:00:00.000Z",
};

const ADAPTER_RUN_INPUT = {
  taskId: "task_1",
  routeId: "route_1",
  capability: "executor.default",
  provider: "codex",
  model: "gpt-5.6-terra",
  effort: "xhigh",
  status: "succeeded",
  startedAt: "2026-08-01T00:00:00.000Z",
  finishedAt: "2026-08-01T00:05:00.000Z",
  exitCode: 0,
};

test("adapter run normalization keeps launch-mechanism fields out of the schema", () => {
  // #526 の結論で起動方式が変わっても migration をやり直さずに済むよう、
  // argv や sandbox 設定のような起動詳細は schema に入れない。
  for (const key of ["argv", "sandbox", "conversationId", "cwd", "env"]) {
    assert.throws(
      () => normalizeAdapterRun({ ...ADAPTER_RUN_INPUT, [key]: "anything" }),
      new RegExp(`unsupported key: ${key}`),
    );
  }
});

test("adapter run normalization keeps status and timestamps consistent", () => {
  assert.throws(
    () => normalizeAdapterRun({ ...ADAPTER_RUN_INPUT, finishedAt: undefined }),
    /requires finishedAt/,
  );
  assert.throws(
    () =>
      normalizeAdapterRun({
        ...ADAPTER_RUN_INPUT,
        status: "running",
        finishedAt: "2026-08-01T00:05:00.000Z",
      }),
    /must not carry finishedAt/,
  );
  assert.throws(
    () =>
      normalizeAdapterRun({
        ...ADAPTER_RUN_INPUT,
        finishedAt: "2026-07-31T00:00:00.000Z",
      }),
    /must not precede startedAt/,
  );
  assert.throws(
    () => normalizeAdapterRun({ ...ADAPTER_RUN_INPUT, status: "done" }),
    /must be one of/,
  );
});

test("record normalization rewrites timestamps into a comparable canonical form", () => {
  // retention は created_at の辞書式比較で判定するため、表記ゆれを残すと
  // 「期限切れなのに消えない」行が生まれる。
  const run = normalizeAdapterRun({
    ...ADAPTER_RUN_INPUT,
    startedAt: "2026-08-01T09:00:00+09:00",
    finishedAt: "2026-08-01T09:05:00+09:00",
  });
  assert.equal(run.startedAt, "2026-08-01T00:00:00.000Z");
  assert.equal(run.finishedAt, "2026-08-01T00:05:00.000Z");
  assert.throws(
    () => normalizeAdapterRun({ ...ADAPTER_RUN_INPUT, startedAt: "yesterday" }),
    /ISO 8601 timestamp/,
  );
});

test("verification and review findings validate their controlled vocabularies", () => {
  assert.throws(
    () =>
      normalizeVerificationResult({
        taskId: "task_1",
        checkKind: "vibes",
        status: "passed",
      }),
    /checkKind must be one of/,
  );
  assert.throws(
    () =>
      normalizeReviewFinding({
        taskId: "task_1",
        reviewerCapability: "semantic.judge",
        severity: "blocker",
        uncertainty: "low",
        summary: "something",
      }),
    /severity must be one of/,
  );
  // finding は evidence 参照・severity・uncertainty・discriminating experiment を保つ。
  const finding = normalizeReviewFinding({
    taskId: "task_1",
    reviewerCapability: "semantic.judge",
    severity: "must",
    uncertainty: "high",
    summary: "the retention window is never applied",
    discriminatingExperiment: "run fh clean with --now past the cutoff",
    evidenceId: "ev_1",
  });
  assert.equal(finding.uncertainty, "high");
  assert.equal(finding.evidenceId, "ev_1");
  assert.match(finding.discriminatingExperiment, /fh clean/);
});

test("an approval can only be granted by the user", () => {
  const base = { ...APPROVAL_INPUT };
  assert.equal(normalizeApproval(base).grantedBy, "user");
  // model が自分自身を承認者として記録できると、安全境界が state 側から無効化される。
  assert.throws(
    () => normalizeApproval({ ...base, grantedBy: "codex" }),
    /grantedBy must be one of/,
  );
  assert.throws(
    () => normalizeApproval({ ...base, subjectHash: "not-a-digest" }),
    /SHA-256 hex digest/,
  );
  assert.throws(
    () =>
      normalizeApproval({ ...base, expiresAt: "2026-07-01T00:00:00.000Z" }),
    /must not precede grantedAt/,
  );
});

const TELEMETRY_INPUT = {
  category: "implementation",
  provider: "codex",
  model: "gpt-5.6-terra",
  effort: "xhigh",
};

test("aggregate telemetry cannot carry free-form content", () => {
  // 集約テレメトリは raw より長く保持されるため、内容を持たないことが前提になる。
  for (const key of ["summary", "diff", "transcript", "prompt"]) {
    assert.throws(
      () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, [key]: "some prose" }),
      new RegExp(`unsupported key: ${key}`),
    );
  }
  // enum / token の外にある値も入らない。
  assert.throws(
    () =>
      normalizeTelemetryEvent({
        ...TELEMETRY_INPUT,
        category: "Implementation of the auth flow",
      }),
    /category must match/,
  );
  assert.throws(
    () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, outcome: "shipped" }),
    /outcome must be one of/,
  );
  assert.throws(
    () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, reviewPrecision: 1.5 }),
    /between 0 and 1/,
  );
});

test("telemetry events round-trip their aggregate measurements", () => {
  const store = createStateStore(":memory:");
  store.recordTelemetryEvent({
    ...TELEMETRY_INPUT,
    risk: ["migration", "data-migration"],
    wallClockMs: 1234,
    inputTokens: 10,
    outputTokens: 20,
    toolCalls: 5,
    toolFailures: 1,
    verificationResult: "passed",
    reviewPrecision: 0.75,
    humanCorrections: 2,
    rollback: true,
    outcome: "merged",
  });

  const [event] = store.listTelemetryEvents();
  assert.deepEqual(event.risk, ["migration", "data-migration"]);
  assert.equal(event.reviewPrecision, 0.75);
  // STRICT には BOOLEAN が無いので 0/1 で持つが、境界では boolean に戻る。
  assert.equal(event.rollback, true);
  assert.equal(event.outcome, "merged");
  store.close();
});

// ---------------------------------------------------------------------------
// 保持期間（raw 30 日 / 集約テレメトリ 180 日 / approvals は対象外）
// ---------------------------------------------------------------------------

// 保持期間のフィクスチャ。--now = 2026-08-31 のとき raw cutoff は 2026-08-01、
// 集約 cutoff は 2026-03-04 になる。判定は created_at < cutoff なので、各 prunable table に
// 「期限切れ・cutoff と同時刻・期限内」の 3 行を置き、境界（< と <= の取り違え）も観測する。
const RAW_CUTOFF = "2026-08-01T00:00:00.000Z";
const TELEMETRY_CUTOFF = "2026-03-04T00:00:00.000Z";
const EXPIRED_AT = "2026-07-01T00:00:00.000Z";
const IN_WINDOW_AT = "2026-08-20T00:00:00.000Z";

function seedRetentionFixture(statePath) {
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "retention" });
  const route = store.recordRoute(task.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: "default executor is available",
  });

  // 期限切れ / cutoff と同時刻 / 期限内 を、raw クラスの 4 table すべてに 1 行ずつ置く。
  for (const [label, at] of [
    ["expired", EXPIRED_AT],
    ["at_cutoff", RAW_CUTOFF],
    ["in_window", IN_WINDOW_AT],
  ]) {
    store.putEvidence({ kind: `evidence_${label}`, producer: "fake", createdAt: at });
    store.recordAdapterRun({
      ...ADAPTER_RUN_INPUT,
      taskId: task.id,
      routeId: route.id,
      startedAt: at,
      finishedAt: at,
      createdAt: at,
    });
    store.recordVerificationResult({
      taskId: task.id,
      checkKind: "test",
      status: "passed",
      createdAt: at,
    });
    store.recordReviewFinding({
      taskId: task.id,
      reviewerCapability: "semantic.judge",
      severity: "should",
      uncertainty: "medium",
      summary: `finding ${label}`,
      createdAt: at,
    });
  }

  // 集約テレメトリ: 180 日より古い / cutoff と同時刻 / raw の窓より古いが 180 日以内。
  for (const at of [
    "2026-01-01T00:00:00.000Z",
    TELEMETRY_CUTOFF,
    EXPIRED_AT,
  ]) {
    store.recordTelemetryEvent({ ...TELEMETRY_INPUT, createdAt: at });
  }

  // 承認は raw より古くても消さない（監査証跡）。
  store.recordApproval({
    ...APPROVAL_INPUT,
    subjectHash: "b".repeat(64),
    grantedAt: "2026-01-01T00:00:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  store.close();
}

test("fh clean applies the raw and aggregate telemetry windows separately", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedRetentionFixture(statePath);

  const output = [];
  assert.equal(
    runCli(["clean", "--now", "2026-08-31T00:00:00.000Z", "--json"], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  const result = JSON.parse(output.pop());

  assert.equal(result.cutoff, RAW_CUTOFF);
  assert.equal(result.telemetryCutoff, TELEMETRY_CUTOFF);
  // 各クラス 1 行ずつ（期限切れのみ）が消える。cutoff と同時刻の行は残る。
  assert.deepEqual(result.prunedRaw, {
    evidence: 1,
    adapterRuns: 1,
    verificationResults: 1,
    reviewFindings: 1,
  });
  assert.equal(result.prunedTelemetry, 1);
  // 既存の消費側が読んでいるキーは意味を変えずに残る（後方互換）。
  assert.equal(result.expiredEvidence, 1);
  assert.equal(result.prunedEvidence, 1);
  assert.equal(result.dryRun, false);
  assert.deepEqual(result.skippedArtifacts, []);

  const store = createStateStore(statePath);
  // cutoff と同時刻の行が残ることで、< が <= に変わる退行を検出できる。
  assert.deepEqual(
    store.listEvidence().map((evidence) => evidence.createdAt),
    [RAW_CUTOFF, IN_WINDOW_AT],
  );
  assert.deepEqual(
    store.listAdapterRuns().map((run) => run.createdAt),
    [RAW_CUTOFF, IN_WINDOW_AT],
  );
  assert.deepEqual(
    store.listVerificationResults().map((result_) => result_.createdAt),
    [RAW_CUTOFF, IN_WINDOW_AT],
  );
  assert.deepEqual(
    store.listReviewFindings().map((finding) => finding.createdAt),
    [RAW_CUTOFF, IN_WINDOW_AT],
  );
  assert.deepEqual(
    store.listTelemetryEvents().map((event) => event.createdAt),
    [TELEMETRY_CUTOFF, EXPIRED_AT],
  );
  // 承認は保持期間のどちらのクラスにも属さないので残る。
  assert.equal(store.listApprovals().length, 1);
  store.close();
});

test("fh clean --dry-run reports every class without deleting anything", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedRetentionFixture(statePath);

  const output = [];
  assert.equal(
    runCli(
      ["clean", "--dry-run", "--now", "2026-08-31T00:00:00.000Z", "--json"],
      { config, statePath, write: (line) => output.push(line) },
    ),
    0,
  );
  const result = JSON.parse(output.pop());

  assert.deepEqual(result.expiredRaw, {
    evidence: 1,
    adapterRuns: 1,
    verificationResults: 1,
    reviewFindings: 1,
  });
  assert.equal(result.expiredTelemetry, 1);
  assert.deepEqual(result.prunedRaw, NO_EXPIRED_RAW_RECORDS);
  assert.equal(result.prunedTelemetry, 0);
  // 後方互換キーも dry-run で意味どおりの値を返す。
  assert.equal(result.dryRun, true);
  assert.equal(result.expiredEvidence, 1);
  assert.equal(result.prunedEvidence, 0);
  assert.deepEqual(result.skippedArtifacts, []);

  const store = createStateStore(statePath);
  assert.equal(store.listEvidence().length, 3);
  assert.equal(store.listAdapterRuns().length, 3);
  assert.equal(store.listVerificationResults().length, 3);
  assert.equal(store.listReviewFindings().length, 3);
  assert.equal(store.listTelemetryEvents().length, 3);
  assert.equal(store.listApprovals().length, 1);
  store.close();
});

test("pruning an expired parent clears the reference instead of failing", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ goal: "cascade" });
  const route = store.recordRoute(task.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: "default executor is available",
  });
  const evidence = store.putEvidence({
    kind: "old_log",
    producer: "fake",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  const run = store.recordAdapterRun({
    ...ADAPTER_RUN_INPUT,
    taskId: task.id,
    routeId: route.id,
    startedAt: "2026-01-01T00:00:00.000Z",
    finishedAt: "2026-01-01T00:05:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  // 期限内の子が、期限切れの親を参照している状態。
  store.recordVerificationResult({
    taskId: task.id,
    adapterRunId: run.id,
    evidenceId: evidence.id,
    checkKind: "test",
    status: "passed",
    createdAt: "2026-08-20T00:00:00.000Z",
  });

  const pruned = store.pruneExpired({
    rawCutoff: "2026-08-01T00:00:00.000Z",
    telemetryCutoff: NEVER_EXPIRES_CUTOFF,
  });
  assert.equal(pruned.raw.evidence, 1);
  assert.equal(pruned.raw.adapterRuns, 1);
  assert.equal(pruned.raw.verificationResults, 0);

  const [survivor] = store.listVerificationResults();
  assert.equal(survivor.adapterRunId, null);
  assert.equal(survivor.evidenceId, null);
  assert.equal(survivor.status, "passed");
  store.close();
});

test("the shipped retention config matches the named retention defaults", () => {
  // 30 / 180 が config.json とコード定数の 2 箇所にあるまま静かにずれるのを防ぐ。
  assert.equal(
    shippedConfig.retention.rawArtifactsDays,
    DEFAULT_RAW_ARTIFACT_RETENTION_DAYS,
  );
  assert.equal(
    shippedConfig.retention.aggregateTelemetryDays,
    DEFAULT_AGGREGATE_TELEMETRY_RETENTION_DAYS,
  );
});

test("retention cutoffs refuse an unusable clock", () => {
  assert.throws(
    () => retentionCutoffs(shippedConfig.retention, new Date("not a date")),
    /valid Date/,
  );
});

// ---------------------------------------------------------------------------
// レビュー指摘に対する回帰テスト（PR #530 round 1）
// ---------------------------------------------------------------------------

// 実プロセスの競合はタイミング依存で決定的に再現できないため、
// 「BEGIN より前に読んだ版数」だけを stale に見せる薄い wrapper で再現する。
function withStaleFirstVersionRead(database, staleVersion) {
  let served = false;
  return {
    exec: (sql) => database.exec(sql),
    prepare: (sql) => {
      if (sql.includes("PRAGMA user_version") && !served) {
        served = true;
        return { get: () => ({ user_version: staleVersion }) };
      }
      return database.prepare(sql);
    },
  };
}

test("migration derives its work from the version read inside the write lock", (context) => {
  // state は Git common directory に置かれ複数 worktree / 並列セッションで共有される。
  // BEGIN より前に読んだ版数を適用範囲の根拠にすると、別プロセスが先に migration を
  // 終えていた場合に適用済みステップを再実行し、duplicate column で起動そのものが落ちる。
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);

  const first = createStateStore(statePath);
  assert.equal(first.schemaVersion(), SCHEMA_VERSION);
  first.close();

  const raw = new DatabaseSync(statePath, { enableForeignKeyConstraints: true });
  migrate(withStaleFirstVersionRead(raw, 1));
  assert.equal(
    Number(raw.prepare("PRAGMA user_version").get().user_version),
    SCHEMA_VERSION,
  );
  assert.equal(Number(raw.prepare("SELECT COUNT(*) AS n FROM evidence").get().n), 1);
  raw.close();
});

// 移行の無損失性は、行を数えるのではなく移行前後の論理スナップショットを比較して確かめる。
function snapshotLegacyTables(statePath) {
  const raw = new DatabaseSync(statePath);
  const snapshot = {};
  for (const table of ["tasks", "route_decisions", "evidence"]) {
    const columns = raw
      .prepare(`PRAGMA table_info(${table})`)
      .all()
      .map((column) => column.name);
    snapshot[table] = {
      columns,
      rows: raw
        .prepare(`SELECT * FROM ${table} ORDER BY id`)
        .all()
        .map((row) => ({ ...row })),
    };
  }
  snapshot.userVersion = Number(
    raw.prepare("PRAGMA user_version").get().user_version,
  );
  snapshot.objects = raw
    .prepare("SELECT type, name FROM sqlite_master ORDER BY type, name")
    .all()
    .map((row) => ({ ...row }));
  raw.close();
  return snapshot;
}

// legacy 行を 1 行だけにすると「2 行目以降の欠落」も「他列の破損」も観測できない。
function seedLegacyRows(statePath, count) {
  const raw = new DatabaseSync(statePath);
  for (let index = 2; index <= count; index += 1) {
    raw
      .prepare("INSERT INTO tasks VALUES (?, ?, ?, ?)")
      .run(`task_${index}`, `goal ${index}`, "{}", `2026-01-0${index}T00:00:00.000Z`);
    raw
      .prepare("INSERT INTO route_decisions VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run(
        `route_${index}`,
        `task_${index}`,
        "escalation",
        null,
        null,
        `reason ${index}`,
        `2026-01-0${index}T00:00:00.000Z`,
      );
    raw
      .prepare("INSERT INTO evidence VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .run(
        `ev_${index}`,
        `kind_${index}`,
        `producer_${index}`,
        `2026-01-0${index}T00:00:00.000Z`,
        null,
        null,
        null,
        "[]",
      );
  }
  raw.close();
}

test("migration preserves every legacy row and column value verbatim", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);
  seedLegacyRows(statePath, 3);

  const before = snapshotLegacyTables(statePath);
  const store = createStateStore(statePath);
  store.close();
  const after = snapshotLegacyTables(statePath);

  for (const table of ["tasks", "route_decisions", "evidence"]) {
    // 既存列は名前・順序ともそのまま残り、新規列だけが末尾に増える。
    assert.deepEqual(
      after[table].columns.slice(0, before[table].columns.length),
      before[table].columns,
    );
    assert.equal(after[table].rows.length, before[table].rows.length);
    // 既存列の値は 1 つも変わらない。
    for (const [index, row] of before[table].rows.entries()) {
      for (const column of before[table].columns) {
        assert.deepEqual(
          after[table].rows[index][column],
          row[column],
          `${table}.${column} changed for row ${index}`,
        );
      }
    }
  }
  // v1 の index は移行後も残る。
  for (const object of before.objects) {
    assert.ok(
      after.objects.some(
        (candidate) =>
          candidate.type === object.type && candidate.name === object.name,
      ),
      `${object.type} ${object.name} disappeared during migration`,
    );
  }
});

test("a failed migration leaves schema and data byte-for-byte unchanged", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedLegacyV1Database(statePath);
  seedLegacyRows(statePath, 3);

  // v2 の後半の ALTER と衝突させ、途中まで進んだ migration を巻き戻させる。
  const seeded = new DatabaseSync(statePath);
  seeded.exec("ALTER TABLE evidence ADD COLUMN content_hash TEXT");
  seeded.exec("PRAGMA user_version = 1");
  seeded.close();

  const before = snapshotLegacyTables(statePath);
  assert.throws(() => createStateStore(statePath), /duplicate column name/);
  const after = snapshotLegacyTables(statePath);

  // user_version・schema オブジェクト・列構成・全行が完全に一致する。
  assert.deepEqual(after, before);
});

test("record stores ignore a caller supplied id and round-trip every field", () => {
  const store = createStateStore(":memory:");
  const task = store.createTask({ goal: "round trip" });
  const route = store.recordRoute(task.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: "default executor is available",
  });
  const evidence = store.putEvidence({
    kind: "test_pass",
    producer: "codex",
    taskId: task.id,
    routeId: route.id,
  });

  const run = store.recordAdapterRun({
    ...ADAPTER_RUN_INPUT,
    id: "arun_forged",
    taskId: task.id,
    routeId: route.id,
  });
  const verification = store.recordVerificationResult({
    id: "vres_forged",
    taskId: task.id,
    adapterRunId: run.id,
    evidenceId: evidence.id,
    checkKind: "lint",
    status: "failed",
    command: "make lint",
    exitCode: 2,
  });
  const finding = store.recordReviewFinding({
    id: "rfind_forged",
    taskId: task.id,
    adapterRunId: run.id,
    evidenceId: evidence.id,
    reviewerCapability: "semantic.judge",
    severity: "must",
    uncertainty: "low",
    summary: "a finding",
    discriminatingExperiment: "run the suite",
  });
  const approval = store.recordApproval({
    ...APPROVAL_INPUT,
    id: "appr_forged",
    taskId: task.id,
  });
  const telemetry = store.recordTelemetryEvent({
    ...TELEMETRY_INPUT,
    id: "tel_forged",
    taskId: task.id,
  });

  // 呼び出し側の id は採用されない（要件 6-3）。
  for (const [record, prefix] of [
    [run, "arun"],
    [verification, "vres"],
    [finding, "rfind"],
    [approval, "appr"],
    [telemetry, "tel"],
  ]) {
    assert.doesNotMatch(record.id, /forged/);
    assert.match(record.id, new RegExp(`^${prefix}_[0-9a-f]{32}$`));
  }

  // bind 順・NULL の往復・list mapper を、書いた値との突き合わせで固定する。
  assert.deepEqual(store.listAdapterRuns(), [run]);
  assert.deepEqual(store.listVerificationResults(), [verification]);
  assert.deepEqual(store.listReviewFindings(), [finding]);
  assert.deepEqual(store.listApprovals(), [approval]);
  assert.deepEqual(store.listTelemetryEvents(), [
    { ...telemetry, risk: [...telemetry.risk] },
  ]);
  store.close();
});

test("every record normalizer rejects an unknown key", () => {
  const cases = [
    [normalizeAdapterRun, ADAPTER_RUN_INPUT],
    [
      normalizeVerificationResult,
      { taskId: "task_1", checkKind: "test", status: "passed" },
    ],
    [
      normalizeReviewFinding,
      {
        taskId: "task_1",
        reviewerCapability: "semantic.judge",
        severity: "must",
        uncertainty: "low",
        summary: "s",
      },
    ],
    [normalizeApproval, APPROVAL_INPUT],
    [normalizeTelemetryEvent, TELEMETRY_INPUT],
  ];
  for (const [normalize, input] of cases) {
    assert.throws(
      () => normalize({ ...input, unexpected: "value" }),
      /unsupported key: unexpected/,
    );
  }
});

test("occurrence timestamps refuse a future date that would evade retention", () => {
  // retention は created_at < cutoff の比較なので、未来日時の行は永久に prune されない。
  const future = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();
  assert.throws(
    () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, createdAt: future }),
    /must not be in the future/,
  );
  assert.throws(
    () => normalizeAdapterRun({ ...ADAPTER_RUN_INPUT, startedAt: future }),
    /must not be in the future/,
  );
  assert.throws(
    () => normalizeApproval({ ...APPROVAL_INPUT, grantedAt: future }),
    /must not be in the future/,
  );
  // 失効時刻は未来が正常なので、同じ制約をかけてはならない。
  assert.equal(
    normalizeApproval({ ...APPROVAL_INPUT, expiresAt: future }).expiresAt,
    future,
  );
});

test("aggregate telemetry bounds every field that could smuggle content", () => {
  // token 配列の要素数を縛らないと、実質的に長さ無制限の TEXT 列になり
  // 「内容を含まない」という 180 日保持の根拠が崩れる。
  assert.throws(
    () =>
      normalizeTelemetryEvent({
        ...TELEMETRY_INPUT,
        risk: Array.from({ length: TELEMETRY_RISK_MAX_ENTRIES + 1 }, () => "migration"),
      }),
    /at most 16 entries/,
  );
  assert.equal(
    normalizeTelemetryEvent({
      ...TELEMETRY_INPUT,
      risk: Array.from({ length: TELEMETRY_RISK_MAX_ENTRIES }, () => "migration"),
    }).risk.length,
    TELEMETRY_RISK_MAX_ENTRIES,
  );
  // token 長は符号化して運べる容量そのものなので、境界を固定する。
  assert.equal(
    normalizeTelemetryEvent({
      ...TELEMETRY_INPUT,
      model: "m".repeat(TELEMETRY_TOKEN_MAX_LENGTH),
    }).model.length,
    TELEMETRY_TOKEN_MAX_LENGTH,
  );
  assert.throws(
    () =>
      normalizeTelemetryEvent({
        ...TELEMETRY_INPUT,
        model: "m".repeat(TELEMETRY_TOKEN_MAX_LENGTH + 1),
      }),
    /at most 32 characters/,
  );
  // 語彙が閉じている列は enum で縛る（provider は providers.mjs が SSOT）。
  assert.throws(
    () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, provider: "acmecorp" }),
    /provider must be one of/,
  );
  assert.throws(
    () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, effort: "turbo" }),
    /effort must be one of/,
  );
});

test("record normalizers pin their numeric and boolean boundaries", () => {
  const accepted = normalizeTelemetryEvent({
    ...TELEMETRY_INPUT,
    reviewPrecision: 0,
    toolCalls: 0,
    rollback: false,
  });
  assert.equal(accepted.reviewPrecision, 0);
  assert.equal(accepted.toolCalls, 0);
  assert.equal(accepted.rollback, false);
  assert.equal(
    normalizeTelemetryEvent({ ...TELEMETRY_INPUT, reviewPrecision: 1 }).reviewPrecision,
    1,
  );
  for (const [field, value, pattern] of [
    ["reviewPrecision", -0.1, /between 0 and 1/],
    ["reviewPrecision", Number.NaN, /finite number/],
    ["toolCalls", -1, /must not be negative/],
    ["toolCalls", 1.5, /must be an integer/],
    ["rollback", "yes", /must be a boolean/],
    ["risk", "migration", /must be an array/],
    ["risk", ["Migration"], /must match/],
  ]) {
    assert.throws(
      () => normalizeTelemetryEvent({ ...TELEMETRY_INPUT, [field]: value }),
      pattern,
      `${field}=${String(value)} should be rejected`,
    );
  }
});

test("the store refuses a record whose references belong to another task", () => {
  // FK は「その id が存在するか」しか見ないため、参照先がすべて実在しつつ
  // 所属 task だけ食い違う行が挿入できてしまう。task 単位の来歴が静かに壊れる。
  const store = createStateStore(":memory:");
  const taskA = store.createTask({ goal: "task A" });
  const taskB = store.createTask({ goal: "task B" });
  const routeB = store.recordRoute(taskB.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: "default executor is available",
  });

  assert.throws(
    () =>
      store.recordAdapterRun({
        ...ADAPTER_RUN_INPUT,
        taskId: taskA.id,
        routeId: routeB.id,
      }),
    /routeId .* belongs to task/,
  );
  assert.throws(
    () =>
      store.putEvidence({
        kind: "test_pass",
        producer: "codex",
        taskId: taskA.id,
        routeId: routeB.id,
      }),
    /routeId .* belongs to task/,
  );

  const runB = store.recordAdapterRun({
    ...ADAPTER_RUN_INPUT,
    taskId: taskB.id,
    routeId: routeB.id,
  });
  assert.throws(
    () =>
      store.recordVerificationResult({
        taskId: taskA.id,
        adapterRunId: runB.id,
        checkKind: "test",
        status: "passed",
      }),
    /adapterRunId .* belongs to task/,
  );
  store.close();
});

test("pruning composes with an outer transaction instead of unwinding it", (context) => {
  // pruneExpired が自前で BEGIN すると、withTransaction の内側から呼ばれたときに
  // 内側の catch の ROLLBACK が外側の書き込みごと巻き戻す。
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  seedRetentionFixture(statePath);

  const store = createStateStore(statePath);
  const pruned = store.withTransaction(() => {
    // 外側の transaction 内での書き込み。ネストが壊れているとこれごと巻き戻る。
    store.putEvidence({ kind: "written_inside", producer: "fake" });
    return store.pruneExpired({
      rawCutoff: RAW_CUTOFF,
      telemetryCutoff: TELEMETRY_CUTOFF,
    });
  });
  assert.equal(pruned.raw.evidence, 1);
  assert.equal(pruned.telemetry, 1);
  store.close();

  // 期限切れ 1 行が消え、外側で書いた 1 行が残って commit されている。
  const reopened = createStateStore(statePath);
  assert.deepEqual(
    reopened.listEvidence().map((evidence) => evidence.kind),
    ["evidence_at_cutoff", "evidence_in_window", "written_inside"],
  );
  reopened.close();
});

test("the approvals table rejects a non-user grantor written outside the store", (context) => {
  // normalizer を通さない直接書き込みに対する多層防御（境界そのものではない）。
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const store = createStateStore(statePath);
  store.close();

  const raw = new DatabaseSync(statePath);
  assert.throws(
    () =>
      raw
        .prepare("INSERT INTO approvals VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(
          "appr_direct",
          "repository_manifest",
          "c".repeat(64),
          "scope",
          null,
          "codex",
          "2026-08-01T00:00:00.000Z",
          null,
          "2026-08-01T00:00:00.000Z",
        ),
    /CHECK constraint failed/,
  );
  raw.close();
});

// paths.mjs は symlink ガードと atomic write の唯一の SSOT。ここでは「最終要素だけを見る検査は
// 中間の祖先を symlink に差し替えられると素通りする」欠陥（#541）と、権限固定を記述子に対して
// 行うこと（check-then-act を作らないこと）を固定する。

test("ensureDirectory refuses to create through a symlinked ancestor", (context) => {
  const directory = temporaryDirectory(context);
  const outside = path.join(directory, "outside");
  mkdirSync(outside);
  symlinkSync(outside, path.join(directory, "link"));

  assert.throws(
    () => ensureDirectory(path.join(directory, "link", "state"), "state directory"),
    /symbolic link/,
  );
  // 拒否より先に symlink 先へディレクトリを作らないこと。
  assert.deepEqual(readdirSync(outside), []);
});

test("writeJsonAtomic refuses to write through a symlinked ancestor", (context) => {
  const directory = temporaryDirectory(context);
  const outside = path.join(directory, "outside");
  mkdirSync(outside);
  symlinkSync(outside, path.join(directory, "link"));

  assert.throws(
    () =>
      writeJsonAtomic(
        path.join(directory, "link", "state", "readiness.json"),
        { version: 1 },
        "readiness cache",
      ),
    /symbolic link/,
  );
  assert.deepEqual(readdirSync(outside), []);
});

test("ensureDirectory refuses a target whose parent does not exist", (context) => {
  const directory = temporaryDirectory(context);

  // 検証していない祖先チェーンを辿って作らない（fail closed）。
  assert.throws(
    () => ensureDirectory(path.join(directory, "missing", "state"), "state directory"),
    /parent directory/,
  );
  assert.equal(existsSync(path.join(directory, "missing")), false);
});

test("ensureStateFileMode refuses a symlinked target and leaves the link target untouched", (context) => {
  const directory = temporaryDirectory(context);
  const target = path.join(directory, "target.json");
  const link = path.join(directory, "state.json");
  writeFileSync(target, "{}\n");
  chmodSync(target, 0o644);
  symlinkSync(target, link);

  assert.throws(() => ensureStateFileMode(link, "state file"), /symbolic link/);
  assert.equal(statSync(target).mode & 0o777, 0o644);
});

test("ensureDirectory restores owner-only mode when umask strips it", (context) => {
  const directory = temporaryDirectory(context);
  const stateDirectory = path.join(directory, "state");

  // umask が owner ビットまで削ると mkdirSync は mode 000 のディレクトリを作る。放置すると
  // 以後 open もできず、壊れたディレクトリが残り続ける（自己回復しない）。
  const previousUmask = process.umask(0o700);
  try {
    ensureDirectory(stateDirectory, "state directory");
  } finally {
    process.umask(previousUmask);
  }

  assert.equal(statSync(stateDirectory).mode & 0o777, 0o700);
});

test("writeJsonAtomic keeps the state file owner-only under a restrictive umask", (context) => {
  const directory = temporaryDirectory(context);
  const targetPath = path.join(directory, "readiness.json");

  const previousUmask = process.umask(0o377);
  try {
    writeJsonAtomic(targetPath, { version: 1 }, "readiness cache");
  } finally {
    process.umask(previousUmask);
  }

  assert.equal(statSync(targetPath).mode & 0o777, 0o600);
});

test("writeJsonAtomic leaves no temporary file behind when the rename fails", (context) => {
  const directory = temporaryDirectory(context);
  const targetPath = path.join(directory, "readiness.json");
  // 宛先がディレクトリだと rename が失敗する。symlink ではないので事前検査は通過し、
  // 一時ファイルの後始末だけが問われる。
  mkdirSync(targetPath);

  assert.throws(() => writeJsonAtomic(targetPath, { version: 1 }, "readiness cache"));
  assert.deepEqual(
    readdirSync(directory).filter((entry) => entry.endsWith(".tmp")),
    [],
  );
});

test("ensureDirectory names a non-directory collision instead of blaming a symlink", (context) => {
  const directory = temporaryDirectory(context);
  const target = path.join(directory, "state");
  writeFileSync(target, "not a directory");

  assert.throws(
    () => ensureDirectory(target, "state directory"),
    /exists and is not a directory/,
  );
});

test("ensureDirectory refuses a parent that is not a directory", (context) => {
  const directory = temporaryDirectory(context);
  const parent = path.join(directory, "parent");
  writeFileSync(parent, "not a directory");

  assert.throws(
    () => ensureDirectory(path.join(parent, "state"), "state directory"),
    /parent directory .* is not a directory/,
  );
});

test("writeJsonAtomic consumes the temporary file on success", (context) => {
  const directory = temporaryDirectory(context);
  const targetPath = path.join(directory, "readiness.json");

  writeJsonAtomic(targetPath, { version: 1 }, "readiness cache");

  assert.deepEqual(JSON.parse(readFileSync(targetPath, "utf8")), { version: 1 });
  assert.equal(statSync(targetPath).mode & 0o777, 0o600);
  assert.deepEqual(
    readdirSync(directory).filter((entry) => entry.endsWith(".tmp")),
    [],
  );
});

test("ensureStateFile creates an owner-only file even when umask strips the owner bits", (context) => {
  const directory = temporaryDirectory(context);
  const target = path.join(directory, "state.db");

  const previousUmask = process.umask(0o700);
  try {
    ensureStateFile(target, "state database");
  } finally {
    process.umask(previousUmask);
  }

  assert.equal(statSync(target).mode & 0o777, 0o600);
});

test("state store keeps the database owner-only under a umask that strips owner bits", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");

  // DatabaseSync にファイルを作らせると umask 次第で owner が開けない mode になり、
  // 以後 fd 経由では権限を直せない（実測: umask 0700 で 0066）。
  const previousUmask = process.umask(0o700);
  let store;
  try {
    store = createStateStore(statePath);
  } finally {
    process.umask(previousUmask);
  }
  store.close();

  assert.equal(statSync(statePath).mode & 0o777, 0o600);
});
