// 外部入力（evaluator が投入する候補 JSON、ディスク上の state、CLI 引数）は信頼しない。
// 書き込み経路はすべてこのモジュールの normalize/parse を通してから store へ渡す。
// 検証は「全件を検証してから 1 度だけ書く」順序で使うこと（部分適用を作らない）。

export const QUEUE_VERSION = 1;

export const DAY_MS = 86_400_000;

export const CANDIDATE_STATES = Object.freeze([
  "active",
  "deferred",
  "adopted",
  "rejected",
  "promoted",
]);

// 終端状態。AC-036「Issue 化済み候補は再提示しない」と、見送りの尊重のため、
// upsert / resolve のどちらからも復活させない。
export const TERMINAL_STATES = Object.freeze(["rejected", "promoted"]);

// AC-039: 回答は三択に固定する。
export const DECISIONS = Object.freeze(["adopt", "defer", "reject"]);

// AC-034: 順位の根拠として記録する 5 指標。
export const RANKING_KEYS = Object.freeze([
  "frequency",
  "impact",
  "evidence_strength",
  "implementation_cost",
  "expected_effect",
]);

// 影響と期待効果を重く、実装コスト/リスクは減点として効かせる。順位そのものは
// 保存せず毎回この重みから導出する（保存した順位と指標が乖離しないため）。
export const RANKING_WEIGHTS = Object.freeze({
  frequency: 1,
  impact: 1.5,
  evidence_strength: 1,
  implementation_cost: -1,
  expected_effect: 1.5,
});

export const RANKING_MIN = 1;
export const RANKING_MAX = 5;

// AC-036: 新しい根拠が無い active 候補は 4 週間で失効する。
export const EXPIRY_DAYS = 28;
// AC-039:「次週まで延期」の既定幅。
export const DEFAULT_DEFER_DAYS = 7;

// AC-041: 採用候補が持つべき 4 項目。
export const ADOPTION_KEYS = Object.freeze([
  "success_metric",
  "baseline",
  "review_on",
  "fallback",
]);

const CANDIDATE_INPUT_KEYS = Object.freeze([
  "id",
  "title",
  "summary",
  "evidence_accounts",
  "ranking",
  "created_at",
  "evidence_updated_at",
]);

// id は表示・重複排除のキーであり、将来ファイル名やコマンド引数へ渡りうる。
// パス片・空白・制御文字が混ざらない字種に限定する。
const ID_PATTERN = /^[a-z0-9][a-z0-9-]*$/;
// account ラベルは設定由来で増減しうるため、閉じた enum ではなく字種で縛る。
const ACCOUNT_PATTERN = /^[a-z][a-z0-9-]*$/;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const ISSUE_PATH_PATTERN = /^\/[^/]+\/[^/]+\/issues\/[1-9]\d*$/;

const MAX_ID_LENGTH = 100;
const MAX_TITLE_LENGTH = 200;
const MAX_TEXT_LENGTH = 2000;
const MAX_URL_LENGTH = 300;
const MAX_ACCOUNTS = 10;

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireObject(value, label) {
  if (!isPlainObject(value)) throw new TypeError(`${label} must be an object`);
  return value;
}

// 未知キーは黙って捨てない。`evidence_account`（単数形）のような綴り違いを
// 素通りさせると provenance が静かに欠落する。
function rejectUnknownKeys(value, allowedKeys, label) {
  const unknown = Object.keys(value).filter((key) => !allowedKeys.includes(key));
  if (unknown.length > 0) {
    throw new TypeError(`${label} has unknown keys: ${unknown.join(", ")}`);
  }
}

function requireText(value, label, maxLength = MAX_TEXT_LENGTH) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError(`${label} must be a non-empty string`);
  }
  if (value.length > maxLength) {
    throw new TypeError(`${label} must be at most ${maxLength} characters`);
  }
  return value.trim();
}

function requirePattern(value, pattern, label, maxLength) {
  const text = requireText(value, label, maxLength);
  if (!pattern.test(text)) {
    throw new TypeError(`${label} must match ${pattern}`);
  }
  return text;
}

// ISO8601 として実際に解釈できることまで確認し、正規形へ揃えて保存する。
export function requireTimestamp(value, label) {
  const text = requireText(value, label, MAX_TITLE_LENGTH);
  const parsed = Date.parse(text);
  if (!Number.isFinite(parsed)) {
    throw new TypeError(`${label} must be an ISO 8601 timestamp`);
  }
  return new Date(parsed).toISOString();
}

