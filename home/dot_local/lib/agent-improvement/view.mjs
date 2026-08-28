import {
  DAY_MS,
  EXPIRY_DAYS,
  RANKING_KEYS,
  RANKING_WEIGHTS,
} from "./schema.mjs";

// 失効・延期解除・再評価期日は、保存値からの導出ビューとして毎回計算する。
// state へ書き戻さないので、表示しただけで state が変わる経路が存在しない
// （#501 完了条件）。

const HISTORY_STATES = Object.freeze([
  "deferred",
  "expired",
  "rejected",
  "promoted",
]);

const STATE_LABELS = Object.freeze({
  active: "候補",
  adopted: "採用済み",
  review_due: "再評価期日",
  deferred: "延期中",
  expired: "失効",
  rejected: "見送り",
  promoted: "Issue 化済み",
});

export function rankScore(ranking) {
  return RANKING_KEYS.reduce(
    (total, key) => total + ranking[key] * RANKING_WEIGHTS[key],
    0,
  );
}

function utcDate(now) {
  return now.toISOString().slice(0, 10);
}

export function deriveCandidate(candidate, now) {
  const nowMs = now.getTime();

  // promoted は payload を捨てているので ranking を持たない（AC-040）。
  if (candidate.state === "promoted") {
    return Object.freeze({ ...candidate, derived_state: "promoted" });
  }

  const score = rankScore(candidate.ranking);
  // rejected も導出は不要だが rank_score は付ける。付けないと履歴の整形が
  // score=undefined を表示する（整形側は順位を常に出す）。
  if (candidate.state === "rejected") {
    return Object.freeze({
      ...candidate,
      derived_state: "rejected",
      rank_score: score,
    });
  }

  // comparator が同点判定のたびに Date.parse し直さずに済むよう、導出時に一度だけ
  // epoch を持たせる。
  const evidenceMs = Date.parse(candidate.evidence_updated_at);

  if (candidate.state === "adopted") {
    // 日付は UTC で比較する（週次運用なので時差の分の前倒しは許容する）。
    const due = candidate.adoption.review_on <= utcDate(now);
    return Object.freeze({
      ...candidate,
      derived_state: due ? "review_due" : "adopted",
      rank_score: score,
      evidence_ms: evidenceMs,
    });
  }

  if (
    candidate.state === "deferred" &&
    Date.parse(candidate.deferred_until) > nowMs
  ) {
    return Object.freeze({
      ...candidate,
      derived_state: "deferred",
      rank_score: score,
      evidence_ms: evidenceMs,
    });
  }

  // 延期期限が切れた候補は active と同じ判定に落とす（AC-039「次週まで延期」）。
  //
  // 境界は「ちょうど EXPIRY_DAYS 経過した時点で失効」（下の `<=`）。AC-036 が
  // 「新しい根拠がなければ 4 週間で失効する」と定めているため、4 週間ちょうどは
  // 失効側に含める。
  const expiresAtMs = evidenceMs + EXPIRY_DAYS * DAY_MS;
  return Object.freeze({
    ...candidate,
    derived_state: expiresAtMs <= nowMs ? "expired" : "active",
    rank_score: score,
    evidence_ms: evidenceMs,
    expires_at: new Date(expiresAtMs).toISOString(),
  });
}

// 同点は根拠の新しい順 → id 昇順で解決し、実行のたびに並びが変わらないようにする。
function byRank(a, b) {
  if (b.rank_score !== a.rank_score) return b.rank_score - a.rank_score;
  const evidenceDelta = b.evidence_ms - a.evidence_ms;
  if (evidenceDelta !== 0) return evidenceDelta;
  return a.id < b.id ? -1 : 1;
}

// 履歴は順位ではなく状態と id で決定論的に並べる（promoted は順位を持たない）。
function byHistory(a, b) {
  const stateDelta =
    HISTORY_STATES.indexOf(a.derived_state) -
    HISTORY_STATES.indexOf(b.derived_state);
  if (stateDelta !== 0) return stateDelta;
  return a.id < b.id ? -1 : 1;
}

