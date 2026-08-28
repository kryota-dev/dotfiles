import { lstatSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

// symlink ガードと atomic write の唯一の SSOT。
// 以前は cli.mjs / readiness.mjs / state-store.mjs が個別に実装しており、
// 検査の有無と順序が経路ごとに食い違っていた。

// 対象パス自身が symlink なら拒否する。存在しない場合は許可（これから作る）。
export function assertNotSymlink(target, label) {
  try {
    if (lstatSync(target).isSymbolicLink()) {
      throw new Error(`${label} must not be a symbolic link`);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

// mkdir -p した後、生成/既存のディレクトリが symlink でないことを確認する。
// mkdirSync({recursive:true}) は既存の symlink ディレクトリでも成功するため、
// この検査が無いと `.harness -> ~/.ssh` のような symlink で書き込み先が脱出する。
export function ensureDirectory(directory, label) {
  mkdirSync(directory, { mode: 0o700, recursive: true });
  if (lstatSync(directory).isSymbolicLink()) {
    throw new Error(`${label} must not be a symbolic link`);
  }
  return directory;
}

// 一時ファイル名は予測可能にしない（先置き symlink による任意ファイル上書きを防ぐ）。
// flag "wx" = O_CREAT|O_EXCL で、既存ファイル・既存 symlink があれば EEXIST で失敗する。
export function writeJsonAtomic(targetPath, value, label) {
  const directory = path.dirname(targetPath);
  ensureDirectory(directory, `${label} directory`);
  assertNotSymlink(targetPath, label);
  const temporaryPath = `${targetPath}.${randomUUID()}.tmp`;
  writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
    flag: "wx",
  });
  renameSync(temporaryPath, targetPath);
  return targetPath;
}
