import { readFileSync, statSync } from "node:fs";
import { pathToFileURL } from "node:url";

import { queuePath } from "./paths.mjs";
import {
  DAY_MS,
  DECISIONS,
  DEFAULT_DEFER_DAYS,
  normalizeAdoption,
  normalizeCandidateInput,
  parseIssueUrl,
  requireDate,
  TERMINAL_STATES,
} from "./schema.mjs";
import { readHealth, readQueue, writeQueue } from "./store.mjs";
import { formatNext, formatStatus, partitionQueue, selectNext } from "./view.mjs";

// 改善候補キューの唯一の操作面（#473 AC-037 / 039 / 040 / 041）。
// status と next は読み取りのみ、resolve と upsert だけが書き込む。

const BOOLEAN_FLAGS = new Set(["history", "json"]);

// サブコマンドごとの許可フラグ。未知フラグを黙って無視すると、綴り違い
// （`--sucess-metric`）が「未指定」として別の error に化けて原因が見えなくなる。
const COMMAND_FLAGS = Object.freeze({
  status: ["history", "json"],
  next: ["json"],
  resolve: [
    "decision",
    "note",
    "success-metric",
    "baseline",
    "review-on",
    "fallback",
    "issue-url",
    "until",
    "json",
  ],
  upsert: ["file", "json"],
});

const ADOPTION_FLAG_NAMES = Object.freeze([
  "success-metric",
  "baseline",
  "review-on",
  "fallback",
]);

// サブコマンドが受け取る位置引数の数。余分な引数を黙って無視すると、
// `agent-improvement upsert candidates.json` が指定ファイルではなく stdin を読む
// といった、成功したように見えて別物が起きる誤用を通してしまう。
const COMMAND_POSITIONALS = Object.freeze({
  status: 0,
  next: 0,
  resolve: 1,
  upsert: 0,
});

// resolve の三択それぞれが受け付ける追加フラグ。ここに無いフラグを渡されたら
// 黙って捨てずに拒否する（`--decision=defer --issue-url=<不正>` が検証もされずに
// 成功していた）。
const DECISION_FLAG_NAMES = Object.freeze({
  adopt: [...ADOPTION_FLAG_NAMES, "issue-url"],
  defer: ["until"],
  reject: [],
});

// upsert の入力上限。schema 検証は JSON 全体を読み込んでパースした後に効くため、
// 読み込む前に頭打ちを設ける。
const MAX_INPUT_BYTES = 1_048_576;

function parseArguments(tokens, allowed) {
  const flags = new Map();
  const positionals = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }
    const body = token.slice(2);
    const separator = body.indexOf("=");
    const name = separator === -1 ? body : body.slice(0, separator);
    if (!allowed.includes(name)) {
      throw new TypeError(`unknown flag --${name}`);
    }
    if (BOOLEAN_FLAGS.has(name)) {
      // `--history=yes` を受け付けると、真偽値として読む側で false になり
      // 「指定したのに効かない」が無言で起きる。値を伴う指定は明示的に弾く。
      if (separator !== -1) {
        throw new TypeError(`--${name} does not take a value`);
      }
      flags.set(name, true);
      continue;
    }
    if (separator !== -1) {
      flags.set(name, body.slice(separator + 1));
      continue;
    }
    // 値フラグは後続のフラグを値として受け取らない（`--note --json` の誤解釈を防ぐ）。
    const value = tokens[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new TypeError(`--${name} requires a value`);
    }
    flags.set(name, value);
    index += 1;
  }
  return { flags, positionals };
}

function flagText(flags, name) {
  const value = flags.get(name);
  if (typeof value !== "string") {
    throw new TypeError(`--${name} requires a value`);
  }
  return value;
}

// state 遷移で持ち回る素の候補フィールド。spread に undefined を混ぜないよう明示する。
function baseFields(candidate) {
  return {
    id: candidate.id,
    title: candidate.title,
    summary: candidate.summary,
    evidence_accounts: candidate.evidence_accounts,
    ranking: candidate.ranking,
    created_at: candidate.created_at,
    evidence_updated_at: candidate.evidence_updated_at,
  };
}

function buildDecision(kind, nowIso, note) {
  const decision = { kind, at: nowIso };
  if (note !== undefined) decision.note = note;
  return decision;
}

function applyAdopt({ existing, flags, nowIso, note }) {
  const issueUrl = flags.has("issue-url")
    ? parseIssueUrl(flagText(flags, "issue-url"))
    : null;
  const hasAdoptionFlags = ADOPTION_FLAG_NAMES.some((name) => flags.has(name));
  // 既に採用済みの候補を Issue 化するだけの呼び出しでは、保存済みの採用条件を
  // 再入力させない（AC-040 の「採用したが現 session で完結しない」経路）。
  const reuseStoredAdoption =
    existing.state === "adopted" && issueUrl !== null && !hasAdoptionFlags;
  const adoption = reuseStoredAdoption
    ? existing.adoption
    : normalizeAdoption({
        success_metric: flags.get("success-metric"),
        baseline: flags.get("baseline"),
        review_on: flags.get("review-on"),
        fallback: flags.get("fallback"),
      });

  if (issueUrl === null) {
    return {
      ...baseFields(existing),
      state: "adopted",
      decision: buildDecision("adopt", nowIso, note),
      adoption,
    };
  }

  // AC-040: Issue 化した候補は GitHub Issue が唯一の正本。queue 側には識別に必要な
  // 最小項目と URL だけを残し、根拠・順位・採用条件の payload は破棄する。
  return {
    id: existing.id,
    title: existing.title,
    state: "promoted",
    created_at: existing.created_at,
    promotion: { issue_url: issueUrl, at: nowIso },
  };
}

