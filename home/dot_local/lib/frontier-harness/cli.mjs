import { accessSync, constants, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { chooseRoute } from "./router.mjs";
import { createStateStore } from "./state-store.mjs";

const PROVIDER_COMMANDS = {
  antigravity: "agy",
  claude: "claude",
  codex: "codex",
};

function findCommand(command, searchPath) {
  for (const directory of searchPath.split(path.delimiter)) {
    const candidate = path.join(directory, command);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // PATH の次候補を確認する。
    }
  }
  return null;
}

function resolveAccountScope(environment) {
  return environment.CLAUDE_CONFIG_DIR?.endsWith(".claude-r06")
    ? "r06"
    : "personal";
}

function loadConfig(configPath) {
  return normalizeConfig(JSON.parse(readFileSync(configPath, "utf8")));
}

function defaultCommandPaths(environment) {
  const searchPath = environment.PATH ?? "";
  return Object.fromEntries(
    Object.entries(PROVIDER_COMMANDS).map(([provider, command]) => [
      provider,
      findCommand(command, searchPath),
    ]),
  );
}

function flagValue(flags, name) {
  const index = flags.indexOf(name);
  if (index === -1 || !flags[index + 1]) {
    throw new TypeError(`${name} requires a value`);
  }
  return flags[index + 1];
}

function defaultStatePath(cwd) {
  const commonDirectory = execFileSync(
    "git",
    ["rev-parse", "--git-common-dir"],
    { cwd, encoding: "utf8" },
  ).trim();
  const absoluteCommonDirectory = path.resolve(cwd, commonDirectory);
  const stateDirectory = path.join(absoluteCommonDirectory, "frontier-harness");
  mkdirSync(stateDirectory, { mode: 0o700, recursive: true });
  return path.join(stateDirectory, "state.db");
}

