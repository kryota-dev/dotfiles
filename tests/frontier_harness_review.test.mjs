import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  REVIEW_FINDINGS_MAX_ENTRIES,
  REVIEW_TEXT_MAX_LENGTH,
  normalizeFindingsDocument,
  reviewClaims,
  reviewVerdict,
} from "../home/dot_local/lib/frontier-harness/review-registry.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";

// review registry と reviewer packet（#495）専用のスイート。
//
// **実 provider を起動しない。** registry が受け取るのは reviewer の出力ファイルであり、
// それを誰が書いたかは registry の関心ではない。packet 側も git しか呼ばない。

const APPROVED_COMMAND = "npm run test";
// writer 側の会話。packet にも registry にも現れてはいけない文字列。
const WRITER_CONVERSATION = "SECRET-WRITER-CONVERSATION do not hand this to a reviewer";

const config = normalizeConfig({
  version: 1,
  rollout: "pilot",
  retention: { rawArtifactsDays: 30, aggregateTelemetryDays: 180 },
  capabilities: {
    "executor.default": { provider: "codex", model: "gpt-5.6-terra", effort: "xhigh" },
    "semantic.judge": { provider: "claude", model: "claude-opus-5", effort: "high" },
  },
  risk: { alwaysEscalate: ["merge"] },
});

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
  const directory = mkdtempSync(path.join(tmpdir(), "frontier-harness-review-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

function initRepository(directory) {
  mkdirSync(directory, { recursive: true });
  git(directory, ["init", "--quiet", directory]);
  writeFileSync(path.join(directory, "tracked.txt"), "one\ntwo\n");
  git(directory, ["add", "-A"]);
  git(directory, ["commit", "--quiet", "-m", "init"]);
  return directory;
}

async function approveCommands(directory, statePath, commands = [APPROVED_COMMAND]) {
  const manifestPath = path.join(directory, "approved-manifest.json");
  writeFileSync(manifestPath, JSON.stringify({ commands, domains: [], capabilities: [] }));
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

// state は repository の外に置く。中に置くと state.db 自体が diff に載り、
// packet の検証がその副作用に巻き込まれる（本番では state root が `.git` の内側なので載らない）。
async function prepared(context, { approve = true } = {}) {
  const directory = temporaryDirectory(context);
  const repository = initRepository(path.join(directory, "repo"));
  const statePath = path.join(directory, "state.db");
  const policyPath = approve
    ? await approveCommands(repository, statePath)
    : path.join(repository, ".harness", "policy.json");
  const store = createStateStore(statePath);
  const task = store.createTask({
    goal: "add the feature",
    risk: ["regression"],
    hasDeterministicOracle: true,
  });
  store.close();
  return { directory, repository, statePath, policyPath, task };
}

function findingsDocument(findings, reviewerCapability = "semantic.judge") {
  return { version: 1, reviewerCapability, findings };
}

function writeFindings(directory, document) {
  const target = path.join(directory, "findings.json");
  writeFileSync(target, JSON.stringify(document));
  return target;
}

async function review(argumentsList, { repository, statePath, policyPath }) {
  const output = [];
  const code = await runCli([...argumentsList, "--json"], {
    config,
    statePath,
    cwd: repository,
    policyPath,
    write: (line) => output.push(line),
  });
  return { code, report: output.length ? JSON.parse(output.at(-1)) : null };
}

// ---------------------------------------------------------------------------
// registry の境界
// ---------------------------------------------------------------------------

test("a finding cannot smuggle the reviewer's prose through an extra key", () => {
  for (const extra of ["transcript", "rationale", "reasoning", "body"]) {
    assert.throws(
      () =>
        normalizeFindingsDocument(
          findingsDocument([
            {
              severity: "must",
              uncertainty: "low",
              summary: "the timeout is never cleared",
              [extra]: WRITER_CONVERSATION,
            },
          ]),
          { taskId: "task_1" },
        ),
      /unsupported key/,
      extra,
    );
  }
});

test("a finding summary is one printable line, not a review body", () => {
  const bad = [
    ["a".repeat(REVIEW_TEXT_MAX_LENGTH + 1), /at most/],
    ["first line\nsecond line", /single line/],
    // 生の ESC バイトをソースへ埋め込まない。実行時の文字列は同じだが、raw だと diff 表示・
    // `gh pr diff`・CI ログといった経路へ制御文字がそのまま漏れる。
    ["colours \u001b[31mred\u001b[0m", /single line/],
    ["   ", /must not be empty/],
  ];
  for (const [summary, pattern] of bad) {
    assert.throws(
      () =>
        normalizeFindingsDocument(
          findingsDocument([{ severity: "must", uncertainty: "low", summary }]),
          { taskId: "task_1" },
        ),
      pattern,
      JSON.stringify(summary),
    );
  }
});

test("the reviewer cannot choose which task its findings attach to", () => {
  // taskId は呼び出し側（CLI の `--task`）が決める。ファイル側に列そのものが無い。
  assert.throws(
    () =>
      normalizeFindingsDocument(
        {
          version: 1,
          reviewerCapability: "semantic.judge",
          taskId: "task_someone_elses",
          findings: [],
        },
        { taskId: "task_mine" },
      ),
    /unsupported key: taskId/,
  );

  const { findings } = normalizeFindingsDocument(
    findingsDocument([{ severity: "nits", uncertainty: "low", summary: "naming" }]),
    { taskId: "task_mine" },
  );
  assert.equal(findings[0].taskId, "task_mine");
});

test("the registry refuses more findings than it will hold", () => {
  const many = Array.from({ length: REVIEW_FINDINGS_MAX_ENTRIES + 1 }, (_unused, index) => ({
    severity: "nits",
    uncertainty: "low",
    summary: `finding ${index}`,
  }));
  assert.throws(
    () => normalizeFindingsDocument(findingsDocument(many), { taskId: "task_1" }),
    /at most/,
  );
});

test("a must finding blocks, and anything less is clear", () => {
  assert.equal(reviewVerdict([]).verdict, "clear");
  assert.equal(reviewVerdict([{ severity: "should" }, { severity: "good" }]).verdict, "clear");
  assert.equal(reviewVerdict([{ severity: "nits" }, { severity: "must" }]).verdict, "blocked");
});

test("evidence claims carry counts, never the findings themselves", () => {
  assert.deepEqual(
    reviewClaims({
      reviewerCapability: "semantic.judge",
      counts: { must: 1, should: 2, nits: 0, good: 0 },
      verdict: "blocked",
    }),
    [
      "semantic.judge returned a blocked review verdict",
      "the review recorded 1 must finding(s)",
      "the review recorded 2 should finding(s)",
    ],
  );
});

// ---------------------------------------------------------------------------
// fh review record
// ---------------------------------------------------------------------------

test("recorded findings land in the registry with a blocked verdict", async (context) => {
  const fixture = await prepared(context);
  const findingsPath = writeFindings(
    fixture.directory,
    findingsDocument([
      {
        severity: "must",
        uncertainty: "low",
        summary: "the timeout is never cleared on the error path",
        discriminatingExperiment: "run the check with a spawn that emits error",
      },
      { severity: "nits", uncertainty: "high", summary: "the constant name reads oddly" },
    ]),
  );

  const { code, report } = await review(
    ["review", "record", "--task", fixture.task.id, "--findings", findingsPath],
    fixture,
  );

  assert.equal(code, 1, "未解決の must がある review を 0 と読ませない");
  assert.equal(report.verdict, "blocked");
  assert.deepEqual(report.counts, { must: 1, should: 0, nits: 1, good: 0 });

  const store = createStateStore(fixture.statePath);
  const findings = store.listReviewFindingsForTask(fixture.task.id);
  // 同一ミリ秒に入った行の並びは `created_at, id` 順、つまり乱数 id 順になる。
  // 順序を前提にせず、集合として確かめる。
  assert.deepEqual(
    findings.map((finding) => finding.severity).sort(),
    ["must", "nits"],
  );
  const must = findings.find((finding) => finding.severity === "must");
  assert.equal(must.reviewerCapability, "semantic.judge");
  assert.equal(must.summary, "the timeout is never cleared on the error path");
  assert.equal(must.discriminatingExperiment, "run the check with a spawn that emits error");
  // finding は evidence に紐付く（Evidence Bus の来歴）。
  const [evidence] = store.listEvidence();
  assert.equal(must.evidenceId, evidence.id);
  assert.deepEqual(evidence.claimsSupported, [
    "semantic.judge returned a blocked review verdict",
    "the review recorded 1 must finding(s)",
    "the review recorded 1 nits finding(s)",
  ]);
  store.close();
});

test("a review with nothing above should exits clear", async (context) => {
  const fixture = await prepared(context);
  const findingsPath = writeFindings(
    fixture.directory,
    findingsDocument([{ severity: "good", uncertainty: "low", summary: "the guard is well placed" }]),
  );
  const { code, report } = await review(
    ["review", "record", "--task", fixture.task.id, "--findings", findingsPath],
    fixture,
  );
  assert.equal(code, 0);
  assert.equal(report.verdict, "clear");
});

test("findings cannot be recorded against a task that does not exist", async (context) => {
  const fixture = await prepared(context);
  const findingsPath = writeFindings(fixture.directory, findingsDocument([]));
  await assert.rejects(
    () => review(["review", "record", "--task", "task_missing", "--findings", findingsPath], fixture),
    /task task_missing is not in the state database/,
  );
});

test("fh review refuses an action it does not implement", async (context) => {
  const fixture = await prepared(context);
  await assert.rejects(
    () => review(["review", "--task", fixture.task.id], fixture),
    /fh review requires packet or record/,
  );
});

// ---------------------------------------------------------------------------
// fh review packet
// ---------------------------------------------------------------------------

test("a packet carries the task, constraints, diff, and verification results", async (context) => {
  const fixture = await prepared(context);
  const store = createStateStore(fixture.statePath);
  store.recordVerificationResult({
    taskId: fixture.task.id,
    checkKind: "test",
    status: "passed",
    command: APPROVED_COMMAND,
    exitCode: 0,
  });
  store.close();

  // 追跡済みファイルの変更と、未追跡の新規ファイルの両方を置く。
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\nCHANGED\n");
  writeFileSync(path.join(fixture.repository, "added.txt"), "brand new\n");

  const out = path.join(fixture.directory, "packet.json");
  const { code, report } = await review(
    ["review", "packet", "--task", fixture.task.id, "--out", out],
    fixture,
  );
  assert.equal(code, 0);
  assert.equal(report.verificationResults, 1);
  assert.equal(report.diffTruncated, false);

  const packet = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(packet.task.id, fixture.task.id);
  assert.equal(packet.task.goal, "add the feature");
  assert.deepEqual(packet.task.risk, ["regression"]);
  assert.deepEqual(packet.constraints.approvedCommands, [APPROVED_COMMAND]);
  assert.equal(packet.constraints.rollout, "pilot");
  assert.deepEqual(packet.verification, [
    {
      checkKind: "test",
      status: "passed",
      command: APPROVED_COMMAND,
      exitCode: 0,
      createdAt: packet.verification[0].createdAt,
    },
  ]);
  // 差分は追跡済みの変更と未追跡の新規ファイルの両方を含む。
  assert.match(packet.diff.patch, /-two\n\+CHANGED/);
  assert.match(packet.diff.patch, /new file mode/);
  assert.match(packet.diff.patch, /added\.txt/);
});

test("a packet has no channel for the writer's conversation", async (context) => {
  const fixture = await prepared(context);
  // writer 側の記録を state へ厚く積む。素朴な実装ならここから拾ってしまう。
  const store = createStateStore(fixture.statePath);
  const route = store.recordRoute(fixture.task.id, {
    kind: "single-worker",
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    reason: WRITER_CONVERSATION,
  });
  store.recordAdapterRun({
    taskId: fixture.task.id,
    routeId: route.id,
    capability: "executor.default",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    status: "failed",
    startedAt: new Date().toISOString(),
    finishedAt: new Date().toISOString(),
    failureReason: WRITER_CONVERSATION,
  });
  store.putEvidence({
    kind: "child_session",
    producer: "frontier-harness",
    taskId: fixture.task.id,
    claimsSupported: [WRITER_CONVERSATION],
  });
  store.close();

  const out = path.join(fixture.directory, "packet.json");
  assert.equal(
    (await review(["review", "packet", "--task", fixture.task.id, "--out", out], fixture)).code,
    0,
  );
  assert.equal(readFileSync(out, "utf8").includes(WRITER_CONVERSATION), false);
});

test("the packet is written to a file rather than printed", async (context) => {
  const fixture = await prepared(context);
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\nCHANGED\n");
  const out = path.join(fixture.directory, "packet.json");

  const output = [];
  await runCli(["review", "packet", "--task", fixture.task.id, "--out", out, "--json"], {
    config,
    statePath: fixture.statePath,
    cwd: fixture.repository,
    policyPath: fixture.policyPath,
    write: (line) => output.push(line),
  });
  // 報告するのは所在と形だけで、diff は stdout にもログにも流れない。
  assert.equal(output.join("\n").includes("CHANGED"), false);
});

test("an unapproved repository yields empty constraints instead of the raw policy", async (context) => {
  const fixture = await prepared(context, { approve: false });
  const out = path.join(fixture.directory, "packet.json");
  const { report } = await review(
    ["review", "packet", "--task", fixture.task.id, "--out", out],
    fixture,
  );

  assert.equal(report.policyIntegrity.ok, true);
  const packet = JSON.parse(readFileSync(out, "utf8"));
  // 承認が無い repository では「何も承認されていない」が reviewer へ伝わる（fail-closed）。
  assert.deepEqual(packet.constraints.approvedCommands, []);
  assert.deepEqual(packet.constraints.approvedCapabilities, []);
});

test("building a packet leaves the worktree's own index untouched", async (context) => {
  const fixture = await prepared(context);
  writeFileSync(path.join(fixture.repository, "tracked.txt"), "one\nCHANGED\n");
  writeFileSync(path.join(fixture.repository, "added.txt"), "brand new\n");
  const before = git(fixture.repository, ["status", "--porcelain"]);

  const out = path.join(fixture.directory, "packet.json");
  await review(["review", "packet", "--task", fixture.task.id, "--out", out], fixture);

  // ステージング状態は `pr-workflow` の持ち物である。差分を取るためだけに触らない。
  assert.equal(git(fixture.repository, ["status", "--porcelain"]), before);
  assert.match(before, /^ M tracked\.txt$/m);
  assert.match(before, /^\?\? added\.txt$/m);
});

test("a revision that git would read as a flag is refused", async (context) => {
  const fixture = await prepared(context);
  const out = path.join(fixture.directory, "packet.json");
  const packet = (base) => [
    "review",
    "packet",
    "--task",
    fixture.task.id,
    "--out",
    out,
    "--base",
    base,
  ];

  // 二重の防御。フラグ読み出しは `--` 始まりを値として受け取らず……
  await assert.rejects(
    () => review(packet("--output=/tmp/x"), fixture),
    /--base requires a value/,
  );
  // ……単一ハイフンで抜けてきた値は revision の字集合が拒否する（git に渡す前に落ちる）。
  await assert.rejects(() => review(packet("-o/tmp/x"), fixture), /must match/);
});
