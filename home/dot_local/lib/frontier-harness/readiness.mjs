import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const READINESS_TTL_MS = 15 * 60 * 1000;

export function probeAntigravity(executable, runner = spawnSync) {
  if (!executable) {
    return { verified: false, models: [], reason: "agy executable is unavailable" };
  }
  const result = runner(executable, ["models", "--output-format", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: READINESS_TTL_MS,
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

export function loadVerifiedProviders(readinessPath, now = Date.now()) {
  try {
    const readiness = JSON.parse(requireReadiness(readinessPath));
    const verifiedAt = Date.parse(readiness.antigravity?.verifiedAt ?? "");
    if (
      readiness.antigravity?.verified === true &&
      Number.isFinite(verifiedAt) &&
      now - verifiedAt <= READINESS_TTL_MS
    ) {
      return ["antigravity"];
    }
  } catch {
    // Readiness is optional; an absent or corrupt cache remains unverified.
  }
  return [];
}

function requireReadiness(readinessPath) {
  return readFileSync(readinessPath, "utf8");
}

export function writeReadiness(readinessPath, probe) {
  mkdirSync(path.dirname(readinessPath), { mode: 0o700, recursive: true });
  const temporaryPath = `${readinessPath}.${process.pid}.tmp`;
  writeFileSync(
    temporaryPath,
    `${JSON.stringify({
      version: 1,
      antigravity: {
        verified: probe.verified === true,
        verifiedAt: new Date().toISOString(),
        models: probe.models ?? [],
      },
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  chmodSync(temporaryPath, 0o600);
  renameSync(temporaryPath, readinessPath);
}
