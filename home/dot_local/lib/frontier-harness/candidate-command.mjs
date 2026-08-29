import { existsSync } from "node:fs";

import {
  CANDIDATE_MAX_LIVE_ENTRIES,
  LIVE_CANDIDATE_STATUSES,
  assertCandidateLabel,
} from "./candidate-store.mjs";
import { BLOCKED_PENDING_APPROVAL, CANDIDATE_NOT_ADOPTED } from "./exit-codes.mjs";
import { flagValue, optionalFlagValue } from "./flags.mjs";
import {
  MAX_ADOPTABLE_DIFF_BYTES,
  applyPatch,
  createDetachedWorktree,
  createGitRunner,
  createPatchWriter,
  patchApplies,
  removeWorktree,
  worktreeSnapshot,
} from "./git-worktree.mjs";
import { findManifestGaps, loadVerifiedManifest } from "./manifest-policy.mjs";
import { requireAbsolutePath } from "./paths.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import {
  approvedManifestStoreFor,
  candidateStoreFor,
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

// 取り込み判定。
//
// **この candidate のツリーで走った検証だけを見る。** task と時刻だけで絞ると、同じ task の
// 別 candidate を検証した合格が、一度も検証していない candidate の取り込み根拠として流用できる
// （C1 を検証 → その結果は C2 の作成時刻より後なので C2 の条件も満たす、という経路）。
// `candidate_id` の一致を要求することで、その借用を塞ぐ。
//
// **合格したときの中身と、今から取り込む中身が同じであることも要求する。** 合格後に candidate の
// ツリーへ書き込めば、検証していない差分を「検証済み」として取り込めてしまう。`treeHash` は
// 検証時点のツリーを指すので、取り込み直前に再計算して突き合わせる。
export function adoptionVerdict({ candidate, results, treeHash = null }) {
  const forCandidate = results.filter(
    (result) =>
      result.candidateId === candidate.id && result.createdAt >= candidate.createdAt,
  );
  if (forCandidate.length === 0) {
    return {
      verified: false,
      relevant: forCandidate,
      reason:
        "no deterministic verification has been recorded for this candidate since it was created",
    };
  }
  // 検証時に tree hash を採れていない結果（旧スキーマの行）は根拠にしない。
  // 「hash が無いから素通し」にすると、この gate を無効化する最も簡単な方法になる。
  const pinned = forCandidate.filter((result) => result.treeHash);
  // **「今から取り込むツリー」についての結果だけを見る。** 別のツリーに対する結果は、
  // 合否どちらであれこのツリーについて何も言っていない。全件一致を要求すると、
  // 書き換えて再検証しても古い結果が永久に残って二度と取り込めなくなる。
  const relevant = pinned.filter((result) => result.treeHash === treeHash);
  if (relevant.length === 0) {
    return {
      verified: false,
      relevant,
      reason:
        pinned.length === 0
          ? `${forCandidate.length} deterministic check(s) did not record the tree they verified`
          : "the candidate worktree changed after it was verified; re-run the check before adopting",
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
  store.requireTask(taskId);

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

  // **取り込み判定も rollout guard の内側で行う。** 判定には「今のツリーの hash」が要り、
  // それ自体が git の実プロセスを起こす。guard の外へ出すと `shadow` でも git が動き、
  // 「戻せば何も起きない」が 1 経路だけ破れる（`review packet` / `discard` と同じ穴）。
  const guarded = runWithRolloutGuard(config, "candidate adoption", () => {
    // 取り込みの前提は検証であって、モデルの申告ではない。ここが #495 の中心にある gate。
    // **hash と patch を同じ stage から取る。** 別々に取ると、その間にツリーが書き換わったとき
    // 「hash は検証済みのツリー T、patch は未検証の T'」という組み合わせが成立してしまい、
    // hash 照合が patch について何も保証しなくなる。
    const diff = worktreeSnapshot({
      worktree: candidate.worktree,
      base: candidate.base,
      runGit,
      maxBytes: MAX_ADOPTABLE_DIFF_BYTES,
    });
    const verdict = adoptionVerdict({
      candidate,
      results: store.listVerificationResultsForTask(candidate.taskId),
      // 「今から取り込む中身」の hash。検証時に記録した hash と突き合わせる。
      treeHash: diff.treeHash,
    });
    if (!verdict.verified) return { verdict, applied: false, unverified: true };

    if (diff.truncated || diff.patch.trim().length === 0) {
      return {
        verdict,
        applied: false,
        empty: diff.patch.trim().length === 0,
        truncated: diff.truncated,
      };
    }
    if (!patchApplies({ worktree, patch: diff.patch, runGit, writePatch })) {
      return { verdict, applied: false, empty: false, truncated: false, conflicted: true };
    }
    applyPatch({ worktree, patch: diff.patch, runGit, writePatch });
    return { verdict, applied: true };
  });
  if (!guarded.executed) {
    emit({
      action: "adopt",
      candidate,
      adopted: false,
      executed: false,
      executionReason: guarded.reason,
    });
    return 0;
  }
  const outcome = guarded.result;
  const verdict = outcome.verdict;

  // 検証を通っていない candidate は、ツリーに一切触れずに断る。
  if (outcome.unverified) {
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

  // **登記簿を先に進めてからツリーを撤去する。** 逆順だと、撤去は成功したのに登記簿の
  // 書き込みが失敗した場合に「live なのに実体が無い」状態で固着し、`adopt` も `discard` も
  // 通らなくなる。先に adopted にしておけば、撤去に失敗しても残るのは「adopted なのにツリーが
  // 残っている」という、手で消せる側の不整合になる。
  const adopted = candidates.setStatus(candidate.id, "adopted");
  removeWorktree({ repository: worktree, target: candidate.worktree, runGit });
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

function candidateDiscard({ flags, emit, config, worktree, candidates, runGit }) {
  const candidateId = flagValue(flags, "--candidate");
  const candidate = candidates.read(candidateId);
  if (!candidate) {
    throw new TypeError(`candidate ${candidateId} does not exist`);
  }
  // **登記簿の状態ではなく、ツリーの実在で判断する。** 撤去の途中で失敗すると「登記簿は
  // discarded なのにツリーが残る」状態になりうる。状態だけを見て早期 return すると、その
  // 孤児を CLI から片付ける手段が無くなる。`discard` を冪等にして回復経路を残す。
  if (!existsSync(candidate.worktree)) {
    const settled = LIVE_CANDIDATE_STATUSES.has(candidate.status)
      ? candidates.setStatus(candidate.id, "discarded")
      : candidate;
    emit({
      action: "discard",
      candidate: settled,
      executed: false,
      executionReason: "the candidate worktree is already gone",
    });
    return 0;
  }
  // 撤去も git の実プロセスを起こすので rollout guard を通す。`shadow` でツリーが消えると、
  // 「shadow へ戻せば何も起きない」という非常停止レバーの意味が壊れる。
  const guarded = runWithRolloutGuard(config, "candidate worktree removal", () => {
    // **登記簿を先に進めてからツリーを撤去する**（`candidateAdopt` と同じ順序）。逆順だと、
    // 撤去は成功したのに登記簿の書き込みが失敗した場合に「live なのに実体が無い」状態で
    // 固着し、`adopt` も `discard` も通らなくなる。
    const discarded = candidates.setStatus(candidate.id, "discarded");
    removeWorktree({ repository: worktree, target: candidate.worktree, runGit });
    return discarded;
  });
  if (!guarded.executed) {
    emit({ action: "discard", candidate, executed: false, executionReason: guarded.reason });
    return 0;
  }
  emit({ action: "discard", candidate: guarded.result, executed: true });
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
  const candidates = candidateStoreFor(options, worktree);

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
