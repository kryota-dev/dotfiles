// 改善候補キュー（#501, sub-issue of #473）のユニットテスト。
//
// 実プロバイダも実 HOME も触らない: 状態の置き場所は毎テスト
// AGENT_IMPROVEMENT_STATE_DIR で一時ディレクトリに向ける。`now` を注入できるので、
// 失効（28 日）や延期解除の境界は実時間を待たずに検証する。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { mkdir, readdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  assertNotSymlink,
  ensureStateDirectory,
  healthPath,
  inspectStatePermissions,
  queuePath,
  resolveStateDirectory,
  writeJsonAtomic,
} from "../home/dot_local/lib/agent-improvement/paths.mjs";
import {
  ADOPTION_KEYS,
  DEFAULT_DEFER_DAYS,
  EXPIRY_DAYS,
  normalizeAdoption,
  normalizeCandidateInput,
  parseIssueUrl,
  parseQueueDocument,
  RANKING_KEYS,
} from "../home/dot_local/lib/agent-improvement/schema.mjs";
import {
  readHealth,
  readQueue,
  writeQueue,
} from "../home/dot_local/lib/agent-improvement/store.mjs";
import {
  deriveCandidate,
  formatNext,
  formatStatus,
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

// paths.mjs は state ディレクトリを environment から解決する（#344 耐性のため
// 解決を 1 箇所に閉じている）。任意のディレクトリを対象にしたいテストはこの形で渡す。
function envFor(directory) {
  return { AGENT_IMPROVEMENT_STATE_DIR: directory };
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
    writeJsonAtomic(envFor(directory), target, { ok: true }, "queue file");
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
    () => writeJsonAtomic(envFor(root), linkedFile, { ok: true }, "queue file"),
    /queue file must not be a symbolic link/,
  );
  assert.equal(readFileSync(victim, "utf8"), "secret");

  const linkedDirectory = path.join(root, "state");
  symlinkSync(root, linkedDirectory);
  assert.throws(
    () => ensureStateDirectory(envFor(linkedDirectory)),
    /state directory must not be a symbolic link/,
  );
});

