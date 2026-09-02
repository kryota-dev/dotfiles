import { randomUUID } from "node:crypto";
import { readFileSync, statSync } from "node:fs";

import { codexHomeFor } from "./adapter-claude.mjs";
import { adapterRunStatusFor, requireSafeArgumentValue } from "./adapter-contract.mjs";
import { createAdapterExecutor } from "./adapters.mjs";
import {
  APPROVAL_PROMPT_TOOL,
  approvalServerDeclaration,
  assertSessionProvider,
  probeApprovalServer,
  resolveApprovalServerCommand,
} from "./approval-channel.mjs";
import { resolveApprovalsDirectory } from "./approval-commands.mjs";
import { createChildRunner } from "./child-runner.mjs";
import { providerAvailability } from "./command-paths.mjs";
import { BLOCKED_PENDING_APPROVAL, CHILD_RUN_FAILED } from "./exit-codes.mjs";
import {
  flagValue,
  optionalFlagValue,
  positiveIntegerFlag,
  repeatedFlagValues,
} from "./flags.mjs";
import { findManifestGaps, loadVerifiedManifest } from "./manifest-policy.mjs";
import { providerCommand } from "./providers.mjs";
import { loadVerifiedModels } from "./readiness.mjs";
import { requireAbsolutePath } from "./paths.mjs";
import { nowIso } from "./record-validation.mjs";
import { isProviderExecutionAllowed, runWithRolloutGuard } from "./rollout.mjs";
import { allowsWrite, normalizeSandboxPolicy } from "./sandbox.mjs";
import {
  gateBriefing,
  gateClaims,
  gateTimeoutMs,
  parseGateDeclaration,
  resolveGate,
  runSessionGates,
} from "./session-gate.mjs";
import {
  approvedManifestStoreFor,
  defaultStatePath,
  manifestGapQueueFor,
  readinessPathFor,
  resolvePolicyPath,
  resolveRepositoryScope,
  resolveStateDirectory,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";
import { VERIFICATION_EVIDENCE_KIND, verificationClaims } from "./verify-command.mjs";

// `fh session launch|resume` —— wave-orchestrator の子セッションを非対話で起こす（#537）。
//
// **router を通さない。** `chooseRoute` は `executor.default`（承認チャネルを持たない provider）を
// 選ぶため、人の gate が要る task は必ず escalation になる。子の model / effort は
// `model-fitness-check` の contract が決めるものであって routing 判断ではないので、capability を
// 名前で指定する。routing の意味論には触れず、capability registry・承認境界（manifest）・
// rollout guard・Evidence Bus という既存の fail-closed 層はすべて通す。
//
// **会話内容を記録しない。** prompt はファイルからのみ読み（`fh` の argv に本文を載せない）、
// `tasks.goal` は呼び出し側の文字列ではなく導出値にし、evidence の claim は固定語彙に限る。

// 子を起こしてよい account。`cli.mjs` の `resolveAccountScope` が返す語彙のうち、
// 実際にパスへ解決できるものだけを並べる（`unknown` は含めない）。
const KNOWN_ACCOUNT_SCOPES = new Set(["personal", "r06"]);

export const DEFAULT_SESSION_CAPABILITY = "session.child";
// 子は自分のワークツリーへ書く。read-only では pr-workflow が走らない。
export const DEFAULT_SESSION_SANDBOX = "workspace-write";
export const SESSION_EVIDENCE_KIND = "child_session";

// 子は自分に課された sandbox の効き方を、**失敗する前に**知る必要がある。
//
// 実運用で 2 セッションとも、実装・テスト・文書を終えたあと commit で初めて「署名 socket が
// 塞がれている」ことを知り、そこで止まった（作業は無事だが、往復が 1 回増える）。これを
// 「各 prompt に書く」運用ルールで塞ごうとすると必ず書き漏れるので、**sandbox を課している
// 側が構造的に伝える**。ここに置くのは fh 自身が決めた固定の語彙だけで、呼び出し側の
// 自由文は入らない（記録に会話内容を残さない方針と衝突しない）。
//
// 許可ドメインの実体は adapter が持つ（SANDBOX_ALLOWED_DOMAINS）。ここで文面に埋め込むと
// drift するので、説明は「PR を出す先だけが開いている」という不変の性質に留める。
const SANDBOX_BRIEFING = [
  "<sandbox>",
  "このセッションは frontier-harness が課した sandbox の下で走っている。次の 3 点は仕様であり、",
  "回避策を探す対象ではない。",
  "",
  "1. **outbound 通信は許可リストに載ったホストだけに開いている。** GitHub と、主要な言語の",
  "   パッケージレジストリ（npm / RubyGems / PyPI / Go module proxy）が対象。それ以外への通信は",
  "   プロンプトを出さずに拒否される。**塞がれたら迂回路を組み立てず、どのホストが必要だったかを",
  "   報告すること** —— 許可リストは harness 側の固定値で、あなたには変更できない。",
  "2. **commit 署名は使えない。** 1Password の agent socket へは接続できないので、`git commit` は",
  "   `git -c commit.gpgsign=false commit ...` の形で署名を切って実行する。中間コミットが未署名に",
  "   なるのは意図した運用で、main へ入る squash コミットは GitHub 側が署名する。",
  "3. **`dangerouslyDisableSandbox` は無効化されている。** sandbox の外へ出る抜け道は無い。",
  "4. **git の TLS バックエンドは環境変数で secure-transport に固定済み。** 何もしなくてよい。",
  "   `error setting certificate verify locations` を見たら、その git 呼び出しが環境を落として",
  "   いる（`env -i` 等）ので、環境を渡す形に直すこと。CA バンドルを自前で用意しない。",
  "",
  "上記で塞がれた操作に出会ったら、迂回路を組み立てず、AskUserQuestion で確認すること。",
  "</sandbox>",
  "",
  "",
].join("\n");

const PRODUCER = "frontier-harness";
const SESSION_ACTIONS = new Set(["launch", "resume"]);
// route_decisions.kind の語彙。子セッションは 1 つの capability が単独で走るので single-worker。
const ROUTE_KIND = "single-worker";
// 台帳の相関に使う識別子。wave の識別子（ブランチ名由来）を想定する。会話内容ではないが、
// 自由文の混入を防ぐため字集合を絞る。
const LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,119}$/;
// 拒否ツール名の上限。子の stdout 由来の値を evidence へ載せる前に縛る。
const DENIAL_NAME_MAX_LENGTH = 128;

