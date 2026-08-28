import { readFileSync } from "node:fs";

import {
  assertNotSymlink,
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

function readIfPresent(filePath, label) {
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
  const raw = readIfPresent(filePath, "queue file");
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

export function writeQueue(environment, document) {
  // 保存前に自分の出力をもう一度検証する（不正な形をディスクに残さない）。
  const validated = parseQueueDocument(document);
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
    raw = readIfPresent(filePath, "health file");
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
