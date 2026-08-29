import {
  REVIEW_SEVERITIES,
  rejectUnknownKeys,
  requireObject,
} from "./record-validation.mjs";
import { normalizeReviewFinding } from "./records.mjs";

// review registry —— レビューを散文ではなく**正規化された finding の集合**として扱う。
//
// これ以前の `fh review` は「independent review planned for <task>」という evidence を 1 行
// 置くだけで、レビューが行われたかどうかも、何が見つかったかも state に残らなかった。
// registry が受け取るのは severity / uncertainty / 1 行の finding / 反証実験の 4 つだけで、
// レビュー本文・推論・writer の会話履歴を入れる列は**存在しない**（`records.mjs` の
// `REVIEW_FINDING_KEYS` が未知キーを拒否する）。
//
// 自由文の扱いについて。`review_findings.summary` は「その指摘は何か」を 1 行で述べる欄で、
// これが無いと finding は行動に移せない（schema v2 が NOT NULL で置いた理由）。ただし列がある
// だけでは、そこがレビュー本文の抜け道になる。そこで境界で **1 行・印字可能・長さ上限**を課し、
// 「1 行の指摘」以上のものが物理的に入らないようにする。severity 別の件数と verdict しか
// evidence へ載せないのも同じ理由で、集計だけなら閉じた語彙に収まる。

export const REVIEW_FINDINGS_VERSION = 1;
// 1 回のレビューで受け取る finding の上限。無制限にすると、registry が `review_findings` を
// 無制限に肥やす経路になる（`manifest-gaps.mjs` が queue に上限を置いたのと同じ理由）。
export const REVIEW_FINDINGS_MAX_ENTRIES = 200;
// finding 1 行の上限。要約であって本文でないことを長さで担保する。
export const REVIEW_TEXT_MAX_LENGTH = 300;

const DOCUMENT_KEYS = new Set(["version", "reviewerCapability", "findings"]);
const FINDING_KEYS = new Set([
  "severity",
  "uncertainty",
  "summary",
  "discriminatingExperiment",
]);
// reviewer capability は config の capability 名と同じ字集合に限る。
const REVIEWER_CAPABILITY_PATTERN = /^[a-z][a-z0-9._-]*$/;
// capability 名も長さを縛る。`summary` だけ上限を課しても、この値が evidence の claim へ
// 埋め込まれる以上、無制限なら同じ経路で state を肥やせる（`records.mjs` の token 上限と同趣旨）。
export const REVIEWER_CAPABILITY_MAX_LENGTH = 64;
// 改行・制御文字・書式文字・**行区切り文字**を弾く。これが「1 行の指摘」を「レビュー本文」から
// 隔てる境界で、同時に端末へ ANSI エスケープを流し込む経路も塞ぐ。
//
// `Zl`（U+2028 LINE SEPARATOR）と `Zp`（U+2029 PARAGRAPH SEPARATOR）を落としてはいけない:
// どちらも `Cc` にも `Cf` にも属さないため、カテゴリを 2 つだけ見る実装では素通りし、
// 多くの端末・ブラウザで改行として描画される。つまり「1 行」の保証がそこだけ破れる。
const CONTROL_CHARACTERS = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;

// finding の 1 行テキスト。空白の揺れだけ畳み、内容は変えない。
export function requireFindingText(value, label) {
  if (typeof value !== "string") {
    throw new TypeError(`${label} must be a string`);
  }
  const text = value.trim();
  if (text.length === 0) {
    throw new TypeError(`${label} must not be empty`);
  }
  if (text.length > REVIEW_TEXT_MAX_LENGTH) {
    throw new TypeError(
      `${label} must be at most ${REVIEW_TEXT_MAX_LENGTH} characters; a review body does not belong in the registry`,
    );
  }
  if (CONTROL_CHARACTERS.test(text)) {
    throw new TypeError(`${label} must be a single line of printable text`);
  }
  return text;
}

// レビュー結果ファイルを正規化する。**taskId と reviewerCapability はファイルからは採らない**
// ものを含む: taskId は呼び出し側（CLI の `--task`）が決め、reviewer が自称した task へ
// finding を紐付けられないようにする。
export function normalizeFindingsDocument(input, { taskId }) {
  requireObject(input, "review findings document");
  rejectUnknownKeys(input, DOCUMENT_KEYS, "review findings document");
  if (input.version !== REVIEW_FINDINGS_VERSION) {
    throw new TypeError(
      `review findings document version must be ${REVIEW_FINDINGS_VERSION}`,
    );
  }
  const reviewerCapability = input.reviewerCapability;
  if (
    typeof reviewerCapability !== "string" ||
    !REVIEWER_CAPABILITY_PATTERN.test(reviewerCapability)
  ) {
    throw new TypeError(
      `review findings document reviewerCapability must match ${REVIEWER_CAPABILITY_PATTERN}`,
    );
  }
  if (reviewerCapability.length > REVIEWER_CAPABILITY_MAX_LENGTH) {
    throw new TypeError(
      `review findings document reviewerCapability must be at most ${REVIEWER_CAPABILITY_MAX_LENGTH} characters`,
    );
  }
  if (!Array.isArray(input.findings)) {
    throw new TypeError("review findings document findings must be an array");
  }
  if (input.findings.length > REVIEW_FINDINGS_MAX_ENTRIES) {
    throw new TypeError(
      `review findings document must have at most ${REVIEW_FINDINGS_MAX_ENTRIES} findings`,
    );
  }

  const findings = input.findings.map((finding, index) => {
    const label = `review finding[${index}]`;
    requireObject(finding, label);
    // ここで未知キーを弾くのが要点。`transcript` や `rationale` を足しても
    // 「黙って捨てる」ではなく loud に落ちる。
    rejectUnknownKeys(finding, FINDING_KEYS, label);
    return normalizeReviewFinding({
      taskId,
      reviewerCapability,
      severity: finding.severity,
      uncertainty: finding.uncertainty,
      summary: requireFindingText(finding.summary, `${label} summary`),
      discriminatingExperiment:
        finding.discriminatingExperiment === undefined ||
        finding.discriminatingExperiment === null
          ? null
          : requireFindingText(
              finding.discriminatingExperiment,
              `${label} discriminatingExperiment`,
            ),
    });
  });

  return { reviewerCapability, findings };
}

export function severityCounts(findings) {
  const counts = Object.fromEntries([...REVIEW_SEVERITIES].map((severity) => [severity, 0]));
  for (const finding of findings) counts[finding.severity] += 1;
  return counts;
}

// verdict は「取り込んでよいか」の判定であって、レビューの要約ではない。
// `must` が 1 件でもあれば blocked —— multi-review の [MUST] と同じ語彙を同じ意味で使う。
export function reviewVerdict(findings) {
  const counts = severityCounts(findings);
  return { verdict: counts.must > 0 ? "blocked" : "clear", counts };
}

// evidence に載せるのは件数と verdict だけ。severity は閉じた enum、件数は整数、
// capability 名は上のパターンに縛られているので、ここから自由文は出てこない。
export function reviewClaims({ reviewerCapability, counts, verdict }) {
  const claims = [`${reviewerCapability} returned a ${verdict} review verdict`];
  for (const severity of [...REVIEW_SEVERITIES].sort()) {
    if (counts[severity] > 0) {
      claims.push(`the review recorded ${counts[severity]} ${severity} finding(s)`);
    }
  }
  return claims;
}
