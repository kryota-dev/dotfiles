import { readFileSync } from "node:fs";
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
import { runCandidateCommand } from "./candidate-command.mjs";
import { defaultCommandPaths, providerAvailability } from "./command-paths.mjs";
import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { BLOCKED_PENDING_APPROVAL, INTERNAL_ERROR, USAGE } from "./exit-codes.mjs";
import { flagValue } from "./flags.mjs";
import {
  findManifestGaps,
  loadVerifiedManifest,
} from "./manifest-policy.mjs";
import { runOnboardCommand } from "./onboard-commands.mjs";
import { retentionCutoffs } from "./retention.mjs";
import { runReviewCommand } from "./review-command.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import { chooseRoute } from "./router.mjs";
import { runSessionCommand } from "./session-command.mjs";
import { runVerifyCommand } from "./verify-command.mjs";
import {
  approvedManifestStoreFor,
  defaultStateDirectory,
  defaultStatePath,
  manifestGapQueueFor,
  readinessPathFor,
  resolvePolicyPath,
  resolveReadinessPath,
  resolveRepositoryScope,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";
import { normalizeTask } from "./task.mjs";
import { resolveTrustedPath } from "./trusted-path.mjs";
import {
  loadVerifiedModels,
  probeAntigravity,
  writeReadiness,
} from "./readiness.mjs";

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

function usage() {
  return [
    "Usage: frontier-harness <command> [--json]",
    "",
    "Commands:",
    "  approvals      List pending approval requests (--all, or --purge to drop decided ones)",
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
    "  session Launch or resume a child session through the approval channel:",
    "            fh session launch --worktree <abs> --prompt-file <abs>",
    "            fh session resume --worktree <abs> --prompt-file <abs> --resume-key <id>",
    "          Optional: --capability (default session.child), --session-id, --label,",
    "          --sandbox, --approvals-dir, --approval-server-command, --timeout-ms,",
    "          --progress-interval-ms. Path flags must be absolute.",
    "  status  Show recorded route decisions",
    "  verify  Run an approved deterministic check and record its result:",
    "            fh verify --task <task id> --command <approved command>",
    "          Optional: --kind (default test), --worktree <abs>, --timeout-ms,",
    "          --candidate <id> to run the check inside a candidate worktree.",
    "          Exits 0 only when the check passed.",
    "  review  Hand a reviewer a packet, and take findings back into the registry:",
    "            fh review packet --task <task id> --out <abs> [--base <rev>]",
    "            fh review record --task <task id> --findings <abs>",
    "          A packet carries the task, constraints, diff, and verification",
    "          results, and has no channel for the writer's conversation.",
    "  candidate  Manage disposable child worktrees for write-capable routes:",
    "            fh candidate create --task <task id> [--base <rev>] [--label <l>]",
    "            fh candidate list",
    "            fh candidate adopt --candidate <id>",
    "            fh candidate discard --candidate <id>",
    "          Adoption requires deterministic checks recorded after creation;",
    "          a candidate that conflicts is retained, never discarded.",
  ].join("\n");
}

// 戻り値は command で型が分かれる: `onboard`（domain のアドレス解決を伴う）、`session`
// （子プロセスの stream を読む）、`verify`（決定的チェックの完了を待つ）は
// **Promise<number>** を返し、それ以外は同期に number を返す。プログラムから呼ぶ場合は `Promise.resolve(runCli(...))` で受けるか、ファイル末尾の
// entrypoint と同じく `instanceof Promise` で分岐すること（`process.exitCode = runCli(...)` と
// 素朴に書くと、これらの経路で Promise オブジェクトが exitCode に入り静かに壊れる）。
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
          process.exitCode = INTERNAL_ERROR;
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

  // onboard は domain のアドレス解決を伴うため Promise を返す。呼び出し側
  // （下の entrypoint とテスト）はこのコマンドを await すればよく、他のコマンドの
  // 同期な戻り値の契約は変えない。
  if (command === "onboard") {
    return runOnboardCommand({ flags, options, emit });
  }

  // session も同じく Promise を返す。子の構造化出力を stream で読み、最初の `system/init` で
  // 起動時検査を行う（事後検査にすると、gate を失った子が丸ごと 1 タスク走ったあとになる）。
  // state store はコマンド側が自分で開閉する —— 子は数時間走りうるので、下の try/finally の
  // ように「コマンド実行の間ずっと開いたまま」にしない。
  //
  // **cwd を渡さない。** 承認境界・state・承認 queue は子が走るワークツリーから解決する
  // （呼び出し元の cwd から解決すると `--worktree` で別リポジトリを指すだけで gate を迂回できる）。
  if (command === "session") {
    return runSessionCommand({
      flags,
      options,
      environment,
      emit,
      config,
      commandPaths,
      accountScope,
      ...(options.sessionIo ?? {}),
    });
  }

  // verify / review / candidate も session と同じく、state store を自分で開閉する。
  // 決定的チェックは分単位で走りうるし、candidate の git 操作もフルチェックアウトを伴うため、
  // 下の try/finally のように「コマンド実行の間ずっと開いたまま」にはしない。
  // 承認境界・state も、それぞれのコマンドが対象とするワークツリーから解決する。
  if (command === "verify") {
    return runVerifyCommand({ flags, options, environment, emit, config, cwd });
  }

  if (command === "review") {
    return runReviewCommand({ flags, options, emit, config, cwd });
  }

  if (command === "candidate") {
    return runCandidateCommand({ flags, options, emit, config, cwd });
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
      const policyPath = resolvePolicyPath(options, cwd);
      const approved = loadVerifiedManifest({
        policyPath,
        approvals: store.listApprovals(),
        scope: resolveRepositoryScope(options, cwd),
        currentApproval: approvedManifestStoreFor(options, cwd).read(policyPath),
      });
      const recorded = store.withTransaction(() => {
        const storedTask = store.createTask(task);
        const route = chooseRoute({
          accountScope,
          availability: providerAvailability(commandPaths, verifiedModels),
          config,
          task,
        });
        // 承認境界はここで効く。route が選んだ capability（reviewer 側も provider を
        // 選ぶ軸なので含める）と、task が宣言した command / domain を承認済み manifest と
        // 突き合わせ、1 つでも欠ければ escalation へ差し替える。
        const gaps = findManifestGaps({
          manifest: approved.manifest,
          commands: task.commands,
          domains: task.domains,
          capabilities: [route.capability, route.reviewerCapability],
        });
        // #534 の「塞いだ route は escalation として記録する」と同じ形に揃える。
        // 別種の route を作らず kind を escalation にすることで、下の
        // 「escalation は provider を起動しない」ガードがそのまま manifest gate にも効く。
        const effectiveRoute =
          gaps.length > 0
            ? {
                kind: "escalation",
                capability: null,
                provider: null,
                reason: `${gaps.length} request(s) are not covered by the approved repository capability manifest: ${approved.integrity.reason ?? "see gaps"}`,
              }
            : route;
        const storedRoute = store.recordRoute(storedTask.id, effectiveRoute);
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
        return {
          task: storedTask,
          route: effectiveRoute,
          blocked,
          blockEvidence,
          gaps,
        };
      });
      // **executor をトランザクションの外へ出す。** 以前はここが `withTransaction` の内側に
      // あり、`BEGIN IMMEDIATE` の書き込みロックを握ったまま provider を待つ形だった。
      // 通常の CLI 利用では executor を渡さないため実害は出ていなかったが、#502 で配線した
      // 瞬間に「同じリポジトリの他の `fh` が全部詰まる」に変わる罠だった。記録用トランザクション
      // → 実行 → という順序は `session-command.mjs` および `verify-command.mjs` と同じ形である。
      //
      // escalation は「人の判断へ戻す」ための route なので、rollout に関わらず provider を
      // 起動しない。#534 が選んだ扱い（塞いだ route は実行せず記録する）はここで構造になる
      // —— これが無いと不変条件は「rollout が shadow である」ことに依存し、#502 で昇格して
      // executor を配線した瞬間に gate が実行段ですり抜ける。manifest の gap による escalation も
      // この経路を通るため、承認境界も同じ構造で守られる。
      const execution =
        recorded.route.kind === "escalation"
          ? {
              executed: false,
              reason:
                recorded.gaps.length > 0
                  ? "the repository capability manifest does not approve this task"
                  : "escalation route requires user judgement; recorded without provider execution",
            }
          : runWithRolloutGuard(
              config,
              `route ${recorded.route.kind}`,
              options.executor,
            );
      // gap の記録もトランザクションの外で行う。ファイル書き込みは SQLite の
      // ロールバックに巻き戻されないので、中で書くと「route は無いのに gap だけ残る」
      // 不整合を作れてしまう。
      const gapQueue = manifestGapQueueFor(options, cwd);
      for (const gap of recorded.gaps) gapQueue.record(gap);
      emit({
        task: recorded.task,
        decision: recorded.route,
        blocked: recorded.blocked,
        blockEvidence: recorded.blockEvidence,
        executed: execution.executed,
        executionReason: execution.reason,
        rollout: config.rollout,
        gaps: recorded.gaps,
        policyIntegrity: approved.integrity,
      });
      return recorded.gaps.length > 0 ? BLOCKED_PENDING_APPROVAL : 0;
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

  } finally {
    store.close();
  }

  write(usage());
  return USAGE;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // `onboard` は domain のアドレス解決を伴うため Promise を返す。他のコマンドは同期の
  // ままなので、Promise でないときは従来どおりその場で exitCode を確定させる
  // （同期経路の挙動をマイクロタスク 1 つ分でも変えない）。
  const result = runCli(process.argv.slice(2));
  if (result instanceof Promise) {
    // **rejection を握る。** `.then` だけで受けると未処理の rejection になり、Node は
    // スタックトレースを出して落ちる —— `emit()` の JSON も、設計した終了コード契約
    // （2 = 承認待ち / 1 = 実行失敗）も一切経由しない。子が既に走ったあとで記録の書き込みが
    // 失敗した場合、それは「何が起きたか」を再構成する手段が丸ごと消えることを意味する。
    result.then(
      (code) => {
        process.exitCode = code;
      },
      (error) => {
        // 引数の検証はすべて TypeError で落ちる。使い方の誤りを内部エラーと同じコードで
        // 返すと、呼び出し側スクリプトが「直せる誤り」と「直せない不整合」を区別できない。
        const usageError = error instanceof TypeError;
        process.stderr.write(
          `frontier-harness: ${usageError ? error.message : (error?.stack ?? error)}\n`,
        );
        process.exitCode = usageError ? USAGE : INTERNAL_ERROR;
      },
    );
  } else {
    process.exitCode = result;
  }
}
