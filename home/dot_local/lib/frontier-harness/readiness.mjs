import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

import { writeJsonAtomic } from "./paths.mjs";

// cache をどれだけ信頼するか（TTL）と、probe プロセスをどれだけ待つか（timeout）は
// 意味が異なるため別の定数にする。TTL を timeout に流用すると `agy models` の
// ハングで CLI が 15 分ブロックする。
const READINESS_TTL_MS = 15 * 60 * 1000;
const PROBE_TIMEOUT_MS = 30 * 1000;

export function probeAntigravity(executable, runner = spawnSync) {
  if (!executable) {
    return { verified: false, models: [], reason: "agy executable is unavailable" };
  }
  // PATH の空要素由来の相対パスは CWD 基準で解決されるため起動しない（多層防御）。
  if (!path.isAbsolute(executable)) {
    return {
      verified: false,
      models: [],
      reason: "agy executable must be resolved to an absolute path",
    };
  }
  const result = runner(executable, ["models", "--output-format", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: PROBE_TIMEOUT_MS,
  });
  if (result.status !== 0) {
    const reason = String(result.stderr ?? "").toLowerCase().includes("auth")
      ? "authentication required for Antigravity model discovery"
      : "Antigravity model discovery failed";
    return { verified: false, models: [], reason };
  }
  try {
    const payload = JSON.parse(result.stdout ?? "");
    const entries = Array.isArray(payload) ? payload : payload.models;
    const models = Array.isArray(entries)
      ? entries
          .map((entry) => (typeof entry === "string" ? entry : entry?.slug))
          .filter((slug) => typeof slug === "string" && slug.length > 0)
      : [];
    if (models.length === 0) {
      return { verified: false, models: [], reason: "model discovery returned no models" };
    }
    return { verified: true, models };
  } catch {
    return { verified: false, models: [], reason: "model discovery returned invalid JSON" };
  }
}

// 検出済み model 一覧を provider ごとに返す。provider 名だけを返すと
// 「設定した model が discovery 結果に無くても available」になるため、model を捨てない。
export function loadVerifiedModels(readinessPath, now = Date.now()) {
  try {
    const readiness = JSON.parse(readFileSync(readinessPath, "utf8"));
    const entry = readiness.antigravity;
    const verifiedAt = Date.parse(entry?.verifiedAt ?? "");
    const models = Array.isArray(entry?.models)
      ? entry.models.filter((slug) => typeof slug === "string" && slug.length > 0)
      : [];
    if (
      entry?.verified === true &&
      Number.isFinite(verifiedAt) &&
      // 未来日時の cache は TTL 差分が負値になり素通りするため下限も検査する。
      now >= verifiedAt &&
      now - verifiedAt <= READINESS_TTL_MS &&
      models.length > 0
    ) {
      return { antigravity: models };
    }
  } catch {
    // Readiness is optional; an absent or corrupt cache remains unverified.
  }
  return {};
}

export function loadVerifiedProviders(readinessPath, now = Date.now()) {
  return Object.keys(loadVerifiedModels(readinessPath, now));
}

export function writeReadiness(readinessPath, probe) {
  return writeJsonAtomic(
    readinessPath,
    {
      version: 1,
      antigravity: {
        verified: probe.verified === true,
        verifiedAt: new Date().toISOString(),
        models: probe.models ?? [],
      },
    },
    "readiness cache",
  );
}
