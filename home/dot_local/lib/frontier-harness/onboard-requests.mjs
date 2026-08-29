import { randomBytes } from "node:crypto";
import { readFileSync, unlinkSync } from "node:fs";
import path from "node:path";

import { SHA256_HEX_PATTERN } from "./hash.mjs";
import { writeJsonAtomic } from "./paths.mjs";
import { rejectUnknownKeys, requireObject } from "./record-validation.mjs";

// 2 段階承認儀式の review request。
//
// `fh onboard --manifest X --approve` が 1 回の呼び出しで完結していたため、承認は
// 「自分で書いて自分で許可する」形になっていた。人間の確認を挟む余地がどこにも無い。
//
// そこで承認を 2 回の呼び出しに割る:
//
//   1. `fh onboard --manifest X`          … manifest を検証して表示し、request を発行して exit 2
//   2. `fh onboard --manifest X --approve --request <id>` … その request を消費して承認
//
// 効いているのは **id が推測不能**であることで、`--approve` 側は step 1 の出力を読まない限り
// 正しい id を書けない。つまり単一の argv では自己承認が成立しない。
//
// request は state root（git 非追跡・0700）に置く。repository 側に置くと、
// checkout が「承認済みの request」を同梱できてしまい儀式そのものが迂回される。
//
// 記録した pid と承認側の pid が一致したら拒否する。これは id の推測不能性に対する
// 多層防御で、「同一プロセス内でレビューと承認を続けて呼ぶ」経路（ライブラリとして
// 直接呼ぶ実装など）を塞ぐ。テストは pid を注入して両側を検証する。

export const ONBOARD_REQUEST_VERSION = 1;
// review してから承認するまでの猶予。長すぎると「いつ何を見たのか」が承認と結びつかなくなる。
export const ONBOARD_REQUEST_TTL_MS = 86400000;
export const ONBOARD_REQUEST_ID_PATTERN = /^onbreq_[0-9a-f]{32}$/;

const REQUEST_SUFFIX = ".json";
const REQUEST_KEYS = new Set([
  "version",
  "id",
  "manifestHash",
  "manifest",
  "createdAt",
  "expiresAt",
  "pid",
]);

export function onboardRequestsDirectory(stateDirectory) {
  return path.join(stateDirectory, "onboard-requests");
}

// CLI から来る id をそのままファイル名へ連結するため、形を先に固定する。
export function assertOnboardRequestId(id) {
  if (typeof id !== "string" || !ONBOARD_REQUEST_ID_PATTERN.test(id)) {
    throw new TypeError(
      "onboard request id must match onbreq_ followed by 32 hex characters",
    );
  }
  return id;
}

function normalizeOnboardRequest(input) {
  requireObject(input, "onboard request");
  rejectUnknownKeys(input, REQUEST_KEYS, "onboard request");
  if (input.version !== ONBOARD_REQUEST_VERSION) {
    throw new TypeError(`onboard request version must be ${ONBOARD_REQUEST_VERSION}`);
  }
  assertOnboardRequestId(input.id);
  if (!SHA256_HEX_PATTERN.test(input.manifestHash ?? "")) {
    throw new TypeError("onboard request manifestHash must be a SHA-256 hex digest");
  }
  requireObject(input.manifest, "onboard request manifest");
  if (!Number.isInteger(input.pid)) {
    throw new TypeError("onboard request pid must be an integer");
  }
  const expiresAt = Date.parse(input.expiresAt);
  if (Number.isNaN(expiresAt)) {
    throw new TypeError("onboard request expiresAt must be an ISO 8601 timestamp");
  }
  return Object.freeze({ ...input, manifest: Object.freeze({ ...input.manifest }) });
}

export function createOnboardRequestStore({ directory }) {
  const targetFor = (id) =>
    path.join(directory, `${assertOnboardRequestId(id)}${REQUEST_SUFFIX}`);

  return {
    directory,

    create({ manifest, manifestHash, now = new Date(), pid = process.pid }) {
      if (!SHA256_HEX_PATTERN.test(manifestHash ?? "")) {
        throw new TypeError("onboard request manifestHash must be a SHA-256 hex digest");
      }
      const request = {
        version: ONBOARD_REQUEST_VERSION,
        id: `onbreq_${randomBytes(16).toString("hex")}`,
        manifestHash,
        manifest,
        createdAt: now.toISOString(),
        expiresAt: new Date(now.getTime() + ONBOARD_REQUEST_TTL_MS).toISOString(),
        pid,
      };
      writeJsonAtomic(targetFor(request.id), request, "onboard request");
      return request;
    },

    load(id) {
      let raw;
      try {
        raw = readFileSync(targetFor(id), "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") return null;
        throw error;
      }
      return normalizeOnboardRequest(JSON.parse(raw));
    },

    // 検証して消費する。単回使用にすることで、1 回のレビューが 1 回の承認しか生まないようにする。
    consume({ id, manifestHash, now = new Date(), pid = process.pid }) {
      const request = this.load(id);
      if (!request) {
        throw new TypeError(
          `onboard request ${id} was not found; re-run without --approve to review the manifest first`,
        );
      }
      if (request.pid === pid) {
        throw new TypeError(
          "an onboard request cannot be approved by the process that created it",
        );
      }
      if (Date.parse(request.expiresAt) <= now.getTime()) {
        throw new TypeError(
          `onboard request ${id} expired at ${request.expiresAt}; review the manifest again`,
        );
      }
      if (request.manifestHash !== manifestHash) {
        throw new TypeError(
          "the manifest changed after it was reviewed; review the current manifest again",
        );
      }
      unlinkSync(targetFor(id));
      return request;
    },
  };
}