test("an atomic write leaves no temporary file behind", async () => {
  const root = makeStateRoot();
  const directory = path.join(root, "agent-improvement");
  await mkdir(directory, { recursive: true });
  writeJsonAtomic(
    envFor(directory),
    path.join(directory, "queue.json"),
    { ok: true },
    "queue file",
  );
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
    revision: 1,
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
    parseQueueDocument({
      version: 1,
      revision: 1,
      updated_at: NOW.toISOString(),
      candidates: [promoted],
    }),
  );
  assert.throws(
    () =>
      parseQueueDocument({
        version: 1,
        revision: 1,
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

// state ディレクトリ配下すべての「名前・内容・mtime」を取る。queue.json だけを見ると、
// 表示系が health.json や別ファイルを書き始めた回帰を見逃す。
function snapshotStateDirectory(directory) {
  return readdirSync(directory)
    .sort()
    .map((name) => {
      const target = path.join(directory, name);
      return {
        name,
        content: readFileSync(target, "utf8"),
        mtimeMs: statSync(target).mtimeMs,
      };
    });
}

test("status and next leave the whole state directory unchanged", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  ensureStateDirectory(environment);
  writeFileSync(
    healthPath(environment),
    JSON.stringify({ status: "ok", last_run_at: NOW.toISOString() }),
    { mode: 0o600 },
  );
  const directory = environment.AGENT_IMPROVEMENT_STATE_DIR;
  const before = snapshotStateDirectory(directory);

  // 表示が失敗していれば「変更なし」も自明に成り立つので、exit code も固定する。
  for (const argumentsList of [
    ["status"],
    ["status", "--json"],
    ["status", "--history"],
    ["status", "--history", "--json"],
    ["next"],
    ["next", "--json"],
  ]) {
    assert.equal(
      invoke(environment, argumentsList).code,
      0,
      `${argumentsList.join(" ")} did not succeed`,
    );
  }

  assert.deepEqual(snapshotStateDirectory(directory), before);
});

test("a missing or malformed health file degrades the display without failing", () => {
  const environment = makeEnvironment();
  assert.deepEqual(readHealth(environment), { available: false, reason: "not-run" });

  ensureStateDirectory(environment);
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
  ensureStateDirectory(environment);
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
  assert.deepEqual(Object.keys(plain).sort(), [
    "active",
    "adopted",
    "health",
    "permission_warnings",
  ]);
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

// ============================================================ review round 1
// 以下は PR #528 の multi-review round 1 で挙がった指摘に対する回帰テスト。

// ------------------------------------------------- boundaries (exact ticks)

test("expiry fires exactly at EXPIRY_DAYS, not a tick later", () => {
  // AC-036「新しい根拠がなければ 4 週間で失効する」に従い、4 週間ちょうどは失効側。
  // 比較演算子を `<=` から `<` に変えるとこのテストが落ちる。
  const candidate = storedCandidate();
  const exactly = new Date(NOW.getTime() + EXPIRY_DAYS * DAY_MS);
  assert.equal(deriveCandidate(candidate, exactly).derived_state, "expired");
  assert.equal(
    deriveCandidate(candidate, new Date(exactly.getTime() - 1)).derived_state,
    "active",
  );
});

test("a deferral ends exactly at deferred_until", () => {
  const until = new Date(NOW.getTime() + 7 * DAY_MS);
  const candidate = storedCandidate({
    state: "deferred",
    decision: { kind: "defer", at: NOW.toISOString() },
    deferred_until: until.toISOString(),
  });
  assert.equal(
    deriveCandidate(candidate, new Date(until.getTime() - 1)).derived_state,
    "deferred",
  );
  assert.equal(deriveCandidate(candidate, until).derived_state, "active");
});

// --------------------------------------------------------------- permissions

test("existing loose permissions are tightened on use, not just on creation", () => {
  const root = makeStateRoot();
  const directory = path.join(root, "agent-improvement");
  const target = path.join(directory, "queue.json");
  mkdirSync(directory, { mode: 0o755 });
  chmodSync(directory, 0o755);
  writeFileSync(target, "{}\n", { mode: 0o644 });
  chmodSync(target, 0o644);

  writeJsonAtomic(envFor(directory), target, { ok: true }, "queue file");

  // 要件は「作成または更新する」ときの 0700/0600 なので、既存の緩い権限も矯正する。
  assert.equal(statSync(directory).mode & 0o777, 0o700);
  assert.equal(statSync(target).mode & 0o777, 0o600);
});

// ------------------------------------------------------------ symlink (read)

test("a symlinked state directory is refused on read, not only on write", () => {
  const root = makeStateRoot();
  const real = path.join(root, "real");
  mkdirSync(real, { recursive: true });
  writeFileSync(path.join(real, "queue.json"), "{}\n", { mode: 0o600 });
  const linked = path.join(root, "linked");
  symlinkSync(real, linked);
  const environment = { AGENT_IMPROVEMENT_STATE_DIR: linked };

  for (const read of [
    () => readQueue(environment, NOW.toISOString()),
    () => invoke(environment, ["status"]),
    () => invoke(environment, ["next"]),
  ]) {
    assert.throws(read, /state directory must not be a symbolic link/);
  }
  // readHealth は表示要素として降格させるので throw せず reason で返す。
  assert.equal(readHealth(environment).available, false);
});

test("chmod cannot be redirected through a symlinked state directory", () => {
  const root = makeStateRoot();
  const victim = path.join(root, "victim");
  mkdirSync(victim, { mode: 0o755 });
  chmodSync(victim, 0o755);
  const linked = path.join(root, "linked");
  symlinkSync(victim, linked);

  assert.throws(
    () => ensureStateDirectory(envFor(linked)),
    /state directory must not be a symbolic link/,
  );
  assert.equal(statSync(victim).mode & 0o777, 0o755);
});

// -------------------------------------------------------- timestamp strictness

test("timestamps must be ISO 8601 and name a real calendar day", () => {
  const nowIso = NOW.toISOString();
  for (const bad of [
    "August 29, 2026",
    "2026/08/29",
    "29 Aug 2026",
    "2026-08-29",
    "2026-02-31T00:00:00.000Z",
    "2026-08-29T25:00:00.000Z",
  ]) {
    assert.throws(
      () => normalizeCandidateInput(candidateInput({ created_at: bad }), nowIso),
      TypeError,
      `expected ${bad} to be rejected`,
    );
  }
  // 受理する形（Z と数値オフセット、ミリ秒あり・なし）。
  for (const good of [
    "2026-08-29T00:00:00Z",
    "2026-08-29T00:00:00.123Z",
    "2026-08-29T09:00:00+09:00",
  ]) {
    assert.doesNotThrow(() =>
      normalizeCandidateInput(candidateInput({ created_at: good }), nowIso),
    );
  }
});

test("issue URLs with an explicit port are refused", () => {
  assert.throws(
    () => parseIssueUrl("https://github.com:8443/o/r/issues/1"),
    /must be an https:\/\/github\.com/,
  );
});

// --------------------------------------------------- stored-state contracts

test("a stored candidate whose decision contradicts its state is refused", () => {
  const base = {
    version: 1,
    revision: 1,
    updated_at: NOW.toISOString(),
  };
  // 見送り済みの決定を持ちながら active を名乗る候補が通ると、その候補が
  // 改善候補として再提示されてしまう。
  assert.throws(
    () =>
      parseQueueDocument({
        ...base,
        candidates: [
          storedCandidate({
            state: "active",
            decision: { kind: "reject", at: NOW.toISOString() },
          }),
        ],
      }),
    /active candidate has unknown keys: decision/,
  );
  assert.throws(
    () =>
      parseQueueDocument({
        ...base,
        candidates: [
          storedCandidate({
            state: "deferred",
            decision: { kind: "adopt", at: NOW.toISOString() },
            deferred_until: NOW.toISOString(),
          }),
        ],
      }),
    /decision\.kind must be defer for a deferred candidate/,
  );
});

test("state-specific payload cannot ride along on the wrong state", () => {
  assert.throws(
    () =>
      parseQueueDocument({
        version: 1,
        revision: 1,
        updated_at: NOW.toISOString(),
        candidates: [
          storedCandidate({
            state: "active",
            adoption: {
              success_metric: "m",
              baseline: "b",
              review_on: "2026-09-01",
              fallback: "f",
            },
          }),
        ],
      }),
    /active candidate has unknown keys: adoption/,
  );
});

test("required state-specific fields cannot be omitted", () => {
  assert.throws(
    () =>
      parseQueueDocument({
        version: 1,
        revision: 1,
        updated_at: NOW.toISOString(),
        candidates: [
          storedCandidate({
            state: "adopted",
            decision: { kind: "adopt", at: NOW.toISOString() },
          }),
        ],
      }),
    /adoption must be an object/,
  );
});

// ----------------------------------------------------- schema field coverage

test("every required candidate field is validated by name", () => {
  const nowIso = NOW.toISOString();
  const cases = [
    ["title", { title: "" }, /candidate\.title must be a non-empty string/],
    ["summary", { summary: 42 }, /candidate\.summary must be a non-empty string/],
    ["id", { id: "" }, /candidate\.id must be a non-empty string/],
    [
      "evidence_accounts",
      { evidence_accounts: ["Bad Account"] },
      /evidence_accounts\[0\] must match/,
    ],
    ["ranking", { ranking: null }, /ranking must be an object/],
  ];
  for (const [name, overrides, pattern] of cases) {
    assert.throws(
      () => normalizeCandidateInput(candidateInput(overrides), nowIso),
      pattern,
      `${name} was not validated`,
    );
  }
  for (const key of RANKING_KEYS) {
    const ranking = { ...candidateInput().ranking };
    delete ranking[key];
    assert.throws(
      () => normalizeCandidateInput(candidateInput({ ranking }), nowIso),
      new RegExp(`ranking\\.${key} must be an integer`),
      `ranking.${key} was not validated`,
    );
  }
  for (const key of ADOPTION_KEYS) {
    const adoption = {
      success_metric: "m",
      baseline: "b",
      review_on: "2026-09-01",
      fallback: "f",
    };
    delete adoption[key];
    assert.throws(
      () => normalizeAdoption(adoption),
      new RegExp(`adoption\\.${key}`),
      `adoption.${key} was not validated`,
    );
  }
});

test("a queue document with a bad version or revision is refused", () => {
  const base = { updated_at: NOW.toISOString(), candidates: [] };
  assert.throws(
    () => parseQueueDocument({ ...base, version: 2, revision: 1 }),
    /queue\.version must be 1/,
  );
  for (const revision of [-1, 1.5, Number.MAX_SAFE_INTEGER]) {
    assert.throws(
      () => parseQueueDocument({ ...base, version: 1, revision }),
      /queue\.revision must be an integer between 0 and/,
      `revision ${revision} was accepted`,
    );
  }
});

// ------------------------------------------------------------ concurrency

test("a concurrent write is detected instead of silently clobbered", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);

  // 採否を判断している間に、別プロセスが同じ候補を見送ったという状況。
  const stale = readQueue(environment, NOW.toISOString());
  invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=reject",
  ]);

  // 古い snapshot を書き戻せてしまうと、終端のはずの候補が active に復活する。
  assert.throws(
    () => writeQueue(environment, { ...stale, updated_at: NOW.toISOString() }),
    /queue was modified concurrently/,
  );
  const stored = JSON.parse(readFileSync(queuePath(environment), "utf8"));
  assert.equal(stored.candidates[0].state, "rejected");
});

test("the revision advances by one on every write", () => {
  const environment = makeEnvironment();
  assert.equal(readQueue(environment, NOW.toISOString()).revision, 0);
  seed(environment, [candidateInput()]);
  assert.equal(readQueue(environment, NOW.toISOString()).revision, 1);
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=defer"]);
  assert.equal(readQueue(environment, NOW.toISOString()).revision, 2);
});

// ------------------------------------------------------------- CLI contracts

test("flags that only make sense for adopt are refused elsewhere", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  // 黙って捨てられると、不正な URL を渡しても成功したように見える。
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=defer",
        "--issue-url=not-a-url",
      ]),
    /--issue-url is only valid with --decision=adopt/,
  );
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=reject",
        "--success-metric=m",
      ]),
    /--success-metric is only valid with --decision=adopt/,
  );
});

