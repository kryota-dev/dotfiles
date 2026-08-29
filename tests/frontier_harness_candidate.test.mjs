import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  CANDIDATE_CAPABILITY,
  adoptionVerdict,
} from "../home/dot_local/lib/frontier-harness/candidate-command.mjs";
import {
  CANDIDATE_MAX_LIVE_ENTRIES,
  candidatesDirectory,
  createCandidateStore,
} from "../home/dot_local/lib/frontier-harness/candidate-store.mjs";
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";

// 使い捨て candidate worktree（#495）専用のスイート。
//
// **実 provider を起動しない。** candidate が実際に走らせるのは git だけで、ツリーの中身は
// テストが直接書く。ここで確かめたいのは「隔離されているか」「検証を通ったものだけを
// 取り込むか」「衝突したときに作業を捨てないか」であって、model の書く内容ではない。

const APPROVED_COMMAND = "npm run test";

const baseConfigInput = {
  version: 1,
  rollout: "pilot",
  retention: { rawArtifactsDays: 30, aggregateTelemetryDays: 180 },
  capabilities: {
    "executor.default": { provider: "codex", model: "gpt-5.6-terra", effort: "xhigh" },
    "semantic.judge": { provider: "claude", model: "claude-opus-5", effort: "high" },
  },
  risk: { alwaysEscalate: ["merge"] },
};
const config = normalizeConfig(baseConfigInput);
const shadowConfig = normalizeConfig({ ...baseConfigInput, rollout: "shadow" });

const PUBLIC_LOOKUP = () => [{ address: "93.184.216.34", family: 4 }];

// 本リポジトリはコミット署名（1Password SSH）と gitleaks の pre-commit hook を使うため、
// 明示的に無効化しないと fixture が実行環境の設定に依存する。
const GIT_FIXTURE_FLAGS = Object.freeze([
  "-c",
  "user.email=frontier-harness@example.com",
  "-c",
  "user.name=frontier-harness test",
  "-c",
  "commit.gpgsign=false",
  "-c",
  "core.hooksPath=",
]);

function git(cwd, args) {
  return execFileSync("git", [...GIT_FIXTURE_FLAGS, ...args], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-candidate-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

function initRepository(directory) {
  mkdirSync(directory, { recursive: true });
  git(directory, ["init", "--quiet", directory]);
  writeFileSync(path.join(directory, "tracked.txt"), "one\ntwo\nthree\n");
  git(directory, ["add", "-A"]);
  git(directory, ["commit", "--quiet", "-m", "init"]);
  return directory;
}

async function approveManifest(directory, statePath, manifest) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(
    manifestPath,
    JSON.stringify({ commands: [], domains: [], capabilities: [], ...manifest }),
  );
  const policyPath = path.join(directory, ".harness", "policy.json");
  const base = {
    config,
    cwd: directory,
    statePath,
    policyPath,
    lookup: PUBLIC_LOOKUP,
    write: () => {},
  };
  const output = [];
  assert.equal(
    await runCli(["onboard", "--manifest", manifestPath, "--json"], {
      ...base,
      pid: 4242,
      write: (line) => output.push(line),
    }),
    2,
  );
  const { request } = JSON.parse(output.pop());
  assert.equal(
    await runCli(
      ["onboard", "--manifest", manifestPath, "--approve", "--request", request.id, "--json"],
      { ...base, pid: 4243 },
    ),
    0,
  );
  return policyPath;
}

// state と candidate 登記簿は repository の外に置く。中に置くと候補ツリーと state が
// 互いの diff に載る（本番では state root が `.git` の内側なので載らない）。
async function prepared(context, { capabilities = [CANDIDATE_CAPABILITY] } = {}) {
  const directory = temporaryDirectory(context);
  const repository = initRepository(path.join(directory, "repo"));
  const statePath = path.join(directory, "state.db");
  const policyPath = await approveManifest(repository, statePath, {
    capabilities,
    commands: [APPROVED_COMMAND],
  });
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "diversify a write-capable route" });
  store.close();
  // 承認の儀式は `.harness/policy.json` と manifest candidate を残す。以降の
  // 「主ワークツリーは触られていない」はこの時点との比較で見る。
  const baseline = git(repository, ["status", "--porcelain"]);
  return { directory, repository, statePath, policyPath, task, baseline };
}

