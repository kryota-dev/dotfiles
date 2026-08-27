import { accessSync, chmodSync, constants, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { chooseRoute } from "./router.mjs";
import { createStateStore } from "./state-store.mjs";
import {
  loadVerifiedProviders,
  probeAntigravity,
  writeReadiness,
} from "./readiness.mjs";

const PROVIDER_COMMANDS = {
  antigravity: "agy",
  claude: "claude",
  codex: "codex",
};
const MANIFEST_KEYS = new Set(["commands", "domains", "capabilities"]);

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
  const scopes = [];
  for (const [key, personalSuffix, workSuffix] of [
    ["CLAUDE_CONFIG_DIR", ".claude", ".claude-r06"],
    ["CODEX_HOME", ".codex", ".codex-r06"],
  ]) {
    const value = environment[key];
    if (!value) continue;
    if (value.endsWith(workSuffix)) scopes.push("r06");
    else if (value.endsWith(personalSuffix)) scopes.push("personal");
    else scopes.push("unknown");
  }
  const uniqueScopes = [...new Set(scopes)];
  if (uniqueScopes.length === 0) return "personal";
  if (uniqueScopes.length > 1) return "unknown";
  return uniqueScopes[0];
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
  if (lstatSync(stateDirectory).isSymbolicLink()) {
    throw new Error("frontier-harness state directory must not be a symbolic link");
  }
  chmodSync(stateDirectory, 0o700);
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

function normalizeManifest(input) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError("manifest must be an object");
  }
  const unknownKey = Object.keys(input).find((key) => !MANIFEST_KEYS.has(key));
  if (unknownKey) {
    throw new TypeError(`manifest contains unsupported key: ${unknownKey}`);
  }
  for (const key of MANIFEST_KEYS) {
    if (!Array.isArray(input[key])) {
      throw new TypeError(`manifest.${key} must be an array`);
    }
    if (input[key].some((value) => typeof value !== "string" || value.length === 0)) {
      throw new TypeError(`manifest.${key} entries must be non-empty strings`);
    }
  }
  if (
    input.commands.some(
      (command) =>
        !/^(?:npm run|pnpm run|yarn run|bun run|uv run|pytest|go test|cargo test)(?: [A-Za-z0-9_./:@=-]+)+$/.test(
          command,
        ),
    )
  ) {
    throw new TypeError("manifest.commands contains an unsafe command");
  }
  if (input.domains.some((domain) => !/^(?:localhost|127\.0\.0\.1|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)$/.test(domain))) {
    throw new TypeError("manifest.domains contains an invalid domain");
  }
  if (input.capabilities.some((name) => !/^[a-z][a-z0-9._-]*$/.test(name))) {
    throw new TypeError("manifest.capabilities contains an invalid capability");
  }
  return {
    commands: [...input.commands],
    domains: [...input.domains],
    capabilities: [...input.capabilities],
  };
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
    const readinessPath =
      options.readinessPath ??
      (options.statePath
        ? options.statePath.replace(/state\.db$/, "readiness.json")
        : null);
    let verifiedProviders = options.verifiedProviders;
    if (flags.includes("--probe")) {
      const probe = options.probeProvider
        ? options.probeProvider(commandPaths.antigravity)
        : probeAntigravity(commandPaths.antigravity);
      verifiedProviders = probe.verified ? ["antigravity"] : [];
      if (readinessPath) writeReadiness(readinessPath, probe);
    } else if (!verifiedProviders && readinessPath) {
      verifiedProviders = loadVerifiedProviders(readinessPath);
    }
    const report = createDoctorReport({
      accountScope,
      commandPaths,
      config,
      verifiedProviders,
    });
    write(asJson ? JSON.stringify(report) : JSON.stringify(report, null, 2));
    return 0;
  }

  if (command === "onboard") {
    const manifestPath = flagValue(flags, "--manifest");
    const manifest = normalizeManifest(
      options.readManifest
        ? options.readManifest(manifestPath)
        : JSON.parse(readFileSync(manifestPath, "utf8")),
    );
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
  const verifiedProviders =
    options.verifiedProviders ??
    loadVerifiedProviders(statePath.replace(/state\.db$/, "readiness.json"));
  const store = createStateStore(statePath);
  try {
    if (command === "run") {
      const taskPath = flagValue(flags, "--task");
      const taskInput = JSON.parse(readFileSync(taskPath, "utf8"));
      const result = store.withTransaction(() => {
        const task = store.createTask(taskInput);
        const route = chooseRoute({
          accountScope,
          availability: providerAvailability(commandPaths, verifiedProviders),
          config,
          task: taskInput,
        });
        store.recordRoute(task.id, route);
        return {
          task,
          decision: route,
          executed: false,
          rollout: config.rollout,
        };
      });
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
        : store.pruneEvidenceBefore(
            cutoff,
            path.join(path.dirname(statePath), "evidence"),
          );
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
