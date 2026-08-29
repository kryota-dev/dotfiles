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
import { assertResolvedDomainAllowed } from "./address-classifier.mjs";
import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { flagValue } from "./flags.mjs";
import {
  createManifestGapQueue,
  manifestGapsDirectory,
} from "./manifest-gaps.mjs";
import {
  REPOSITORY_MANIFEST_APPROVAL_KIND,
  findManifestGaps,
  loadVerifiedManifest,
  manifestEntryRejection,
  manifestHash,
  normalizeManifest,
} from "./manifest-policy.mjs";
import {
  createOnboardRequestStore,
  onboardRequestsDirectory,
} from "./onboard-requests.mjs";
import { ensureDirectory, writeJsonAtomic } from "./paths.mjs";
import { PROVIDER_COMMANDS } from "./providers.mjs";
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

// 承認待ちで実行を止めたときの終了コード。`onboard` が「まだ承認していない」に使っていた
// ものを、承認境界が実行を止めた全経路（run / verify）へ広げる。0 と区別できないと、
// 呼び出し側スクリプトが「承認が要る」を「成功」と読んでしまう。
const BLOCKED_PENDING_APPROVAL = 2;
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

// 承認ストア（onboard request / manifest gap）は state root 配下に置く。
// repository 側へ置くと、checkout が「承認済みの request」や「空の gap queue」を同梱でき、
// 儀式そのものが迂回される。テストは statePath / stateDirectory を注入して git 非依存にできる。
function resolveStateDirectory(options, cwd) {
  if (options.stateDirectory) return options.stateDirectory;
  if (options.statePath) return path.dirname(options.statePath);
  return defaultStateDirectory(cwd);
}

// 承認台帳の scope。repository の同一性をこれで表し、別 repository から持ち込んだ
// policy.json が台帳突合を通らないようにする。
//
// state root（`<gitCommonDir>/frontier-harness`）をそのまま使う。git common dir を直接
// 引き直さないのは、state path が注入された経路（テスト・埋め込み利用）でも同じ値が
// 得られるようにするため。どちらも repository を一意に指すので識別子としては等価。
function resolveRepositoryScope(options, cwd) {
  return options.repositoryScope ?? resolveStateDirectory(options, cwd);
}

function resolvePolicyPath(options, cwd) {
  return options.policyPath ?? path.join(cwd, ".harness", "policy.json");
}

function manifestGapQueueFor(options, cwd) {
  return createManifestGapQueue({
    directory: manifestGapsDirectory(resolveStateDirectory(options, cwd)),
  });
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
    "  gaps    List command/domain/capability requests the manifest did not approve",
    "  onboard Review and approve the repository capability manifest, in two steps:",
    "            fh onboard --manifest <path>            review; prints a request id",
    "            fh onboard --manifest <path> --approve --request <id>",
    "          --from-gaps builds the candidate from the approved manifest plus",
    "          everything queued by `fh gaps`",
    "  run     Record a shadow route for a task JSON file",
    "  status  Show recorded route decisions",
    "  verify  Record a deterministic verification plan",
    "  review  Record an independent review plan",
  ].join("\n");
}

const GAP_KIND_TO_MANIFEST_KEY = Object.freeze({
  command: "commands",
  domain: "domains",
  capability: "capabilities",
});

// `fh onboard --from-gaps` の候補 manifest。承認済み manifest に、queue に溜まった gap のうち
// manifest へ載せられるものを足す。載せられないもの（`curl …` のように承認対象外の形、
// 内部アドレスを指す domain など）は落として理由と一緒に報告する。1 件の不正で一括承認全体が
// 止まると、wave 境界でまとめて承認するという目的が果たせない。落とした側は未承認のまま残る
// ので、fail-closed は維持される。
function candidateFromGaps(approvedManifest, gaps) {
  const candidate = {
    commands: [...approvedManifest.commands],
    domains: [...approvedManifest.domains],
    capabilities: [...approvedManifest.capabilities],
  };
  const included = [];
  const rejected = [];
  for (const gap of gaps) {
    const key = GAP_KIND_TO_MANIFEST_KEY[gap.kind];
    const rejection = manifestEntryRejection(key, gap.value);
    if (rejection) {
      rejected.push({ kind: gap.kind, value: gap.value, reason: rejection });
      continue;
    }
    if (!candidate[key].includes(gap.value)) candidate[key].push(gap.value);
    included.push(gap);
  }
  return { candidate, included, rejected };
}

