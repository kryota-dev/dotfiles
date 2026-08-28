import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

import { assertNotSymlink } from "./paths.mjs";

// state root（SQLite state と raw artifacts の置き場所）を決める唯一の場所。
// `git rev-parse --git-common-dir` の結果は repository 側の設定（`.git` ファイルの
// `gitdir:` 指定、submodule、GIT_DIR / GIT_COMMON_DIR）に影響される。untrusted な
// checkout の上でその値をそのまま使うと、別リポジトリの metadata ディレクトリ配下に
// 0700 のディレクトリを作らされる。

// git working tree が無い（＝ state root を解決できない）ことと、
// 「信頼できない state root を検出した」ことは区別する。
// 前者だけが握り潰してよい失敗であり、後者を握り潰すと doctor 経路だけ
// ガードが無効化される。
export class GitWorktreeUnavailableError extends Error {}

// 1 回の起動で common dir / git dir / working tree の 3 つを得る。
// `--path-format=absolute` を付けないと common dir は cwd 相対で返り、
// 解決が作業ディレクトリに依存する。
const TOPOLOGY_ARGUMENTS = Object.freeze([
  "rev-parse",
  "--path-format=absolute",
  "--git-common-dir",
  "--git-dir",
  "--show-toplevel",
]);

function runGitSync(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function isInside(parent, child) {
  const base = parent.endsWith(path.sep) ? parent : `${parent}${path.sep}`;
  return child.startsWith(base);
}

function readTopology(cwd, runGit) {
  let output;
  try {
    output = runGit(cwd, TOPOLOGY_ARGUMENTS);
  } catch (error) {
    // bare repository も working tree が無いためここに来る。
    throw new GitWorktreeUnavailableError(
      "frontier-harness state root requires a git working tree",
      { cause: error },
    );
  }
  const [commonDirectory, gitDirectory, topLevel] = String(output)
    .split("\n")
    .map((line) => line.trim());
  if (!commonDirectory || !gitDirectory || !topLevel) {
    throw new GitWorktreeUnavailableError(
      "git did not report a complete working tree topology",
    );
  }
  return { commonDirectory, gitDirectory, topLevel };
}

// submodule の working tree では common dir が superproject の metadata 配下にある。
// 解決できないときは空文字を返して「submodule ではない」とみなす（判定を緩めない側）。
function superprojectCommonDirectory(cwd, runGit) {
  let superproject;
  try {
    superproject = runGit(cwd, [
      "rev-parse",
      "--show-superproject-working-tree",
    ]).trim();
  } catch {
    return "";
  }
  if (!superproject || !path.isAbsolute(superproject)) return "";
  try {
    return runGit(superproject, [
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir",
    ]).trim();
  } catch {
    return "";
  }
}

// 「common dir が現在の作業ツリー配下にあること」（containment）は要求しない。
// linked worktree では common dir が作業ツリーの外を指すのが正常であり
// （実測: /Users/ryota/worktrees/dotfiles/<branch> -> /Users/ryota/dotfiles/.git）、
// containment を課すと worktree 運用を丸ごと壊す。
// 代わりに「この作業ツリーが所有する common dir か」を検証する。
function isOwnedByWorkingTree(topology, resolveSuperproject) {
  const { commonDirectory, gitDirectory, topLevel } = topology;
  // (a) 通常の repository: <topLevel>/.git がそのまま common dir。
  if (path.dirname(commonDirectory) === topLevel) return true;
  // (b) linked worktree: git dir が <commonDir>/worktrees/<name>。
  if (isInside(path.join(commonDirectory, "worktrees"), gitDirectory)) return true;
  // (c) submodule: common dir が superproject の common dir 配下。
  //     (a)(b) で確定したときは git を追加起動しない。
  const superproject = resolveSuperproject();
  return Boolean(superproject) && isInside(superproject, commonDirectory);
}

// 検証済みの git common directory を返す。`runGit` はテスト用の seam であり、
// 実 git では再現できない分岐（相対パスや symlink の common dir）を検証するために使う。
export function resolveGitCommonDirectory(cwd, runGit = runGitSync) {
  const topology = readTopology(cwd, runGit);
  for (const [label, value] of [
    ["git common directory", topology.commonDirectory],
    ["git directory", topology.gitDirectory],
    ["git working tree", topology.topLevel],
  ]) {
    if (!path.isAbsolute(value)) {
      throw new Error(`${label} must be an absolute path`);
    }
  }
  // symlink 検査は paths.mjs の SSOT を再利用する。
  // 実 git は symlink を解決した realpath を返すため通常は発火しないが、
  // 経路ごとに検査の有無が食い違う退行を避けるため多層防御として残す。
  assertNotSymlink(topology.commonDirectory, "git common directory");
  // 真正な git metadata ディレクトリでなければ state root にしない。
  if (!existsSync(path.join(topology.commonDirectory, "HEAD"))) {
    throw new Error("git common directory is not a git metadata directory");
  }
  if (
    !isOwnedByWorkingTree(topology, () =>
      superprojectCommonDirectory(cwd, runGit),
    )
  ) {
    throw new Error(
      "git common directory is not owned by the current working tree",
    );
  }
  return topology.commonDirectory;
}
