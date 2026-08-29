import { accessSync, chmodSync, constants, readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  createApprovalQueue,
} from "./approval-queue.mjs";
import {
  resolveApprovalsDirectory,
  runApprovalsCommand,
  runApproveCommand,
  startApprovalServerCommand,
} from "./approval-commands.mjs";
import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { flagValue } from "./flags.mjs";
import { sha256Hex } from "./hash.mjs";
import { ensureDirectory, writeJsonAtomic } from "./paths.mjs";
import { PROVIDER_COMMANDS } from "./providers.mjs";
import { requireObject } from "./record-validation.mjs";
import { retentionCutoffs } from "./retention.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import { chooseRoute } from "./router.mjs";
import {
  GitWorktreeUnavailableError,
  resolveGitCommonDirectory,
} from "./state-root.mjs";
import { createStateStore } from "./state-store.mjs";
import { normalizeTask } from "./task.mjs";
import { resolveTrustedPath } from "./trusted-path.mjs";
import {
  loadVerifiedModels,
  probeAntigravity,
  writeReadiness,
} from "./readiness.mjs";

const MANIFEST_KEYS = new Set(["commands", "domains", "capabilities"]);
// --dry-run は state を変更しないので、削除件数はすべて 0 で返す。
const EMPTY_RAW_PRUNE_COUNTS = Object.freeze({
  evidence: 0,
  adapterRuns: 0,
  verificationResults: 0,
  reviewFindings: 0,
});
const UNKNOWN_ACCOUNT_SCOPE = "unknown";
// account scope は readiness キャッシュのファイル名に入るため、
// パス区切りや相対参照が混ざらないことを保証する。
const ACCOUNT_SCOPE_PATTERN = /^[a-z][a-z0-9-]*$/;

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
    else scopes.push(UNKNOWN_ACCOUNT_SCOPE);
  }
  const uniqueScopes = [...new Set(scopes)];
  // 判定材料が無い（両方未設定）ときと、2 つの変数が食い違うときは、どちらも
  // 「いずれのプロファイルでもない」に倒す。以前は前者だけ personal を返しており、
  // 「想定外の値は unknown」という他の分岐と非対称だった（環境変数が未設定なだけで
  // personal 限定 capability が利用可能と判定されていた）。
  if (uniqueScopes.length !== 1) return UNKNOWN_ACCOUNT_SCOPE;
  return uniqueScopes[0];
}

function loadConfig(configPath) {
  return normalizeConfig(JSON.parse(readFileSync(configPath, "utf8")));
}

