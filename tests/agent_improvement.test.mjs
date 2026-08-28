// 改善候補キュー（#501, sub-issue of #473）のユニットテスト。
//
// 実プロバイダも実 HOME も触らない: 状態の置き場所は毎テスト
// AGENT_IMPROVEMENT_STATE_DIR で一時ディレクトリに向ける。`now` を注入できるので、
// 失効（28 日）や延期解除の境界は実時間を待たずに検証する。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { mkdir, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  assertNotSymlink,
  ensureStateDirectory,
  healthPath,
  queuePath,
  resolveStateDirectory,
  writeJsonAtomic,
} from "../home/dot_local/lib/agent-improvement/paths.mjs";
import {
  DEFAULT_DEFER_DAYS,
  EXPIRY_DAYS,
  normalizeCandidateInput,
  parseIssueUrl,
  parseQueueDocument,
  RANKING_KEYS,
} from "../home/dot_local/lib/agent-improvement/schema.mjs";
import {
  readHealth,
  readQueue,
} from "../home/dot_local/lib/agent-improvement/store.mjs";
import {
  deriveCandidate,
  partitionQueue,
  rankScore,
  selectNext,
} from "../home/dot_local/lib/agent-improvement/view.mjs";
import { runCli } from "../home/dot_local/lib/agent-improvement/cli.mjs";

const DAY_MS = 86_400_000;
const NOW = new Date("2026-08-01T00:00:00.000Z");

const temporaryRoots = [];

function makeStateRoot() {
  const directory = mkdtempSync(path.join(tmpdir(), "agent-improvement-test-"));
  temporaryRoots.push(directory);
  return directory;
}

function makeEnvironment(overrides = {}) {
  return { AGENT_IMPROVEMENT_STATE_DIR: makeStateRoot(), ...overrides };
}

