import { randomUUID } from "node:crypto";

import { PROVIDER_COMMANDS } from "./providers.mjs";

// state へ書き込むレコードの列挙値と、汎用の境界検証プリミティブ。
// entity ごとの normalizer は records.mjs にある（ここは entity を知らない）。

// ---------------------------------------------------------------------------
// 列挙値（enum の SSOT）
// ---------------------------------------------------------------------------

export const ADAPTER_RUN_STATUSES = new Set([
  "planned",
  "running",
  "succeeded",
  "failed",
  "cancelled",
]);

// 終端状態では finished_at が確定していなければならない。
export const TERMINAL_ADAPTER_RUN_STATUSES = new Set([
  "succeeded",
  "failed",
  "cancelled",
]);

export const VERIFICATION_CHECK_KINDS = new Set([
  "test",
  "typecheck",
  "lint",
  "browser",
  "performance",
  "security",
]);

export const VERIFICATION_STATUSES = new Set([
  "passed",
  "failed",
  "skipped",
  "errored",
]);

// multi-review が使う [MUST]/[SHOULD]/[NITS]/[GOOD] と同じ語彙に揃える。
export const REVIEW_SEVERITIES = new Set(["must", "should", "nits", "good"]);

export const REVIEW_UNCERTAINTIES = new Set(["low", "medium", "high"]);

export const APPROVAL_KINDS = new Set([
  "repository_manifest",
  "intent",
  "capability",
  "wave_batch",
]);

// 承認者は user だけ。model が「自分が承認した」と自称する経路を塞ぐ。
//
// ただしこれは承認者ラベルの語彙を縛るだけで、承認の出所の証明ではない。
// harness 内のコードはどれも grantedBy: "user" を書けるため、承認 1 行を根拠に
// escalation を免除する consumer は、この列だけを信頼してはならない。
// 出所をどう証明・検証するかは #494（onboarding 承認の実効化）が決める。
// 検証方式が決まる前に取得経路の語彙をここで固定すると、#494 が実際に必要とする
// 形と食い違ったまま NOT NULL 列だけが残る。
export const APPROVAL_GRANTORS = new Set(["user"]);

export const TELEMETRY_VERIFICATION_RESULTS = new Set([
  "passed",
  "failed",
  "mixed",
  "none",
]);

export const TELEMETRY_OUTCOMES = new Set([
  "pending",
  "merged",
  "closed",
  "abandoned",
  "reverted",
]);

// telemetry は「内容を含まない集約」でなければならない（180 日保持されるため）。
// 自由記述列を一切持たせず、TEXT はすべて enum か下記 token に制限する。
export const TELEMETRY_TOKEN_PATTERN = /^[a-z][a-z0-9._-]*$/;
// token は小文字 hex や base32 を素通りさせるため、長さがそのまま「符号化して運べる容量」になる。
// 出荷 config の最長 model 名は 21 文字なので、実用を損なわない範囲まで詰める。
export const TELEMETRY_TOKEN_MAX_LENGTH = 32;
// 要素数を縛らないと、token 配列がそのまま長さ無制限の TEXT 列になり、
// 「内容を含まない」という 180 日保持の根拠が崩れる。出荷 config の alwaysEscalate は 8 件。
export const TELEMETRY_RISK_MAX_ENTRIES = 16;

// provider は providers.mjs の PROVIDER_COMMANDS が唯一の語彙。ここで再定義しない。
export const TELEMETRY_PROVIDERS = new Set(Object.keys(PROVIDER_COMMANDS));
// telemetry 列の制約であると同時に、**harness で唯一の effort 語彙**である。
// adapter-contract.mjs の requireCapabilityTokens が実行前検査にも同じ Set を使うため、
// ここを変えると adapter が受け付ける effort も変わる（2 つ目の語彙を作らないための共有）。
export const TELEMETRY_EFFORTS = new Set(["low", "medium", "high", "xhigh"]);

// ---------------------------------------------------------------------------
// 汎用 validator
// ---------------------------------------------------------------------------

export function newId(prefix) {
  return `${prefix}_${randomUUID().replaceAll("-", "")}`;
}

export function nowIso() {
  return new Date().toISOString();
}

export function requireObject(input, label) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError(`${label} must be an object`);
  }
}

