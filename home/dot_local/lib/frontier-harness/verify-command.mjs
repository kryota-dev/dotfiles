import { LIVE_CANDIDATE_STATUSES } from "./candidate-store.mjs";
import {
  DEFAULT_CHECK_TIMEOUT_MS,
  runDeterministicCheck,
} from "./check-runner.mjs";
import { createGitRunner, worktreeTreeHash } from "./git-worktree.mjs";
import { BLOCKED_PENDING_APPROVAL, VERIFICATION_FAILED } from "./exit-codes.mjs";
import { flagValue, optionalFlagValue, positiveIntegerFlag } from "./flags.mjs";
import { findManifestGaps, loadVerifiedManifest } from "./manifest-policy.mjs";
import { requireAbsolutePath } from "./paths.mjs";
import { VERIFICATION_CHECK_KINDS, requireEnum } from "./record-validation.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import {
  approvedManifestStoreFor,
  candidateStoreFor,
  defaultStatePath,
  manifestGapQueueFor,
  resolvePolicyPath,
  resolveRepositoryScope,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";

// `fh verify` —— 承認済みの決定的チェックを**実際に走らせて**、その結果を記録する（#495）。
//
// これ以前の `fh verify` は `verification_plan` evidence を 1 行置くだけで、承認境界は通るが
// 何も実行しなかった。完了判定の根拠がモデルの自己申告を超えないという問題は、そこに直接
// 由来する。ここで変わるのは「計画を記録する」から「終了コードを取る」までであって、
// 承認境界・rollout guard・Evidence Bus のどれも緩めない。
//
// **task を要求する。** 検証結果は必ず何かの検証であり、`verification_results.task_id` は
// NOT NULL である。task を省ける形にすると、結果が宙に浮いて後から「何が緑だったのか」を
// 引けない。task id は `fh run` が印字する。
//
// **実行はトランザクションの外で行う。** `state-store.mjs` の `withTransaction` は
// `BEGIN IMMEDIATE`（書き込みロック）を取る。テストスイートは分単位で走りうるので、内側で
// 走らせると同じリポジトリの他の `fh` が全部詰まる。`session-command.mjs` と同じ形に揃える。
//
// **candidate の中で検証するときは `--candidate` を使う。** candidate は base commit の detached
// checkout なので、`.harness/policy.json` が未コミットならそのツリーには存在しない。`--worktree` で
// 直接指すと承認境界が「このリポジトリには承認が無い」と判定して必ず止まる（fail-closed としては
// 正しいが、隔離 → 検証 → 取り込みという本来の流れがそれでは通らない）。`--candidate` は
// **登記簿を経由**して解決する: そのツリーがこのリポジトリの持ち物であることを登記簿が保証するので、
// 承認は所有元リポジトリのものを使い、チェックだけを candidate のツリーで走らせられる。
// 呼び出し側が渡した path を信用するわけではないので、`--worktree` の gate は弱まらない。

export const DEFAULT_CHECK_KIND = "test";
// チェックに与える時間の上限。`approval-server.mjs` が escalation の待機に上限を課しているのと
// 同じ理由で、ここにも要る —— チェックの実行中はツリーの書き換えを検知できない窓（下記参照）
// なので、`--timeout-ms` を無制限にできると、その窓を任意に広げられる。
export const MAX_CHECK_TIMEOUT_MS = 3_600_000;
export const VERIFICATION_EVIDENCE_KIND = "verification_run";

const PRODUCER = "frontier-harness";

// evidence に載せてよいのは固定語彙だけ。status と checkKind はどちらも閉じた enum なので、
// ここから組み立てた文が自由文になることはない（`session-command.mjs` の sessionClaims と同じ規律）。
export function verificationClaims({ checkKind, status, timedOut }) {
  const claims = [`the deterministic ${checkKind} check ${status}`];
  if (timedOut) {
    claims.push("the check was terminated for exceeding its time limit");
  }
  return claims;
}