function providerAvailability(commandPaths, verifiedProviders = []) {
  const verified = new Set(verifiedProviders);
  return Object.fromEntries(
    Object.keys(PROVIDER_COMMANDS).map((provider) => [
      provider,
      Boolean(commandPaths[provider]) &&
        (provider !== "antigravity" || verified.has("antigravity")),
    ]),
  );
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function approvalHash(manifest) {
  return createHash("sha256")
    .update(JSON.stringify(canonicalize(manifest)))
    .digest("hex");
}

function writePolicy(policyPath, policy) {
  mkdirSync(path.dirname(policyPath), { mode: 0o700, recursive: true });
  const temporaryPath = `${policyPath}.${process.pid}.tmp`;
  writeFileSync(temporaryPath, `${JSON.stringify(policy, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  renameSync(temporaryPath, policyPath);
}

function usage() {
  return [
    "Usage: frontier-harness <command> [--json]",
    "",
    "Commands:",
    "  doctor  Report adapter and capability readiness",
    "  clean   Prune expired raw evidence",
    "  onboard Approve one repository capability manifest",
    "  run     Record a shadow route for a task JSON file",
    "  status  Show recorded route decisions",
    "  verify  Record a deterministic verification plan",
    "  review  Record an independent review plan",
  ].join("\n");
}

export function runCli(argumentsList, options = {}) {
  const environment = options.environment ?? process.env;
  const write = options.write ?? ((line) => process.stdout.write(`${line}\n`));
  const [command, ...flags] = argumentsList;
  const asJson = flags.includes("--json");
  const configPath =
    options.configPath ??
    environment.FH_CONFIG_PATH ??
    path.join(environment.HOME ?? "", ".config/frontier-harness/config.json");
  const config = options.config ?? loadConfig(configPath);
  const commandPaths = options.commandPaths ?? defaultCommandPaths(environment);
  const accountScope = options.accountScope ?? resolveAccountScope(environment);

  if (command === "doctor") {
    const report = createDoctorReport({
      accountScope,
      commandPaths,
      config,
      verifiedProviders: options.verifiedProviders,
    });
    write(asJson ? JSON.stringify(report) : JSON.stringify(report, null, 2));
    return 0;
  }

  if (command === "onboard") {
    const manifestPath = flagValue(flags, "--manifest");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    if (!flags.includes("--approve")) {
      write(
        JSON.stringify({
          approved: false,
          manifest,
          reason: "re-run with --approve after reviewing the capability manifest",
        }),
      );
      return 2;
    }
    const policyPath =
      options.policyPath ??
      path.join(options.cwd ?? process.cwd(), ".harness", "policy.json");
    const policy = {
      version: 1,
      approvedAt: new Date().toISOString(),
      approvalHash: approvalHash(manifest),
      manifest,
    };
    writePolicy(policyPath, policy);
    write(
      asJson
        ? JSON.stringify({ approved: true, policyPath, approvalHash: policy.approvalHash })
        : JSON.stringify({ approved: true, policyPath, approvalHash: policy.approvalHash }, null, 2),
    );
    return 0;
  }

  const statePath = options.statePath ?? defaultStatePath(options.cwd ?? process.cwd());
  const store = createStateStore(statePath);
  try {
    if (command === "run") {
      const taskPath = flagValue(flags, "--task");
      const taskInput = JSON.parse(readFileSync(taskPath, "utf8"));
      const task = store.createTask(taskInput);
      const route = chooseRoute({
        accountScope,
        availability: providerAvailability(commandPaths, options.verifiedProviders),
        config,
        task: taskInput,
      });
      store.recordRoute(task.id, route);
      const result = {
        task,
        decision: route,
        executed: false,
        rollout: config.rollout,
      };
      write(asJson ? JSON.stringify(result) : JSON.stringify(result, null, 2));
      return 0;
    }

    if (command === "status") {
      const result = { routes: store.listRoutes() };
      write(asJson ? JSON.stringify(result) : JSON.stringify(result, null, 2));
      return 0;
    }

    if (command === "clean") {
      const nowValue = flags.includes("--now")
        ? flagValue(flags, "--now")
        : new Date().toISOString();
      const now = new Date(nowValue);
      if (Number.isNaN(now.getTime())) {
        throw new TypeError("--now must be an ISO 8601 timestamp");
      }
      const cutoff = new Date(
        now.getTime() - config.retention.rawArtifactsDays * 24 * 60 * 60 * 1000,
      ).toISOString();
      const expired = store
        .listEvidence()
        .filter((evidence) => evidence.createdAt < cutoff).length;
      const prunedEvidence = flags.includes("--dry-run")
        ? 0
        : store.pruneEvidenceBefore(cutoff);
      const result = {
        cutoff,
        dryRun: flags.includes("--dry-run"),
        expiredEvidence: expired,
        prunedEvidence,
      };
      write(asJson ? JSON.stringify(result) : JSON.stringify(result, null, 2));
      return 0;
    }

    if (command === "verify") {
      const verificationCommand = flagValue(flags, "--command");
      const evidence = store.putEvidence({
        kind: "verification_plan",
        producer: "frontier-harness",
        command: verificationCommand,
        claimsSupported: ["verification is planned for a shadow route"],
      });
      const result = { evidence, executed: false, rollout: config.rollout };
      write(asJson ? JSON.stringify(result) : JSON.stringify(result, null, 2));
      return 0;
    }

    if (command === "review") {
      const taskId = flagValue(flags, "--task");
      const evidence = store.putEvidence({
        kind: "review_plan",
        producer: "frontier-harness",
        claimsSupported: [`independent review planned for ${taskId}`],
      });
      const result = {
        evidence,
        executed: false,
        rollout: config.rollout,
        taskId,
      };
      write(asJson ? JSON.stringify(result) : JSON.stringify(result, null, 2));
      return 0;
    }
  } finally {
    store.close();
  }

  write(usage());
  return 64;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = runCli(process.argv.slice(2));
}
