import { readFileSync } from "node:fs";

import { assertResolvedDomainAllowed } from "./address-classifier.mjs";
import { flagValue } from "./flags.mjs";
import {
  REPOSITORY_MANIFEST_APPROVAL_KIND,
  candidateFromGaps,
  loadVerifiedManifest,
  manifestHash,
  normalizeManifest,
} from "./manifest-policy.mjs";
import {
  createOnboardRequestStore,
  onboardRequestsDirectory,
} from "./onboard-requests.mjs";
import { writeJsonAtomic } from "./paths.mjs";
import {
  approvedManifestStoreFor,
  defaultStatePath,
  manifestGapQueueFor,
  resolvePolicyPath,
  resolveRepositoryScope,
  resolveStateDirectory,
} from "./state-paths.mjs";
import { createStateStore } from "./state-store.mjs";

// repository onboarding の CLI コマンド本体。cli.mjs は分岐だけを持ち、ここに委譲する
// （approval-commands.mjs と同じ規約）。onboard は 2 段階儀式・`--from-gaps` の一括承認・
// domain のアドレス解決を伴う非同期処理・台帳記録・policy 書き込みを持ち、兄弟コマンドの
// どれより複雑なので、cli.mjs 本体に置くと分岐の見通しが失われる。

// 承認待ちで実行を止めたときの終了コード。cli.mjs 側と同じ値を使う。
const BLOCKED_PENDING_APPROVAL = 2;

export async function runOnboardCommand({ flags, options, emit }) {
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
  const approvedManifests = approvedManifestStoreFor(options, cwd);
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
        currentApproval: approvedManifests.read(policyPath),
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
    // 有効な認可状態を差し替える。これが「承認をやり直したら前の承認は失効する」を表し、
    // 過去に承認した policy への差し戻しを塞ぐ（approved-manifest.mjs 参照）。
    approvedManifests.write({
      policyPath,
      manifestHash: hash,
      approvalId: approval.id,
      approvedAt: approval.grantedAt,
    });
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