async function candidate(argumentsList, fixture, { candidateConfig = config } = {}) {
  const output = [];
  const code = await runCli([...argumentsList, "--json"], {
    config: candidateConfig,
    statePath: fixture.statePath,
    cwd: fixture.repository,
    policyPath: fixture.policyPath,
    write: (line) => output.push(line),
  });
  return { code, report: output.length ? JSON.parse(output.at(-1)) : null };
}

// candidate の task に対して決定的チェックの結果を 1 件記録する。実際に `fh verify` を
// 走らせる経路は frontier_harness_verify.test.mjs が押さえているので、ここでは取り込み
// 判定への入力として直接置く。
function recordCheck(fixture, { status = "passed", exitCode = 0 } = {}) {
  const store = createStateStore(fixture.statePath);
  try {
    return store.recordVerificationResult({
      taskId: fixture.task.id,
      checkKind: "test",
      status,
      command: APPROVED_COMMAND,
      exitCode,
    });
  } finally {
    store.close();
  }
}

async function createCandidate(fixture) {
  const { code, report } = await candidate(
    ["candidate", "create", "--task", fixture.task.id],
    fixture,
  );
  assert.equal(code, 0);
  return report.candidate;
}

// ---------------------------------------------------------------------------
// 隔離
// ---------------------------------------------------------------------------

test("a candidate is a detached, disposable worktree that leaves the primary tree alone", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);

  assert.equal(record.status, "open");
  assert.equal(record.taskId, fixture.task.id);
  assert.equal(existsSync(path.join(record.worktree, "tracked.txt")), true);

  // 候補は使い捨てなので branch を持たない（`pr-workflow` の PR ブランチを置き換えない）。
  const worktrees = git(fixture.repository, ["worktree", "list"]);
  assert.match(worktrees, /\(detached HEAD\)/);
  assert.equal(/\[/.test(worktrees.split("\n")[1] ?? ""), false);

  // 主ワークツリーは触られていない。
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), fixture.baseline);
});

test("writes inside a candidate do not reach the primary worktree", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);

  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");
  writeFileSync(path.join(record.worktree, "added.txt"), "from the candidate\n");

  assert.equal(
    readFileSync(path.join(fixture.repository, "tracked.txt"), "utf8"),
    "one\ntwo\nthree\n",
  );
  assert.equal(existsSync(path.join(fixture.repository, "added.txt")), false);
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), fixture.baseline);
});

test("the candidate registry lives outside the primary worktree", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  // 登記簿もツリーも、主ワークツリーの `git status` には現れない。
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), fixture.baseline);
  assert.equal(record.worktree.startsWith(fixture.repository + path.sep), false);
});

// ---------------------------------------------------------------------------
// 承認境界と rollout
// ---------------------------------------------------------------------------

test("a repository that has not approved candidate worktrees creates none", async (context) => {
  const fixture = await prepared(context, { capabilities: [] });
  const { code, report } = await candidate(
    ["candidate", "create", "--task", fixture.task.id],
    fixture,
  );

  assert.equal(code, 2);
  assert.equal(report.executed, false);
  assert.deepEqual(
    report.gaps.map((gap) => [gap.kind, gap.value]),
    [["capability", CANDIDATE_CAPABILITY]],
  );
  assert.equal(git(fixture.repository, ["worktree", "list"]).trim().split("\n").length, 1);
});

