import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  APPROVAL_CHANNEL_STRENGTH,
  UNKNOWN_PROVIDER_CAPABILITIES,
  defaultProviderCapabilityFacts,
  describeUnmetRequirements,
  providerCapabilityFacts,
  resolveProviderCapabilities,
  unmetRequirements,
} from "../home/dot_local/lib/frontier-harness/provider-capabilities.mjs";
import { chooseRoute } from "../home/dot_local/lib/frontier-harness/router.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";
import { normalizeTask } from "../home/dot_local/lib/frontier-harness/task.mjs";

// 承認チャネル / 書き込み可否を route 段階の軸として扱う挙動（#534）専用のスイート。
//
// tests/frontier_harness.test.mjs には触れない。あちらは engine 全体の回帰スイートで、
// 別作業が同時に編集している。ここで必要なフィクスチャは小さいので書き起こす。

const CONFIGURED_FRONTEND_MODEL = "gemini-3.7-flash-high";

const baseConfigInput = {
  version: 1,
  rollout: "shadow",
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
    "frontend.primary": {
      provider: "antigravity",
      model: CONFIGURED_FRONTEND_MODEL,
      effort: "high",
      accountScope: "personal",
    },
  },
  risk: { alwaysEscalate: ["merge"] },
};

const config = normalizeConfig(baseConfigInput);

// 承認チャネルを持つ executor を宣言した config。出荷 config には存在しない組み合わせなので、
// 「承認が要る task はどこへも行けない」だけでなく「承認できる provider へは行ける」ことも
// 分けて観測できるようにする。
const approvingExecutorConfig = normalizeConfig({
  ...baseConfigInput,
  capabilities: {
    ...baseConfigInput.capabilities,
    "executor.default": {
      provider: "claude",
      model: "claude-opus-5",
      effort: "high",
    },
  },
});