function applyDefer({ existing, flags, now, nowIso, note }) {
  const until = flags.has("until")
    ? new Date(`${requireDate(flagText(flags, "until"), "--until")}T00:00:00Z`)
    : new Date(now.getTime() + DEFAULT_DEFER_DAYS * DAY_MS);
  return {
    ...baseFields(existing),
    state: "deferred",
    decision: buildDecision("defer", nowIso, note),
    deferred_until: until.toISOString(),
  };
}

function applyReject({ existing, nowIso, note }) {
  return {
    ...baseFields(existing),
    state: "rejected",
    decision: buildDecision("reject", nowIso, note),
  };
}

function assertDecisionFlags(flags, decision) {
  const allowedForDecision = DECISION_FLAG_NAMES[decision];
  for (const name of Object.values(DECISION_FLAG_NAMES).flat()) {
    if (flags.has(name) && !allowedForDecision.includes(name)) {
      throw new TypeError(`--${name} is only valid with --decision=adopt`);
    }
  }
}

function resolveCommand({ environment, flags, positionals, now, nowIso }) {
  const id = positionals[0];
  const decision = flags.get("decision");
  if (!DECISIONS.includes(decision)) {
    throw new TypeError(`--decision must be one of ${DECISIONS.join(", ")}`);
  }
  assertDecisionFlags(flags, decision);

  const document = readQueue(environment, nowIso);
  const existing = document.candidates.find((candidate) => candidate.id === id);
  if (!existing) {
    throw new TypeError(`no candidate with id ${id}`);
  }
  // AC-036: Issue 化済み・見送り済みは終端。再提示も再判断もしない。
  if (TERMINAL_STATES.includes(existing.state)) {
    throw new TypeError(
      `candidate ${id} is already ${existing.state} and cannot be resolved again`,
    );
  }

  const note = flags.has("note") ? flagText(flags, "note") : undefined;
  const context = { existing, flags, now, nowIso, note };
  const updated =
    decision === "adopt"
      ? applyAdopt(context)
      : decision === "defer"
        ? applyDefer(context)
        : applyReject(context);

  const saved = writeQueue(environment, {
    ...document,
    updated_at: nowIso,
    candidates: document.candidates.map((candidate) =>
      candidate.id === id ? updated : candidate,
    ),
  });
  return {
    id,
    decision,
    state: updated.state,
    updated_at: saved.updated_at,
    queue_path: queuePath(environment),
  };
}

function assertWithinInputLimit(raw) {
  const bytes = Buffer.byteLength(raw, "utf8");
  if (bytes > MAX_INPUT_BYTES) {
    throw new TypeError(
      `candidate input must be at most ${MAX_INPUT_BYTES} bytes (got ${bytes})`,
    );
  }
  return raw;
}

function readCandidateInput(flags, options) {
  if (flags.has("file")) {
    const filePath = flagText(flags, "file");
    // ファイルは読む前にサイズで弾ける（stdin と違い事前に大きさが分かる）。
    const { size } = statSync(filePath);
    if (size > MAX_INPUT_BYTES) {
      throw new TypeError(
        `${filePath} must be at most ${MAX_INPUT_BYTES} bytes (got ${size})`,
      );
    }
    return readFileSync(filePath, "utf8");
  }
  if (options.readInput) return assertWithinInputLimit(options.readInput());
  if (process.stdin.isTTY) {
    throw new TypeError("候補 JSON を stdin か --file <path> で渡してください");
  }
  // stdin は事前にサイズが分からないため、読み切ってから上限で弾く。
  return assertWithinInputLimit(readFileSync(0, "utf8"));
}

function candidateEntries(parsed) {
  if (Array.isArray(parsed)) return parsed;
  if (parsed && Array.isArray(parsed.candidates)) return parsed.candidates;
  return [parsed];
}

