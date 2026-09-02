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
import {
  COMMAND_HELP,
  assertDeclaredOutput,
  commandHelpJson,
  renderCommandHelp,
  renderUsage,
  usageJson,
} from "./command-help.mjs";
import { defaultCommandPaths, providerAvailability } from "./command-paths.mjs";
import { normalizeConfig } from "./config.mjs";
import { createDoctorReport } from "./doctor.mjs";
import { describeCliFailure } from "./errors.mjs";
import { BLOCKED_PENDING_APPROVAL, USAGE } from "./exit-codes.mjs";
import { assertKnownFlags, inspectFlags } from "./flag-registry.mjs";
import {
  flagValue,
  nonNegativeIntegerFlag,
  optionalFlagValue,
  positiveIntegerFlag,
} from "./flags.mjs";
import {
  findManifestGaps,
  loadVerifiedManifest,
} from "./manifest-policy.mjs";
import { runOnboardCommand } from "./onboard-commands.mjs";
import { readJsonFile } from "./paths.mjs";
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
// `fh status` が既定で返す route 件数と、`--limit` で要求できる上限。
// state は Git の共通ディレクトリに蓄積し続ける設計なので、既定を「全件」にはしない。
export const DEFAULT_STATUS_LIMIT = 50;
export const MAX_STATUS_LIMIT = 500;
// `fh clean --dry-run` が挙げる削除対象の、クラスごとの上限。
// 一覧は「何が消えるか」を読むためのもので、全件の書き出しではない。
export const CLEAN_TARGET_PREVIEW_LIMIT = 20;
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
  return normalizeConfig(readJsonFile(configPath, "frontier-harness config"));
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


// コマンドの JSON を書き出し、`fh <command> --help` が宣言した出力契約と突き合わせる。
//
// **payload を先に書き、検査はそのあと。** 契約違反は内部の不整合であって利用者の誤りでは
// ないうえ、`session` のように子が既に走ったあとの emit もここを通る。先に落とすと
// 「何が起きたか」を再構成する手段が丸ごと消える —— この harness が最も避けたい失敗である。
// 順序そのものが不変条件なので、テストから直接叩けるよう factory として切り出してある。
export function createEmitter({ command, asJson, write }) {
  return (value) => {
    const serialized = JSON.stringify(value, null, asJson ? undefined : 2);
    write(serialized);
    // **検査するのは「実際に出た JSON」であって、その手前の JavaScript 値ではない。**
    // `undefined` を値に持つプロパティは `JSON.stringify` で出力から消えるが `Object.keys`
    // には残るため、シリアライズ前を見ると契約どおりの出力でも 70 に落ちる（`toJSON()` を
    // 持つ値でも同じ乖離が起きる）。読み手が受け取るものと同じものを検査する。
    assertDeclaredOutput(
      command,
      serialized === undefined ? serialized : JSON.parse(serialized),
    );
  };
}