test("the shadow rollout creates no worktree at all", async (context) => {
  const fixture = await prepared(context);
  const { code, report } = await candidate(
    ["candidate", "create", "--task", fixture.task.id],
    fixture,
    { candidateConfig: shadowConfig },
  );

  assert.equal(code, 0);
  assert.equal(report.executed, false);
  assert.match(report.executionReason, /shadow rollout/);
  assert.equal(report.candidate, null);
  assert.equal(git(fixture.repository, ["worktree", "list"]).trim().split("\n").length, 1);
});

// ---------------------------------------------------------------------------
// 取り込み判定
// ---------------------------------------------------------------------------

test("adoption requires a check recorded after the candidate was created", () => {
  const candidateRecord = { createdAt: "2026-08-29T12:00:00.000Z" };
  // 作成より前の緑は、このツリーの中身について何も言っていない。
  assert.equal(
    adoptionVerdict({
      candidate: candidateRecord,
      results: [{ status: "passed", createdAt: "2026-08-29T11:59:59.000Z" }],
    }).verified,
    false,
  );
  assert.equal(
    adoptionVerdict({
      candidate: candidateRecord,
      results: [{ status: "passed", createdAt: "2026-08-29T12:00:01.000Z" }],
    }).verified,
    true,
  );
  // 1 件でも通っていなければ取り込まない。
  assert.equal(
    adoptionVerdict({
      candidate: candidateRecord,
      results: [
        { status: "passed", createdAt: "2026-08-29T12:00:01.000Z" },
        { status: "failed", createdAt: "2026-08-29T12:00:02.000Z" },
      ],
    }).verified,
    false,
  );
});

test("an unverified candidate is not adopted and its worktree is kept", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");

  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );

  assert.equal(code, 2);
  assert.equal(report.adopted, false);
  assert.match(report.executionReason, /no deterministic verification/);
  // 検証されていないだけで、作業は捨てない。
  assert.equal(report.candidate.status, "open");
  assert.equal(existsSync(record.worktree), true);
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), fixture.baseline);
});

test("a candidate whose check went red is not adopted", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");
  recordCheck(fixture, { status: "failed", exitCode: 1 });

  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );

  assert.equal(code, 2);
  assert.equal(report.adopted, false);
  assert.match(report.executionReason, /did not pass/);
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), fixture.baseline);
});

test("a verified candidate moves into the primary worktree and is then disposed of", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");
  writeFileSync(path.join(record.worktree, "added.txt"), "from the candidate\n");
  recordCheck(fixture);

  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );

  assert.equal(code, 0);
  assert.equal(report.adopted, true);
  assert.equal(report.verifiedChecks, 1);
  assert.equal(report.candidate.status, "adopted");

  // 追跡済みの変更も未追跡の新規ファイルも取り込まれる。
  assert.equal(
    readFileSync(path.join(fixture.repository, "tracked.txt"), "utf8"),
    "one\nCANDIDATE\nthree\n",
  );
  assert.equal(
    readFileSync(path.join(fixture.repository, "added.txt"), "utf8"),
    "from the candidate\n",
  );
  // 取り込みは適用までで、commit も push もしない（所有権は pr-workflow のまま）。
  assert.match(git(fixture.repository, ["status", "--porcelain"]), /^ M tracked\.txt$/m);
  assert.equal(git(fixture.repository, ["log", "--oneline"]).trim().split("\n").length, 1);

  // 用済みのツリーは撤去される。
  assert.equal(existsSync(record.worktree), false);
  assert.equal(git(fixture.repository, ["worktree", "list"]).trim().split("\n").length, 1);
});

test("an empty candidate is refused rather than adopted as a no-op", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  recordCheck(fixture);

  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );
  assert.equal(code, 2);
  assert.equal(report.adopted, false);
  assert.match(report.executionReason, /no changes to adopt/);
});

