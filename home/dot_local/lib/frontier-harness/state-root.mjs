import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import path from "node:path";

import { HarnessError } from "./errors.mjs";
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
// HarnessError を継承する: 「repository の外で実行した」は想定内の失敗であり、
// stack trace ではなく原因の読めるメッセージで返す（#508）。
export class GitWorktreeUnavailableError extends HarnessError {}

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
    // git が実際に起動して非 0 終了したときだけ「working tree が無い」とみなす。
    // 実測: 非 working tree（bare 含む）は status=128、spawn 自体の失敗は
    // code="ENOENT" / "EACCES" かつ status=null。後者まで握り潰すと、git 不在や
    // 権限エラーを doctor が「repository の外にいるだけ」と誤診断して隠してしまう。
    if (typeof error?.status !== "number") throw error;
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

// 作業ツリーの `.git` が、git の報告した git dir を実際に指しているかを確認する。
// これが無いと、GIT_DIR / GIT_COMMON_DIR で別リポジトリの metadata を指したまま
// 任意のディレクトリを作業ツリーとして通せる（実測で再現した escape）。
// 見つからない・形が違うときは null を返し、所有と認めない（fail closed）。
function workingTreeGitLink(topLevel) {
  const link = path.join(topLevel, ".git");
  let stats;
  try {
    stats = lstatSync(link);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  // symlink の `.git` は escape と同じ形になるため受け付けない。
  if (stats.isSymbolicLink()) return null;
  if (stats.isDirectory()) return link;
  if (!stats.isFile()) return null;
  const match = /^gitdir:\s*(.+)$/m.exec(readFileSync(link, "utf8"));
  if (!match) return null;
  // submodule の `.git` は `gitdir: ../.git/modules/<name>` のように相対で書かれる。
  return path.resolve(topLevel, match[1].trim());
}

// linked worktree の admin dir は `gitdir` に「所有する作業ツリーの .git」を書き戻す。
// 読めない場合は空文字を返し、(b) を成立させない（fail closed）。
function worktreeBacklink(gitDirectory) {
  try {
    return path.resolve(
      gitDirectory,
      readFileSync(path.join(gitDirectory, "gitdir"), "utf8").trim(),
    );
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
  // 3 形態に共通の前提: 作業ツリーの `.git` が、この git dir を指していること。
  // GIT_DIR で他リポジトリの metadata を指すだけでは、この結び付きは作れない。
  if (workingTreeGitLink(topLevel) !== gitDirectory) return false;

  // (a) 通常の repository: <topLevel>/.git がそのまま common dir。
  //     dirname 比較だと `.git` 以外の名前の git dir まで通るため完全一致で見る。
  if (commonDirectory === path.join(topLevel, ".git")) return true;
  // (b) linked worktree: git dir が <commonDir>/worktrees/<name> にあり、かつ
  //     その admin dir の backlink がこの作業ツリーを指していること。
  //     形（パス配置）だけを見ると、victim の正当な admin dir を GIT_DIR で
  //     指した任意の cwd が通ってしまう（実測で再現した escape）。
  if (
    isInside(path.join(commonDirectory, "worktrees"), gitDirectory) &&
    worktreeBacklink(gitDirectory) === path.join(topLevel, ".git")
  ) {
    return true;
  }
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
      throw new HarnessError(`${label} must be an absolute path`);
    }
  }
  // symlink 検査は paths.mjs の SSOT を再利用する。
  // 実 git は symlink を解決した realpath を返すため通常は発火しないが、
  // 経路ごとに検査の有無が食い違う退行を避けるため多層防御として残す。
  assertNotSymlink(topology.commonDirectory, "git common directory");
  // 真正な git metadata ディレクトリでなければ state root にしない。
  if (!existsSync(path.join(topology.commonDirectory, "HEAD"))) {
    throw new HarnessError("git common directory is not a git metadata directory");
  }
  if (
    !isOwnedByWorkingTree(topology, () =>
      superprojectCommonDirectory(cwd, runGit),
    )
  ) {
    throw new HarnessError(
      "git common directory is not owned by the current working tree",
    );
  }
  return topology.commonDirectory;
}