process.on("exit", () => {
  for (const directory of temporaryRoots) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function candidateInput(overrides = {}) {
  return {
    id: "reduce-ci-log-refetch",
    title: "CI ログの再取得を減らす",
    summary: "同じ失敗ログを 2 回取得している",
    evidence_accounts: ["personal", "r06"],
    ranking: {
      frequency: 4,
      impact: 4,
      evidence_strength: 3,
      implementation_cost: 2,
      expected_effect: 4,
    },
    ...overrides,
  };
}

// CLI を 1 回動かし、標準出力を 1 本の文字列として返す。
function invoke(environment, argumentsList, options = {}) {
  const lines = [];
  const code = runCli(argumentsList, {
    environment,
    now: NOW,
    write: (line) => lines.push(line),
    ...options,
  });
  return { code, output: lines.join("\n") };
}

function seed(environment, candidates, options = {}) {
  const { code } = invoke(environment, ["upsert"], {
    readInput: () => JSON.stringify({ candidates }),
    ...options,
  });
  assert.equal(code, 0);
}

// ---------------------------------------------------------------- paths

test("state directory resolution prefers the explicit override, then XDG, then HOME", () => {
  assert.equal(
    resolveStateDirectory({ AGENT_IMPROVEMENT_STATE_DIR: "/srv/queue" }),
    "/srv/queue",
  );
  assert.equal(
    resolveStateDirectory({ XDG_STATE_HOME: "/srv/state", HOME: "/home/x" }),
    path.join("/srv/state", "agent-improvement"),
  );
  assert.equal(
    resolveStateDirectory({ HOME: "/home/x" }),
    path.join("/home/x", ".local", "state", "agent-improvement"),
  );
});

test("state directory resolution rejects relative paths from every source", () => {
  // 相対値を許すと、たまたま cd していたリポジトリの中に owner-only の state を作らされる。
  assert.throws(
    () => resolveStateDirectory({ AGENT_IMPROVEMENT_STATE_DIR: "queue" }),
    /AGENT_IMPROVEMENT_STATE_DIR must be an absolute path/,
  );
  assert.throws(
    () => resolveStateDirectory({ XDG_STATE_HOME: "state", HOME: "/home/x" }),
    /XDG_STATE_HOME must be an absolute path/,
  );
  assert.throws(
    () => resolveStateDirectory({}),
    /HOME must be an absolute path/,
  );
});

test("queue and health files sit side by side under the state directory", () => {
  const environment = { AGENT_IMPROVEMENT_STATE_DIR: "/srv/queue" };
  assert.equal(queuePath(environment), "/srv/queue/queue.json");
  assert.equal(healthPath(environment), "/srv/queue/health.json");
});

test("the state directory is 0700 and the queue file is 0600 regardless of umask", () => {
  const root = makeStateRoot();
  const directory = path.join(root, "nested", "agent-improvement");
  const target = path.join(directory, "queue.json");
  const previousUmask = process.umask(0o000);
  try {
    writeJsonAtomic(target, { ok: true }, "queue file");
  } finally {
    process.umask(previousUmask);
  }
  assert.equal(statSync(directory).mode & 0o777, 0o700);
  assert.equal(statSync(target).mode & 0o777, 0o600);
});

test("symlinked state paths are refused instead of followed", () => {
  const root = makeStateRoot();
  const victim = path.join(root, "victim");
  writeFileSync(victim, "secret", { mode: 0o600 });

  const linkedFile = path.join(root, "queue.json");
  symlinkSync(victim, linkedFile);
  assert.throws(
    () => assertNotSymlink(linkedFile, "queue file"),
    /queue file must not be a symbolic link/,
  );
  assert.throws(
    () => writeJsonAtomic(linkedFile, { ok: true }, "queue file"),
    /queue file must not be a symbolic link/,
  );
  assert.equal(readFileSync(victim, "utf8"), "secret");

  const linkedDirectory = path.join(root, "state");
  symlinkSync(root, linkedDirectory);
  assert.throws(
    () => ensureStateDirectory(linkedDirectory),
    /state directory must not be a symbolic link/,
  );
});

test("an atomic write leaves no temporary file behind", async () => {
  const root = makeStateRoot();
  const directory = path.join(root, "agent-improvement");
  await mkdir(directory, { recursive: true });
  writeJsonAtomic(path.join(directory, "queue.json"), { ok: true }, "queue file");
  assert.deepEqual(await readdir(directory), ["queue.json"]);
});

// --------------------------------------------------------------- schema

test("candidate input validation names the offending field", () => {
  const nowIso = NOW.toISOString();
  assert.throws(
    () => normalizeCandidateInput(candidateInput({ id: "Has Upper" }), nowIso),
    /candidate\.id must match/,
  );
  assert.throws(
    () => normalizeCandidateInput(candidateInput({ evidence_accounts: [] }), nowIso),
    /evidence_accounts must be a non-empty array/,
  );
  assert.throws(
    () =>
      normalizeCandidateInput(
        candidateInput({ ranking: { ...candidateInput().ranking, impact: 9 } }),
        nowIso,
      ),
    /ranking\.impact must be an integer between 1 and 5/,
  );
  assert.throws(
    () =>
      normalizeCandidateInput(
        candidateInput({ ranking: { frequency: 1, impact: 1 } }),
        nowIso,
      ),
    /ranking\.evidence_strength must be an integer/,
  );
});

test("a misspelled key is rejected instead of silently dropped", () => {
  // `evidence_account`（単数形）を素通りさせると provenance が静かに欠落する。
  assert.throws(
    () =>
      normalizeCandidateInput(
        { ...candidateInput(), evidence_account: ["personal"] },
        NOW.toISOString(),
      ),
    /candidate has unknown keys: evidence_account/,
  );
});

test("candidate input cannot declare its own state", () => {
  assert.throws(
    () =>
      normalizeCandidateInput(
        { ...candidateInput(), state: "promoted" },
        NOW.toISOString(),
      ),
    /candidate has unknown keys: state/,
  );
});

test("issue URLs are restricted to GitHub issue permalinks", () => {
  assert.equal(
    parseIssueUrl("https://github.com/kryota-dev/dotfiles/issues/501?x=1#c"),
    "https://github.com/kryota-dev/dotfiles/issues/501",
  );
  for (const bad of [
    "http://github.com/o/r/issues/1",
    "https://evil.example.com/o/r/issues/1",
    "https://github.com/o/r/pull/1",
    "https://github.com/o/r/issues/0",
    "javascript:alert(1)",
  ]) {
    assert.throws(() => parseIssueUrl(bad), TypeError, `expected ${bad} to be rejected`);
  }
});

test("a stored queue with a duplicate id is rejected rather than deduplicated", () => {
  const stored = {
    version: 1,
    updated_at: NOW.toISOString(),
    candidates: [
      { ...candidateInput(), state: "active", created_at: NOW.toISOString(), evidence_updated_at: NOW.toISOString() },
      { ...candidateInput(), state: "active", created_at: NOW.toISOString(), evidence_updated_at: NOW.toISOString() },
    ],
  };
  assert.throws(() => parseQueueDocument(stored), /duplicate id/);
});

test("a stored promoted candidate keeps only its identity and issue URL", () => {
  const promoted = {
    id: "reduce-ci-log-refetch",
    title: "CI ログの再取得を減らす",
    state: "promoted",
    created_at: NOW.toISOString(),
    promotion: {
      issue_url: "https://github.com/kryota-dev/dotfiles/issues/501",
      at: NOW.toISOString(),
    },
  };
  assert.doesNotThrow(() =>
    parseQueueDocument({ version: 1, updated_at: NOW.toISOString(), candidates: [promoted] }),
  );
  assert.throws(
    () =>
      parseQueueDocument({
        version: 1,
        updated_at: NOW.toISOString(),
        candidates: [{ ...promoted, summary: "leftover payload" }],
      }),
    /promoted candidate has unknown keys: summary/,
  );
});

// ----------------------------------------------------------------- view

test("the rank score weights impact and expected effect up and cost down", () => {
  const base = candidateInput().ranking;
  const cheaper = { ...base, implementation_cost: base.implementation_cost - 1 };
  assert.ok(rankScore(cheaper) > rankScore(base));
  const weightier = { ...base, impact: base.impact + 1 };
  assert.ok(rankScore(weightier) - rankScore(base) > 1);
  // 5 指標すべてがスコアに効く（どれかが無視されていない）。
  for (const key of RANKING_KEYS) {
    const bumped = { ...base, [key]: base[key] === 5 ? 4 : base[key] + 1 };
    assert.notEqual(rankScore(bumped), rankScore(base), `${key} does not affect the score`);
  }
});

function storedCandidate(overrides = {}) {
  return {
    ...candidateInput(),
    state: "active",
    created_at: NOW.toISOString(),
    evidence_updated_at: NOW.toISOString(),
    ...overrides,
  };
}

test("an active candidate expires only after the evidence is EXPIRY_DAYS old", () => {
  const candidate = storedCandidate();
  const justBefore = new Date(NOW.getTime() + (EXPIRY_DAYS - 1) * DAY_MS);
  const justAfter = new Date(NOW.getTime() + (EXPIRY_DAYS + 1) * DAY_MS);
  assert.equal(deriveCandidate(candidate, justBefore).derived_state, "active");
  assert.equal(deriveCandidate(candidate, justAfter).derived_state, "expired");
});

test("expiry is derived, never written back", () => {
  const candidate = storedCandidate();
  const derived = deriveCandidate(candidate, new Date(NOW.getTime() + 40 * DAY_MS));
  assert.equal(derived.derived_state, "expired");
  assert.equal(candidate.state, "active");
});

test("a deferred candidate returns to the active pool once its window closes", () => {
  const candidate = storedCandidate({
    state: "deferred",
    deferred_until: new Date(NOW.getTime() + 7 * DAY_MS).toISOString(),
  });
  assert.equal(deriveCandidate(candidate, NOW).derived_state, "deferred");
  const later = new Date(NOW.getTime() + 8 * DAY_MS);
  assert.equal(deriveCandidate(candidate, later).derived_state, "active");
});

test("an adopted candidate becomes review_due on its review date", () => {
  const candidate = storedCandidate({
    state: "adopted",
    adoption: {
      success_metric: "CI ログ取得回数/週",
      baseline: "週 8 回",
      review_on: "2026-08-15",
      fallback: "半減しなければ revert",
    },
  });
  assert.equal(deriveCandidate(candidate, NOW).derived_state, "adopted");
  assert.equal(
    deriveCandidate(candidate, new Date("2026-08-15T00:00:00.000Z")).derived_state,
    "review_due",
  );
});

test("ties are broken deterministically by evidence recency then id", () => {
  // どちらも失効窓（EXPIRY_DAYS）の内側に置く。外れると active から落ちて並びを確認できない。
  const older = storedCandidate({ id: "aaa", evidence_updated_at: "2026-07-20T00:00:00.000Z" });
  const newer = storedCandidate({ id: "zzz", evidence_updated_at: "2026-07-25T00:00:00.000Z" });
  const document = { candidates: [older, newer] };
  const { active } = partitionQueue(document, NOW);
  assert.deepEqual(active.map((candidate) => candidate.id), ["zzz", "aaa"]);

  const sameEvidence = [
    storedCandidate({ id: "bbb" }),
    storedCandidate({ id: "aaa" }),
  ];
  assert.deepEqual(
    partitionQueue({ candidates: sameEvidence }, NOW).active.map((c) => c.id),
    ["aaa", "bbb"],
  );
});

test("next prefers an overdue review over a higher-ranked new candidate", () => {
  const due = storedCandidate({
    id: "already-adopted",
    state: "adopted",
    ranking: { frequency: 1, impact: 1, evidence_strength: 1, implementation_cost: 5, expected_effect: 1 },
    adoption: {
      success_metric: "m",
      baseline: "b",
      review_on: "2026-07-01",
      fallback: "f",
    },
  });
  const fresh = storedCandidate({ id: "brand-new" });
  assert.equal(selectNext({ candidates: [fresh, due] }, NOW).id, "already-adopted");
  assert.equal(selectNext({ candidates: [fresh] }, NOW).id, "brand-new");
  assert.equal(selectNext({ candidates: [] }, NOW), null);
});

// ------------------------------------------------------------ read-only

test("status and next never create or touch the state directory", () => {
  const environment = makeEnvironment();
  const directory = environment.AGENT_IMPROVEMENT_STATE_DIR;
  rmSync(directory, { force: true, recursive: true });

  assert.equal(invoke(environment, ["status"]).code, 0);
  assert.equal(invoke(environment, ["status", "--history"]).code, 0);
  assert.equal(invoke(environment, ["next"]).code, 0);
  // #501 の完了条件: 表示操作は評価処理を再実行せず、状態も作らない。
  assert.equal(existsSync(directory), false);
});

test("status and next leave an existing queue byte-for-byte unchanged", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  const file = queuePath(environment);
  const before = readFileSync(file, "utf8");
  const beforeStat = statSync(file);

  invoke(environment, ["status", "--history"]);
  invoke(environment, ["next"]);

  assert.equal(readFileSync(file, "utf8"), before);
  assert.equal(statSync(file).mtimeMs, beforeStat.mtimeMs);
});

test("a missing or malformed health file degrades the display without failing", () => {
  const environment = makeEnvironment();
  assert.deepEqual(readHealth(environment), { available: false, reason: "not-run" });

  ensureStateDirectory(environment.AGENT_IMPROVEMENT_STATE_DIR);
  writeFileSync(healthPath(environment), "{ broken", { mode: 0o600 });
  const health = readHealth(environment);
  assert.equal(health.available, false);
  assert.ok(health.reason.length > 0);

  const { code, output } = invoke(environment, ["status"]);
  assert.equal(code, 0);
  assert.match(output, /読み取れません/);
});

test("a corrupt queue file is surfaced instead of silently reset", () => {
  const environment = makeEnvironment();
  ensureStateDirectory(environment.AGENT_IMPROVEMENT_STATE_DIR);
  writeFileSync(queuePath(environment), "{ not json", { mode: 0o600 });
  assert.throws(
    () => readQueue(environment, NOW.toISOString()),
    /is not valid JSON/,
  );
  assert.equal(readFileSync(queuePath(environment), "utf8"), "{ not json");
});

// --------------------------------------------------------------- upsert

test("upsert creates, then updates in place, keeping one entry per id", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  const created = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.equal(created.candidates.length, 1);
  assert.equal(created.candidates[0].state, "active");

  const later = new Date(NOW.getTime() + 10 * DAY_MS);
  const { output } = invoke(
    environment,
    ["upsert", "--json"],
    {
      now: later,
      readInput: () =>
        JSON.stringify(candidateInput({ title: "新しい根拠つきのタイトル" })),
    },
  );
  assert.match(output, /"outcome": "updated"/);

  const updated = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.equal(updated.candidates.length, 1);
  assert.equal(updated.candidates[0].title, "新しい根拠つきのタイトル");
  // 新しい根拠で失効の起点が更新される（AC-036）。
  assert.equal(updated.candidates[0].evidence_updated_at, later.toISOString());
});