// 戻り値は command で型が分かれる: `onboard`（domain のアドレス解決を伴う）、`session`
// （子プロセスの stream を読む）、`verify`（決定的チェックの完了を待つ）は
// **Promise<number>** を返し、それ以外は同期に number を返す。プログラムから呼ぶ場合は `Promise.resolve(runCli(...))` で受けるか、ファイル末尾の
// entrypoint と同じく `instanceof Promise` で分岐すること（`process.exitCode = runCli(...)` と
// 素朴に書くと、これらの経路で Promise オブジェクトが exitCode に入り静かに壊れる）。
export function runCli(argumentsList, options = {}) {
  const environment = options.environment ?? process.env;
  const write = options.write ?? ((line) => process.stdout.write(`${line}\n`));
  // 先頭が `-` で始まるならコマンド名ではない。`fh --help` を「`--help` というコマンド」と
  // 読むと、自己記述を求めた呼び出しが未知コマンド扱いで落ちる。
  const [first, ...rest] = argumentsList;
  const command =
    typeof first === "string" && !first.startsWith("-") ? first : undefined;
  const flags = command === undefined ? [...argumentsList] : rest;
  // 打ち間違えたフラグを黙って捨てない。ここは副作用の手前（state root の解決も
  // config の読み出しもまだ）なので、拒否だけが起きて何も変わらない。
  // 未知の**コマンド**はこの層の担当ではなく、下の usage が扱う。
  //
  // **`--help` もこの検査を通る。** 表に載ったから通るのであって、迂回するのではない。
  // `fh approvals --bogus --help` は今までどおり `--bogus` を名指しで拒む。
  assertKnownFlags(command, flags);
  // **`--json` / `--help` はフラグ位置に現れたときだけ効く。** 値として渡された文字列が
  // たまたま一致しただけでコマンドが help にすり替わらないよう、判定は flag-registry の
  // 走査に委ねる（`fh approve --deny --message "--help"` が承認を記録せず exit 0 で
  // 終わっていた経路を塞ぐ）。
  const { tokens, scoped, onlyGlobals } = inspectFlags(command, flags);
  const asJson = tokens.has("--json");
  // **スコープが解決していないときは、`fh session --help` の形だけを help として扱う。**
  // `fh session --bogus-flag --help` で help を出すと、`assertKnownFlags` が黙る条件
  // （action を解決できない）と重なって未知フラグが名指しされないまま exit 0 になる。
  // その場合はコマンド実装へ落として、`fh session requires launch or resume, not ...` の
  // ような名指しのエラーを先に出させる（本来この層より読まれるべき情報である）。
  if (tokens.has("--help") && (scoped || onlyGlobals)) {
    const known = command !== undefined && Object.hasOwn(COMMAND_HELP, command);
    if (known) {
      write(
        asJson
          ? JSON.stringify(commandHelpJson(command))
          : renderCommandHelp(command),
      );
      return 0;
    }
    // 打ち間違えたコマンド名を「一覧が出たので成功」と読ませない。help そのものは出す。
    write(asJson ? JSON.stringify(usageJson()) : renderUsage());
    return command === undefined ? 0 : USAGE;
  }
  const emit = createEmitter({ command, asJson, write });
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
      finished.then((code) => {
        process.exitCode = code;
      }, reportFailure);
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
      const task = normalizeTask(readJsonFile(taskPath, "task file"));
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
      // route 履歴は state root に溜まり続け、長期利用で線形に増える。既定で全件を吐くと、
      // 「直近に何が起きたか」を見たいだけの呼び出しが数千件の JSON を返す。
      const limit = Math.min(
        positiveIntegerFlag(flags, "--limit") ?? DEFAULT_STATUS_LIMIT,
        MAX_STATUS_LIMIT,
      );
      const offset = nonNegativeIntegerFlag(flags, "--offset") ?? 0;
      const page = store.listRoutePage({ limit, offset });
      emit({
        routes: page.routes,
        // 切り詰めたことを呼び出し側が「これで全部だった」と読み違えないよう、
        // 総数と続きの有無を必ず添える。
        page: {
          limit,
          offset,
          total: page.total,
          returned: page.routes.length,
          hasMore: offset + page.routes.length < page.total,
        },
      });
      return 0;
    }

    // run の結末を後から引く。`fh status` は route 決定（何を選んだか）しか持たず、
    // 結末（どう終わったか）は adapter_runs に記録済みなのに読み手が無かった。そのため
    // 起動時 JSON を流したターミナルのスクロールバックを失うと、子が成功したのか
    // 失敗したのかを確認する手段が消えていた —— 子を並列で回すほど効く欠落である。
    //
    // **起動時 JSON の全項目は返らない。** `resumeKey` / `denials` / `initHealth` /
    // `evidenceId` は adapter_runs の列に無い（session-command.mjs が emit するだけ）。
    // ここで空欄として並べると「記録されているが空だった」に見えるので、持っている列だけを返す。
    //
    // **完了条件（gate）は返る。** `verification_results.adapter_run_id` は列として存在し、
    // `fh session --gate` がそこへ書くようになったため（#573）、「この run が何本の検証を
    // 通したか」は記録から読める。`verification.total` が 0 の run は、gate を 1 本も
    // 通していない —— `status: "succeeded"` が意味するのは「ターンがエラーなく終わった」
    // だけで、指示した gate を通ったことではない。
    if (command === "runs") {
      const runId = optionalFlagValue(flags, "--run");
      if (runId !== undefined) {
        if (flags.includes("--limit") || flags.includes("--offset")) {
          throw new TypeError(
            "--run looks up a single record, so it cannot be combined with --limit or --offset",
          );
        }
        const run = store.readAdapterRun(runId);
        if (run === null) {
          throw new TypeError(`no adapter run is recorded with id ${runId}`);
        }
        // 1 件を引くときは件数だけでなく、連結された検証そのものを返す。「何を通したのか」は
        // 一覧では要らないが、1 本の run を調べているときにはそれが知りたいことである。
        emit({ run, verifications: store.listVerificationResultsForAdapterRun(runId) });
        return 0;
      }
      const limit = Math.min(
        positiveIntegerFlag(flags, "--limit") ?? DEFAULT_STATUS_LIMIT,
        MAX_STATUS_LIMIT,
      );
      const offset = nonNegativeIntegerFlag(flags, "--offset") ?? 0;
      const page = store.listAdapterRunPage({ limit, offset });
      emit({
        runs: page.runs,
        page: {
          limit,
          offset,
          total: page.total,
          returned: page.runs.length,
          hasMore: offset + page.runs.length < page.total,
        },
      });
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
      // 事前確認では「何件」ではなく「何が」消えるかを出す。消えたものは戻らないので、
      // 件数だけを見て実行に進めるようにはしない。実行時に一覧を出さないのは、
      // 「対象一覧が出た ＝ まだ消えていない」を読み手の側で取り違えさせないため。
      const targets = dryRun
        ? store.listExpired({
            rawCutoff,
            telemetryCutoff,
            limit: CLEAN_TARGET_PREVIEW_LIMIT,
          })
        : null;
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
        targets: targets
          ? { raw: targets.raw, telemetry: targets.telemetry }
          : null,
        targetsTruncated: targets?.truncated ?? false,
      });
      return 0;
    }

  } finally {
    store.close();
  }

  write(renderUsage());
  return USAGE;
}

