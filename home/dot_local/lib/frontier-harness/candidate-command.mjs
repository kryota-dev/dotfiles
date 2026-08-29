import path from "node:path";

import {
  CANDIDATE_MAX_LIVE_ENTRIES,
  LIVE_CANDIDATE_STATUSES,
  assertCandidateLabel,
  candidatesDirectory,
  createCandidateStore,
} from "./candidate-store.mjs";
import { BLOCKED_PENDING_APPROVAL, CANDIDATE_NOT_ADOPTED } from "./exit-codes.mjs";
import { flagValue, optionalFlagValue } from "./flags.mjs";
import {
  MAX_GIT_OUTPUT_BYTES,
  applyPatch,
  createDetachedWorktree,
  createGitRunner,
  createPatchWriter,
  patchApplies,
  removeWorktree,
  worktreeDiff,
} from "./git-worktree.mjs";
import { findManifestGaps, loadVerifiedManifest } from "./manifest-policy.mjs";
import { ensureDirectory } from "./paths.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import {
  approvedManifestStoreFor,
  defaultStatePath,
  manifestGapQueueFor,
  resolvePolicyPath,
  resolveRepositoryScope,
  resolveStateDirectory,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";

// `fh candidate create|list|adopt|discard` —— 書き込みを伴う多様化ルートのための
// 使い捨て子ワークツリー（#495）。
//
// **所有権を移さない。** 主ワークツリーと PR ブランチは `pr-workflow` のものである。candidate は
// detached HEAD の使い捨てで、ブランチを持たず、`pr-workflow` のブランチを置き換えない。
// 取り込みは「patch を主ワークツリーへ当てる」だけで、commit も push もしない。
//
// **`wtp` を使わない。** `.wtp.yml` の post-create hook は `.env` を新しいワークツリーへ
// symlink する。自律ルートが書き込むツリーへ credential を持ち込まないため、hook を持たない
// `git worktree add --detach` を使う。`wtp` は人が使う named worktree のための道具で、
// 使い捨ての candidate はその用途ではない。
//
// **検証を通った candidate だけを取り込む。** 判定材料はモデルの自己申告ではなく
// `verification_results` の実測で、しかも candidate 作成**以降**に記録されたものに限る
// （作成前の緑は、このツリーの中身について何も言っていない）。
//
// **衝突したら捨てずに残す。** 適用が衝突した candidate は `conflicted` にしてツリーを保持し、
// 承認待ちと同じ終了コードで user の判断へ戻す。自動で解決も破棄もしない。

export const CANDIDATE_CAPABILITY = "worktree.candidate";
export const CANDIDATE_EVIDENCE_KIND = "candidate_worktree";

const PRODUCER = "frontier-harness";
const CANDIDATE_ACTIONS = new Set(["create", "list", "adopt", "discard"]);
const DEFAULT_CANDIDATE_BASE = "HEAD";

function requireAbsolutePath(value, label) {
  if (typeof value !== "string" || !path.isAbsolute(value)) {
    throw new TypeError(`${label} must be an absolute path`);
  }
  return value;
}

// 取り込み判定。candidate 作成以降に記録された検証結果だけを見る。
export function adoptionVerdict({ candidate, results }) {
  const relevant = results.filter((result) => result.createdAt >= candidate.createdAt);
  if (relevant.length === 0) {
    return {
      verified: false,
      relevant,
      reason:
        "no deterministic verification has been recorded for this task since the candidate was created",
    };
  }
  const unmet = relevant.filter((result) => result.status !== "passed");
  if (unmet.length > 0) {
    return {
      verified: false,
      relevant,
      reason: `${unmet.length} deterministic check(s) did not pass`,
    };
  }
  return { verified: true, relevant, reason: null };
}

