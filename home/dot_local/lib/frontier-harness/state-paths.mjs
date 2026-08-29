import { chmodSync } from "node:fs";
import path from "node:path";

import {
  approvedManifestDirectory,
  createApprovedManifestStore,
} from "./approved-manifest.mjs";
import {
  candidatesDirectory,
  createCandidateStore,
} from "./candidate-store.mjs";
import {
  createManifestGapQueue,
  manifestGapsDirectory,
} from "./manifest-gaps.mjs";
import { ensureDirectory } from "./paths.mjs";
import {
  GitWorktreeUnavailableError,
  resolveGitCommonDirectory,
} from "./state-root.mjs";

// 「harness の状態がどこに置かれるか」の解決を 1 か所に集める。
//
// cli.mjs と onboard-commands.mjs の両方がこれらを必要とするため、どちらかに置くと
// 片方向の依存が生まれる。置き場所の決定は security 不変条件（作業ディレクトリの内容から
// 設定・承認の位置を解決しない）に直結するので、分散させない。

// account scope は readiness キャッシュのファイル名に入るため、
// パス区切りや相対参照が混ざらないことを保証する。
const ACCOUNT_SCOPE_PATTERN = /^[a-z][a-z0-9-]*$/;

export { GitWorktreeUnavailableError };

export function defaultStateDirectory(cwd) {
  const stateDirectory = path.join(
    resolveGitCommonDirectory(cwd),
    "frontier-harness",
  );
  ensureDirectory(stateDirectory, "frontier-harness state directory");
  chmodSync(stateDirectory, 0o700);
  return stateDirectory;
}

export function defaultStatePath(cwd) {
  return path.join(defaultStateDirectory(cwd), "state.db");
}

// readiness は account scope ごとに分ける。共有すると、あるプロファイルで確定した
// provider の可用性が、別プロファイルとして解決される実行に流用される。
export function readinessPathFor(statePath, accountScope) {
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
export function resolveReadinessPath(options, accountScope) {
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

// 承認ストア（onboard request / manifest gap）は state root 配下に置く。
// repository 側へ置くと、checkout が「承認済みの request」や「空の gap queue」を同梱でき、
// 儀式そのものが迂回される。テストは statePath / stateDirectory を注入して git 非依存にできる。
export function resolveStateDirectory(options, cwd) {
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
export function resolveRepositoryScope(options, cwd) {
  return options.repositoryScope ?? resolveStateDirectory(options, cwd);
}

export function resolvePolicyPath(options, cwd) {
  return options.policyPath ?? path.join(cwd, ".harness", "policy.json");
}

export function manifestGapQueueFor(options, cwd) {
  return createManifestGapQueue({
    directory: manifestGapsDirectory(resolveStateDirectory(options, cwd)),
  });
}

// candidate 登記簿も他のストアと同じくここで解決する。`state-paths.mjs` 冒頭が述べるとおり
// 「置き場所の決定は security 不変条件に直結するので分散させない」——
// 呼び出し側でインライン構築すると、候補だけ解決規則が分岐しうる。
export function candidateStoreFor(options, cwd) {
  return createCandidateStore({
    directory: ensureDirectory(
      candidatesDirectory(resolveStateDirectory(options, cwd)),
      "candidate directory",
    ),
  });
}

export function approvedManifestStoreFor(options, cwd) {
  return createApprovedManifestStore({
    directory: approvedManifestDirectory(resolveStateDirectory(options, cwd)),
  });
}