// registry に adapter が無い provider を宣言した config（fail-closed の観測用）。
const unknownProviderConfig = normalizeConfig({
  ...baseConfigInput,
  capabilities: {
    ...baseConfigInput.capabilities,
    "executor.default": {
      provider: "not-a-registered-provider",
      model: "some-model",
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
  extra = {},
} = {}) {
  return {
    antigravity: {
      available: antigravity,
      models: antigravity ? antigravityModels : null,
    },
    claude: { available: claude, models: null },
    codex: { available: codex, models: null },
    ...extra,
  };
}

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-router-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

function writeTask(directory, task) {
  const taskPath = path.join(directory, "task.json");
  writeFileSync(taskPath, JSON.stringify(task));
  return taskPath;
}

// ---------------------------------------------------------------------------
// 供給側: adapter の宣言を route 段階が引ける表に束ねる
// ---------------------------------------------------------------------------

test("provider capability facts mirror what the shipped adapters declare", () => {
  const facts = defaultProviderCapabilityFacts();

  assert.deepEqual(facts.claude, {
    approvalChannel: "external",
    writeAccess: "supported",
  });
  assert.deepEqual(facts.codex, {
    approvalChannel: "agent-review",
    writeAccess: "supported",
  });
  assert.deepEqual(facts.antigravity, {
    approvalChannel: "none",
    writeAccess: "unenforceable",
  });
});

test("provider capability facts are memoised and frozen", () => {
  // 同じ表を使い回す（route ごとに registry を組み直さない）ことと、
  // 呼び出し側が事実を書き換えられないことの両方を固定する。
  assert.equal(defaultProviderCapabilityFacts(), defaultProviderCapabilityFacts());
  assert.equal(Object.isFrozen(defaultProviderCapabilityFacts()), true);
  assert.equal(Object.isFrozen(providerCapabilityFacts().codex), true);
});

test("an unknown provider resolves to the weakest capabilities (fail closed)", () => {
  assert.deepEqual(
    resolveProviderCapabilities(defaultProviderCapabilityFacts(), "nope"),
    UNKNOWN_PROVIDER_CAPABILITIES,
  );
  assert.deepEqual(UNKNOWN_PROVIDER_CAPABILITIES, {
    approvalChannel: "none",
    writeAccess: "unenforceable",
  });
});

test("resolving provider capabilities ignores inherited Object.prototype keys", () => {
  // provider 名は設定由来。"constructor" のような継承プロパティを事実として拾わない。
  assert.deepEqual(
    resolveProviderCapabilities({}, "constructor"),
    UNKNOWN_PROVIDER_CAPABILITIES,
  );
  assert.deepEqual(
    resolveProviderCapabilities(null, "codex"),
    UNKNOWN_PROVIDER_CAPABILITIES,
  );
});

test("a declaration outside the vocabulary is normalised to the weakest value", () => {
  // 通常は assertAdapterShape() が registry 登録時に弾く。ここは多層防御の確認。
  assert.deepEqual(
    resolveProviderCapabilities(
      { rogue: { approvalChannel: "constructor", writeAccess: "sort-of" } },
      "rogue",
    ),
    UNKNOWN_PROVIDER_CAPABILITIES,
  );
});

test("only an external channel satisfies a task that needs human judgement", () => {
  assert.ok(
    APPROVAL_CHANNEL_STRENGTH["agent-review"] < APPROVAL_CHANNEL_STRENGTH.external,
  );
  assert.deepEqual(
    unmetRequirements(
      { approvalChannel: "agent-review", writeAccess: "supported" },
      { requiresApproval: true },
    ),
    [{ axis: "approvalChannel", required: "external", actual: "agent-review" }],
  );
  assert.deepEqual(
    unmetRequirements(
      { approvalChannel: "external", writeAccess: "supported" },
      { requiresApproval: true, requiresWrite: true },
    ),
    [],
  );
});

test("describeUnmetRequirements renders every unmet axis for the route reason", () => {
  const unmet = unmetRequirements(
    { approvalChannel: "none", writeAccess: "unenforceable" },
    { requiresApproval: true, requiresWrite: true },
  );

  assert.equal(
    describeUnmetRequirements(unmet),
    "approvalChannel external (declares none), writeAccess supported (declares unenforceable)",
  );
});

// ---------------------------------------------------------------------------
// 需要側: task が要求を宣言する
// ---------------------------------------------------------------------------

test("normalizeTask defaults both requirement flags to false", () => {
  const task = normalizeTask({ goal: "text work" });

  assert.equal(task.requiresApproval, false);
  assert.equal(task.requiresWrite, false);
});

test("normalizeTask rejects a non-boolean requirement flag", () => {
  assert.throws(
    () => normalizeTask({ goal: "g", requiresApproval: "true" }),
    /task\.requiresApproval must be a boolean/,
  );
  assert.throws(
    () => normalizeTask({ goal: "g", requiresWrite: 1 }),
    /task\.requiresWrite must be a boolean/,
  );
  // 既存フィールドのエラーメッセージが helper 化で変わっていないこと。
  assert.throws(
    () => normalizeTask({ goal: "g", hasDeterministicOracle: "false" }),
    /task\.hasDeterministicOracle must be a boolean/,
  );
});

// ---------------------------------------------------------------------------
// 突き合わせ: router
// ---------------------------------------------------------------------------

test("a task needing human judgement is not routed to an agent-review executor", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "rewrite published history",
      requiresApproval: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.kind, "escalation");
  assert.equal(decision.capability, null);
  assert.equal(decision.provider, null);
  assert.match(decision.reason, /approvalChannel external \(declares agent-review\)/);
});

test("the blocked route carries the capability, provider, axis and both values", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "rewrite published history",
      requiresApproval: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.deepEqual(decision.blocked, [
    {
      capability: "executor.default",
      provider: "codex",
      axis: "approvalChannel",
      required: "external",
      actual: "agent-review",
    },
  ]);
});

test("a task needing human judgement is routed to an executor that can ask", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "rewrite published history",
      requiresApproval: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config: approvingExecutorConfig,
  });

  assert.equal(decision.kind, "single-worker");
  assert.equal(decision.capability, "executor.default");
  assert.equal(decision.provider, "claude");
  assert.equal(decision.blocked, undefined);
});