function candidateCreate({ flags, emit, config, worktree, store, candidates, runGit }) {
  const taskId = flagValue(flags, "--task");
  const base = optionalFlagValue(flags, "--base") ?? DEFAULT_CANDIDATE_BASE;
  const label = assertCandidateLabel(optionalFlagValue(flags, "--label") ?? null);
  if (!store.findTask(taskId)) {
    throw new TypeError(`task ${taskId} is not in the state database`);
  }

  const live = candidates.countLive();
  if (live >= CANDIDATE_MAX_LIVE_ENTRIES) {
    emit({
      action: "create",
      candidate: null,
      executed: false,
      executionReason: `${live} candidate worktrees are already open; adopt or discard one before creating another`,
    });
    return CANDIDATE_NOT_ADOPTED;
  }

  const id = candidates.newCandidateId();
  const target = candidates.worktreePathFor(id);
  // rollout guard は新しい実行経路にも効かせる。`shadow` では git を 1 回も呼ばない。
  const guarded = runWithRolloutGuard(config, "candidate worktree creation", () =>
    createDetachedWorktree({ repository: worktree, target, base, runGit }),
  );
  if (!guarded.executed) {
    emit({ action: "create", candidate: null, executed: false, executionReason: guarded.reason });
    return 0;
  }
  const baseCommit = guarded.result;

  let record;
  try {
    record = candidates.create({ id, taskId, base: baseCommit, worktree: target, label });
  } catch (error) {
    // 登記簿に載らなかったツリーを残さない。載っていないツリーは `fh candidate` からは
    // 見えないのに path を占有し続けるため、`discard` でも片付けられなくなる。
    removeWorktree({ repository: worktree, target, runGit });
    throw error;
  }

  const evidence = store.withTransaction(() =>
    store.putEvidence({
      kind: CANDIDATE_EVIDENCE_KIND,
      producer: PRODUCER,
      taskId,
      claimsSupported: ["a disposable candidate worktree was created for this task"],
    }),
  );
  emit({ action: "create", candidate: record, evidenceId: evidence.id, executed: true });
  return 0;
}

function candidateAdopt({
  flags,
  emit,
  config,
  worktree,
  store,
  candidates,
  runGit,
  writePatch,
}) {
  const candidateId = flagValue(flags, "--candidate");
  const candidate = candidates.read(candidateId);
  if (!candidate) {
    throw new TypeError(`candidate ${candidateId} does not exist`);
  }
  if (!LIVE_CANDIDATE_STATUSES.has(candidate.status)) {
    throw new TypeError(
      `candidate ${candidateId} is ${candidate.status} and has no worktree to adopt`,
    );
  }

  // 取り込みの前提は検証であって、モデルの申告ではない。ここが #495 の中心にある gate なので、
  // git を 1 回も呼ぶ前に判定する。
  const verdict = adoptionVerdict({
    candidate,
    results: store.listVerificationResultsForTask(candidate.taskId),
  });
  if (!verdict.verified) {
    emit({
      action: "adopt",
      candidate,
      adopted: false,
      executed: false,
      executionReason: verdict.reason,
      verifiedChecks: verdict.relevant.length,
    });
    return CANDIDATE_NOT_ADOPTED;
  }

  const guarded = runWithRolloutGuard(config, "candidate adoption", () => {
    // 取り込む patch は切り詰めない。切り詰めた patch は適用できないうえ、当たったとしても
    // 「一部だけ取り込まれた」状態を作る。
    const diff = worktreeDiff({
      worktree: candidate.worktree,
      base: candidate.base,
      runGit,
      maxBytes: MAX_GIT_OUTPUT_BYTES,
    });
    if (diff.truncated || diff.patch.trim().length === 0) {
      return { applied: false, empty: diff.patch.trim().length === 0, truncated: diff.truncated };
    }
    if (!patchApplies({ worktree, patch: diff.patch, runGit, writePatch })) {
      return { applied: false, empty: false, truncated: false, conflicted: true };
    }
    applyPatch({ worktree, patch: diff.patch, runGit, writePatch });
    return { applied: true };
  });
  if (!guarded.executed) {
    emit({
      action: "adopt",
      candidate,
      adopted: false,
      executed: false,
      executionReason: guarded.reason,
      verifiedChecks: verdict.relevant.length,
    });
    return 0;
  }
  const outcome = guarded.result;

  if (!outcome.applied) {
    // **衝突しても candidate を捨てない。** ツリーを残したまま状態だけを移し、
    // user の判断へ戻す。ここで自動 rebase や自動解決を試みると、検証済みだったはずの
    // 中身が黙って別物になる。
    const reason = outcome.empty
      ? "the candidate worktree has no changes to adopt"
      : outcome.truncated
        ? "the candidate diff is too large to adopt safely"
        : "the candidate does not apply cleanly to the target worktree";
    const retained = outcome.empty ? candidate : candidates.setStatus(candidate.id, "conflicted");
    const evidence = store.withTransaction(() =>
      store.putEvidence({
        kind: CANDIDATE_EVIDENCE_KIND,
        producer: PRODUCER,
        taskId: candidate.taskId,
        claimsSupported: [
          `the candidate passed ${verdict.relevant.length} deterministic check(s)`,
          "the candidate was retained for user review instead of being adopted",
        ],
      }),
    );
    emit({
      action: "adopt",
      candidate: retained,
      adopted: false,
      executed: true,
      executionReason: reason,
      verifiedChecks: verdict.relevant.length,
      evidenceId: evidence.id,
    });
    return CANDIDATE_NOT_ADOPTED;
  }

  // 取り込みが済んだツリーは使い捨てなので撤去する。中身は主ワークツリーへ移っている。
  removeWorktree({ repository: worktree, target: candidate.worktree, runGit });
  const adopted = candidates.setStatus(candidate.id, "adopted");
  const evidence = store.withTransaction(() =>
    store.putEvidence({
      kind: CANDIDATE_EVIDENCE_KIND,
      producer: PRODUCER,
      taskId: candidate.taskId,
      claimsSupported: [
        `the candidate passed ${verdict.relevant.length} deterministic check(s)`,
        "the candidate applied cleanly and was adopted into the target worktree",
      ],
    }),
  );
  emit({
    action: "adopt",
    candidate: adopted,
    adopted: true,
    executed: true,
    verifiedChecks: verdict.relevant.length,
    evidenceId: evidence.id,
  });
  return 0;
}