test("upsert refuses to resurrect a terminal candidate and says why", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=reject",
    "--note=今回は見送る",
  ]);

  const { output } = invoke(environment, ["upsert", "--json"], {
    readInput: () => JSON.stringify(candidateInput()),
  });
  assert.match(output, /"outcome": "skipped"/);
  assert.match(output, /"reason": "rejected"/);

  const stored = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.equal(stored.candidates[0].state, "rejected");
});

test("an invalid entry aborts the whole batch, leaving the queue untouched", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  const before = readFileSync(queuePath(environment), "utf8");

  assert.throws(
    () =>
      invoke(environment, ["upsert"], {
        readInput: () =>
          JSON.stringify({
            candidates: [
              candidateInput({ id: "valid-second-entry" }),
              candidateInput({ id: "INVALID" }),
            ],
          }),
      }),
    /candidate\.id must match/,
  );
  assert.equal(readFileSync(queuePath(environment), "utf8"), before);
});

test("upsert rejects a batch that repeats one id", () => {
  const environment = makeEnvironment();
  assert.throws(
    () =>
      invoke(environment, ["upsert"], {
        readInput: () =>
          JSON.stringify({ candidates: [candidateInput(), candidateInput()] }),
      }),
    /duplicate id/,
  );
});

// -------------------------------------------------------------- resolve