test("a write-capable browser task falls back to the executor instead of Antigravity", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "edit the page fixtures from the browser session",
      modality: ["browser"],
      requiresWrite: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  // 既存の「frontend が使えないときは executor.default」経路をそのまま再利用する。
  assert.equal(decision.kind, "single-worker");
  assert.equal(decision.capability, "executor.default");
  assert.equal(decision.provider, "codex");
  assert.match(
    decision.reason,
    /frontend provider does not satisfy writeAccess supported \(declares unenforceable\); using executor\.default/,
  );
  assert.deepEqual(decision.blocked, [
    {
      capability: "frontend.primary",
      provider: "antigravity",
      axis: "writeAccess",
      required: "supported",
      actual: "unenforceable",
    },
  ]);
});

test("a fallback route keeps its kind and reviewer while recording the block", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "edit the page fixtures from the browser session",
      modality: ["browser"],
      requiresWrite: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.kind, "writer-plus-reviewer");
  assert.equal(decision.reviewerCapability, "semantic.judge");
  assert.equal(decision.blocked.length, 1);
});

test("a browser task that needs both axes records both blocked axes", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "apply a reviewed patch from the browser session",
      modality: ["browser"],
      requiresApproval: true,
      requiresWrite: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  // frontend は 2 軸とも満たさず、fallback 先の executor も承認できないので escalation。
  assert.equal(decision.kind, "escalation");
  assert.deepEqual(
    decision.blocked.map((entry) => [entry.capability, entry.axis]),
    [
      ["frontend.primary", "approvalChannel"],
      ["frontend.primary", "writeAccess"],
      ["executor.default", "approvalChannel"],
    ],
  );
});

test("a task that declares no requirement routes exactly as before", () => {
  const browser = chooseRoute({
    task: normalizeTask({
      goal: "browser work",
      modality: ["browser"],
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });
  assert.equal(browser.capability, "frontend.primary");
  assert.equal(browser.kind, "single-worker");
  assert.equal(browser.blocked, undefined);

  const text = chooseRoute({
    task: normalizeTask({ goal: "text work", modality: ["text"] }),
    accountScope: "personal",
    availability: availability(),
    config,
  });
  assert.equal(text.kind, "writer-plus-reviewer");
  assert.equal(text.capability, "executor.default");
  assert.equal(text.blocked, undefined);
});

test("a provider with no registered adapter is blocked, not trusted", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "write some files",
      requiresWrite: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability({
      extra: { "not-a-registered-provider": { available: true, models: null } },
    }),
    config: unknownProviderConfig,
  });

  assert.equal(decision.kind, "escalation");
  assert.deepEqual(decision.blocked, [
    {
      capability: "executor.default",
      provider: "not-a-registered-provider",
      axis: "writeAccess",
      required: "supported",
      actual: "unenforceable",
    },
  ]);
});

test("provider capability facts can be injected instead of read from the registry", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "rewrite published history",
      requiresApproval: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
    // codex が外部往復できるようになった世界を、adapter を書き換えずに観測する。
    providerCapabilities: {
      codex: { approvalChannel: "external", writeAccess: "supported" },
    },
  });

  assert.equal(decision.kind, "single-worker");
  assert.equal(decision.capability, "executor.default");
});

test("a risk escalation stays untouched by the new axes", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "merge the branch",
      risk: ["merge"],
      requiresApproval: true,
      requiresWrite: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
  });

  assert.equal(decision.kind, "escalation");
  assert.match(decision.reason, /risk merge requires user escalation/);
  // risk escalation は kind と reason だけで説明が閉じるため blocked を付けない。
  assert.equal(decision.blocked, undefined);
});