async function runOnboardCommand({ flags, options, emit }) {
  const cwd = options.cwd ?? process.cwd();
  const fromGaps = flags.includes("--from-gaps");
  // 承認する対象を 2 通りに指定させない。片方を黙って無視すると、レビューした manifest と
  // 承認した manifest が食い違いうる。
  if (fromGaps && flags.includes("--manifest")) {
    throw new TypeError(
      "--from-gaps builds the candidate manifest itself; pass either --from-gaps or --manifest",
    );
  }
  const stateDirectory = resolveStateDirectory(options, cwd);
  const requests = createOnboardRequestStore({
    directory: onboardRequestsDirectory(stateDirectory),
  });
  const gapQueue = manifestGapQueueFor(options, cwd);
  const policyPath = resolvePolicyPath(options, cwd);
  const scope = resolveRepositoryScope(options, cwd);
  const statePath = options.statePath ?? defaultStatePath(cwd);
  const store = createStateStore(statePath);

  try {
    let candidate;
    let includedGaps = [];
    let rejectedGaps = [];
    if (fromGaps) {
      const approved = loadVerifiedManifest({
        policyPath,
        approvals: store.listApprovals(),
        scope,
      });
      const built = candidateFromGaps(approved.manifest, gapQueue.list());
      candidate = normalizeManifest(built.candidate);
      includedGaps = built.included;
      rejectedGaps = built.rejected;
    } else {
      const manifestPath = flagValue(flags, "--manifest");
      candidate = normalizeManifest(
        options.readManifest
          ? options.readManifest(manifestPath)
          : JSON.parse(readFileSync(manifestPath, "utf8")),
      );
    }

    // 承認の両側でアドレス解決を行う。レビュー時点で落とすのは利用者への親切で、
    // 承認時点でもう一度見るのは、レビューから承認までの間に DNS の答えが変わる場合を
    // 拾うため（承認を通すのは承認時点の解決結果に責任を持つ側）。
    for (const domain of candidate.domains) {
      await assertResolvedDomainAllowed(domain, { lookup: options.lookup });
    }
    const hash = manifestHash(candidate);

    if (!flags.includes("--approve")) {
      const request = requests.create({
        manifest: candidate,
        manifestHash: hash,
        pid: options.pid,
      });
      emit({
        approved: false,
        manifest: candidate,
        approvalHash: hash,
        request: { id: request.id, expiresAt: request.expiresAt },
        reason:
          "review the manifest above, then approve it in a separate run with --approve --request <id>",
        ...(fromGaps
          ? { gapsIncluded: includedGaps, gapsRejected: rejectedGaps }
          : {}),
      });
      return BLOCKED_PENDING_APPROVAL;
    }

    // ここが自己承認の遮断点。`--request` を欠く `--approve` は、レビュー段階を一度も
    // 通っていないことを意味する（id は step 1 の出力にしか現れない）。
    if (!flags.includes("--request")) {
      throw new TypeError(
        "--approve requires --request <id> from a previous review run; a manifest cannot be reviewed and approved in the same invocation",
      );
    }
    requests.consume({
      id: flagValue(flags, "--request"),
      manifestHash: hash,
      pid: options.pid,
    });

    const approval = store.recordApproval({
      kind: REPOSITORY_MANIFEST_APPROVAL_KIND,
      subjectHash: hash,
      scope,
      grantedBy: "user",
      grantedAt: new Date().toISOString(),
    });
    const policy = {
      version: 1,
      approvedAt: approval.grantedAt,
      approvalHash: hash,
      approvalId: approval.id,
      manifest: candidate,
    };
    // `.harness` が symlink の repository で書き込み先が脱出しないよう、
    // symlink 検査 + O_EXCL + 予測不能な一時名を使う共通ヘルパーを経由する。
    writeJsonAtomic(policyPath, policy, "repository policy");
    if (fromGaps) gapQueue.clear(includedGaps);
    emit({
      approved: true,
      policyPath,
      approvalHash: hash,
      approvalId: approval.id,
      scope,
      ...(fromGaps
        ? { gapsApproved: includedGaps, gapsRejected: rejectedGaps }
        : {}),
    });
    return 0;
  } finally {
    store.close();
  }
}