test("resolve accepts only the fixed three-way answer", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=maybe",
      ]),
    /--decision must be one of adopt, defer, reject/,
  );
});

test("adopting requires all four AC-041 fields", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=adopt",
        "--success-metric=CI ログ取得回数/週",
        "--baseline=週 8 回",
        "--review-on=2026-09-26",
      ]),
    /adoption\.fallback must be a non-empty string/,
  );

  const { code } = invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=adopt",
    "--success-metric=CI ログ取得回数/週",
    "--baseline=週 8 回",
    "--review-on=2026-09-26",
    "--fallback=2 週で半減しなければ revert",
  ]);
  assert.equal(code, 0);
  const stored = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.equal(stored.candidates[0].state, "adopted");
  assert.equal(stored.candidates[0].adoption.review_on, "2026-09-26");
  assert.equal(stored.candidates[0].decision.kind, "adopt");
});

test("a bogus review date is rejected before anything is written", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=adopt",
        "--success-metric=m",
        "--baseline=b",
        "--review-on=2026-02-31",
        "--fallback=f",
      ]),
    /not a real calendar date/,
  );
});

test("deferring defaults to DEFAULT_DEFER_DAYS and honours an explicit date", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput(), candidateInput({ id: "second-candidate" })]);

  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=defer"]);
  invoke(environment, [
    "resolve",
    "second-candidate",
    "--decision=defer",
    "--until=2026-09-15",
  ]);

  const stored = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  const byId = Object.fromEntries(stored.candidates.map((c) => [c.id, c]));
  assert.equal(
    byId["reduce-ci-log-refetch"].deferred_until,
    new Date(NOW.getTime() + DEFAULT_DEFER_DAYS * DAY_MS).toISOString(),
  );
  assert.equal(byId["second-candidate"].deferred_until, "2026-09-15T00:00:00.000Z");
});