test("a check can run inside the candidate, authorized through the registry", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");

  // candidate は base commit の detached checkout なので、`.harness/policy.json` が未コミット
  // ならそのツリーには無い。`--worktree` で直接指すと承認境界が必ず止める（fail-closed）。
  const bin = path.join(fixture.directory, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(path.join(bin, "npm"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const verifyOptions = {
    config,
    statePath: fixture.statePath,
    cwd: fixture.repository,
    policyPath: fixture.policyPath,
    environment: { PATH: bin },
    write: () => {},
  };
  assert.equal(
    await runCli(
      [
        "verify",
        "--task",
        fixture.task.id,
        "--command",
        APPROVED_COMMAND,
        "--worktree",
        record.worktree,
        "--json",
      ],
      { ...verifyOptions, policyPath: path.join(record.worktree, ".harness", "policy.json") },
    ),
    2,
  );

  // `--candidate` は登記簿経由でツリーを解決するので、承認は所有元リポジトリのものが効く。
  const output = [];
  assert.equal(
    await runCli(
      [
        "verify",
        "--task",
        fixture.task.id,
        "--candidate",
        record.id,
        "--command",
        APPROVED_COMMAND,
        "--json",
      ],
      { ...verifyOptions, write: (line) => output.push(line) },
    ),
    0,
  );
  const report = JSON.parse(output.pop());
  assert.equal(report.status, "passed");
  assert.equal(report.candidateId, record.id);

  // その結果がそのまま取り込みの根拠になる（隔離 → 検証 → 取り込みが一本で通る）。
  const adopted = await candidate(["candidate", "adopt", "--candidate", record.id], fixture);
  assert.equal(adopted.code, 0);
  assert.equal(adopted.report.adopted, true);
  assert.equal(
    readFileSync(path.join(fixture.repository, "tracked.txt"), "utf8"),
    "one\nCANDIDATE\nthree\n",
  );
});

test("a check cannot be aimed at a candidate that is not in the registry", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  await candidate(["candidate", "discard", "--candidate", record.id], fixture);

  const verify = (candidateId) =>
    runCli(
      [
        "verify",
        "--task",
        fixture.task.id,
        "--candidate",
        candidateId,
        "--command",
        APPROVED_COMMAND,
        "--json",
      ],
      {
        config,
        statePath: fixture.statePath,
        cwd: fixture.repository,
        policyPath: fixture.policyPath,
        write: () => {},
      },
    );

  await assert.rejects(() => verify(record.id), /is discarded and has no worktree to verify/);
  await assert.rejects(
    () => verify("cand_ffffffffffffffffffffffffffffffff"),
    /does not exist/,
  );
});

// ---------------------------------------------------------------------------
// 衝突時の保持とエスカレーション
// ---------------------------------------------------------------------------

test("a conflicting candidate is retained, not discarded, and escalates", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");
  recordCheck(fixture);

  // 主ワークツリーが同じ行を別の内容へ動かす（衝突を作る）。
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\nPRIMARY\nthree\n");

  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );

  // 承認待ちと同じ終了コードで user の判断へ戻す。
  assert.equal(code, 2);
  assert.equal(report.adopted, false);
  assert.match(report.executionReason, /does not apply cleanly/);
  assert.equal(report.candidate.status, "conflicted");

  // **作業を捨てない。** 候補ツリーはそのまま残る。
  assert.equal(existsSync(record.worktree), true);
  assert.equal(
    readFileSync(path.join(record.worktree, "tracked.txt"), "utf8"),
    "one\nCANDIDATE\nthree\n",
  );
  // 主ワークツリーは部分適用されていない。
  assert.equal(
    readFileSync(path.join(fixture.repository, "tracked.txt"), "utf8"),
    "one\nPRIMARY\nthree\n",
  );
});