test("extra positional arguments are refused, not ignored", () => {
  const environment = makeEnvironment();
  assert.throws(
    () => invoke(environment, ["status", "typo"]),
    /status takes 0 positional argument\(s\), got 1/,
  );
  // `upsert candidates.json` は stdin を読んでしまうため、成功させると危険。
  assert.throws(
    () => invoke(environment, ["upsert", "candidates.json"]),
    /upsert takes 0 positional argument\(s\), got 1/,
  );
  assert.throws(
    () => invoke(environment, ["resolve", "--decision=defer"]),
    /resolve takes 1 positional argument\(s\), got 0/,
  );
});

test("oversized candidate input is refused before it is parsed", () => {
  const environment = makeEnvironment();
  assert.throws(
    () =>
      invoke(environment, ["upsert"], {
        readInput: () => " ".repeat(2 * 1024 * 1024),
      }),
    /candidate input must be at most \d+ bytes/,
  );
});

// -------------------------------------------------------- health and display

test("a populated health file is surfaced with its status and detail", () => {
  const environment = makeEnvironment();
  ensureStateDirectory(environment);
  writeFileSync(
    healthPath(environment),
    JSON.stringify({
      status: "failed",
      last_run_at: "2026-07-31T09:00:00.000Z",
      detail: "evaluator timed out",
    }),
    { mode: 0o600 },
  );

  const health = readHealth(environment);
  assert.equal(health.available, true);
  assert.equal(health.status, "failed");
  assert.equal(health.lastRunAt, "2026-07-31T09:00:00.000Z");
  assert.equal(health.detail, "evaluator timed out");

  const { output } = invoke(environment, ["status"]);
  assert.match(output, /evaluator: failed/);
  assert.match(output, /evaluator timed out/);
});

