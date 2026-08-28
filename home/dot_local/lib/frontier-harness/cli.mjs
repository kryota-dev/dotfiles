import { accessSync, chmodSync, constants, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { ensureDirectory, writeJsonAtomic } from "./paths.mjs";
import { PROVIDER_COMMANDS } from "./providers.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import { chooseRoute } from "./router.mjs";
import { createStateStore } from "./state-store.mjs";
import { normalizeTask } from "./task.mjs";
import {
  loadVerifiedModels,
  probeAntigravity,
  writeReadiness,
} from "./readiness.mjs";

const MANIFEST_KEYS = new Set(["commands", "domains", "capabilities"]);

export function findCommand(command, searchPath) {
  for (const directory of searchPath.split(path.delimiter)) {
    // 空要素・相対パスは CWD 基準で解決されるため候補にしない。
    // POSIX は PATH の zero-length prefix を CWD と定義しており、そのまま join すると
    // untrusted repository が同梱した実行ファイルを provider として選んでしまう。
    if (!directory || !path.isAbsolute(directory)) continue;
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
  const value = index === -1 ? undefined : flags[index + 1];
  // 後続のフラグを値として受け取らない（`--task --json` の誤解釈を防ぐ）。
  if (!value || value.startsWith("--")) {
    throw new TypeError(`${name} requires a value`);
  }
  return value;
}

function defaultStatePath(cwd) {
  const commonDirectory = execFileSync(
    "git",
    ["rev-parse", "--git-common-dir"],
    { cwd, encoding: "utf8" },
  ).trim();
  const absoluteCommonDirectory = path.resolve(cwd, commonDirectory);
  const stateDirectory = path.join(absoluteCommonDirectory, "frontier-harness");
  ensureDirectory(stateDirectory, "frontier-harness state directory");
  chmodSync(stateDirectory, 0o700);
  return path.join(stateDirectory, "state.db");
}

function readinessPathFor(statePath) {
  return path.join(path.dirname(statePath), "readiness.json");
}

// doctor も run と同じ state root から readiness path を解決する。
// これが無いと `doctor --probe` の結果が保存されず、後続の `run` が常に unverified になる。
function resolveReadinessPath(options) {
  try {
    const statePath =
      options.statePath ?? defaultStatePath(options.cwd ?? process.cwd());
    return readinessPathFor(statePath);
  } catch {
    // git repository 外では state root を解決できないため readiness を永続化しない。
    return null;
  }
}

function providerAvailability(commandPaths, verifiedModels = {}) {
  return Object.fromEntries(
    Object.keys(PROVIDER_COMMANDS).map((provider) => {
      const executable = Boolean(commandPaths[provider]);
      if (provider !== "antigravity") {
        return [provider, { available: executable, models: null }];
      }
      const models = Object.hasOwn(verifiedModels, "antigravity")
        ? verifiedModels.antigravity
        : null;
      const verified = Array.isArray(models) && models.length > 0;
      return [
        provider,
        { available: executable && verified, models: verified ? models : null },
      ];
    }),
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
  const emit = (value) =>
    write(asJson ? JSON.stringify(value) : JSON.stringify(value, null, 2));

  if (command === "doctor") {
    let verifiedModels = options.verifiedModels;
    // state root の解決はディレクトリ作成を伴うため、必要なときだけ行う。
    const needsReadinessPath = flags.includes("--probe") || !verifiedModels;
    const readinessPath = needsReadinessPath
      ? (options.readinessPath ?? resolveReadinessPath(options))
      : null;
    if (flags.includes("--probe")) {
      const probe = options.probeProvider
        ? options.probeProvider(commandPaths.antigravity)
        : probeAntigravity(commandPaths.antigravity);
      verifiedModels = probe.verified ? { antigravity: probe.models ?? [] } : {};
      if (readinessPath) writeReadiness(readinessPath, probe);
    } else if (!verifiedModels && readinessPath) {
      verifiedModels = loadVerifiedModels(readinessPath);
    }
    emit(
      createDoctorReport({
        accountScope,
        commandPaths,
        config,
        verifiedModels: verifiedModels ?? {},
      }),
    );
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
    // `.harness` が symlink の repository で書き込み先が脱出しないよう、
    // symlink 検査 + O_EXCL + 予測不能な一時名を使う共通ヘルパーを経由する。
    writeJsonAtomic(policyPath, policy, "repository policy");
    emit({ approved: true, policyPath, approvalHash: policy.approvalHash });
    return 0;
  }

  const statePath = options.statePath ?? defaultStatePath(options.cwd ?? process.cwd());
  const verifiedModels =
    options.verifiedModels ?? loadVerifiedModels(readinessPathFor(statePath));
  const store = createStateStore(statePath);
  try {
    if (command === "run") {
      const taskPath = flagValue(flags, "--task");
      // task JSON は未検証の外部入力として境界で正規化する。
      const task = normalizeTask(JSON.parse(readFileSync(taskPath, "utf8")));
      const result = store.withTransaction(() => {
        const storedTask = store.createTask(task);
        const route = chooseRoute({
          accountScope,
          availability: providerAvailability(commandPaths, verifiedModels),
          config,
          task,
        });
        store.recordRoute(storedTask.id, route);
        const execution = runWithRolloutGuard(
          config,
          `route ${route.kind}`,
          options.executor,
        );
        return {
          task: storedTask,
          decision: route,
          executed: execution.executed,
          executionReason: execution.reason,
          rollout: config.rollout,
        };
      });
      emit(result);
      return 0;
    }

    if (command === "status") {
      emit({ routes: store.listRoutes() });
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
      const dryRun = flags.includes("--dry-run");
      const expiredEvidence = store.countEvidenceBefore(cutoff);
      const pruned = dryRun
        ? { prunedEvidence: 0, skippedArtifacts: [] }
        : store.pruneEvidenceBefore(
            cutoff,
            path.join(path.dirname(statePath), "evidence"),
          );
      emit({
        cutoff,
        dryRun,
        expiredEvidence,
        prunedEvidence: pruned.prunedEvidence,
        skippedArtifacts: pruned.skippedArtifacts,
      });
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
      const execution = runWithRolloutGuard(
        config,
        "verification command",
        options.executor,
      );
      emit({
        evidence,
        executed: execution.executed,
        executionReason: execution.reason,
        rollout: config.rollout,
      });
      return 0;
    }

    if (command === "review") {
      const taskId = flagValue(flags, "--task");
      const evidence = store.putEvidence({
        kind: "review_plan",
        producer: "frontier-harness",
        claimsSupported: [`independent review planned for ${taskId}`],
      });
      const execution = runWithRolloutGuard(
        config,
        "independent review",
        options.executor,
      );
      emit({
        evidence,
        executed: execution.executed,
        executionReason: execution.reason,
        rollout: config.rollout,
        taskId,
      });
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
