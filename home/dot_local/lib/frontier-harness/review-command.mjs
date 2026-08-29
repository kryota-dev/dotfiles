import { readFileSync } from "node:fs";

import { VERIFICATION_FAILED } from "./exit-codes.mjs";
import { flagValue, optionalFlagValue } from "./flags.mjs";
import { createGitRunner } from "./git-worktree.mjs";
import { loadVerifiedManifest } from "./manifest-policy.mjs";
import { runWithRolloutGuard } from "./rollout.mjs";
import { requireAbsolutePath, writeJsonToChosenPath } from "./paths.mjs";
import { buildReviewPacket } from "./review-packet.mjs";
import {
  normalizeFindingsDocument,
  reviewClaims,
  reviewVerdict,
} from "./review-registry.mjs";
import {
  approvedManifestStoreFor,
  defaultStatePath,
  resolvePolicyPath,
  resolveRepositoryScope,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";

// `fh review packet|record` —— レビューを「計画の記録」から registry へ変える（#495）。
//
//   packet: reviewer へ渡してよいものだけを組み立てて書き出す（会話履歴は渡さない）。
//   record: 返ってきた finding を正規化して registry へ入れ、verdict を返す。
//
// **2 つを 1 コマンドにまとめない。** packet は provider を起こさず、record は git を触らない。
// 分けておくことで、実際に reviewer を走らせるのは既存の `fh session`（承認チャネル付きの
// 子セッション）に任せられる —— provider を起こす経路をもう 1 本作らない、という #537 の
// 決定をそのまま引き継ぐ。

export const REVIEW_EVIDENCE_KIND = "review_findings";
export const DEFAULT_REVIEW_BASE = "HEAD";

const PRODUCER = "frontier-harness";
const REVIEW_ACTIONS = new Set(["packet", "record"]);

function reviewPacketCommand({ flags, options, emit, config, worktree, store }) {
  const taskId = flagValue(flags, "--task");
  const out = requireAbsolutePath(flagValue(flags, "--out"), "--out");
  const base = optionalFlagValue(flags, "--base") ?? DEFAULT_REVIEW_BASE;

  // 制約として渡すのは**承認済み**の manifest である。policy.json の生の内容ではない
  // ので、台帳の裏付けが取れなければ空 manifest になり、reviewer には「何も承認されて
  // いない」が伝わる（`fh run` と同じ fail-closed の向き）。
  const policyPath = resolvePolicyPath(options, worktree);
  const approved = loadVerifiedManifest({
    policyPath,
    approvals: store.listApprovals(),
    scope: resolveRepositoryScope(options, worktree),
    currentApproval: approvedManifestStoreFor(options, worktree).read(policyPath),
  });

  // packet の組み立ては git の実プロセスを起こすので、他の新経路と同じく rollout guard を通す。
  // ここだけ素通しにすると、「`shadow` へ戻せば一切のプロセスが起きない」という非常停止レバーの
  // 保証が 1 経路だけ破れる（docs はその保証を明記している）。
  const guarded = runWithRolloutGuard(config, "review packet diff", () =>
    buildReviewPacket({
      store,
      taskId,
      worktree,
      base,
      manifest: approved.manifest,
      rollout: config.rollout,
      runGit: options.runGit ?? createGitRunner(),
    }),
  );
  if (!guarded.executed) {
    emit({
      action: "packet",
      taskId,
      out: null,
      executed: false,
      executionReason: guarded.reason,
      policyIntegrity: approved.integrity,
    });
    return 0;
  }
  const packet = guarded.result;
  writeJsonToChosenPath(out, packet, "review packet");

  // **packet 本体を stdout へ出さない。** diff がそのまま端末とログへ流れるうえ、
  // 呼び出し側が「出力をそのまま prompt へ貼る」形になると、渡してよいものの境界を
  // packet ファイルで表現した意味が薄れる。報告するのは所在と形だけにする。
  emit({
    action: "packet",
    taskId,
    out,
    executed: true,
    base: packet.diff.base,
    diffTruncated: packet.diff.truncated,
    verificationResults: packet.verification.length,
    policyIntegrity: approved.integrity,
  });
  return 0;
}

function reviewRecordCommand({ flags, emit, config, store }) {
  const taskId = flagValue(flags, "--task");
  const findingsPath = requireAbsolutePath(
    flagValue(flags, "--findings"),
    "--findings",
  );

  store.requireTask(taskId);
  // reviewer の出力は未検証の外部入力として境界で正規化する（task JSON と同じ規律）。
  const document = normalizeFindingsDocument(
    JSON.parse(readFileSync(findingsPath, "utf8")),
    { taskId },
  );
  const { verdict, counts } = reviewVerdict(document.findings);

  const stored = store.withTransaction(() => {
    const evidence = store.putEvidence({
      kind: REVIEW_EVIDENCE_KIND,
      producer: PRODUCER,
      taskId,
      claimsSupported: reviewClaims({
        reviewerCapability: document.reviewerCapability,
        counts,
        verdict,
      }),
    });
    const findings = document.findings.map((finding) =>
      store.recordReviewFinding({ ...finding, evidenceId: evidence.id }),
    );
    return { evidence, findings };
  });

  emit({
    action: "record",
    taskId,
    reviewerCapability: document.reviewerCapability,
    verdict,
    counts,
    findingIds: stored.findings.map((finding) => finding.id),
    evidenceId: stored.evidence.id,
    rollout: config.rollout,
  });
  // blocked は「レビューが未解決の must を返した」であって harness の失敗ではないが、
  // 呼び出し側スクリプトが 0 と読んで先へ進めてしまっては registry を置いた意味が無い。
  return verdict === "blocked" ? VERIFICATION_FAILED : 0;
}

export function runReviewCommand({ flags, options = {}, emit, config, cwd }) {
  const action = flags[0];
  if (!REVIEW_ACTIONS.has(action)) {
    throw new TypeError(
      `fh review requires packet or record, not ${action ?? "(nothing)"}`,
    );
  }
  // packet は差分の生成（git 呼び出し）を伴うため、state は開くが書き込みトランザクションは
  // 張らない。record は書くが git を触らない。どちらも長時間ロックを握らない形にしてある。
  const worktree = requireAbsolutePath(
    optionalFlagValue(flags, "--worktree") ?? cwd,
    "--worktree",
  );
  const statePath = options.statePath ?? defaultStatePath(worktree);
  const store = createStateStore(statePath);
  try {
    return action === "packet"
      ? reviewPacketCommand({ flags, options, emit, config, worktree, store })
      : reviewRecordCommand({ flags, emit, config, store });
  } finally {
    store.close();
  }
}
