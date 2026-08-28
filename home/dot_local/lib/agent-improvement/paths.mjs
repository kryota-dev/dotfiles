import { chmodSync, lstatSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

// 改善候補キューの state 置き場と、owner-only 書き込みの安全契約を決める唯一の場所
// （#473 AC-035）。パス解決をこのモジュールに閉じているのは、#344（CLV2 状態を
// アカウント別の親ディレクトリへまとめる）が将来このレイアウトにも及んだときに、
// 変更点が 1 箇所で済むようにするため。#344 の移行そのものはここでは行わない。

const STATE_DIRECTORY_NAME = "agent-improvement";
const QUEUE_FILE_NAME = "queue.json";
// #506 の週次 evaluator が書く health ファイル。このリポジトリのコードは読むだけで、
// 一度も書かない（本 issue のスコープは queue 側だけ）。
const HEALTH_FILE_NAME = "health.json";
const STATE_DIRECTORY_MODE = 0o700;
const STATE_FILE_MODE = 0o600;

// 相対パスは cwd 基準で解決されるため受け付けない。許すと、たまたま cd していた
// リポジトリの中に owner-only の state を作らされる。
function requireAbsolute(value, label) {
  if (typeof value !== "string" || !path.isAbsolute(value)) {
    throw new TypeError(`${label} must be an absolute path`);
  }
  return value;
}

export function resolveStateDirectory(environment) {
  const override = environment.AGENT_IMPROVEMENT_STATE_DIR;
  if (override) {
    return requireAbsolute(override, "AGENT_IMPROVEMENT_STATE_DIR");
  }
  const stateHome = environment.XDG_STATE_HOME;
  if (stateHome) {
    return path.join(
      requireAbsolute(stateHome, "XDG_STATE_HOME"),
      STATE_DIRECTORY_NAME,
    );
  }
  return path.join(
    requireAbsolute(environment.HOME, "HOME"),
    ".local",
    "state",
    STATE_DIRECTORY_NAME,
  );
}

export function queuePath(environment) {
  return path.join(resolveStateDirectory(environment), QUEUE_FILE_NAME);
}

export function healthPath(environment) {
  return path.join(resolveStateDirectory(environment), HEALTH_FILE_NAME);
}

// 対象パス自身が symlink なら拒否する。存在しない場合は許可（これから作る）。
export function assertNotSymlink(target, label) {
  let stats;
  try {
    stats = lstatSync(target);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  if (stats.isSymbolicLink()) {
    throw new Error(`${label} must not be a symbolic link`);
  }
}

export function ensureStateDirectory(directory) {
  assertNotSymlink(directory, "state directory");
  mkdirSync(directory, { mode: STATE_DIRECTORY_MODE, recursive: true });
  // mkdirSync({recursive:true}) は既存の symlink ディレクトリでも成功するため、
  // 作成後にもう一度検査する（`agent-improvement -> ~/.ssh` のような脱出を防ぐ）。
  assertNotSymlink(directory, "state directory");
  // mode オプションは umask に削られ、既存ディレクトリには適用されない。
  // owner-only は AC-035 の要件なので、作成経路に関わらず明示的に固定する。
  chmodSync(directory, STATE_DIRECTORY_MODE);
  return directory;
}

export function writeJsonAtomic(targetPath, value, label) {
  ensureStateDirectory(path.dirname(targetPath));
  assertNotSymlink(targetPath, label);
  // 一時ファイル名は予測可能にしない（先置き symlink による任意ファイル上書きを防ぐ）。
  // flag "wx" = O_CREAT|O_EXCL で、既存ファイル・既存 symlink があれば EEXIST で失敗する。
  const temporaryPath = `${targetPath}.${randomUUID()}.tmp`;
  writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    mode: STATE_FILE_MODE,
    flag: "wx",
  });
  try {
    chmodSync(temporaryPath, STATE_FILE_MODE);
    renameSync(temporaryPath, targetPath);
  } catch (error) {
    // rename 前に失敗したら一時ファイルを残さない（0600 の断片を溜めない）。
    rmSync(temporaryPath, { force: true });
    throw error;
  }
  return targetPath;
}