export async function runVerifyCommand({
  flags,
  options = {},
  environment,
  emit,
  config,
  cwd,
}) {
  const taskId = flagValue(flags, "--task");
  const command = flagValue(flags, "--command");
  const checkKind = requireEnum(
    optionalFlagValue(flags, "--kind") ?? DEFAULT_CHECK_KIND,
    VERIFICATION_CHECK_KINDS,
    "--kind",
  );
  // チェックが走るツリー。既定は呼び出し元の cwd だが、candidate worktree を検証する経路が
  // あるので明示指定できる。**承認境界と state はチェックが走るツリーから解決する** ——
  // 呼び出し元の cwd から解決すると、承認済みリポジトリの中から `--worktree` で別リポジトリを
  // 指すだけで gate を迂回できる（`session-command.mjs` が `--worktree` に対して置いた規則と同じ）。
  const worktree = requireAbsolutePath(
    optionalFlagValue(flags, "--worktree") ?? cwd,
    "--worktree",
  );
  const candidateId = optionalFlagValue(flags, "--candidate");
  const timeoutMs = Math.min(
    positiveIntegerFlag(flags, "--timeout-ms") ?? DEFAULT_CHECK_TIMEOUT_MS,
    MAX_CHECK_TIMEOUT_MS,
  );

  const statePath = options.statePath ?? defaultStatePath(worktree);
  const store = createStateStore(statePath);
  try {
    store.requireTask(taskId);

    // チェックを走らせるツリー。`--candidate` のときだけ、承認を引くツリー（リポジトリ）と
    // チェックが走るツリー（candidate）が分かれる。
    let checkCwd = worktree;
    let verifiedCandidate = null;
    if (candidateId !== undefined) {
      const candidate = candidateStoreFor(options, worktree).read(candidateId);
      if (!candidate) {
        throw new TypeError(`candidate ${candidateId} does not exist`);
      }
      if (!LIVE_CANDIDATE_STATUSES.has(candidate.status)) {
        throw new TypeError(
          `candidate ${candidateId} is ${candidate.status} and has no worktree to verify`,
        );
      }
      // **task の取り違えを通さない。** 記録は `--task` の値で行うので、ここが食い違うと
      // 「candidate A のツリーで走った合格」が task B の結果として残る。取り込み判定は
      // candidate id で照合するようになったため直接の bypass にはならないが、
      // 監査証跡が嘘になるうえ、呼び出し側の取り違えを黙って受け入れることになる。
      if (candidate.taskId !== taskId) {
        throw new TypeError(
          `candidate ${candidateId} belongs to task ${candidate.taskId}, not ${taskId}`,
        );
      }
      verifiedCandidate = candidate;
      checkCwd = candidate.worktree;
    }

    // 検証コマンドは承認境界の内側にある。未承認のまま走らせると、`fh verify` が
    // 「承認済み manifest に無い任意コマンドの実行器」になる。
    const policyPath = resolvePolicyPath(options, worktree);
    const approved = loadVerifiedManifest({
      policyPath,
      approvals: store.listApprovals(),
      scope: resolveRepositoryScope(options, worktree),
      currentApproval: approvedManifestStoreFor(options, worktree).read(policyPath),
    });
    const gaps = findManifestGaps({ manifest: approved.manifest, commands: [command] });

    const common = {
      taskId,
      checkKind,
      command,
      candidateId: candidateId ?? null,
      // 実際に効いた上限を出す。クランプされたことを呼び出し側（と運用者）が見られないと、
      // 「指定したつもりの値」と「効いている値」が静かにずれる。
      timeoutMs,
      rollout: config.rollout,
      policyIntegrity: approved.integrity,
    };

    if (gaps.length > 0) {
      // gap の記録はトランザクションの外。ファイル書き込みは SQLite のロールバックに
      // 巻き戻されないので、中で書くと「結果は無いのに gap だけ残る」不整合を作れてしまう。
      const gapQueue = manifestGapQueueFor(options, worktree);
      for (const gap of gaps) gapQueue.record(gap);
      emit({
        ...common,
        result: null,
        evidence: null,
        executed: false,
        executionReason:
          "the repository capability manifest does not approve this verification command",
        gaps,
      });
      return BLOCKED_PENDING_APPROVAL;
    }

    // **チェックが見たツリーを、走らせる前に確定させる。** 実行後にだけ hash を採ると、
    // それは「チェックが見たもの」ではなく「チェックが終わった時点のもの」になる。
    // チェックは既定 15 分走りうるので、その間に candidate のツリーへ書き込めば、
    // 検証していない内容が「検証済み」として記録される（取り込み判定はこの hash を信じる）。
    const runGit = options.runGit ?? createGitRunner();
    const treeHashBefore = verifiedCandidate
      ? worktreeTreeHash({
          worktree: verifiedCandidate.worktree,
          base: verifiedCandidate.base,
          runGit,
        })
      : null;

    // rollout guard は新しい実行経路にも必ず効かせる。`shadow` へ戻せば、承認済みの
    // コマンドであってもプロセスは 1 つも起きない。
    const guarded = runWithRolloutGuard(config, `deterministic ${checkKind} check`, () =>
      runDeterministicCheck({
        command,
        cwd: checkCwd,
        environment,
        spawn: options.spawn,
        timeoutMs,
        // CLI フラグにはしない（運用で変える値ではない）。テストが実時間で猶予を待たずに
        // SIGKILL への昇格を観測できるようにするための内部の口。
        ...(options.terminationGraceMs === undefined
          ? {}
          : { terminationGraceMs: options.terminationGraceMs }),
      }),
    );
    if (!guarded.executed) {
      emit({
        ...common,
        result: null,
        evidence: null,
        executed: false,
        executionReason: guarded.reason,
        gaps: [],
      });
      return 0;
    }

    // ここから先はトランザクションの外。await している間、書き込みロックは握っていない。
    const outcome = await guarded.result;

    // 実行後にもう一度採り、走らせる前と一致することを要求する。一致しなければ、チェックが
    // 実行中に書き換えられたツリーを見たことになり、その合否は**どのツリーについての判定でも
    // ない**。結果は監査のために残すが、`errored` にし hash を付けない —— hash の無い結果は
    // `adoptionVerdict` が取り込み根拠にしないので、fail-closed に倒れる。
    const treeHashAfter = verifiedCandidate
      ? worktreeTreeHash({
          worktree: verifiedCandidate.worktree,
          base: verifiedCandidate.base,
          runGit,
        })
      : null;
    const treeMoved = treeHashBefore !== treeHashAfter;
    const treeHash = treeMoved ? null : treeHashBefore;
    const status = treeMoved ? "errored" : outcome.status;
    const failureReason = treeMoved
      ? "the candidate worktree changed while the check was running; the result does not describe any single tree"
      : outcome.failureReason;

    const stored = store.withTransaction(() => {
      const evidence = store.putEvidence({
        kind: VERIFICATION_EVIDENCE_KIND,
        producer: PRODUCER,
        taskId,
        // 承認済み manifest と完全一致した文字列なので、自由文ではない。
        command,
        exitCode: outcome.exitCode,
        claimsSupported: verificationClaims({
          checkKind,
          status,
          timedOut: outcome.timedOut,
        }),
      });
      const result = store.recordVerificationResult({
        taskId,
        // どのツリーを検証したかを結果に焼き付ける。null は主ワークツリーに対する検証で、
        // candidate の取り込み根拠にはならない。
        candidateId: verifiedCandidate ? verifiedCandidate.id : null,
        treeHash,
        checkKind,
        status,
        command,
        exitCode: outcome.exitCode,
        evidenceId: evidence.id,
      });
      return { evidence, result };
    });

    emit({
      ...common,
      result: stored.result,
      evidence: stored.evidence,
      executed: true,
      status,
      exitCode: outcome.exitCode,
      timedOut: outcome.timedOut,
      failureReason,
      gaps: [],
    });
    return status === "passed" ? 0 : VERIFICATION_FAILED;
  } finally {
    store.close();
  }
}