test("a retained candidate can be adopted once the conflict is gone", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");
  recordCheck(fixture);
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\nPRIMARY\nthree\n");
  assert.equal(
    (await candidate(["candidate", "adopt", "--candidate", record.id], fixture)).code,
    2,
  );

  // user が主ワークツリー側を戻せば、保持された候補はそのまま取り込める。
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\ntwo\nthree\n");
  const { code, report } = await candidate(
    ["candidate", "adopt", "--candidate", record.id],
    fixture,
  );
  assert.equal(code, 0);
  assert.equal(report.candidate.status, "adopted");
  assert.equal(
    readFileSync(path.join(fixture.repository, "tracked.txt"), "utf8"),
    "one\nCANDIDATE\nthree\n",
  );
});

// ---------------------------------------------------------------------------
// 登記簿
// ---------------------------------------------------------------------------

test("discard removes the worktree and records that it was discarded", async (context) => {
  const fixture = await prepared(context);
  const record = await createCandidate(fixture);
  writeFileSync(path.join(record.worktree, "tracked.txt"), "one\nCANDIDATE\nthree\n");

  const { code, report } = await candidate(
    ["candidate", "discard", "--candidate", record.id],
    fixture,
  );
  assert.equal(code, 0);
  assert.equal(report.candidate.status, "discarded");
  assert.equal(existsSync(record.worktree), false);

  // 破棄済みの候補にツリーは無いので、取り込もうとすれば名指しで落ちる。
  await assert.rejects(
    () => candidate(["candidate", "adopt", "--candidate", record.id], fixture),
    /is discarded and has no worktree/,
  );
});

test("list reports every candidate the registry knows about", async (context) => {
  const fixture = await prepared(context);
  const first = await createCandidate(fixture);
  const second = await createCandidate(fixture);
  await candidate(["candidate", "discard", "--candidate", first.id], fixture);

  const { report } = await candidate(["candidate", "list"], fixture);
  assert.deepEqual(
    report.candidates.map((entry) => [entry.id, entry.status]),
    [
      [first.id, "discarded"],
      [second.id, "open"],
    ],
  );
});

test("the registry refuses to hold more live candidates than its limit", async (context) => {
  const fixture = await prepared(context);
  for (let index = 0; index < CANDIDATE_MAX_LIVE_ENTRIES; index += 1) {
    await createCandidate(fixture);
  }
  const { code, report } = await candidate(
    ["candidate", "create", "--task", fixture.task.id],
    fixture,
  );
  assert.equal(code, 2);
  assert.equal(report.candidate, null);
  assert.match(report.executionReason, /already open/);
});

test("a candidate id cannot escape the registry directory", async (context) => {
  const fixture = await prepared(context);
  // traversal の題材に `/etc/...` の実在パスを使わない。id の字集合が拒むことを見るのが目的で
  // 行き先は関係ないうえ、秘密情報スキャナが「汎用パスワード」として誤検知する。
  for (const identifier of ["../../escaped", "cand_../x", "cand_XYZ"]) {
    await assert.rejects(
      () => candidate(["candidate", "adopt", "--candidate", identifier], fixture),
      /candidate id must match/,
      identifier,
    );
  }
});

test("a candidate worktree cannot be created for a task that does not exist", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => candidate(["candidate", "create", "--task", "task_missing"], fixture),
    /task task_missing is not in the state database/,
  );
});

test("fh candidate refuses an action it does not implement", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => candidate(["candidate", "promote"], fixture),
    /fh candidate requires create, list, adopt, or discard/,
  );
});

test("a corrupt registry entry is surfaced rather than skipped", async (context) => {
  const fixture = await prepared(context);
  await createCandidate(fixture);
  const directory = candidatesDirectory(path.dirname(fixture.statePath));
  const entry = path.join(directory, `${(await createCandidate(fixture)).id}.candidate.json`);
  writeFileSync(entry, "{ not json");

  // 読み飛ばすと、実在するツリーを「無い」と判断して上限も撤去も効かなくなる。
  assert.throws(() => createCandidateStore({ directory }).list(), /JSON/);
});
