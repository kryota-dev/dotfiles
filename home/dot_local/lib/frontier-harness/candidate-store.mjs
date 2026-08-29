import { readFileSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";

import { writeJsonAtomic, writeJsonExclusive } from "./paths.mjs";
import {
  newId,
  nowIso,
  rejectUnknownKeys,
  requireEnum,
  requireNonEmptyString,
  requireObject,
} from "./record-validation.mjs";

// 使い捨て candidate worktree の登記簿。
//
// **state DB のテーブルにしない。** candidate は「ディスク上のツリーが今どうなっているか」を
// 指す運用上の状態で、evidence でもテレメトリでもない。retention の窓に入れると、30 日後に
// 行だけ消えてツリーが残る（登記簿が「無い」と言うのに `git worktree add` は path 衝突で
// 失敗する）。承認 queue・gap queue・承認済み manifest ポインタが同じ理由で state root 配下の
// ファイルなのと同じ扱いにする。撤去は `fh candidate discard` が明示的に行う。
//
// 置き場所は state root（`<gitCommonDir>/frontier-harness`）の配下。`.git` の内側なので、
// 主ワークツリーの `git status` に candidate のファイルが現れない —— `pr-workflow` が所有する
// ツリーを、その所有者に断りなく汚さないための位置である。

export const CANDIDATE_VERSION = 1;
export const CANDIDATE_STATUSES = new Set([
  // ツリーが存在し、取り込み判定をまだ受けていない。
  "open",
  // 検証を通り、対象ワークツリーへ適用済み。ツリーは撤去済み。
  "adopted",
  // 適用が衝突した。**ツリーは残す**（作業を捨てないための状態）。
  "conflicted",
  // 明示的に破棄された。ツリーは撤去済み。
  "discarded",
]);
// ツリーが残る状態。上限判定と撤去の要否がこの集合で決まる。
export const LIVE_CANDIDATE_STATUSES = new Set(["open", "conflicted"]);
// 同時に抱えられる candidate の上限。1 件がフルチェックアウト 1 本なので、gap queue の
// 1000 件のような桁は取れない。上限に達したら新規作成を断り、先に片付けさせる。
export const CANDIDATE_MAX_LIVE_ENTRIES = 8;

const CANDIDATE_SUFFIX = ".candidate.json";
const CANDIDATE_KEYS = new Set([
  "version",
  "id",
  "taskId",
  "status",
  "base",
  "worktree",
  "label",
  "createdAt",
  "updatedAt",
]);
// 台帳の相関に使う識別子。`session-command.mjs` の `--label` と同じ字集合に揃える。
const LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,119}$/;
// id はファイル名になる。パス区切りや相対参照が混ざらないことを保証する。
const CANDIDATE_ID_PATTERN = /^cand_[0-9a-f]{32}$/;

export function candidatesDirectory(stateDirectory) {
  return path.join(stateDirectory, "candidates");
}

export function assertCandidateLabel(label) {
  if (label === undefined || label === null) return null;
  if (typeof label !== "string" || !LABEL_PATTERN.test(label)) {
    throw new TypeError(`--label must match ${LABEL_PATTERN}`);
  }
  return label;
}

function assertCandidateId(value) {
  if (typeof value !== "string" || !CANDIDATE_ID_PATTERN.test(value)) {
    throw new TypeError(`candidate id must match ${CANDIDATE_ID_PATTERN}`);
  }
  return value;
}

function normalizeCandidate(input, label) {
  requireObject(input, label);
  rejectUnknownKeys(input, CANDIDATE_KEYS, label);
  if (input.version !== CANDIDATE_VERSION) {
    throw new TypeError(`${label} version must be ${CANDIDATE_VERSION}`);
  }
  return Object.freeze({
    version: input.version,
    id: assertCandidateId(input.id),
    taskId: requireNonEmptyString(input.taskId, `${label} taskId`),
    status: requireEnum(input.status, CANDIDATE_STATUSES, `${label} status`),
    base: requireNonEmptyString(input.base, `${label} base`),
    worktree: requireNonEmptyString(input.worktree, `${label} worktree`),
    label: input.label === null ? null : assertCandidateLabel(input.label),
    createdAt: requireNonEmptyString(input.createdAt, `${label} createdAt`),
    updatedAt: requireNonEmptyString(input.updatedAt, `${label} updatedAt`),
  });
}

export function createCandidateStore({ directory }) {
  const recordPath = (id) => path.join(directory, `${assertCandidateId(id)}${CANDIDATE_SUFFIX}`);

  function read(id) {
    try {
      return normalizeCandidate(
        JSON.parse(readFileSync(recordPath(id), "utf8")),
        `candidate ${id}`,
      );
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  }

  return {
    directory,
    newCandidateId: () => newId("cand"),
    // ツリーの置き場所。id が `CANDIDATE_ID_PATTERN` に縛られているので、
    // ここでディレクトリを抜け出す名前は作れない。
    worktreePathFor: (id) => path.join(directory, assertCandidateId(id)),

    read,

    list() {
      let entries;
      try {
        entries = readdirSync(directory);
      } catch (error) {
        if (error?.code === "ENOENT") return [];
        throw error;
      }
      const candidates = [];
      for (const entry of entries.sort()) {
        if (!entry.endsWith(CANDIDATE_SUFFIX)) continue;
        // 壊れたファイルを読み飛ばさない。読み飛ばすと、実在するツリーを「無い」と
        // 判断して上限も撤去も効かなくなる。
        candidates.push(
          normalizeCandidate(
            JSON.parse(readFileSync(path.join(directory, entry), "utf8")),
            `candidate ${entry}`,
          ),
        );
      }
      return candidates.sort(
        (left, right) =>
          left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id),
      );
    },

    countLive() {
      return this.list().filter((candidate) => LIVE_CANDIDATE_STATUSES.has(candidate.status))
        .length;
    },

    // 作成は `O_EXCL` 相当（`writeJsonExclusive`）で行う。id は乱数なので衝突は事実上
    // 起きないが、既存ファイルを上書きしうる書き方を登記簿に持たせない。
    create({ id, taskId, base, worktree, label }) {
      const now = nowIso();
      const record = {
        version: CANDIDATE_VERSION,
        id: assertCandidateId(id),
        taskId: requireNonEmptyString(taskId, "candidate taskId"),
        status: "open",
        base: requireNonEmptyString(base, "candidate base"),
        worktree: requireNonEmptyString(worktree, "candidate worktree"),
        label: assertCandidateLabel(label),
        createdAt: now,
        updatedAt: now,
      };
      if (!writeJsonExclusive(recordPath(id), record, "candidate")) {
        throw new Error(`candidate ${id} already exists`);
      }
      return normalizeCandidate(record, `candidate ${id}`);
    },

    setStatus(id, status) {
      const current = read(id);
      if (!current) throw new TypeError(`candidate ${id} does not exist`);
      const updated = {
        ...current,
        status: requireEnum(status, CANDIDATE_STATUSES, "candidate status"),
        updatedAt: nowIso(),
      };
      writeJsonAtomic(recordPath(id), updated, "candidate");
      return normalizeCandidate(updated, `candidate ${id}`);
    },

    // 登記簿の行そのものを消す。ツリーの撤去は git 側の責務なので、ここでは扱わない。
    forget(id) {
      rmSync(recordPath(id), { force: true });
    },
  };
}
