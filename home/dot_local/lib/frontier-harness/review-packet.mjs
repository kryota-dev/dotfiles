import { createGitRunner, worktreeDiff } from "./git-worktree.mjs";

// reviewer へ渡してよいものの定義。
//
// #495 の完了条件は「レビュー担当へ writer の会話履歴を渡さない」であり、渡してよいのは
// **task・制約・差分・検証結果**の 4 つだけである。それを規約ではなく構造で担保するために、
// packet の組み立てをこの 1 関数に閉じ、入力を「task id」「ワークツリー」「base revision」に
// 限る。writer の prompt も、adapter の stdout も、会話 ID も、**引数として受け取る口が無い**
// —— 渡せないものは漏れない。
//
// 4 つの出所も分けてある: task と検証結果は state（`tasks` / `verification_results`）から、
// 制約は承認済み manifest と rollout から、差分は git から読む。いずれも writer が自由に
// 書き込める場所ではない。

export const REVIEW_PACKET_VERSION = 1;

export function buildReviewPacket({
  store,
  taskId,
  worktree,
  base,
  manifest,
  rollout,
  runGit = createGitRunner(),
}) {
  const stored = store.requireTask(taskId);

  const diff = worktreeDiff({ worktree, base, runGit });

  return {
    version: REVIEW_PACKET_VERSION,
    // 1. task —— `normalizeTask` を通って保存された宣言そのもの。goal は呼び出し側が
    //    書いた文字列だが、これは task の定義であってレビュー対象の会話ではない。
    task: {
      id: stored.id,
      goal: stored.goal,
      modality: stored.task.modality,
      risk: stored.task.risk,
      hasDeterministicOracle: stored.task.hasDeterministicOracle,
      requiresApproval: stored.task.requiresApproval,
      requiresWrite: stored.task.requiresWrite,
      createdAt: stored.createdAt,
    },
    // 2. 制約 —— 承認済み manifest と rollout。「何をしてよかったか」を reviewer が
    //    知らなければ、逸脱を指摘できない。
    constraints: {
      rollout,
      approvedCommands: [...manifest.commands],
      approvedDomains: [...manifest.domains],
      approvedCapabilities: [...manifest.capabilities],
    },
    // 3. 検証結果 —— 決定的チェックの実測。reviewer の意見より優先される事実である。
    verification: store.listVerificationResultsForTask(taskId).map((result) => ({
      checkKind: result.checkKind,
      status: result.status,
      command: result.command,
      exitCode: result.exitCode,
      createdAt: result.createdAt,
    })),
    // 4. 差分 —— レビュー対象そのもの。`truncated` を隠さないのは、切り詰めた patch を
    //    「全部見た」と誤解したまま clear が返るのを防ぐため。
    diff,
  };
}
