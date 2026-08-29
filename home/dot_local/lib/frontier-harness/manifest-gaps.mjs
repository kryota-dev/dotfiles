import { readFileSync, readdirSync, unlinkSync } from "node:fs";
import path from "node:path";

import { sha256Hex } from "./hash.mjs";
import { ensureDirectory, writeJsonExclusive } from "./paths.mjs";
import { nowIso, rejectUnknownKeys, requireObject } from "./record-validation.mjs";

// 承認済み manifest に無かった command / domain / capability の記録。
//
// 実行を止めた事実をその場で捨てず、wave の境界で `fh onboard --from-gaps` にまとめて渡せる
// ようにするための queue。承認境界が fail-closed である以上、止まった項目が失われると
// 「なぜ動かないのか」が利用者に届かない。
//
// 1 項目 1 ファイルで、ファイル名は内容から導く hash。書き込みは**作成のみ**（`O_EXCL`）で、
// 既存ファイルには一切触れない。並行する wave 子セッションが同じ項目を同時に踏むのは日常的に
// 起きるので、read-modify-write（出現回数や lastSeenAt の更新）を持たせない設計にしている
// —— 持たせた瞬間に lock 無しでは lost update になる。`approval-queue.mjs` が同じ理由で
// 1 要求 1 ファイルを選んでいるのと同型だが、あちらは tool call 形状に密結合しているため
// 流用はしない（両者の統合は #534 の所有）。

export const MANIFEST_GAP_VERSION = 1;
export const MANIFEST_GAP_KINDS = Object.freeze(
  new Set(["command", "domain", "capability"]),
);

const GAP_SUFFIX = ".gap.json";
const GAP_KEYS = new Set(["version", "kind", "value", "reason", "firstSeenAt"]);

export function manifestGapsDirectory(stateDirectory) {
  return path.join(stateDirectory, "manifest-gaps");
}

// kind と value を配列として hash する。文字列連結にすると、区切り文字を含む value で
// 別の (kind, value) と衝突しうる。
function gapFileName(kind, value) {
  return `${sha256Hex([kind, value])}${GAP_SUFFIX}`;
}

function normalizeGap(input, label) {
  requireObject(input, label);
  rejectUnknownKeys(input, GAP_KEYS, label);
  if (input.version !== MANIFEST_GAP_VERSION) {
    throw new TypeError(`${label} version must be ${MANIFEST_GAP_VERSION}`);
  }
  if (!MANIFEST_GAP_KINDS.has(input.kind)) {
    throw new TypeError(`${label} kind must be command, domain, or capability`);
  }
  if (typeof input.value !== "string" || input.value.length === 0) {
    throw new TypeError(`${label} value must be a non-empty string`);
  }
  return Object.freeze({
    version: input.version,
    kind: input.kind,
    value: input.value,
    reason: typeof input.reason === "string" ? input.reason : null,
    firstSeenAt: input.firstSeenAt,
  });
}

export function createManifestGapQueue({ directory }) {
  return {
    directory,

    // 既に記録済みなら false を返す（冪等）。
    record({ kind, value, reason }) {
      if (!MANIFEST_GAP_KINDS.has(kind)) {
        throw new TypeError("manifest gap kind must be command, domain, or capability");
      }
      if (typeof value !== "string" || value.length === 0) {
        throw new TypeError("manifest gap value must be a non-empty string");
      }
      ensureDirectory(directory, "manifest gap directory");
      return writeJsonExclusive(
        path.join(directory, gapFileName(kind, value)),
        {
          version: MANIFEST_GAP_VERSION,
          kind,
          value,
          reason: typeof reason === "string" && reason.length > 0 ? reason : null,
          firstSeenAt: nowIso(),
        },
        "manifest gap",
      );
    },

    list() {
      let entries;
      try {
        entries = readdirSync(directory);
      } catch (error) {
        if (error?.code === "ENOENT") return [];
        throw error;
      }
      const gaps = [];
      for (const entry of entries.sort()) {
        if (!entry.endsWith(GAP_SUFFIX)) continue;
        const target = path.join(directory, entry);
        // 壊れたファイルは黙って読み飛ばさない。承認境界の入力なので、
        // 「1 件読めなかった」を「gap が無い」に丸めると承認漏れになる。
        gaps.push(
          normalizeGap(JSON.parse(readFileSync(target, "utf8")), `manifest gap ${entry}`),
        );
      }
      return gaps.sort(
        (left, right) =>
          String(left.firstSeenAt).localeCompare(String(right.firstSeenAt)) ||
          left.kind.localeCompare(right.kind) ||
          left.value.localeCompare(right.value),
      );
    },

    clear(gaps) {
      let removed = 0;
      for (const { kind, value } of gaps) {
        try {
          unlinkSync(path.join(directory, gapFileName(kind, value)));
          removed += 1;
        } catch (error) {
          if (error?.code !== "ENOENT") throw error;
        }
      }
      return removed;
    },
  };
}
