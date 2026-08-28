import { readFileSync } from "node:fs";

import {
  assertNotSymlink,
  assertStateDirectoryNotSymlink,
  healthPath,
  inspectStatePermissions,
  queuePath,
  writeJsonAtomic,
} from "./paths.mjs";
import {
  emptyQueueDocument,
  MAX_REVISION,
  parseQueueDocument,
  requireTimestamp,
  TERMINAL_STATES,
} from "./schema.mjs";

// 読み取り経路と書き込み経路をここで分ける。readQueue / readHealth は state
// ディレクトリの作成すら行わない —— #501 の完了条件「表示操作が評価処理を
// 再実行しない」を、呼び出し側の作法ではなく構造で担保するため。

const HEALTH_STATUSES = Object.freeze(["ok", "failed"]);

// eslint-disable-next-line no-control-regex -- 表示前に落とす対象そのもの
const CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F]/g;
const MAX_DETAIL_LENGTH = 500;

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

// 終端状態（rejected / promoted）は巻き戻さない、という AC-036 の不変条件を
// 書き込み境界で直接検査する。CAS（下）が捕まえるのは「読んでから書くまでに
// ディスクが変わった」ケースだけなので、呼び出し側が古い in-memory の複製から
// 文書を組み立てるような論理バグはすり抜ける。ここは競合対策ではなく、
// 自分たちの将来の変更に対する防御。
function assertNoTerminalRegression(current, next) {
  const terminalById = new Map(
    current.candidates
      .filter((candidate) => TERMINAL_STATES.includes(candidate.state))
      .map((candidate) => [candidate.id, candidate.state]),
  );
  if (terminalById.size === 0) return;
  for (const candidate of next.candidates) {
    const previous = terminalById.get(candidate.id);
    if (previous && !TERMINAL_STATES.includes(candidate.state)) {
      throw new TypeError(
        `candidate ${candidate.id} is ${previous} on disk and cannot be rolled back to ${candidate.state}`,
      );
    }
  }
}

// 読んだ時点の revision を期待値として、書き込み直前に読み直して突き合わせる。
//
// **この検査が保証する範囲は限定的である。** `rename` は原子的だが、それが守るのは
// 「書きかけが見えないこと」だけで、read-modify-write の相互排除ではない。ここで
// 塞げるのは「先行する書き込みが既に rename を終えている」逐次的なケースだけで、
// 2 つの writer が**どちらも rename 前に**読み直した場合は両方がこの検査を通過し、
// 後から rename した側が黙って勝つ（そのとき revision も片方分しか進まないため、
// 外形上は正常な 1 回の書き込みと区別できない）。真の相互排除にはロックが要る。
//
// ロックを今入れないのは、(1) 現時点の writer が対話操作の 1 本だけで、週次
// evaluator（#506）はまだ存在せず自動起動経路もリポジトリに無い、(2) ロックファイル
// 自体が stale 判定・デッドロック・新たな symlink 攻撃面という失敗モードを持ち込み、
// それはこの変更で state の symlink 対策を締めた直後に増設することになる、ため。
// **#506 で 2 つ目の writer を足すときに、この関数をロックで包むことを前提条件とする。**
export function writeQueue(environment, document) {
  const expectedRevision = document.revision;
  if (expectedRevision >= MAX_REVISION) {
    throw new TypeError(
      `queue.revision reached its maximum (${MAX_REVISION}); the queue must be rebuilt`,
    );
  }
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
  assertNoTerminalRegression(current, validated);
  writeJsonAtomic(environment, queuePath(environment), validated, "queue file");
  return validated;
}

// 表示のために権限のドリフトを検出する。矯正も停止もしない（矯正は要件 5.3 の
// 「表示は書かない」を破り、停止は AC-037 の「active 候補の全件を表示」を
// 達成できなくするうえ権限も直らない）。書き込み経路の矯正はそのまま維持する。
export function readPermissionWarnings(environment) {
  try {
    return inspectStatePermissions(environment);
  } catch (error) {
    return Object.freeze([`permissions could not be inspected: ${error.message}`]);
  }
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
      // health は #506 の evaluator が書く別プロデューサの出力で、候補と違って
      // schema の境界検証を通らない。表示前にここで制御文字を落とす。
      detail:
        typeof parsed.detail === "string"
          ? parsed.detail.replace(CONTROL_CHARACTERS, " ").slice(0, MAX_DETAIL_LENGTH)
          : null,
    });
  } catch (error) {
    return Object.freeze({ available: false, reason: error.message });
  }
}