function requireWorktree(value) {
  const worktree = requireAbsolutePath(value, "--worktree");
  let stat;
  try {
    stat = statSync(worktree);
  } catch (error) {
    throw new TypeError(`--worktree is not accessible: ${error.message}`);
  }
  if (!stat.isDirectory()) {
    throw new TypeError("--worktree must be a directory");
  }
  return worktree;
}

// prompt をファイルからのみ受け取る。argv 経由で渡すと、同一ホストの他プロセスから
// `ps` で本文が読める（子の argv には adapter が載せるので完全には避けられないが、
// `fh` 自身が増やす経路は作らない）。
function readPrompt(flags) {
  const target = requireAbsolutePath(flagValue(flags, "--prompt-file"), "--prompt-file");
  const prompt = readFileSync(target, "utf8").trim();
  if (prompt.length === 0) {
    throw new TypeError("--prompt-file must not be empty");
  }
  return prompt;
}

function readLabel(flags) {
  const label = optionalFlagValue(flags, "--label");
  if (label === undefined) return null;
  if (!LABEL_PATTERN.test(label)) {
    throw new TypeError(`--label must match ${LABEL_PATTERN}`);
  }
  return label;
}

// 完了条件の宣言を読む。`--gate` は繰り返せる。
//
// **承認境界の内側にある。** ここで読んだコマンドは capability と同じ `findManifestGaps` に
// 掛かるので、未承認の gate を宣言したセッションは子を起こす前に exit 2 で止まる。数時間
// 走ったあとで「その gate は承認されていない」と分かる形にはしない。
function readGates(flags) {
  return repeatedFlagValues(flags, "--gate").map(parseGateDeclaration);
}

