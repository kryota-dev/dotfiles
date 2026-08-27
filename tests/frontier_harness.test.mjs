import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { createDoctorReport } from "../home/dot_local/lib/frontier-harness/doctor.mjs";
import { chooseRoute } from "../home/dot_local/lib/frontier-harness/router.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";

const config = normalizeConfig({
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
      model: "gemini-3.7-flash-high",
      effort: "high",
      accountScope: "personal",
    },
  },
  risk: {
    alwaysEscalate: ["merge"],
  },
});

test("normalizeConfig rejects an invalid rollout before an adapter runs", () => {
  assert.throws(
    () => normalizeConfig({ ...config, rollout: "unverified" }),
    /rollout/,
  );
});

test("router chooses Antigravity for personal frontend work when available", () => {
  const decision = chooseRoute({
    task: {
      modality: ["browser"],
      risk: [],
      hasDeterministicOracle: true,
    },
    accountScope: "personal",
    availability: {
      antigravity: true,
      claude: true,
      codex: true,
    },
    config,
  });

  assert.equal(decision.capability, "frontend.primary");
  assert.equal(decision.provider, "antigravity");
  assert.equal(decision.kind, "single-worker");
});

test("router fails closed for an unavailable Antigravity account scope", () => {
  const decision = chooseRoute({
    task: {
      modality: ["browser"],
      risk: [],
      hasDeterministicOracle: true,
    },
    accountScope: "r06",
    availability: {
      antigravity: false,
      claude: true,
      codex: true,
    },
    config,
  });

  assert.equal(decision.capability, "executor.default");
  assert.match(decision.reason, /unavailable/);
});

test("router escalates a task without a deterministic oracle to independent review", () => {
  const decision = chooseRoute({
    task: {
      modality: ["text"],
      risk: [],
      hasDeterministicOracle: false,
    },
    accountScope: "personal",
    availability: {
      antigravity: true,
      claude: true,
      codex: true,
    },
    config,
  });

  assert.equal(decision.kind, "writer-plus-reviewer");
  assert.equal(decision.reviewerCapability, "semantic.judge");
});

test("state store records evidence without a transcript field", () => {
  const store = createStateStore(":memory:");
  const evidence = store.putEvidence({
    kind: "test_failure",
    producer: "codex:gpt-5.6-terra",
    command: "node --test",
    exitCode: 1,
    artifactPath: "/tmp/test.log",
    claimsSupported: ["regression reproducible"],
  });

  assert.match(evidence.id, /^ev_/);
  assert.equal(evidence.transcript, undefined);
  assert.deepEqual(store.listEvidence(), [evidence]);
  store.close();
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

  assert.equal(store.pruneEvidenceBefore("2026-08-01T00:00:00.000Z"), 1);
  assert.equal(store.listEvidence().length, 1);
  assert.equal(store.listEvidence()[0].kind, "test_pass");
  store.close();
});

test("doctor reports Antigravity as unavailable instead of crossing into r06", () => {
  const report = createDoctorReport({
    accountScope: "r06",
    commandPaths: {
      antigravity: "/opt/homebrew/bin/agy",
      claude: "/Users/example/.local/launchers/claude",
      codex: "/Users/example/.local/launchers/codex",
    },
    config,
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
    commandPaths: {
      antigravity: "/opt/homebrew/bin/agy",
      claude: "/Users/example/.local/launchers/claude",
      codex: "/Users/example/.local/launchers/codex",
    },
    config,
  });

  assert.equal(report.capabilities["frontend.primary"].status, "unverified");
  assert.match(report.capabilities["frontend.primary"].reason, /authentication/);
});

test("fh doctor emits machine-readable capability readiness", () => {
  const output = [];
  const exitCode = runCli(["doctor", "--json"], {
    accountScope: "personal",
    commandPaths: {
      antigravity: "/opt/homebrew/bin/agy",
      claude: "/Users/example/.local/launchers/claude",
      codex: "/Users/example/.local/launchers/codex",
    },
    config,
    verifiedProviders: ["antigravity"],
    write: (line) => output.push(line),
  });

  assert.equal(exitCode, 0);
  const report = JSON.parse(output.join("\n"));
  assert.equal(report.capabilities["frontend.primary"].status, "available");
  assert.equal(report.capabilities["semantic.judge"].model, "claude-opus-5");
});

test("fh run records a shadow route without starting a provider", (context) => {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
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
  const commonOptions = {
    accountScope: "personal",
    commandPaths: {
      antigravity: "/opt/homebrew/bin/agy",
      claude: "/Users/example/.local/launchers/claude",
      codex: "/Users/example/.local/launchers/codex",
    },
    config,
    verifiedProviders: ["antigravity"],
    statePath,
    write: (line) => output.push(line),
  };
  assert.equal(runCli(["run", "--task", taskPath, "--json"], commonOptions), 0);
  const run = JSON.parse(output.pop());
  assert.equal(run.executed, false);
  assert.equal(run.decision.capability, "frontend.primary");

  assert.equal(runCli(["status", "--json"], commonOptions), 0);
  const status = JSON.parse(output.pop());
  assert.equal(status.routes.length, 1);
  assert.equal(status.routes[0].capability, "frontend.primary");
});

test("fh onboard writes one approved repository capability manifest", (context) => {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
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
  assert.equal(JSON.parse(output.pop()).policyPath, policyPath);
});

test("fh clean applies the configured raw evidence retention window", (context) => {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
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
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  const statePath = path.join(directory, "state.db");
  const output = [];
  const options = {
    config,
    statePath,
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