test("an unrecognised health status is shown as unknown rather than hidden", () => {
  const environment = makeEnvironment();
  ensureStateDirectory(environment);
  writeFileSync(healthPath(environment), JSON.stringify({ status: "weird" }), {
    mode: 0o600,
  });
  // 「読めたが状態を解釈できない」は「読めない」とは別の事実なので分けて出す。
  assert.equal(readHealth(environment).status, "unknown");
  assert.match(invoke(environment, ["status"]).output, /evaluator: unknown/);
});

test("the human-readable views name each section and every candidate state", () => {
  const environment = makeEnvironment();
  seed(environment, [
    candidateInput(),
    candidateInput({ id: "second-candidate", title: "二件目" }),
  ]);
  invoke(environment, ["resolve", "second-candidate", "--decision=defer"]);

  const status = invoke(environment, ["status", "--history"]).output;
  assert.match(status, /改善候補（1 件）/);
  assert.match(status, /\[候補\] reduce-ci-log-refetch/);
  assert.match(status, /採用済み（効果測定中）: なし/);
  assert.match(status, /\[延期中\] second-candidate — 二件目/);
  assert.match(status, /延期期限:/);

  assert.match(invoke(environment, ["next"]).output, /reduce-ci-log-refetch/);
  assert.equal(
    formatNext(null),
    "提示すべき候補はありません。",
  );
  assert.match(
    formatStatus({
      health: { available: false, reason: "not-run" },
      partitions: { active: [], adopted: [], history: [] },
      includeHistory: false,
    }),
    /evaluator: 未実行/,
  );

  const upsert = invoke(environment, ["upsert"], {
    readInput: () => JSON.stringify(candidateInput()),
  }).output;
  assert.match(upsert, /reduce-ci-log-refetch: updated/);
  assert.match(upsert, /保持中の候補: 2 件/);
});