function selectCapability(config, capabilityName) {
  // 設定由来のキーで引くので、Object.prototype の継承プロパティを capability として拾わない
  // （router.mjs / adapters.mjs と同じ扱い）。
  if (!Object.hasOwn(config.capabilities, capabilityName)) {
    throw new TypeError(
      `capability ${capabilityName} is not in the capability registry`,
    );
  }
  const capability = config.capabilities[capabilityName];
  assertSessionProvider(capability.provider);
  return capability;
}

// evidence に載せてよいのは固定語彙と、会話内容を含まない識別子だけ。
function sessionClaims({ action, sandbox, health, outcome, gate }) {
  const claims = [
    `child session ${action} ran under the ${sandbox.mode} sandbox`,
    `startup health check reported ${health?.healthy ? "healthy" : "unhealthy"}`,
    // gate を宣言したか、通ったかは、この run の記録そのものに属する事実である。
    // 一覧側（`fh runs`）は連結された verification_results の件数から同じことを読む。
    ...gateClaims(gate),
  ];
  for (const problem of health?.problems ?? []) {
    claims.push(`startup health problem: ${problem}`);
  }
  if (outcome?.resumeKey) claims.push(`resume key ${outcome.resumeKey}`);
  // 拒否されたツールは**名前だけ**（adapter-claude の denialNames が tool_input を落とす）。
  // 名前そのものは子の未検証な stdout 由来なので、長さも縛る（failureReason 側は
  // adapter-contract が既に truncate しており、evidence へ載る値の扱いをそれに揃える）。
  for (const name of outcome?.denials ?? []) {
    claims.push(`the child was denied the ${name.slice(0, DENIAL_NAME_MAX_LENGTH)} tool`);
  }
  return claims;
}

function healthFailureReason(health) {
  return health?.problems?.length ? health.problems.join("; ") : null;
}