// 未知キーを拒否する。id や contentHash のように「受け取っても捨てる」キーは
// allowed 側に入れておき、normalizer が値を採用しないことで上書きを防ぐ。
export function rejectUnknownKeys(input, allowed, label) {
  const unknown = Object.keys(input).find((key) => !allowed.has(key));
  if (unknown) {
    throw new TypeError(`${label} contains an unsupported key: ${unknown}`);
  }
}

export function requireNonEmptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} must be a non-empty string`);
  }
  return value;
}

export function optionalNonEmptyString(value, label) {
  if (value === undefined || value === null) return null;
  return requireNonEmptyString(value, label);
}

export function requireEnum(value, allowed, label) {
  if (typeof value !== "string" || !allowed.has(value)) {
    throw new TypeError(
      `${label} must be one of: ${[...allowed].sort().join(", ")}`,
    );
  }
  return value;
}

export function optionalEnum(value, allowed, label) {
  if (value === undefined || value === null) return null;
  return requireEnum(value, allowed, label);
}

// 保持期間は created_at の辞書式比較で判定するため、表記ゆれが混ざると
// 比較そのものが壊れる。パースできることを確認したうえで canonical な
// ISO 8601 UTC 表現へ正規化して返す（拒否より寛容で、比較の健全性は同じ）。
export function requireTimestamp(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} must be an ISO 8601 timestamp`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new TypeError(`${label} must be an ISO 8601 timestamp`);
  }
  return parsed.toISOString();
}

export function optionalTimestamp(value, label) {
  if (value === undefined || value === null) return null;
  return requireTimestamp(value, label);
}

// 端末間の時計ずれとして許容する幅。
export const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

// 「起きた時刻」は未来であってはならない。retention は created_at < cutoff の比較なので、
// 未来日時の行は永久に prune されず、自由記述列（command / failure_reason 等）が
// 保持期間を越えて残留する。失効時刻（expiresAt）は未来が正常なので requireTimestamp を使う。
export function requireOccurredAt(value, label) {
  const timestamp = requireTimestamp(value, label);
  if (Date.parse(timestamp) > Date.now() + MAX_CLOCK_SKEW_MS) {
    throw new TypeError(`${label} must not be in the future`);
  }
  return timestamp;
}

export function optionalOccurredAt(value, label) {
  if (value === undefined || value === null) return null;
  return requireOccurredAt(value, label);
}

export function optionalInteger(value, label) {
  if (value === undefined || value === null) return null;
  if (!Number.isInteger(value)) {
    throw new TypeError(`${label} must be an integer`);
  }
  return value;
}

export function optionalNonNegativeInteger(value, label) {
  const parsed = optionalInteger(value, label);
  if (parsed !== null && parsed < 0) {
    throw new TypeError(`${label} must not be negative`);
  }
  return parsed;
}

export function optionalUnitInterval(value, label) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number`);
  }
  if (value < 0 || value > 1) {
    throw new TypeError(`${label} must be between 0 and 1`);
  }
  return value;
}

export function optionalBoolean(value, label) {
  if (value === undefined || value === null) return false;
  if (typeof value !== "boolean") {
    throw new TypeError(`${label} must be a boolean`);
  }
  return value;
}

export function requireToken(value, label) {
  requireNonEmptyString(value, label);
  if (value.length > TELEMETRY_TOKEN_MAX_LENGTH) {
    throw new TypeError(
      `${label} must be at most ${TELEMETRY_TOKEN_MAX_LENGTH} characters`,
    );
  }
  if (!TELEMETRY_TOKEN_PATTERN.test(value)) {
    throw new TypeError(`${label} must match ${TELEMETRY_TOKEN_PATTERN}`);
  }
  return value;
}

export function optionalToken(value, label) {
  if (value === undefined || value === null) return null;
  return requireToken(value, label);
}

export function optionalTokenArray(value, label, maxEntries) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new TypeError(`${label} must be an array`);
  }
  if (maxEntries !== undefined && value.length > maxEntries) {
    throw new TypeError(`${label} must have at most ${maxEntries} entries`);
  }
  return value.map((entry, index) => requireToken(entry, `${label}[${index}]`));
}

export function optionalStringArray(value, label) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new TypeError(`${label} must be an array`);
  }
  return value.map((entry, index) =>
    requireNonEmptyString(entry, `${label}[${index}]`),
  );
}