test("the reviewer capability is never gated by the new axes", () => {
  // semantic.judge は claude（external / supported）だが、ここで観測したいのは
  // 「reviewer が軸で外されない」こと。executor 側は要求を満たす config を使う。
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "write some files without an oracle",
      requiresWrite: true,
    }),
    accountScope: "personal",
    availability: availability(),
    config,
    providerCapabilities: {
      codex: { approvalChannel: "agent-review", writeAccess: "supported" },
      // reviewer の provider は最弱を宣言していても reviewer から外れない。
      claude: { approvalChannel: "none", writeAccess: "unenforceable" },
    },
  });

  assert.equal(decision.kind, "writer-plus-reviewer");
  assert.equal(decision.reviewerCapability, "semantic.judge");
  assert.equal(decision.blocked, undefined);
});

test("an unavailable executor still reports the frontend block it already found", () => {
  const decision = chooseRoute({
    task: normalizeTask({
      goal: "edit the page fixtures from the browser session",
      modality: ["browser"],
      requiresWrite: true,
      hasDeterministicOracle: true,
    }),
    accountScope: "personal",
    availability: availability({ codex: false }),
    config,
  });

  assert.equal(decision.kind, "escalation");
  assert.match(decision.reason, /executor\.default is unavailable/);
  assert.equal(decision.blocked.length, 1);
  assert.equal(decision.blocked[0].capability, "frontend.primary");
});

// ---------------------------------------------------------------------------
// evidence: 塞いだ route を後から追える
// ---------------------------------------------------------------------------

test("fh run records a blocked route as evidence tied to the task and route", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const taskPath = writeTask(directory, {
    goal: "rewrite published history",
    requiresApproval: true,
    hasDeterministicOracle: true,
  });

  const output = [];
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );

  const run = JSON.parse(output.pop());
  assert.equal(run.decision.kind, "escalation");
  assert.equal(run.blocked.length, 1);
  assert.equal(run.blockEvidence.kind, "route_block");
  assert.equal(run.blockEvidence.taskId, run.task.id);
  assert.ok(run.blockEvidence.routeId);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  const evidence = store.listEvidence();
  assert.equal(evidence.length, 1);
  assert.equal(evidence[0].kind, "route_block");
  assert.equal(evidence[0].taskId, run.task.id);
  assert.equal(evidence[0].routeId, run.blockEvidence.routeId);

  // 記録から 5 つ組（capability / provider / 軸 / 要求値 / 実際値）を復元できること。
  assert.deepEqual(evidence[0].claimsSupported, [
    "executor.default (codex) was not routed: approvalChannel requires external but the provider declares agent-review",
  ]);

  // 記録した routeId が本当にこの task の route を指していること。
  const routes = store.listRoutes();
  assert.equal(routes.length, 1);
  assert.equal(routes[0].id, evidence[0].routeId);
  assert.equal(routes[0].kind, "escalation");
});

test("fh run records no route_block evidence when nothing was blocked", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const taskPath = writeTask(directory, {
    goal: "browser work",
    modality: ["browser"],
    hasDeterministicOracle: true,
  });

  const output = [];
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );

  const run = JSON.parse(output.pop());
  assert.equal(run.decision.capability, "frontend.primary");
  assert.deepEqual(run.blocked, []);
  assert.equal(run.blockEvidence, null);

  const store = createStateStore(statePath);
  context.after(() => store.close());
  assert.deepEqual(store.listEvidence(), []);
});

test("fh run keeps a browser fallback routed while recording why it moved", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const taskPath = writeTask(directory, {
    goal: "edit the page fixtures from the browser session",
    modality: ["browser"],
    requiresWrite: true,
    hasDeterministicOracle: true,
  });

  const output = [];
  assert.equal(
    runCli(["run", "--task", taskPath, "--json"], {
      accountScope: "personal",
      commandPaths: COMMAND_PATHS,
      config,
      verifiedModels: VERIFIED_MODELS,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );

  const run = JSON.parse(output.pop());
  assert.equal(run.decision.capability, "executor.default");
  assert.equal(run.executed, false);
  assert.equal(run.blockEvidence.kind, "route_block");
  assert.deepEqual(run.blockEvidence.claimsSupported, [
    "frontend.primary (antigravity) was not routed: writeAccess requires supported but the provider declares unenforceable",
  ]);
});
