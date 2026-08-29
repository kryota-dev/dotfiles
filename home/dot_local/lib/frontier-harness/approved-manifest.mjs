import { readFileSync } from "node:fs";
import path from "node:path";

import { SHA256_HEX_PATTERN, sha256Hex } from "./hash.mjs";
import { writeJsonAtomic } from "./paths.mjs";
import { rejectUnknownKeys, requireObject } from "./record-validation.mjs";

// 「いまこの policy ファイルに対して有効な承認はどれか」を指すポインタ。
//
// approvals 台帳は**追記のみ**の監査証跡で、過去の承認行を無効化する手段を持たない。
// そのため「台帳のどれか 1 行と hash が一致すれば有効」と判定すると、広い manifest M1 を
// 承認したあと狭い M2 へ承認し直しても、`.harness/policy.json` を M1 の内容へ差し戻すだけで
// M1 の行に再び一致してしまう（承認当時のバイト列そのものなので `approvalHash` の改変すら
// 要らない）。policy.json は repository 側にあり `git checkout <old-sha> -- .harness/policy.json`
// で戻せるため、この PR が脅威モデルに挙げる「checkout / pull / 悪意ある PR による差し替え」に
// そのまま合致する。つまり承認の絞り込み（revoke）が実効性を持たない。
//
// そこで **監査証跡（台帳・append-only）と有効な認可状態（このポインタ・可変）を分離**する。
// 照合はポインタが指す hash とのみ突き合わせるので、過去の承認内容への差し戻しは通らない。
//
// **キーを policy ファイルのパスで分ける理由**: state root は
// `git rev-parse --git-common-dir` 配下にあり、同一リポジトリの全 worktree で共有される。
// 一方 policy は worktree ごとの `<cwd>/.harness/policy.json` に存在する。ポインタを
// リポジトリ単位で 1 つにすると、後から承認した worktree が先に承認した worktree の policy を
// 未承認化してしまう（linked worktree が state root を共有することはテストで契約化済み）。
// パスごとに分ければその巻き添えが構造的に起きず、「最新はどれか」を時刻順で決める必要も
// 無くなる（承認時刻が同一のときにランダム UUID の順序へ意味を持たせずに済む）。
//
// **残余リスク**: このポインタも同一 uid で書き換えられる。`approvals.granted_by` と
// 承認ディレクトリに付いている但し書きと同じで、同一 uid の攻撃者に対する境界ではない。

export const APPROVED_MANIFEST_VERSION = 1;

const RECORD_KEYS = new Set([
  "version",
  "policyPath",
  "manifestHash",
  "approvalId",
  "approvedAt",
]);

export function approvedManifestDirectory(stateDirectory) {
  return path.join(stateDirectory, "approved-manifests");
}

// policy パスをそのままファイル名にはしない（区切り文字と長さの制約を避ける）。
// パスは配列として hash し、区切りの曖昧さを持ち込まない。
function pointerFileName(policyPath) {
  return `${sha256Hex([policyPath])}.json`;
}

function normalizeRecord(input, label) {
  requireObject(input, label);
  rejectUnknownKeys(input, RECORD_KEYS, label);
  if (input.version !== APPROVED_MANIFEST_VERSION) {
    throw new TypeError(`${label} version must be ${APPROVED_MANIFEST_VERSION}`);
  }
  if (!SHA256_HEX_PATTERN.test(input.manifestHash ?? "")) {
    throw new TypeError(`${label} manifestHash must be a SHA-256 hex digest`);
  }
  if (typeof input.policyPath !== "string" || input.policyPath.length === 0) {
    throw new TypeError(`${label} policyPath must be a non-empty string`);
  }
  return Object.freeze({ ...input });
}

export function createApprovedManifestStore({ directory }) {
  const targetFor = (policyPath) => path.join(directory, pointerFileName(policyPath));

  return {
    directory,

    read(policyPath) {
      let raw;
      try {
        raw = readFileSync(targetFor(policyPath), "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") return null;
        throw error;
      }
      const record = normalizeRecord(JSON.parse(raw), "approved manifest pointer");
      // hash 衝突ではなく取り違えを検出するための照合。ファイル名は path の hash なので、
      // 中身の policyPath が一致しないのは想定外の状態。
      if (record.policyPath !== policyPath) {
        throw new TypeError(
          "approved manifest pointer does not belong to the policy file it was read for",
        );
      }
      return record;
    },

    // 承認のたびに上書きする。これが「有効な承認は常にちょうど 1 つ」を表す。
    write({ policyPath, manifestHash, approvalId, approvedAt }) {
      const record = {
        version: APPROVED_MANIFEST_VERSION,
        policyPath,
        manifestHash,
        approvalId,
        approvedAt,
      };
      normalizeRecord(record, "approved manifest pointer");
      writeJsonAtomic(targetFor(policyPath), record, "approved manifest pointer");
      return record;
    },
  };
}