// 日付は UTC で解釈する。round-trip 比較で 2026-02-31 のような存在しない日を弾く。
export function requireDate(value, label) {
  const text = requirePattern(value, DATE_PATTERN, label, MAX_TITLE_LENGTH);
  const parsed = new Date(`${text}T00:00:00Z`);
  if (!Number.isFinite(parsed.getTime())) {
    throw new TypeError(`${label} must be a calendar date (YYYY-MM-DD)`);
  }
  if (parsed.toISOString().slice(0, 10) !== text) {
    throw new TypeError(`${label} is not a real calendar date: ${text}`);
  }
  return text;
}

export function parseIssueUrl(value) {
  const text = requireText(value, "issue_url", MAX_URL_LENGTH);
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new TypeError("issue_url must be a valid URL");
  }
  if (url.protocol !== "https:" || url.hostname !== "github.com") {
    throw new TypeError("issue_url must be an https://github.com/... URL");
  }
  if (!ISSUE_PATH_PATTERN.test(url.pathname)) {
    throw new TypeError(
      "issue_url must point at https://github.com/<owner>/<repo>/issues/<number>",
    );
  }
  // query / fragment は正本の識別に不要なので落とす。
  return `${url.origin}${url.pathname}`;
}

function normalizeAccounts(value) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new TypeError("evidence_accounts must be a non-empty array");
  }
  if (value.length > MAX_ACCOUNTS) {
    throw new TypeError(
      `evidence_accounts must have at most ${MAX_ACCOUNTS} entries`,
    );
  }
  const accounts = value.map((entry, index) =>
    requirePattern(
      entry,
      ACCOUNT_PATTERN,
      `evidence_accounts[${index}]`,
      MAX_ID_LENGTH,
    ),
  );
  return Object.freeze([...new Set(accounts)].sort());
}

function normalizeRanking(value) {
  const ranking = requireObject(value, "ranking");
  rejectUnknownKeys(ranking, RANKING_KEYS, "ranking");
  const normalized = {};
  for (const key of RANKING_KEYS) {
    const score = ranking[key];
    if (!Number.isInteger(score) || score < RANKING_MIN || score > RANKING_MAX) {
      throw new TypeError(
        `ranking.${key} must be an integer between ${RANKING_MIN} and ${RANKING_MAX}`,
      );
    }
    normalized[key] = score;
  }
  return Object.freeze(normalized);
}

export function normalizeAdoption(value) {
  const adoption = requireObject(value, "adoption");
  rejectUnknownKeys(adoption, ADOPTION_KEYS, "adoption");
  return Object.freeze({
    success_metric: requireText(adoption.success_metric, "adoption.success_metric"),
    baseline: requireText(adoption.baseline, "adoption.baseline"),
    review_on: requireDate(adoption.review_on, "adoption.review_on"),
    fallback: requireText(adoption.fallback, "adoption.fallback"),
  });
}

// 投入時に省略された timestamp は「今」で埋める。既定値を持たない呼び出し
// （保存済み候補の再検証）では省略を許さず、欠落として弾く。
function timestampOrDefault(value, fallbackIso, label) {
  if (value !== undefined) return requireTimestamp(value, label);
  if (typeof fallbackIso !== "string") {
    throw new TypeError(`${label} is required`);
  }
  return requireTimestamp(fallbackIso, label);
}

// evaluator / 手動投入が渡す候補。state は受け付けない（外部入力から `promoted` を
// 名乗らせない）。状態遷移は resolve だけが行う。
export function normalizeCandidateInput(value, nowIso) {
  const input = requireObject(value, "candidate");
  rejectUnknownKeys(input, CANDIDATE_INPUT_KEYS, "candidate");
  return Object.freeze({
    id: requirePattern(input.id, ID_PATTERN, "candidate.id", MAX_ID_LENGTH),
    title: requireText(input.title, "candidate.title", MAX_TITLE_LENGTH),
    summary: requireText(input.summary, "candidate.summary"),
    evidence_accounts: normalizeAccounts(input.evidence_accounts),
    ranking: normalizeRanking(input.ranking),
    created_at: timestampOrDefault(
      input.created_at,
      nowIso,
      "candidate.created_at",
    ),
    evidence_updated_at: timestampOrDefault(
      input.evidence_updated_at,
      nowIso,
      "candidate.evidence_updated_at",
    ),
  });
}

const DECISION_KEYS = Object.freeze(["kind", "at", "note"]);