function candidateDiscard({ flags, emit, worktree, candidates, runGit }) {
  const candidateId = flagValue(flags, "--candidate");
  const candidate = candidates.read(candidateId);
  if (!candidate) {
    throw new TypeError(`candidate ${candidateId} does not exist`);
  }
  if (LIVE_CANDIDATE_STATUSES.has(candidate.status)) {
    removeWorktree({ repository: worktree, target: candidate.worktree, runGit });
  }
  emit({ action: "discard", candidate: candidates.setStatus(candidate.id, "discarded") });
  return 0;
}

export function runCandidateCommand({ flags, options = {}, emit, config, cwd }) {
  const action = flags[0];
  if (!CANDIDATE_ACTIONS.has(action)) {
    throw new TypeError(
      `fh candidate requires create, list, adopt, or discard, not ${action ?? "(nothing)"}`,
    );
  }
  // 承認境界・state・candidate 登記簿は、candidate を抱えるリポジトリのワークツリーから
  // 解決する（`session-command.mjs` が `--worktree` に対して置いた規則と同じ）。
  const worktree = requireAbsolutePath(
    optionalFlagValue(flags, "--worktree") ?? cwd,
    "--worktree",
  );
  const stateDirectory = resolveStateDirectory(options, worktree);
  const candidates = createCandidateStore({
    directory: ensureDirectory(candidatesDirectory(stateDirectory), "candidate directory"),
  });

  if (action === "list") {
    emit({ action: "list", candidates: candidates.list() });
    return 0;
  }

  const statePath = options.statePath ?? defaultStatePath(worktree);
  const store = createStateStore(statePath);
  try {
    // 承認境界。ここで問うのは「このリポジトリで使い捨ての書き込み可能ワークツリーを作り、
    // 検証を通った差分を主ワークツリーへ取り込んでよいか」で、その単位が capability である。
    // 個々のコマンドは `fh verify` の command gate が別に見る。
    const policyPath = resolvePolicyPath(options, worktree);
    const approved = loadVerifiedManifest({
      policyPath,
      approvals: store.listApprovals(),
      scope: resolveRepositoryScope(options, worktree),
      currentApproval: approvedManifestStoreFor(options, worktree).read(policyPath),
    });
    const gaps = findManifestGaps({
      manifest: approved.manifest,
      capabilities: [CANDIDATE_CAPABILITY],
    });
    if (gaps.length > 0) {
      const gapQueue = manifestGapQueueFor(options, worktree);
      for (const gap of gaps) gapQueue.record(gap);
      emit({
        action,
        candidate: null,
        executed: false,
        executionReason:
          "the repository capability manifest does not approve disposable candidate worktrees",
        gaps,
        policyIntegrity: approved.integrity,
      });
      return BLOCKED_PENDING_APPROVAL;
    }

    const runGit = options.runGit ?? createGitRunner();
    const context = { flags, emit, config, worktree, store, candidates, runGit };
    if (action === "create") return candidateCreate(context);
    if (action === "discard") return candidateDiscard(context);
    return candidateAdopt({
      ...context,
      writePatch: options.writePatch ?? createPatchWriter(stateDirectory),
    });
  } finally {
    store.close();
  }
}
