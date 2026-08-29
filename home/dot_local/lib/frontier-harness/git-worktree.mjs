import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, constants, openSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

import { requireAbsolutePath } from "./paths.mjs";

// harness が git を呼ぶ唯一の場所。candidate worktree の作成・差分・適用・撤去と、
// reviewer packet の差分がここを通る（`state-root.mjs` は state root の解決だけを行い、
// 作業ツリーを操作しない。役割が違うので統合しない）。
//
// **revision を argv の先頭要素にしない。** 呼び出し側から来る rev は `--` 以降か、
// 下の `assertRevision` を通した値だけを使う。ハイフンで始まる文字列がそのまま渡ると、
// git はそれをフラグとして解釈する。
//
// **作業ツリーの index を書き換えない。** 差分は毎回使い捨ての `GIT_INDEX_FILE` を用意し、
// `read-tree` で base を流し込んでから `add -A` する。`git add` を本物の index に対して
// 走らせると、`pr-workflow` が主ワークツリーで組み立て中のステージング状態を壊す
// —— 所有権は `pr-workflow` にあり、この layer が触ってよいものではない。

// diff の上限。reviewer packet は JSON へ埋め込まれるため、際限なく大きくしない。
export const MAX_DIFF_BYTES = 1_048_576;
// git の stdout 上限。diff の上限より広く取り、切り詰めは呼び出し側で明示的に行う。
export const MAX_GIT_OUTPUT_BYTES = 64 * 1_048_576;

// 先頭は英数字に限る（`-` 始まりをフラグとして解釈させない）。`~` `^` は `HEAD~1` 等で使う。
const REVISION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/~^-]{0,255}$/;

export function assertRevision(value, label) {
  if (typeof value !== "string" || !REVISION_PATTERN.test(value)) {
    throw new TypeError(`${label} must match ${REVISION_PATTERN}`);
  }
  return value;
}

// 別名を残すのは呼び出し側の語彙（assert*）に合わせるためで、実装は持たない。
// 2 つ目の実装を置くと、片方だけ強化されたときに黙って食い違う。
// `export { x as y }` ではモジュール内に `y` の束縛ができないため、const で別名を作る。
export const assertAbsolutePath = requireAbsolutePath;