function upsertCommand({ environment, flags, nowIso, options }) {
  const raw = readCandidateInput(flags, options);
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new TypeError(`candidate input is not valid JSON: ${error.message}`);
  }
  const entries = candidateEntries(parsed);
  if (entries.length === 0) {
    throw new TypeError("candidate input contains no candidates");
  }
  // 全件を検証してから 1 度だけ書く（部分適用を作らない）。
  const inputs = entries.map((entry) => normalizeCandidateInput(entry, nowIso));
  const seen = new Set();
  for (const input of inputs) {
    if (seen.has(input.id)) {
      throw new TypeError(`candidate input has a duplicate id: ${input.id}`);
    }
    seen.add(input.id);
  }

  const document = readQueue(environment, nowIso);
  const byId = new Map(
    document.candidates.map((candidate) => [candidate.id, candidate]),
  );
  const results = [];
  for (const input of inputs) {
    const existing = byId.get(input.id);
    if (!existing) {
      byId.set(input.id, { ...input, state: "active" });
      results.push({ id: input.id, outcome: "created" });
      continue;
    }
    if (TERMINAL_STATES.includes(existing.state)) {
      results.push({ id: input.id, outcome: "skipped", reason: existing.state });
      continue;
    }
    // 状態と採否の記録は保ち、新しい根拠で内容・順位・根拠更新日時だけ差し替える。
    // AC-036 の失効解除はこの日時更新で起きる。
    byId.set(input.id, {
      ...existing,
      title: input.title,
      summary: input.summary,
      evidence_accounts: input.evidence_accounts,
      ranking: input.ranking,
      evidence_updated_at: input.evidence_updated_at,
    });
    results.push({ id: input.id, outcome: "updated" });
  }

  const saved = writeQueue(environment, {
    ...document,
    updated_at: nowIso,
    candidates: [...byId.values()],
  });
  return {
    results,
    total: saved.candidates.length,
    queue_path: queuePath(environment),
  };
}

function formatUpsert(payload) {
  const lines = payload.results.map((result) =>
    result.reason
      ? `- ${result.id}: ${result.outcome}（${result.reason}）`
      : `- ${result.id}: ${result.outcome}`,
  );
  lines.push(`保持中の候補: ${payload.total} 件`);
  return lines.join("\n");
}

function usage() {
  return [
    "使い方: agent-improvement <サブコマンド> [オプション]",
    "",
    "サブコマンド:",
    "  status [--history] [--json]   evaluator の健全性と候補一覧を表示する（読み取り専用）",
    "  next [--json]                 最優先の候補を 1 件だけ返す（読み取り専用）",
    "  resolve <id> --decision=adopt|defer|reject [...]",
    "                                採否を記録する（唯一の対話的な書き込み経路）",
    "  upsert [--file <path>]        候補を投入する。省略時は stdin から読む",
    "",
    "resolve のオプション:",
    "  --decision=adopt   --success-metric / --baseline / --review-on / --fallback が必須",
    "                     --issue-url を添えると Issue 化済み（promoted）にする",
    "  --decision=defer   --until=YYYY-MM-DD（既定は 7 日後）",
    "  --decision=reject  --note で理由を残せる",
    "",
    "採用専用のフラグ（--success-metric / --baseline / --review-on / --fallback /",
    "--issue-url）を defer / reject に渡すとエラーになります。",
  ].join("\n");
}

export function runCli(argumentsList, options = {}) {
  const environment = options.environment ?? process.env;
  const write = options.write ?? ((line) => process.stdout.write(`${line}\n`));
  const now = options.now ?? new Date();
  const nowIso = now.toISOString();

  const [command, ...tokens] = argumentsList;
  const allowed = COMMAND_FLAGS[command];
  if (!allowed) {
    write(usage());
    return 64;
  }

  const { flags, positionals } = parseArguments(tokens, allowed);
  const expectedPositionals = COMMAND_POSITIONALS[command];
  if (positionals.length !== expectedPositionals) {
    throw new TypeError(
      `${command} takes ${expectedPositionals} positional argument(s), got ${positionals.length}`,
    );
  }
  const asJson = flags.get("json") === true;
  const emit = (payload, text) =>
    write(asJson ? JSON.stringify(payload, null, 2) : text);

  if (command === "status") {
    const document = readQueue(environment, nowIso);
    const health = readHealth(environment);
    const partitions = partitionQueue(document, now);
    const includeHistory = flags.get("history") === true;
    // JSON も人間向け表示と同じ内容にする（--history の有無で 2 つのビューが
    // 食い違うと、片方だけを見て「履歴が無い」と誤解する経路ができる）。
    const payload = {
      health,
      active: partitions.active,
      adopted: partitions.adopted,
      ...(includeHistory ? { history: partitions.history } : {}),
    };
    emit(payload, formatStatus({ health, partitions, includeHistory }));
    return 0;
  }

  if (command === "next") {
    const document = readQueue(environment, nowIso);
    const candidate = selectNext(document, now);
    emit({ candidate }, formatNext(candidate));
    return 0;
  }

  if (command === "resolve") {
    const payload = resolveCommand({
      environment,
      flags,
      positionals,
      now,
      nowIso,
    });
    emit(
      payload,
      `${payload.id} を ${payload.decision} として記録しました（state=${payload.state}）。`,
    );
    return 0;
  }

  const payload = upsertCommand({ environment, flags, nowIso, options });
  emit(payload, formatUpsert(payload));
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`agent-improvement: ${error.message}\n`);
    process.exitCode = 1;
  }
}