// 失敗の見せ方を 1 か所に集める。想定内の失敗（打ち間違えたフラグ、読めないファイル、
// working tree の外での実行）は stack trace を出さず、原因が読めるメッセージだけを返す。
// 分類は errors.mjs が持ち、ここは書き出すだけにする。
function reportFailure(error) {
  const { message, exitCode } = describeCliFailure(error);
  process.stderr.write(`frontier-harness: ${message}\n`);
  process.exitCode = exitCode;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // `onboard` は domain のアドレス解決を伴うため Promise を返す。他のコマンドは同期の
  // ままなので、Promise でないときは従来どおりその場で exitCode を確定させる
  // （同期経路の挙動をマイクロタスク 1 つ分でも変えない）。
  try {
    const result = runCli(process.argv.slice(2));
    if (result instanceof Promise) {
      // **rejection を握る。** `.then` だけで受けると未処理の rejection になり、Node は
      // スタックトレースを出して落ちる —— `emit()` の JSON も、設計した終了コード契約
      // （2 = 承認待ち / 1 = 実行失敗）も一切経由しない。子が既に走ったあとで記録の書き込みが
      // 失敗した場合、それは「何が起きたか」を再構成する手段が丸ごと消えることを意味する。
      result.then((code) => {
        process.exitCode = code;
      }, reportFailure);
    } else {
      process.exitCode = result;
    }
  } catch (error) {
    // **同期経路も握る。** ここが無いと、`fh clean --now bogus` のような引数の誤りが
    // 未処理の例外として Node の stack trace で表示され、終了コードも 1 になっていた
    // ——「64 = 使い方の誤り」という契約が非同期コマンドにしか効いていなかった。
    reportFailure(error);
  }
}