test("promoting an adopted candidate drops the payload and keeps the issue URL", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=adopt",
    "--success-metric=m",
    "--baseline=b",
    "--review-on=2026-09-26",
    "--fallback=f",
  ]);
  // 既に採用済みなので、Issue 化だけの呼び出しでは採用条件を再入力させない。
  const { code } = invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=adopt",
    "--issue-url=https://github.com/kryota-dev/dotfiles/issues/501",
  ]);
  assert.equal(code, 0);

  const stored = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.deepEqual(Object.keys(stored.candidates[0]).sort(), [
    "created_at",
    "id",
    "promotion",
    "state",
    "title",
  ]);
  assert.equal(
    stored.candidates[0].promotion.issue_url,
    "https://github.com/kryota-dev/dotfiles/issues/501",
  );
});

test("a terminal candidate cannot be resolved again", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=reject"]);
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=defer",
      ]),
    /already rejected and cannot be resolved again/,
  );
});

test("resolving an unknown id fails without creating the queue", () => {
  const environment = makeEnvironment();
  // makeEnvironment は mkdtemp でディレクトリを作るので、未作成の状態から始める。
  rmSync(environment.AGENT_IMPROVEMENT_STATE_DIR, { force: true, recursive: true });
  assert.throws(
    () => invoke(environment, ["resolve", "missing-candidate", "--decision=defer"]),
    /no candidate with id missing-candidate/,
  );
  assert.equal(existsSync(environment.AGENT_IMPROVEMENT_STATE_DIR), false);
});