// 設定ファイルの置き場所を作業ディレクトリの内容から解決しない。
// HOME が無いまま path.join("", ...) すると cwd 相対になり、untrusted repository が
// 同梱した config が escalation 方針（risk.alwaysEscalate）や rollout を差し替えうる。
// 同じ不変条件を承認ルールのファイルも要求するため、実装は trusted-path.mjs に集約する。
function resolveConfigPath(options, environment) {
  return resolveTrustedPath({
    explicit: options.configPath,
    environment,
    envKey: "FH_CONFIG_PATH",
    homeRelative: [".config", "frontier-harness", "config.json"],
    label: "frontier-harness config",
  });
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

function defaultStateDirectory(cwd) {
  const stateDirectory = path.join(
    resolveGitCommonDirectory(cwd),
    "frontier-harness",
  );
  ensureDirectory(stateDirectory, "frontier-harness state directory");
  chmodSync(stateDirectory, 0o700);
  return stateDirectory;
}

function defaultStatePath(cwd) {
  return path.join(defaultStateDirectory(cwd), "state.db");
}

// readiness は account scope ごとに分ける。共有すると、あるプロファイルで確定した
// provider の可用性が、別プロファイルとして解決される実行に流用される。
function readinessPathFor(statePath, accountScope) {
  if (
    typeof accountScope !== "string" ||
    !ACCOUNT_SCOPE_PATTERN.test(accountScope)
  ) {
    throw new TypeError(
      `account scope ${accountScope} cannot be used as a readiness cache key`,
    );
  }
  return path.join(path.dirname(statePath), `readiness.${accountScope}.json`);
}

// doctor も run と同じ state root から readiness path を解決する。
// これが無いと `doctor --probe` の結果が保存されず、後続の `run` が常に unverified になる。
function resolveReadinessPath(options, accountScope) {
  try {
    const statePath =
      options.statePath ?? defaultStatePath(options.cwd ?? process.cwd());
    return readinessPathFor(statePath, accountScope);
  } catch (error) {
    // git working tree の外では state root を解決できないため readiness を永続化しない。
    if (error instanceof GitWorktreeUnavailableError) return null;
    // 信頼できない state root の検出は握り潰さない。
    // 握り潰すと doctor 経路だけガードが無効化される。
    throw error;
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

function normalizeManifest(input) {
  requireObject(input, "manifest");
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
    "  approvals      List pending approval requests",
    "  approve        Answer one approval request (--request <id> --allow|--deny)",
    "  approve-server Run the stdio permission prompt tool for a child session",
    "                 (--session, --approvals-dir, --rules, --timeout-ms,",
    "                  --progress-interval-ms; path flags must be absolute)",
    "  doctor  Report adapter and capability readiness",
    "  clean   Prune expired raw evidence and aggregate telemetry",
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
  const emit = (value) =>
    write(asJson ? JSON.stringify(value) : JSON.stringify(value, null, 2));

  // 承認チャネルは SQLite state も config.json も必要としない。承認待ちは既定 8 時間に
  // 及ぶため、その間 DB を開いたままにせず、無関係な config.json の生死にも巻き込まない
  // （escalation ルールを manifest と別ファイルにしたのと同じ独立性の理由）。
  if (
    command === "approve-server" ||
    command === "approvals" ||
    command === "approve"
  ) {
    const cwd = options.cwd ?? process.cwd();
    const directory = resolveApprovalsDirectory({
      flags,
      stateDirectory: () => options.stateDirectory ?? defaultStateDirectory(cwd),
    });
    if (command === "approve-server") {
      const finished = startApprovalServerCommand({
        flags,
        environment,
        cwd,
        directory,
        ...options.approvalServerIo,
      });
      // stdin を読んでいるあいだ event loop は生きている。終了コードは
      // stdio が閉じた時点で確定させる。
      finished.then(
        (code) => {
          process.exitCode = code;
        },
        (error) => {
          process.stderr.write(`frontier-harness: ${error.message}\n`);
          process.exitCode = 70;
        },
      );
      return 0;
    }
    const queue = createApprovalQueue({ directory });
    return command === "approvals"
      ? runApprovalsCommand({ queue, emit, flags })
      : runApproveCommand({ queue, emit, flags });
  }

  // 設定パスの解決は遅延させる。設定そのものを注入された呼び出しで、
  // 一度も読まないパスの解決を理由に停止しないため。
  const config =
    options.config ?? loadConfig(resolveConfigPath(options, environment));
  const commandPaths = options.commandPaths ?? defaultCommandPaths(environment);
  const accountScope = options.accountScope ?? resolveAccountScope(environment);

  if (command === "doctor") {
    let verifiedModels = options.verifiedModels;
    // state root の解決はディレクトリ作成を伴うため、必要なときだけ行う。
    const needsReadinessPath = flags.includes("--probe") || !verifiedModels;
    const readinessPath = needsReadinessPath
      ? (options.readinessPath ?? resolveReadinessPath(options, accountScope))
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
      approvalHash: sha256Hex(manifest),
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
    options.verifiedModels ??
    loadVerifiedModels(readinessPathFor(statePath, accountScope));
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
        const storedRoute = store.recordRoute(storedTask.id, route);
        // 塞いだ route は evidence として残す（#534）。routes テーブルには
        // capability / provider / 軸 / 要求値 / 実際値 の 5 つ組を入れる列が無いため、
        // 理由の追跡は evidence 側が担う。route と同じトランザクションで確定するので
        // 「route は残ったが理由は残らない」中途半端な状態を作らない。
        const blocked = route.blocked ?? [];
        const blockEvidence =
          blocked.length > 0
            ? store.putEvidence({
                kind: "route_block",
                producer: "frontier-harness",
                taskId: storedTask.id,
                routeId: storedRoute.id,
                claimsSupported: blocked.map(
                  (entry) =>
                    `${entry.capability} (${entry.provider}) was not routed: ${entry.axis} requires ${entry.required} but the provider declares ${entry.actual}`,
                ),
              })
            : null;
        // escalation は「人の判断へ戻す」ための route なので、rollout に関わらず provider を
        // 起動しない。#534 が選んだ扱い（塞いだ route は実行せず記録する）はここで初めて
        // 構造になる —— これが無いと不変条件は「rollout が shadow である」ことに依存し、
        // #502 で昇格して executor を配線した瞬間に gate が実行段ですり抜ける。
        // shadow の間は runWithRolloutGuard も executor を呼ばないため、挙動は変わらない。
        const execution =
          route.kind === "escalation"
            ? {
                executed: false,
                reason:
                  "escalation route requires user judgement; recorded without provider execution",
              }
            : runWithRolloutGuard(config, `route ${route.kind}`, options.executor);
        return {
          task: storedTask,
          decision: route,
          blocked,
          blockEvidence,
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
      // raw（evidence と実行系レコード）と集約テレメトリでは保持期間が異なる。
      // approvals は承認の監査証跡なので、どちらの cutoff でも削除しない。
      const { rawCutoff, telemetryCutoff } = retentionCutoffs(
        config.retention,
        now,
      );
      const dryRun = flags.includes("--dry-run");
      const expired = store.countExpired({ rawCutoff, telemetryCutoff });
      const pruned = dryRun
        ? { raw: EMPTY_RAW_PRUNE_COUNTS, telemetry: 0, skippedArtifacts: [] }
        : store.pruneExpired({
            rawCutoff,
            telemetryCutoff,
            artifactRoot: path.join(path.dirname(statePath), "evidence"),
          });
      emit({
        // cutoff / expiredEvidence / prunedEvidence は既存の消費側との互換のため
        // 名前と意味をそのまま残し、2 クラス分の内訳を追加で出す。
        cutoff: rawCutoff,
        telemetryCutoff,
        dryRun,
        expiredEvidence: expired.raw.evidence,
        prunedEvidence: pruned.raw.evidence,
        expiredRaw: expired.raw,
        prunedRaw: pruned.raw,
        expiredTelemetry: expired.telemetry,
        prunedTelemetry: pruned.telemetry,
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