export async function runSessionCommand({
  flags,
  options = {},
  environment,
  emit,
  config,
  commandPaths,
  accountScope,
  stderr = process.stderr,
}) {
  const action = flags[0];
  if (!SESSION_ACTIONS.has(action)) {
    throw new TypeError(
      `fh session requires launch or resume, not ${action ?? "(nothing)"}`,
    );
  }

  // account が読めないまま子を起こさない。
  //
  // `CLAUDE_CONFIG_DIR` はランチャーが呼び出しごとに設定するもので、シェルには export されない。
  // 素の tmux ペイン（skill が起動場所として指示している場所）にはこの変数が無く、
  // `resolveAccountScope` は `unknown` を返す。それでも子は起動できてしまい、
  //
  //   - account に紐づくパス（codex home 等）が解決できず、その機能だけが静かに落ちる
  //   - `accountScope` を宣言した capability は拒否される
  //   - readiness キャッシュが `unknown` キーで書かれる
  //
  // という劣化が、**外形上は正常な起動と見分けられないまま**続く（実際に wave 1 本分を
  // この状態で走らせた）。起動時に落として原因を読めるようにするほうがよい。
  if (!KNOWN_ACCOUNT_SCOPES.has(accountScope)) {
    emit({
      action,
      executed: false,
      executionReason:
        "the account scope could not be resolved; launch with CLAUDE_CONFIG_DIR set so the child inherits an account",
      accountScope: accountScope ?? null,
    });
    return BLOCKED_PENDING_APPROVAL;
  }

  const capabilityName =
    optionalFlagValue(flags, "--capability") ?? DEFAULT_SESSION_CAPABILITY;
  const capability = selectCapability(config, capabilityName);
  const worktree = requireWorktree(flagValue(flags, "--worktree"));
  const gates = readGates(flags);
  // 制約の説明と完了条件を先に置く。呼び出し側の prompt はそのまま後ろに続く。
  const prompt = `${SANDBOX_BRIEFING}${gateBriefing(gates)}${readPrompt(flags)}`;
  const label = readLabel(flags);
  const sandbox = normalizeSandboxPolicy(
    { mode: optionalFlagValue(flags, "--sandbox") ?? DEFAULT_SESSION_SANDBOX },
    "--sandbox",
  );

  // 再開キーはそのまま子の session id である（#526 §1.3: `--resume <uuid>` で同じ
  // session_id のまま続く）。承認要求に刻む session も同じ値にしないと、`fh approvals` から
  // どの子の問いかを引けなくなる。
  //
  // **副作用より前に検証する。** この値は stderr へ出て、label 未指定なら `tasks.goal` にも
  // 入る。adapter 側の検証（requireSafeArgumentValue）まで待つと、貼り間違えた自由文が
  // 「起動は失敗したのに state には残る」形で残留する。adapter と**同じ検証器**を通すことで、
  // 通る形が 2 か所で食い違うこともない。
  const resumeKey =
    action === "resume"
      ? requireSafeArgumentValue(flagValue(flags, "--resume-key"), "--resume-key")
      : null;
  const sessionId =
    action === "resume"
      ? resumeKey
      : requireSafeArgumentValue(
          optionalFlagValue(flags, "--session-id") ?? randomUUID(),
          "--session-id",
        );

  // **完走を待たずに出す。** 停止すると `ps` の argv という情報源が消えるため、
  // 台帳へ記録できるのがここしかない局面がある（wave の「中断と再開」）。
  stderr.write(`${PRODUCER}: child session ${sessionId}\n`);

  const executable = commandPaths[capability.provider];
  if (!executable) {
    throw new Error(
      `${providerCommand(capability.provider)} is not on PATH as an absolute entry; the child cannot be started`,
    );
  }

  // 承認境界・state・承認 queue はすべて**子が走るワークツリー**から解決する。
  //
  // 呼び出し元の cwd から解決すると、承認済みリポジトリの中から `--worktree` で別リポジトリを
  // 指すだけで capability gate を迂回できる（manifest は cwd 側、実行は worktree 側になる）。
  // 「どのリポジトリで自律的な子を走らせてよいか」を問うている以上、その単位は子の作業ツリーで
  // なければならない。linked worktree は git common directory を共有するので、同一リポジトリ内の
  // ワークツリーから起動した場合の解決先は変わらない。
  const repositoryRoot = worktree;
  const approvalsDir = resolveApprovalsDirectory({
    flags,
    stateDirectory: () => resolveStateDirectory(options, repositoryRoot),
  });
  const approvalServer = approvalServerDeclaration({
    command: resolveApprovalServerCommand({
      explicit: optionalFlagValue(flags, "--approval-server-command"),
      environment,
    }),
    sessionId,
    approvalsDirectory: approvalsDir,
    // 既定値を持たない。渡されたときだけフラグを足し、既定は approval-server.mjs に委ねる。
    timeoutMs: positiveIntegerFlag(flags, "--timeout-ms"),
    progressIntervalMs: positiveIntegerFlag(flags, "--progress-interval-ms"),
  });

  const statePath = options.statePath ?? defaultStatePath(repositoryRoot);
  const verifiedModels =
    options.verifiedModels ??
    loadVerifiedModels(readinessPathFor(statePath, accountScope));
  const store = createStateStore(statePath);
  try {
    const policyPath = resolvePolicyPath(options, repositoryRoot);
    const approved = loadVerifiedManifest({
      policyPath,
      approvals: store.listApprovals(),
      scope: resolveRepositoryScope(options, repositoryRoot),
      currentApproval: approvedManifestStoreFor(options, repositoryRoot).read(policyPath),
    });
    // 承認境界はここで効く。子は任意のコマンドを走らせるので command 単位では宣言できない
    // —— そちらは承認チャネル（approval-rules）が実行時に受け持つ。ここで問うのは
    // 「このリポジトリで自律的な子セッションを走らせてよいか」であり、その単位が capability である。
    //
    // 完了条件（`--gate`）は逆に command 単位で宣言されている。`fh` が終了後に自分で
    // 起こすプロセスなので、`fh verify` と同じく承認済み manifest との照合を通す。
    const gaps = findManifestGaps({
      manifest: approved.manifest,
      capabilities: [capabilityName],
      commands: gates.map((gate) => gate.command),
    });
    const blocked = gaps.length > 0;

    // route と task は、止まった場合も含めて必ず残す（なぜ止まったかの監査証跡）。
    // **実行はこのトランザクションの外で行う** —— 子は数時間走りうるので、内側で実行すると
    // その間ずっと書き込みロックを握り、同じリポジトリの他の子の `fh` が全部詰まる。
    const recorded = store.withTransaction(() => {
      const storedTask = store.createTask({
        // 呼び出し側から goal 文字列を受け取らない。prompt 本文が tasks 行へ流れ込む経路を作らない。
        goal: `wave child session ${label ?? sessionId}`,
        requiresApproval: true,
        requiresWrite: allowsWrite(sandbox),
      });
      const storedRoute = store.recordRoute(
        storedTask.id,
        blocked
          ? {
              kind: "escalation",
              capability: null,
              provider: null,
              reason: `${gaps.length} request(s) are not covered by the approved repository capability manifest: ${approved.integrity.reason ?? "see gaps"}`,
            }
          : {
              kind: ROUTE_KIND,
              capability: capabilityName,
              provider: capability.provider,
              model: capability.model,
              effort: capability.effort,
              reason:
                "child session runs an explicitly selected capability; the router does not choose it",
            },
      );
      return { task: storedTask, route: storedRoute };
    });

    const common = {
      action,
      capability: capabilityName,
      sessionId,
      taskId: recorded.task.id,
      routeId: recorded.route.id,
      rollout: config.rollout,
      policyIntegrity: approved.integrity,
    };

    if (blocked) {
      // gap の記録はトランザクションの外。ファイル書き込みは SQLite のロールバックに
      // 巻き戻されないので、中で書くと「route は無いのに gap だけ残る」不整合を作れてしまう。
      const gapQueue = manifestGapQueueFor(options, repositoryRoot);
      for (const gap of gaps) gapQueue.record(gap);
      emit({
        ...common,
        executed: false,
        // 何が承認されていないのかを名指しする。capability と完了条件では、承認の取り方も
        // 直し方も違う（前者は onboard、後者は gate コマンドの承認）。
        executionReason: gaps.every((gap) => gap.kind === "command")
          ? "the repository capability manifest does not approve this completion gate command"
          : "the repository capability manifest does not approve this capability",
        gaps,
      });
      return BLOCKED_PENDING_APPROVAL;
    }

    // 承認 server が本当に喋ることを**子を起こす前に**確かめる。sealInvocation は
    // 「配線されたフラグが揃っているか」しか見ないので、宣言の指す先が動くことは別途要る。
    // rollout が provider 実行を許さないなら、そもそも子を起こさないので probe もしない。
    if (isProviderExecutionAllowed(config)) {
      const probe = probeApprovalServer({
        command: approvalServer.command,
        args: approvalServer.args,
        spawn: options.probeSpawn,
      });
      if (!probe.ok) {
        emit({
          ...common,
          executed: false,
          executionReason: `the approval channel is not usable: ${probe.reason}`,
          gaps: [],
        });
        return CHILD_RUN_FAILED;
      }
    }

    const runner = createChildRunner({
      cwd: worktree,
      permissionPromptTool: APPROVAL_PROMPT_TOOL,
      spawn: options.spawn,
      stderr,
    });
    const executor = createAdapterExecutor({
      accountScope,
      // 関数で渡す。値で固定すると executor 生成から実行までの間に readiness が失効しても
      // 「実行直前に再検査した」ことにならない。
      availability: () => providerAvailability(commandPaths, verifiedModels),
      capability,
      capabilityName,
      request: {
        executable,
        prompt,
        sandbox,
        // 子は親の CLAUDE_CONFIG_DIR を継承し、codex ランチャーがそこから CODEX_HOME を
        // 決める。したがって子の codex home は account で決まる。両 account 分を開けると
        // profile 分離が崩れるので、scope に対応する 1 つだけを渡す（未知なら null）。
        codexHome: codexHomeFor(accountScope, environment.HOME),
        // launch と resume で adapter が読むキーが違う。両方を同時に渡さない
        // （resumeKey が非 null だと adapters.mjs は resume 経路を選ぶ）。
        ...(action === "resume" ? { resumeKey } : { sessionId }),
        permissionPromptTool: APPROVAL_PROMPT_TOOL,
        approvalServer,
      },
      runner: runner.run,
    });

    const guarded = runWithRolloutGuard(config, `child session ${action}`, executor);
    if (!guarded.executed) {
      emit({ ...common, executed: false, executionReason: guarded.reason, gaps: [] });
      return 0;
    }

    // 実行そのものが例外で終わる経路（spawn の ENOENT / EACCES / EMFILE 等）を、
    // 未処理の rejection にしない。**子は既に走ったかもしれない**ので、記録を残さずに
    // クラッシュするのが最悪の失敗になる（監査証跡が丸ごと消える）。
    let outcome;
    const attemptedAt = nowIso();
    try {
      outcome = await guarded.result;
    } catch (error) {
      const reason = `the child process could not be run: ${error.message}`;
      const failure = store.withTransaction(() =>
        store.recordAdapterRun({
          taskId: recorded.task.id,
          routeId: recorded.route.id,
          capability: capabilityName,
          provider: capability.provider,
          model: capability.model,
          effort: capability.effort,
          status: "failed",
          startedAt: attemptedAt,
          finishedAt: nowIso(),
          failureReason: reason,
        }),
      );
      emit({
        ...common,
        executed: true,
        status: "failed",
        outcome: "failed",
        failureReason: reason,
        adapterRunId: failure.id,
        gaps: [],
      });
      return CHILD_RUN_FAILED;
    }
    const health = runner.initHealth();
    // 起動時検査が unhealthy なら、provider の結果が何であれ成功と読まない。
    // runner は子を終わらせているので通常は結果イベントが無く failed になるが、
    // 判定を「子が何を出したか」だけに委ねない（fail-closed の二重化）。
    const unhealthy = health !== null && health.healthy !== true;

    if (!outcome.ranProvider) {
      emit({
        ...common,
        executed: false,
        executionReason: outcome.reason,
        outcome: outcome.outcome,
        gaps: [],
      });
      return CHILD_RUN_FAILED;
    }

    const childOutcome = unhealthy ? "failed" : outcome.outcome;

    // 完了条件の検証。**子が成功したときにだけ走らせる。**
    //
    // 失敗した子のツリーで gate を走らせても、既に確定している failed を確認するだけで、
    // 通らないチェックの結果が「gate が赤だった」として記録に増える。ここで問いたいのは
    // 「ターンはエラーなく終わったが、指示した gate を通っているか」であって、その問いは
    // 子が成功したときにしか立たない。
    //
    // **実行はトランザクションの外。** チェックは既定 15 分走りうるので、内側で走らせると
    // 同じリポジトリの他の `fh` が全部詰まる（子の実行と同じ理由）。
    let gateResults = [];
    let gateNotRunReason = null;
    if (gates.length > 0 && childOutcome === "succeeded") {
      // rollout guard を通す。ここへ到達するのは子が実際に走ったとき（= shadow ではない）
      // だけだが、プロセスを起こす経路はすべてこのガードの内側にある、という不変条件を
      // 構造で保つ（`fh verify` が決定的チェックに対して置いているのと同じ形）。
      const guardedGates = runWithRolloutGuard(
        config,
        "session completion gate checks",
        () =>
          runSessionGates({
            gates,
            cwd: worktree,
            environment,
            // 子の spawn（`options.spawn`）とは別の口にする。同じ口を共有すると、
            // 子を fake で観測するテストが gate の終了コードまで肩代わりしてしまい、
            // 「gate が赤でも緑に見える」という、この issue が直そうとしている失敗の
            // ミニチュアをテスト側に作ることになる（`options.probeSpawn` と同じ形）。
            spawn: options.gateSpawn,
            timeoutMs: gateTimeoutMs(positiveIntegerFlag(flags, "--gate-timeout-ms")),
            ...(options.terminationGraceMs === undefined
              ? {}
              : { terminationGraceMs: options.terminationGraceMs }),
          }),
      );
      if (guardedGates.executed) {
        gateResults = await guardedGates.result;
      } else {
        gateNotRunReason = guardedGates.reason;
      }
    } else if (gates.length > 0) {
      gateNotRunReason = "the child session did not succeed, so no gate check was run";
    }

    // gate は結果を下方向にしか動かさない。`indeterminate` は `adapterRunStatusFor` が
    // failed へ写すので、adapter_runs の status 語彙は増えない。
    const resolved = resolveGate({
      gates,
      results: gateResults,
      notRunReason: gateNotRunReason,
      childOutcome,
    });
    const sessionOutcome = resolved.outcome;
    const status = adapterRunStatusFor(sessionOutcome);
    const failureReason =
      (unhealthy ? healthFailureReason(health) : null) ??
      resolved.failureReason ??
      outcome.failureReason;
    const gate = {
      gates,
      verdict: resolved.verdict,
      reason: gateNotRunReason,
      results: gateResults,
    };
    const stored = store.withTransaction(() => {
      const run = store.recordAdapterRun({
        taskId: recorded.task.id,
        routeId: recorded.route.id,
        capability: capabilityName,
        provider: capability.provider,
        model: capability.model,
        effort: capability.effort,
        status,
        startedAt: outcome.startedAt,
        finishedAt: outcome.finishedAt,
        exitCode: outcome.exitCode,
        failureReason,
      });
      const evidence = store.putEvidence({
        kind: SESSION_EVIDENCE_KIND,
        producer: PRODUCER,
        taskId: recorded.task.id,
        routeId: recorded.route.id,
        exitCode: outcome.exitCode,
        claimsSupported: sessionClaims({ action, sandbox, health, outcome, gate }),
      });
      // **ここが #573 の連結そのもの。** verification_results.adapter_run_id は最初から
      // 列としてあったが、書く実装がどこにも無かった。この 1 本の紐付けによって、
      // 「succeeded で終わった run」と「gate を通った run」が記録だけで区別できる。
      const verifications = gateResults.map((result) => {
        const checkEvidence = store.putEvidence({
          kind: VERIFICATION_EVIDENCE_KIND,
          producer: PRODUCER,
          taskId: recorded.task.id,
          routeId: recorded.route.id,
          // 承認済み manifest と完全一致した文字列なので、自由文ではない。
          command: result.command,
          exitCode: result.exitCode,
          claimsSupported: verificationClaims({
            checkKind: result.kind,
            status: result.status,
            timedOut: result.timedOut,
          }),
        });
        return store.recordVerificationResult({
          taskId: recorded.task.id,
          adapterRunId: run.id,
          checkKind: result.kind,
          status: result.status,
          command: result.command,
          exitCode: result.exitCode,
          evidenceId: checkEvidence.id,
        });
      });
      return { run, evidence, verifications };
    });

    emit({
      ...common,
      executed: true,
      provider: capability.provider,
      model: capability.model,
      effort: capability.effort,
      sandbox: sandbox.mode,
      status,
      // 3 値のまま返す。「gate を通っていない」は outcome を潰さず、下の `gate` が語る。
      outcome: sessionOutcome,
      childOutcome,
      exitCode: outcome.exitCode,
      resumeKey: outcome.resumeKey,
      denials: outcome.denials,
      failureReason,
      initHealth: {
        healthy: health === null ? null : health.healthy,
        problems: health?.problems ?? [],
      },
      gate: {
        status: resolved.status,
        reason: gateNotRunReason,
        declared: gates.map((entry) => ({ kind: entry.kind, command: entry.command })),
        results: gateResults.map((result, index) => ({
          verificationResultId: stored.verifications[index].id,
          kind: result.kind,
          command: result.command,
          status: result.status,
          exitCode: result.exitCode,
          timedOut: result.timedOut,
          failureReason: result.failureReason,
        })),
      },
      adapterRunId: stored.run.id,
      evidenceId: stored.evidence.id,
      gaps: [],
    });
    return status === "succeeded" ? 0 : CHILD_RUN_FAILED;
  } finally {
    store.close();
  }
}