// 例外を投げず `{ status, stdout, stderr }` を返す。`git apply --check` のように
// 「非 0 終了そのものが答え」である呼び出しがあるため、成功/失敗の判定は呼び出し側が行う。
export function createGitRunner({ environment = process.env } = {}) {
  return function runGit(cwd, args, extraEnvironment = {}) {
    const result = spawnSync("git", args, {
      cwd,
      encoding: "utf8",
      maxBuffer: MAX_GIT_OUTPUT_BYTES,
      env: { ...environment, ...extraEnvironment },
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (result.error) throw result.error;
    return {
      status: result.status,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  };
}

function requireGit(result, action) {
  if (result.status !== 0) {
    // git の stderr はここでしか使わない（state にも evidence にも入れない）。
    throw new Error(`${action} failed: ${result.stderr.trim() || `git exited ${result.status}`}`);
  }
  return result.stdout;
}

export function resolveRevision(worktree, revision, runGit) {
  const output = requireGit(
    runGit(worktree, ["rev-parse", "--verify", `${assertRevision(revision, "revision")}^{commit}`]),
    `resolving ${revision}`,
  );
  return output.trim();
}

// base を流し込んだ使い捨て index にワークツリー全体を stage し、その index に対して
// 任意の git コマンドを走らせる。diff と tree hash が同じ「何が入っているか」の定義を
// 共有するために切り出してある（2 つが別々に stage すると、両者の指す内容がずれうる）。
function withStagedIndex(worktree, base, runGit, action) {
  assertAbsolutePath(worktree, "worktree");
  const gitDirectory = requireGit(
    runGit(worktree, ["rev-parse", "--absolute-git-dir"]),
    "locating the git directory",
  ).trim();
  const baseCommit = resolveRevision(worktree, base, runGit);
  const indexFile = path.join(gitDirectory, `fh-index-${randomUUID()}.index`);
  const withIndex = { GIT_INDEX_FILE: indexFile };
  try {
    requireGit(runGit(worktree, ["read-tree", baseCommit], withIndex), "seeding a scratch index");
    requireGit(runGit(worktree, ["add", "-A", "--", "."], withIndex), "staging the worktree");
    return action({ baseCommit, withIndex });
  } finally {
    // 使い捨て index を残さない。存在しなくても失敗しない。
    rmSync(indexFile, { force: true });
  }
}

// 追跡済みの変更と未追跡の新規ファイルの両方を含む patch を作る。
//
// 使い捨ての index を使うため、対象ワークツリーの index は一切変わらない。`.gitignore` は
// `add -A` が尊重するので、無視対象のビルド成果物は patch に入らない。
//
// **scratch index の置き場所を呼び出し側に選ばせない。** ワークツリーの内側に置くと
// `git add -A` がその index ファイル自身を patch へ取り込む。git ディレクトリ配下は
// git が決して走査しないので、そこから導出すれば呼び出し側が何を渡しても壊れない。
export function worktreeDiff({ worktree, base, runGit, maxBytes = MAX_DIFF_BYTES }) {
  return withStagedIndex(worktree, base, runGit, ({ baseCommit, withIndex }) => {
    const patch = requireGit(
      runGit(worktree, ["diff", "--binary", "--cached", baseCommit], withIndex),
      "diffing the worktree",
    );
    const bytes = Buffer.from(patch, "utf8");
    if (bytes.byteLength <= maxBytes) return { base: baseCommit, patch, truncated: false };
    // **文字境界で切る。** バイト境界で切ると多バイト文字を割り、末尾に U+FFFD が生まれる。
    // patch はここで既に適用不能（truncated）だが、壊れた文字を reviewer へ見せる意味は無い。
    const decoder = new TextDecoder("utf-8", { fatal: false, ignoreBOM: true });
    const head = decoder.decode(bytes.subarray(0, maxBytes), { stream: true });
    return { base: baseCommit, patch: head, truncated: true };
  });
}

// 「検証した時点でツリーに何が入っていたか」を一意に表す git tree object の hash。
// `verification_results.tree_hash` に記録し、取り込み直前に再計算して突き合わせる
// ことで、「合格したあとにツリーを書き換えて取り込む」経路を塞ぐ。
export function worktreeTreeHash({ worktree, base, runGit }) {
  return withStagedIndex(worktree, base, runGit, ({ withIndex }) =>
    requireGit(runGit(worktree, ["write-tree"], withIndex), "hashing the worktree").trim(),
  );
}

export function createDetachedWorktree({ repository, target, base, runGit }) {
  assertAbsolutePath(repository, "repository");
  assertAbsolutePath(target, "candidate worktree path");
  const baseCommit = resolveRevision(repository, base, runGit);
  requireGit(
    runGit(repository, ["worktree", "add", "--detach", target, baseCommit]),
    "creating the candidate worktree",
  );
  return baseCommit;
}

// 撤去は best-effort ではない。失敗を握り潰すと、登録簿は「片付いた」と言うのに
// ディスクにはツリーが残り、次の `git worktree add` が同じ path で失敗する。
export function removeWorktree({ repository, target, runGit }) {
  requireGit(
    runGit(repository, ["worktree", "remove", "--force", target]),
    "removing the candidate worktree",
  );
}

// patch を一時ファイルへ書き出す。`git apply` は stdin からも読めるが、`spawnSync` へ
// 大きな入力を渡す形にすると runner の注入点が 2 種類になる（引数だけを見れば何が起きるか
// 分かる、という他の呼び出しとの一貫性を優先する）。名前は予測不能にし、0600 で作る。
export function createPatchWriter(directory) {
  assertAbsolutePath(directory, "patch directory");
  return function writePatch(patch) {
    const target = path.join(directory, `fh-patch-${randomUUID()}.patch`);
    const descriptor = openSync(
      target,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
      0o600,
    );
    try {
      writeFileSync(descriptor, patch, { encoding: "utf8" });
    } finally {
      closeSync(descriptor);
    }
    return target;
  };
}

// 適用できるかを、作業ツリーを一切変えずに確かめる。非 0 は「衝突した」であって異常ではない。
export function patchApplies({ worktree, patch, runGit, writePatch }) {
  const patchPath = writePatch(patch);
  try {
    return runGit(worktree, ["apply", "--check", "--", patchPath]).status === 0;
  } finally {
    rmSync(patchPath, { force: true });
  }
}

export function applyPatch({ worktree, patch, runGit, writePatch }) {
  const patchPath = writePatch(patch);
  try {
    requireGit(runGit(worktree, ["apply", "--", patchPath]), "applying the candidate patch");
  } finally {
    rmSync(patchPath, { force: true });
  }
}