// ------------------------------------------------------- real process entry

test("the real entry point reads argv, stdin and reports failures on stderr", () => {
  const environment = makeEnvironment();
  const cliPath = fileURLToPath(
    new URL("../home/dot_local/lib/agent-improvement/cli.mjs", import.meta.url),
  );
  const base = { ...process.env, ...environment };

  const created = spawnSync(process.execPath, [cliPath, "upsert"], {
    env: base,
    input: JSON.stringify(candidateInput()),
    encoding: "utf8",
  });
  assert.equal(created.status, 0, created.stderr);
  assert.match(created.stdout, /reduce-ci-log-refetch: created/);

  const shown = spawnSync(process.execPath, [cliPath, "status"], {
    env: base,
    encoding: "utf8",
  });
  assert.equal(shown.status, 0, shown.stderr);
  assert.match(shown.stdout, /reduce-ci-log-refetch/);

  // 例外は stack ではなく一行のメッセージとして stderr に出し、exit 1 で終わる。
  const failed = spawnSync(process.execPath, [cliPath, "status", "--histry"], {
    env: base,
    encoding: "utf8",
  });
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /^agent-improvement: unknown flag --histry\n$/);

  const usage = spawnSync(process.execPath, [cliPath, "bogus"], {
    env: base,
    encoding: "utf8",
  });
  assert.equal(usage.status, 64);
  assert.match(usage.stdout, /使い方: agent-improvement/);
});

// ============================================================ review round 2
// large tier（cc-security-review / architecture-reviewer / codex generalist /
// test-reviewer / performance-reviewer）と adversarial round で挙がった指摘の回帰テスト。

const ESC = String.fromCharCode(27);

// ------------------------------------------------------------- permissions

test("a restrictive umask cannot leave an unusable state directory behind", () => {
  // umask が owner ビットを削ると mkdirSync は mode 000 のディレクトリを作り、
  // O_NOFOLLOW の open が EACCES で失敗して 0700 へ矯正できない。残骸が残ると
  // 次回以降も同じ理由で失敗し続けるため、自己回復することを固定する。
  const root = makeStateRoot();
  const parent = path.join(root, "state");
  mkdirSync(parent, { recursive: true });
  chmodSync(parent, 0o755);
  const directory = path.join(parent, "agent-improvement");

  const previousUmask = process.umask(0o700);
  try {
    ensureStateDirectory(envFor(directory));
  } finally {
    process.umask(previousUmask);
  }
  assert.equal(statSync(directory).mode & 0o777, 0o700);
});

test("a directory left at mode 000 by an earlier failure is healed", () => {
  const root = makeStateRoot();
  const directory = path.join(root, "agent-improvement");
  mkdirSync(directory, { recursive: true });
  chmodSync(directory, 0o000);

  ensureStateDirectory(envFor(directory));
  assert.equal(statSync(directory).mode & 0o777, 0o700);
});

test("a symlinked ancestor below the trusted base is refused before anything is created", () => {
  // O_NOFOLLOW が守るのは最終要素だけなので、`<base>/.local/state` を symlink に
  // したときに追従しないことを別に固定する。検査は mkdir の前に走るので、
  // リンク先には何も作られない。
  const root = makeStateRoot();
  const victim = path.join(root, "victim");
  mkdirSync(victim, { recursive: true });
  const home = path.join(root, "home");
  mkdirSync(path.join(home, ".local"), { recursive: true });
  symlinkSync(victim, path.join(home, ".local", "state"));

  assert.throws(
    () => ensureStateDirectory({ HOME: home }),
    /state path component .* must not be a symbolic link/,
  );
  assert.equal(existsSync(path.join(victim, "agent-improvement")), false);
});