export function runCli(argumentsList, options = {}) {
  const environment = options.environment ?? process.env;
  const write = options.write ?? ((line) => process.stdout.write(`${line}\n`));
  const [command, ...flags] = argumentsList;
  const asJson = flags.includes("--json");
  const emit = (value) =>
    write(asJson ? JSON.stringify(value) : JSON.stringify(value, null, 2));
  const cwd = options.cwd ?? process.cwd();

  // 承認チャネルは SQLite state も config.json も必要としない。承認待ちは既定 8 時間に
  // 及ぶため、その間 DB を開いたままにせず、無関係な config.json の生死にも巻き込まない
  // （escalation ルールを manifest と別ファイルにしたのと同じ独立性の理由）。
  if (
    command === "approve-server" ||
    command === "approvals" ||
    command === "approve"
  ) {
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

  // gap queue も state root だけを読む。承認境界が実行を止めた記録を確認するのに
  // capability registry は要らないので、config.json の有無に巻き込まない
  // （config を未デプロイの環境で `fh gaps` が落ちると、なぜ止まったのかを調べる手段が消える）。
  if (command === "gaps") {
    emit({ gaps: manifestGapQueueFor(options, cwd).list() });
    return 0;
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

  // onboard だけは domain のアドレス解決を伴うため Promise を返す。呼び出し側
  // （下の entrypoint とテスト）はこの 1 コマンドだけ await すればよく、他のコマンドの
  // 同期な戻り値の契約は変えない。
  if (command === "onboard") {
    return runOnboardCommand({ flags, options, emit });
  }

  const statePath = options.statePath ?? defaultStatePath(cwd);
  const verifiedModels =
    options.verifiedModels ??
    loadVerifiedModels(readinessPathFor(statePath, accountScope));
  const store = createStateStore(statePath);
  try {
    if (command === "run") {
      const taskPath = flagValue(flags, "--task");
      // task JSON は未検証の外部入力として境界で正規化する。
      const task = normalizeTask(JSON.parse(readFileSync(taskPath, "utf8")));
      const approved = loadVerifiedManifest({
        policyPath: resolvePolicyPath(options, cwd),
        approvals: store.listApprovals(),
        scope: resolveRepositoryScope(options, cwd),
      });
      const result = store.withTransaction(() => {
        const storedTask = store.createTask(task);
        const route = chooseRoute({
          accountScope,
          availability: providerAvailability(commandPaths, verifiedModels),
          config,
          task,
        });
        // 承認境界はここで効く。route が選んだ capability と、task が宣言した
        // command / domain を承認済み manifest と突き合わせ、1 つでも欠ければ
        // provider へ渡さず escalation として記録する。
        const gaps = findManifestGaps({
          manifest: approved.manifest,
          commands: task.commands,
          domains: task.domains,
          capability: route.capability,
        });
        if (gaps.length > 0) {
          const blocked = {
            kind: "escalation",
            capability: null,
            provider: null,
            reason: `${gaps.length} request(s) are not covered by the approved repository capability manifest: ${approved.integrity.reason ?? "see gaps"}`,
          };
          store.recordRoute(storedTask.id, blocked);
          return {
            task: storedTask,
            decision: blocked,
            executed: false,
            executionReason:
              "the repository capability manifest does not approve this task",
            rollout: config.rollout,
            gaps,
            policyIntegrity: approved.integrity,
          };
        }
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
          gaps: [],
          policyIntegrity: approved.integrity,
        };
      });
      // gap の記録はトランザクションの外で行う。ファイル書き込みは SQLite の
      // ロールバックに巻き戻されないので、中で書くと「route は無いのに gap だけ残る」
      // 不整合を作れてしまう。
      const gapQueue = manifestGapQueueFor(options, cwd);
      for (const gap of result.gaps) gapQueue.record(gap);
      emit(result);
      return result.gaps.length > 0 ? BLOCKED_PENDING_APPROVAL : 0;
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
      // 検証コマンドも承認境界の内側にある。未承認のまま計画を記録すると、
      // rollout が昇格した時点でその計画がそのまま実行対象になる。
      const approved = loadVerifiedManifest({
        policyPath: resolvePolicyPath(options, cwd),
        approvals: store.listApprovals(),
        scope: resolveRepositoryScope(options, cwd),
      });
      const gaps = findManifestGaps({
        manifest: approved.manifest,
        commands: [verificationCommand],
      });
      if (gaps.length > 0) {
        const gapQueue = manifestGapQueueFor(options, cwd);
        for (const gap of gaps) gapQueue.record(gap);
        emit({
          evidence: null,
          executed: false,
          executionReason:
            "the repository capability manifest does not approve this verification command",
          rollout: config.rollout,
          gaps,
          policyIntegrity: approved.integrity,
        });
        return BLOCKED_PENDING_APPROVAL;
      }
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
        gaps: [],
        policyIntegrity: approved.integrity,
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
  // `onboard` は domain のアドレス解決を伴うため Promise を返す。他のコマンドは同期の
  // ままなので、Promise でないときは従来どおりその場で exitCode を確定させる
  // （同期経路の挙動をマイクロタスク 1 つ分でも変えない）。
  const result = runCli(process.argv.slice(2));
  if (result instanceof Promise) {
    result.then((code) => {
      process.exitCode = code;
    });
  } else {
    process.exitCode = result;
  }
}
