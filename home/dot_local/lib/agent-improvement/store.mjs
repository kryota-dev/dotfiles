import { readFileSync } from "node:fs";

import {
  assertNotSymlink,
  assertStateDirectoryNotSymlink,
  healthPath,
  queuePath,
  writeJsonAtomic,
} from "./paths.mjs";
import {
  emptyQueueDocument,
  parseQueueDocument,
  requireTimestamp,
} from "./schema.mjs";

// 読み取り経路と書き込み経路をここで分ける。readQueue / readHealth は state
// ディレクトリの作成すら行わない —— #501 の完了条件「表示操作が評価処理を
// 再実行しない」を、呼び出し側の作法ではなく構造で担保するため。

const HEALTH_STATUSES = Object.freeze(["ok", "failed"]);

function readIfPresent(environment, filePath, label) {
  // 葉のファイルだけを検査すると、state ディレクトリ自体を symlink に差し替えられた
  // ときにリンク先の内容を無警告で読んでしまう。読み取りも書き込みと同じ拒否条件にする。
  assertStateDirectoryNotSymlink(environment);
  assertNotSymlink(filePath, label);
  try {
    return readFileSync(filePath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export function readQueue(environment, nowIso) {
  const filePath = queuePath(environment);
  const raw = readIfPresent(environment, filePath, "queue file");
  // 未作成は初回起動の正常な状態。ここでファイルもディレクトリも作らない。
  if (raw === null) return emptyQueueDocument(nowIso);
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    // 壊れた state を黙って空で上書きすると採否履歴を破壊する。パスを示して止まる。
    throw new TypeError(`${filePath} is not valid JSON: ${error.message}`);
  }
  return parseQueueDocument(parsed);
}

// 読んだ時点の revision を期待値として、書き込み直前に読み直して突き合わせる（CAS）。
//
// `rename` は原子的だが、それが守るのは「書きかけが見えないこと」だけで、
// read-modify-write の競合は防げない。`upsert` が active な候補を読んだ後、
// 別プロセスが同じ候補を `reject` して保存し、その後で `upsert` が古い snapshot を
// 書き戻すと、終端状態のはずの候補が active に復活する（AC-036 違反）。
//
// 残る窓は「revision を読み直してから rename するまで」で、人が採否を判断する
// 時間（秒〜分）に対して桁違いに短い。書き込み側が週次 evaluator と対話操作の
// 2 つしかないこの用途では、ロックファイルの寿命管理を持ち込むより釣り合う。
export function writeQueue(environment, document) {
  const expectedRevision = document.revision;
  // 保存前に自分の出力をもう一度検証する（不正な形をディスクに残さない）。
  const validated = parseQueueDocument({
    ...document,
    revision: expectedRevision + 1,
  });
  const current = readQueue(environment, validated.updated_at);
  if (current.revision !== expectedRevision) {
    throw new TypeError(
      `queue was modified concurrently (expected revision ${expectedRevision}, found ${current.revision}); re-run the command`,
    );
  }
  writeJsonAtomic(queuePath(environment), validated, "queue file");
  return validated;
}

// #506 の evaluator が書く health を「表示要素」として読む。存在しない・壊れている
// ことは error にせず、その事実を返して呼び出し側に表示させる（AC-037）。
// このリポジトリのコードはこのファイルへ一度も書き込まない。
export function readHealth(environment) {
  const filePath = healthPath(environment);
  let raw;
  try {
    raw = readIfPresent(environment, filePath, "health file");
  } catch (error) {
    return Object.freeze({ available: false, reason: error.message });
  }
  if (raw === null) {
    return Object.freeze({ available: false, reason: "not-run" });
  }
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new TypeError("health must be an object");
    }
    return Object.freeze({
      available: true,
      status: HEALTH_STATUSES.includes(parsed.status) ? parsed.status : "unknown",
      lastRunAt: parsed.last_run_at
        ? requireTimestamp(parsed.last_run_at, "health.last_run_at")
        : null,
      detail: typeof parsed.detail === "string" ? parsed.detail : null,
    });
  } catch (error) {
    return Object.freeze({ available: false, reason: error.message });
  }
}