test("an OS-level symlink above the trusted base is not mistaken for an attack", () => {
  // macOS の os.tmpdir() は /var -> /private/var を経由する。信頼ベースより上を
  // 検査対象にすると、この経路のすべての呼び出しが誤検知で壊れる。
  const environment = makeEnvironment();
  assert.doesNotThrow(() => ensureStateDirectory(environment));
  assert.equal(
    statSync(environment.AGENT_IMPROVEMENT_STATE_DIR).mode & 0o777,
    0o700,
  );
});

test("loose permissions are surfaced on read without being changed or fatal", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  const directory = environment.AGENT_IMPROVEMENT_STATE_DIR;
  chmodSync(directory, 0o755);
  chmodSync(queuePath(environment), 0o644);

  const warnings = inspectStatePermissions(environment);
  assert.equal(warnings.length, 2);

  // 表示は成功し（AC-037 の全件表示を止めない）、権限も矯正しない（要件 5.3）。
  const { code, output } = invoke(environment, ["status"]);
  assert.equal(code, 0);
  assert.match(output, /警告: state directory is 755/);
  assert.equal(statSync(directory).mode & 0o777, 0o755);

  // 次の書き込みで矯正される。
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=defer"]);
  assert.equal(statSync(directory).mode & 0o777, 0o700);
  assert.equal(statSync(queuePath(environment)).mode & 0o777, 0o600);
});

// ------------------------------------------------------------ content safety

test("control characters are refused in every free-text field", () => {
  const nowIso = NOW.toISOString();
  // 値は既定の plain text 出力へそのまま補間され、端末のエスケープとして解釈され
  // うるうえ、その出力を会話へ整形表示する skill を通じて後続セッションの入力にもなる。
  for (const overrides of [
    { title: `a${ESC}[2Jb` },
    { summary: `line1${String.fromCharCode(10)}line2` },
    { id: `ok${String.fromCharCode(9)}` },
  ]) {
    assert.throws(
      () => normalizeCandidateInput(candidateInput(overrides), nowIso),
      /must not contain control characters|must match/,
      `${Object.keys(overrides)[0]} accepted a control character`,
    );
  }
  assert.throws(
    () =>
      normalizeAdoption({
        success_metric: `m${ESC}`,
        baseline: "b",
        review_on: "2026-09-01",
        fallback: "f",
      }),
    /must not contain control characters/,
  );
  // 通常の日本語は通る。
  assert.doesNotThrow(() =>
    normalizeCandidateInput(
      candidateInput({ title: "CI ログの再取得を減らす" }),
      nowIso,
    ),
  );
});

test("a control character in the evaluator's health detail is stripped for display", () => {
  // health は #506 が書く別プロデューサの出力で、候補と違って schema を通らない。
  const environment = makeEnvironment();
  ensureStateDirectory(environment);
  writeFileSync(
    healthPath(environment),
    JSON.stringify({ status: "ok", detail: `x${ESC}[2Jy` }),
    { mode: 0o600 },
  );
  const health = readHealth(environment);
  assert.equal(health.detail.includes(ESC), false);
  assert.equal(invoke(environment, ["status"]).output.includes(ESC), false);
});

// -------------------------------------------------------------- timestamps

test("hour 24 is refused instead of rolling over to the next day", () => {
  assert.throws(
    () =>
      normalizeCandidateInput(
        candidateInput({ created_at: "2026-02-28T24:00:00Z" }),
        NOW.toISOString(),
      ),
    /must match/,
  );
});

// ------------------------------------------------------------- write guards

test("the revision is a safe integer, so the counter cannot silently stall", () => {
  // 2^53 では revision + 1 === revision となり、増分が止まったことに誰も
  // 気づけないまま CAS が機能停止する。
  assert.throws(
    () =>
      parseQueueDocument({
        version: 1,
        revision: Number.MAX_SAFE_INTEGER,
        updated_at: NOW.toISOString(),
        candidates: [],
      }),
    /queue\.revision must be an integer between 0 and/,
  );
});