// `includeHistory` を渡さない呼び出し（`next` や `status` の既定）では履歴の
// filter / sort を組み立てない。表示しないものを毎回並べ替える理由がない。
export function partitionQueue(document, now, { includeHistory = true } = {}) {
  const derived = document.candidates.map((candidate) =>
    deriveCandidate(candidate, now),
  );
  return Object.freeze({
    active: Object.freeze(
      derived
        .filter((candidate) => candidate.derived_state === "active")
        .sort(byRank),
    ),
    adopted: Object.freeze(
      derived
        .filter(
          (candidate) =>
            candidate.derived_state === "adopted" ||
            candidate.derived_state === "review_due",
        )
        .sort(byRank),
    ),
    history: includeHistory
      ? Object.freeze(
          derived
            .filter((candidate) =>
              HISTORY_STATES.includes(candidate.derived_state),
            )
            .sort(byHistory),
        )
      : Object.freeze([]),
  });
}

// AC-038 が読む「最優先の 1 件」。既に約束した再評価を、新規候補より先に出す。
export function selectNext(document, now) {
  const { active, adopted } = partitionQueue(document, now, {
    includeHistory: false,
  });
  const reviewDue = adopted.filter(
    (candidate) => candidate.derived_state === "review_due",
  );
  return reviewDue[0] ?? active[0] ?? null;
}

function formatHealth(health) {
  if (!health.available) {
    return health.reason === "not-run"
      ? "evaluator: 未実行（health.json なし）"
      : `evaluator: 状態を読み取れません（${health.reason}）`;
  }
  const parts = [`evaluator: ${health.status}`];
  if (health.lastRunAt) parts.push(`最終実行 ${health.lastRunAt}`);
  if (health.detail) parts.push(health.detail);
  return parts.join(" / ");
}

function formatRanking(ranking) {
  return RANKING_KEYS.map((key) => `${key}=${ranking[key]}`).join(" ");
}

function formatCandidate(candidate) {
  const lines = [
    `- [${STATE_LABELS[candidate.derived_state]}] ${candidate.id} — ${candidate.title}`,
  ];
  if (candidate.state === "promoted") {
    lines.push(`  Issue: ${candidate.promotion.issue_url}`);
    return lines;
  }
  lines.push(`  ${candidate.summary}`);
  lines.push(
    `  根拠: ${candidate.evidence_accounts.join(", ")} / 更新 ${candidate.evidence_updated_at}`,
  );
  lines.push(
    `  順位: score=${candidate.rank_score} (${formatRanking(candidate.ranking)})`,
  );
  if (candidate.expires_at) lines.push(`  失効: ${candidate.expires_at}`);
  if (candidate.deferred_until) {
    lines.push(`  延期期限: ${candidate.deferred_until}`);
  }
  if (candidate.adoption) {
    lines.push(`  成功指標: ${candidate.adoption.success_metric}`);
    lines.push(`  基準値: ${candidate.adoption.baseline}`);
    lines.push(`  再評価日: ${candidate.adoption.review_on}`);
    lines.push(`  効果不十分時: ${candidate.adoption.fallback}`);
  }
  return lines;
}

function formatSection(title, candidates, emptyText) {
  if (candidates.length === 0) return [`${title}: ${emptyText}`, ""];
  return [
    `${title}（${candidates.length} 件）:`,
    ...candidates.flatMap(formatCandidate),
    "",
  ];
}

export function formatStatus({
  health,
  partitions,
  includeHistory,
  permissionWarnings = [],
}) {
  const lines = [formatHealth(health)];
  // 権限のドリフトは表示で知らせるだけ（矯正も停止もしない）。次の書き込みで
  // 自動的に 0700/0600 へ戻る。
  for (const warning of permissionWarnings) {
    lines.push(`警告: ${warning}（次の書き込みで矯正されます）`);
  }
  lines.push("");
  lines.push(...formatSection("改善候補", partitions.active, "なし"));
  lines.push(
    ...formatSection("採用済み（効果測定中）", partitions.adopted, "なし"),
  );
  if (includeHistory) {
    lines.push(
      ...formatSection(
        "履歴（延期・見送り・失効・Issue 化）",
        partitions.history,
        "なし",
      ),
    );
  }
  return lines.join("\n").trimEnd();
}

export function formatNext(candidate) {
  if (!candidate) return "提示すべき候補はありません。";
  return formatCandidate(candidate).join("\n");
}