function normalizeDecision(value) {
  const decision = requireObject(value, "candidate.decision");
  rejectUnknownKeys(decision, DECISION_KEYS, "candidate.decision");
  if (!DECISIONS.includes(decision.kind)) {
    throw new TypeError(
      `candidate.decision.kind must be one of ${DECISIONS.join(", ")}`,
    );
  }
  const normalized = {
    kind: decision.kind,
    at: requireTimestamp(decision.at, "candidate.decision.at"),
  };
  if (decision.note !== undefined) {
    normalized.note = requireText(decision.note, "candidate.decision.note");
  }
  return Object.freeze(normalized);
}

const PROMOTION_KEYS = Object.freeze(["issue_url", "at"]);

function normalizePromotion(value) {
  const promotion = requireObject(value, "candidate.promotion");
  rejectUnknownKeys(promotion, PROMOTION_KEYS, "candidate.promotion");
  return Object.freeze({
    issue_url: parseIssueUrl(promotion.issue_url),
    at: requireTimestamp(promotion.at, "candidate.promotion.at"),
  });
}

// AC-040: Issue 化した候補は GitHub Issue を唯一の正本にするため、queue 側には
// 識別に必要な最小項目と URL しか残さない。ディスク上の形もそれに合わせて縛る。
const PROMOTED_KEYS = Object.freeze([
  "id",
  "title",
  "state",
  "created_at",
  "promotion",
]);

const STORED_KEYS = Object.freeze([
  ...CANDIDATE_INPUT_KEYS,
  "state",
  "decision",
  "deferred_until",
  "adoption",
]);

function normalizeStoredCandidate(value) {
  const stored = requireObject(value, "candidate");
  if (!CANDIDATE_STATES.includes(stored.state)) {
    throw new TypeError(
      `candidate.state must be one of ${CANDIDATE_STATES.join(", ")}`,
    );
  }

  if (stored.state === "promoted") {
    rejectUnknownKeys(stored, PROMOTED_KEYS, "promoted candidate");
    return Object.freeze({
      id: requirePattern(stored.id, ID_PATTERN, "candidate.id", MAX_ID_LENGTH),
      title: requireText(stored.title, "candidate.title", MAX_TITLE_LENGTH),
      state: "promoted",
      created_at: requireTimestamp(stored.created_at, "candidate.created_at"),
      promotion: normalizePromotion(stored.promotion),
    });
  }

  rejectUnknownKeys(stored, STORED_KEYS, "candidate");
  const base = normalizeCandidateInput(
    Object.fromEntries(
      CANDIDATE_INPUT_KEYS.filter((key) => stored[key] !== undefined).map(
        (key) => [key, stored[key]],
      ),
    ),
    // 保存済み候補では両 timestamp が必須。既定値で埋めない。
    undefined,
  );
  const candidate = { ...base, state: stored.state };
  if (stored.decision !== undefined) {
    candidate.decision = normalizeDecision(stored.decision);
  }
  if (stored.state === "deferred") {
    candidate.deferred_until = requireTimestamp(
      stored.deferred_until,
      "candidate.deferred_until",
    );
  }
  if (stored.state === "adopted") {
    candidate.adoption = normalizeAdoption(stored.adoption);
  }
  return Object.freeze(candidate);
}

const QUEUE_KEYS = Object.freeze(["version", "updated_at", "candidates"]);

export function emptyQueueDocument(nowIso) {
  return Object.freeze({
    version: QUEUE_VERSION,
    updated_at: nowIso,
    candidates: Object.freeze([]),
  });
}

// ディスク上の state。壊れていたら黙って空にせず throw する（採否履歴を消さない）。
export function parseQueueDocument(value) {
  const document = requireObject(value, "queue");
  rejectUnknownKeys(document, QUEUE_KEYS, "queue");
  if (document.version !== QUEUE_VERSION) {
    throw new TypeError(
      `queue.version must be ${QUEUE_VERSION} (found ${JSON.stringify(document.version)})`,
    );
  }
  if (!Array.isArray(document.candidates)) {
    throw new TypeError("queue.candidates must be an array");
  }
  const candidates = document.candidates.map(normalizeStoredCandidate);
  const ids = new Set();
  for (const candidate of candidates) {
    if (ids.has(candidate.id)) {
      throw new TypeError(`queue.candidates has a duplicate id: ${candidate.id}`);
    }
    ids.add(candidate.id);
  }
  return Object.freeze({
    version: QUEUE_VERSION,
    updated_at: requireTimestamp(document.updated_at, "queue.updated_at"),
    candidates: Object.freeze(candidates),
  });
}