test("a write that would roll a terminal candidate back is refused", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=reject"]);
  const stored = readQueue(environment, NOW.toISOString());

  // revision は正しいのに、候補だけを active へ戻そうとする論理バグを模す。
  assert.throws(
    () =>
      writeQueue(environment, {
        ...stored,
        updated_at: NOW.toISOString(),
        candidates: [
          storedCandidate({ id: "reduce-ci-log-refetch", state: "active" }),
        ],
      }),
    /is rejected on disk and cannot be rolled back to active/,
  );
});

// --------------------------------------------------------------------- cli

test("a repeated flag is refused rather than resolved last-wins", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  // 三択に固定した契約が曖昧な入力を素通りさせてはいけない。
  assert.throws(
    () =>
      invoke(environment, [
        "resolve",
        "reduce-ci-log-refetch",
        "--decision=reject",
        "--decision=adopt",
      ]),
    /--decision was given more than once/,
  );
});

test("a decision-scoped flag names the decision it actually belongs to", () => {
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
        "--review-on=2026-09-01",
        "--fallback=f",
        "--until=2026-09-01",
      ]),
    /--until is only valid with --decision=defer/,
  );
});

test("unknown envelope keys are refused like unknown candidate keys", () => {
  const environment = makeEnvironment();
  assert.throws(
    () =>
      invoke(environment, ["upsert"], {
        readInput: () =>
          JSON.stringify({ candidates: [candidateInput()], canditates: [] }),
      }),
    /candidate input has unknown keys: canditates/,
  );
});

test("an upsert that changes nothing leaves the queue untouched", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, ["resolve", "reduce-ci-log-refetch", "--decision=reject"]);
  const before = readFileSync(queuePath(environment), "utf8");
  const beforeStat = statSync(queuePath(environment));

  const { output } = invoke(environment, ["upsert", "--json"], {
    readInput: () => JSON.stringify(candidateInput()),
  });
  assert.match(output, /"changed": false/);
  assert.equal(readFileSync(queuePath(environment), "utf8"), before);
  assert.equal(statSync(queuePath(environment)).mtimeMs, beforeStat.mtimeMs);
});

test("an oversized --file is refused while it is read, not after", () => {
  const environment = makeEnvironment();
  const root = makeStateRoot();
  const big = path.join(root, "big.json");
  writeFileSync(big, " ".repeat(2 * 1024 * 1024));
  assert.throws(
    () => invoke(environment, ["upsert", "--file", big]),
    /must be at most \d+ bytes/,
  );
});

test("history is only built when it will be shown", () => {
  const document = {
    candidates: [
      storedCandidate({
        state: "rejected",
        decision: { kind: "reject", at: NOW.toISOString() },
      }),
    ],
  };
  assert.equal(partitionQueue(document, NOW).history.length, 1);
  assert.equal(
    partitionQueue(document, NOW, { includeHistory: false }).history.length,
    0,
  );
});

test("a rejected candidate keeps its rank score in the history view", () => {
  const environment = makeEnvironment();
  seed(environment, [candidateInput()]);
  invoke(environment, [
    "resolve",
    "reduce-ci-log-refetch",
    "--decision=reject",
    "--note=今回は見送る",
  ]);
  const output = invoke(environment, ["status", "--history"]).output;
  assert.match(output, /\[見送り\] reduce-ci-log-refetch/);
  assert.doesNotMatch(output, /score=undefined/);
});

// ---------------------------------------------------------------- launcher

test("the launcher refuses a relative HOME before resolving the module", () => {
  // HOME が相対だと cwd 基準で解決され、たまたま cd していたリポジトリが同梱する
  // .local/lib/agent-improvement/cli.mjs を実行してしまう。
  const launcher = fileURLToPath(
    new URL(
      "../home/dot_local/bin/executable_agent-improvement",
      import.meta.url,
    ),
  );
  const planted = makeStateRoot();
  mkdirSync(path.join(planted, ".local", "lib", "agent-improvement"), {
    recursive: true,
  });
  writeFileSync(
    path.join(planted, ".local", "lib", "agent-improvement", "cli.mjs"),
    "process.stdout.write('planted\\n');\n",
  );

  const result = spawnSync("bash", [launcher, "status"], {
    cwd: planted,
    env: { ...process.env, HOME: "." },
    encoding: "utf8",
  });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /HOME を絶対パスで設定してください/);
  assert.doesNotMatch(result.stdout, /planted/);
});