// ------------------------------------------------------------------ cli

test("an unknown subcommand prints usage and exits 64", () => {
  const { code, output } = invoke(makeEnvironment(), ["bogus"]);
  assert.equal(code, 64);
  assert.match(output, /使い方: agent-improvement/);
});

test("a misspelled flag is rejected rather than ignored", () => {
  assert.throws(
    () => invoke(makeEnvironment(), ["status", "--histry"]),
    /unknown flag --histry/,
  );
  // 真偽値フラグに値を渡す誤用も止める（黙って false 扱いにしない）。
  assert.throws(
    () => invoke(makeEnvironment(), ["status", "--history=yes"]),
    /--history does not take a value/,
  );
});

test("a value flag never swallows the following flag as its value", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision",
        "--json",
      ]),
    /--decision requires a value/,
  );
});

test("status --json mirrors the human view, exposing history only on request", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=defer"]);

  const plain = JSON.parse(invoke(environment, ["status", "--json"]).output);
  assert.deepEqual(Object.keys(plain).sort(), ["active", "adopted", "health"]);
  assert.equal(plain.active.length, 0);

  const withHistory = JSON.parse(
    invoke(environment, ["status", "--history", "--json"]).output,
  );
  assert.equal(withHistory.history.length, 1);
  assert.equal(withHistory.history[0].derived_state, "deferred");
});

test("next --json returns a single candidate or null", () => {
  const environment = makeEnvironment();
  assert.equal(JSON.parse(invoke(environment, ["next", "--json"]).output).candidate, null);
  seed(environment, [candidateInput()]);
  assert.equal(
    JSON.parse(invoke(environment, ["next", "--json"]).output).candidate.id,
    "reduce-ci-log-refetch",
  );
});
