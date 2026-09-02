import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  CLEAN_TARGET_PREVIEW_LIMIT,
  DEFAULT_STATUS_LIMIT,
  MAX_STATUS_LIMIT,
  createEmitter,
  runCli,
} from "../home/dot_local/lib/frontier-harness/cli.mjs";
import {
  COMMAND_HELP,
  helpCommandNames,
  undeclaredOutputKeys,
} from "../home/dot_local/lib/frontier-harness/command-help.mjs";
import { HarnessError, describeCliFailure } from "../home/dot_local/lib/frontier-harness/errors.mjs";
import { INTERNAL_ERROR, USAGE } from "../home/dot_local/lib/frontier-harness/exit-codes.mjs";
import {
  COMMAND_FLAGS,
  assertKnownFlags,
  knownFlagNames,
} from "../home/dot_local/lib/frontier-harness/flag-registry.mjs";
import { createStateStore } from "../home/dot_local/lib/frontier-harness/state-store.mjs";

// #508 の運用品質 7 項目の回帰テスト。
//
// **`fh clean` は破壊的である。** ここのテストはすべて `mkdtemp` で作った state root を
// `statePath` で注入し、実運用の state（git common directory 配下）には触れない。

const CLI_PATH = new URL(
  "../home/dot_local/lib/frontier-harness/cli.mjs",
  import.meta.url,
).pathname;

const COMMAND_MODULES = [
  "cli.mjs",
  "approval-commands.mjs",
  "candidate-command.mjs",
  "onboard-commands.mjs",
  "review-command.mjs",
  "session-command.mjs",
  "verify-command.mjs",
];

const config = normalizeConfig({
  version: 1,
  rollout: "shadow",
  retention: { rawArtifactsDays: 30, aggregateTelemetryDays: 180 },
  capabilities: {
    "executor.default": {
      provider: "codex",
      model: "gpt-5.6-terra",
      effort: "xhigh",
    },
  },
  risk: { alwaysEscalate: ["merge"] },
});

const NOW = "2026-08-31T00:00:00.000Z";
const EXPIRED_AT = "2026-07-01T00:00:00.000Z";

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "fh-cli-quality-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

function isolatedState(context) {
  return path.join(temporaryDirectory(context), "state.db");
}

function emitted(lines) {
  return JSON.parse(lines[lines.length - 1]);
}

// ---------------------------------------------------------------------------
// 1. 未知フラグを黙殺しない（#508 の 7 件目）
// ---------------------------------------------------------------------------

test("fh names an unknown flag and refuses it instead of ignoring it", (context) => {
  const statePath = isolatedState(context);
  for (const argumentsList of [
    ["status", "--bogus-flag"],
    ["gaps", "--bogus-flag"],
    ["doctor", "--bogus-flag"],
    ["clean", "--bogus-flag"],
    ["run", "--task", "/tmp/task.json", "--bogus-flag"],
    ["session", "launch", "--bogus-flag"],
    ["review", "packet", "--bogus-flag"],
    ["candidate", "list", "--bogus-flag"],
    ["approvals", "--bogus-flag"],
  ]) {
    assert.throws(
      () => runCli(argumentsList, { config, statePath, write: () => {} }),
      (error) => {
        assert.ok(error instanceof TypeError, `${argumentsList[0]} threw ${error}`);
        // 原因が読めないエラーは、この issue が直そうとしている問題そのもの。
        assert.match(error.message, /--bogus-flag/);
        return true;
      },
      argumentsList.join(" "),
    );
  }
});

test("fh clean refuses a misspelled --dry-run instead of pruning", (context) => {
  const statePath = isolatedState(context);
  const store = createStateStore(statePath);
  store.putEvidence({ kind: "old_log", producer: "fake", createdAt: EXPIRED_AT });
  store.close();

  // `--dryrun` は打ち間違い。以前はここが黙って捨てられ、確認のつもりの実行が実プルーンだった。
  assert.throws(
    () =>
      runCli(["clean", "--dryrun", "--now", NOW, "--json"], {
        config,
        statePath,
        write: () => {},
      }),
    /--dryrun/,
  );

  const survived = createStateStore(statePath);
  assert.equal(survived.listEvidence().length, 1);
  survived.close();
});

test("an unknown flag is refused before the value flag that follows it", (context) => {
  const statePath = isolatedState(context);
  // 値を取るフラグの読み飛ばしが、その手前の未知フラグを覆い隠さないこと。
  assert.throws(
    () =>
      runCli(["clean", "--dryrun", "--now", NOW], {
        config,
        statePath,
        write: () => {},
      }),
    /--dryrun/,
  );
});

test("a value that starts with a hyphen is not read as a flag", () => {
  // `--timeout-ms -1` の `-1` は値であって、未知フラグではない
  // （値そのものの検証は positiveIntegerFlag が行う）。
  assert.doesNotThrow(() => assertKnownFlags("verify", ["--timeout-ms", "-1"]));
});

test("fh points at the separate-argument form instead of calling --flag=value unknown", () => {
  assert.throws(
    () => assertKnownFlags("run", ["--task=/tmp/task.json"]),
    (error) => {
      assert.match(error.message, /--task/);
      assert.match(error.message, /separate argument/);
      return true;
    },
  );
});

// ---------------------------------------------------------------------------
// 2. 既知フラグを壊さない（`fh` は wave orchestration の実行経路そのもの）
// ---------------------------------------------------------------------------

test("the flag registry covers every flag the command modules read", () => {
  const known = knownFlagNames();
  const missing = new Set();
  for (const module of COMMAND_MODULES) {
    const source = readFileSync(
      new URL(`../home/dot_local/lib/frontier-harness/${module}`, import.meta.url),
      "utf8",
    );
    // `flagValue(flags, "--x")` / `optionalFlagValue(flags, "--x")` /
    // `positiveIntegerFlag(flags, "--x")` / `flags.includes("--x")` のいずれの形も拾う。
    for (const match of source.matchAll(
      /flags(?:,\s*|\.includes\(\s*)"(--[a-z][a-z0-9-]*)"/g,
    )) {
      if (!known.has(match[1])) missing.add(`${module}: ${match[1]}`);
    }
  }
  assert.deepEqual([...missing], []);
});

test("every documented flag of every command stays accepted", () => {
  const accepted = [
    ["approvals", ["--all", "--json"]],
    ["approvals", ["--purge", "--approvals-dir", "/abs/approvals"]],
    ["approve", ["--request", "req_1", "--allow", "--answers", "{}", "--message", "ok"]],
    ["approve", ["--request", "req_1", "--deny", "--approvals-dir", "/abs/approvals"]],
    [
      "approve-server",
      [
        "--session",
        "s1",
        "--approvals-dir",
        "/abs/approvals",
        "--rules",
        "/abs/rules.json",
        "--timeout-ms",
        "1000",
        "--progress-interval-ms",
        "500",
      ],
    ],
    ["candidate", ["create", "--task", "task_1", "--base", "HEAD", "--label", "l"]],
    ["candidate", ["list", "--worktree", "/abs/tree", "--json"]],
    ["candidate", ["adopt", "--candidate", "cand_1"]],
    ["candidate", ["discard", "--candidate", "cand_1"]],
    ["clean", ["--dry-run", "--now", NOW, "--json"]],
    ["doctor", ["--probe", "--json"]],
    ["gaps", ["--json"]],
    ["onboard", ["--manifest", "/abs/m.json", "--approve", "--request", "req_1"]],
    ["onboard", ["--from-gaps", "--json"]],
    ["review", ["packet", "--task", "task_1", "--out", "/abs/out.json", "--base", "HEAD"]],
    ["review", ["record", "--task", "task_1", "--findings", "/abs/f.json"]],
    ["run", ["--task", "/abs/task.json", "--json"]],
    ["runs", ["--json", "--limit", "10", "--offset", "20"]],
    ["runs", ["--run", "arun_1", "--json"]],
    [
      "session",
      [
        "launch",
        "--capability",
        "session.child",
        "--session-id",
        "abc",
        "--label",
        "wave-1",
        "--sandbox",
        "workspace-write",
        "--approvals-dir",
        "/abs/approvals",
        "--approval-server-command",
        "/abs/fh",
        "--timeout-ms",
        "1000",
        "--progress-interval-ms",
        "500",
        "--worktree",
        "/abs/tree",
        "--prompt-file",
        "/abs/prompt.md",
      ],
    ],
    [
      "session",
      ["resume", "--worktree", "/abs/tree", "--prompt-file", "/abs/p.md", "--resume-key", "abc"],
    ],
    ["status", ["--json", "--limit", "10", "--offset", "20"]],
    [
      "verify",
      [
        "--task",
        "task_1",
        "--command",
        "npm run test",
        "--kind",
        "lint",
        "--worktree",
        "/abs/tree",
        "--candidate",
        "cand_1",
        "--timeout-ms",
        "1000",
      ],
    ],
  ];
  for (const [command, flags] of accepted) {
    assert.doesNotThrow(
      () => assertKnownFlags(command, flags),
      `${command} ${flags.join(" ")}`,
    );
  }
  // 未知コマンドの診断は usage 側の仕事なので、フラグ検証は口を出さない。
  assert.doesNotThrow(() => assertKnownFlags("bogus", ["--whatever"]));
  // サブコマンドが解決できないときも同じ。コマンド側の名指しのエラーを先に出させる。
  assert.doesNotThrow(() => assertKnownFlags("review", ["bogus", "--task", "t"]));
});

test("a flag from a sibling subcommand is still refused", () => {
  assert.throws(() => assertKnownFlags("session", ["launch", "--resume-key", "x"]), /--resume-key/);
  assert.throws(() => assertKnownFlags("review", ["record", "--out", "/abs/x"]), /--out/);
  assert.throws(() => assertKnownFlags("candidate", ["list", "--candidate", "c"]), /--candidate/);
});

test("the registry is exported frozen so a caller cannot widen it at runtime", () => {
  assert.equal(Object.isFrozen(COMMAND_FLAGS), true);
  assert.equal(Object.isFrozen(COMMAND_FLAGS.clean), true);
});

// ---------------------------------------------------------------------------
// 3. route 履歴に上限とページングを設ける
// ---------------------------------------------------------------------------

function seedRoutes(statePath, count) {
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "route history" });
  const ids = [];
  for (let index = 0; index < count; index += 1) {
    ids.push(
      store.recordRoute(task.id, {
        kind: "escalation",
        capability: null,
        provider: null,
        reason: `route ${index}`,
      }).id,
    );
  }
  store.close();
  return ids;
}

test("fh status bounds the route history instead of printing every row", (context) => {
  const statePath = isolatedState(context);
  const total = DEFAULT_STATUS_LIMIT + 3;
  seedRoutes(statePath, total);

  const output = [];
  assert.equal(
    runCli(["status", "--json"], { config, statePath, write: (line) => output.push(line) }),
    0,
  );
  const first = emitted(output);
  assert.equal(first.routes.length, DEFAULT_STATUS_LIMIT);
  assert.deepEqual(first.page, {
    limit: DEFAULT_STATUS_LIMIT,
    offset: 0,
    total,
    returned: DEFAULT_STATUS_LIMIT,
    hasMore: true,
  });

  // ページを跨いでも重複せず、全件を覆う。
  assert.equal(
    runCli(["status", "--json", "--offset", String(DEFAULT_STATUS_LIMIT)], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  const second = emitted(output);
  assert.equal(second.page.hasMore, false);
  const seen = new Set([...first.routes, ...second.routes].map((route) => route.id));
  assert.equal(seen.size, total);
});

test("fh status --limit is honoured and capped", (context) => {
  const statePath = isolatedState(context);
  seedRoutes(statePath, 4);

  const output = [];
  runCli(["status", "--json", "--limit", "2"], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  assert.equal(emitted(output).routes.length, 2);

  runCli(["status", "--json", "--limit", String(MAX_STATUS_LIMIT + 1000)], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  assert.equal(emitted(output).page.limit, MAX_STATUS_LIMIT);

  assert.throws(
    () =>
      runCli(["status", "--json", "--limit", "0"], {
        config,
        statePath,
        write: () => {},
      }),
    /--limit/,
  );
  assert.throws(
    () =>
      runCli(["status", "--json", "--offset", "-1"], {
        config,
        statePath,
        write: () => {},
      }),
    /--offset/,
  );
});

test("fh status shows the newest routes first", async (context) => {
  const statePath = isolatedState(context);
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "route history" });
  const ordered = [];
  for (const label of ["oldest", "middle", "newest"]) {
    ordered.push(
      store.recordRoute(task.id, {
        kind: "escalation",
        capability: null,
        provider: null,
        reason: label,
      }).id,
    );
    // created_at は ISO のミリ秒なので、同一ミリ秒に潰れないよう間隔を空ける。
    await delay(2);
  }
  store.close();

  const output = [];
  runCli(["status", "--json", "--limit", "1"], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  assert.equal(emitted(output).routes[0].id, ordered[ordered.length - 1]);
});

// ---------------------------------------------------------------------------
// 3b. run の結末を後から引ける（`fh status` は route 決定しか持たない）
// ---------------------------------------------------------------------------

// createdAt を明示して並び順を決める。実時刻に頼ると同一ミリ秒へ潰れて、
// 「新しい順」の検証が偶然通ったり落ちたりする。
function seedAdapterRuns(statePath, count) {
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "adapter runs" });
  const route = store.recordRoute(task.id, {
    kind: "escalation",
    capability: null,
    provider: null,
    reason: "seed",
  });
  const ids = [];
  for (let index = 0; index < count; index += 1) {
    const at = new Date(Date.parse(NOW) + index * 1000).toISOString();
    const failed = index % 2 === 1;
    ids.push(
      store.recordAdapterRun({
        taskId: task.id,
        routeId: route.id,
        capability: "session.child",
        provider: "claude",
        model: "claude-opus-5",
        effort: "xhigh",
        status: failed ? "failed" : "succeeded",
        startedAt: at,
        finishedAt: at,
        exitCode: failed ? 1 : 0,
        failureReason: failed ? `run ${index} failed` : undefined,
        createdAt: at,
      }).id,
    );
  }
  store.close();
  return ids;
}

test("fh runs reports how each recorded run ended, newest first", (context) => {
  const statePath = isolatedState(context);
  const ids = seedAdapterRuns(statePath, 3);

  const output = [];
  assert.equal(
    runCli(["runs", "--json"], { config, statePath, write: (line) => output.push(line) }),
    0,
  );
  const listed = emitted(output);
  assert.deepEqual(
    listed.runs.map((run) => run.id),
    [...ids].reverse(),
  );
  // 「どう終わったか」がここで読めることが、このコマンドの存在理由そのもの。
  const newest = listed.runs[0];
  assert.equal(newest.status, "succeeded");
  assert.equal(newest.exitCode, 0);
  assert.equal(listed.runs[1].status, "failed");
  assert.equal(listed.runs[1].failureReason, "run 1 failed");
});

test("fh runs bounds the history the same way fh status does", (context) => {
  const statePath = isolatedState(context);
  const total = DEFAULT_STATUS_LIMIT + 2;
  seedAdapterRuns(statePath, total);

  const output = [];
  runCli(["runs", "--json"], { config, statePath, write: (line) => output.push(line) });
  const first = emitted(output);
  assert.deepEqual(first.page, {
    limit: DEFAULT_STATUS_LIMIT,
    offset: 0,
    total,
    returned: DEFAULT_STATUS_LIMIT,
    hasMore: true,
  });

  runCli(["runs", "--json", "--offset", String(DEFAULT_STATUS_LIMIT)], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  const second = emitted(output);
  assert.equal(second.page.hasMore, false);
  const seen = new Set([...first.runs, ...second.runs].map((run) => run.id));
  assert.equal(seen.size, total);

  runCli(["runs", "--json", "--limit", String(MAX_STATUS_LIMIT + 1000)], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  assert.equal(emitted(output).page.limit, MAX_STATUS_LIMIT);
});

test("fh runs --run looks up one record and refuses to invent one", (context) => {
  const statePath = isolatedState(context);
  const ids = seedAdapterRuns(statePath, 2);

  const output = [];
  assert.equal(
    runCli(["runs", "--json", "--run", ids[0]], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  assert.equal(emitted(output).run.id, ids[0]);

  // 未知の id を空の一覧として返すと「まだ何も走っていない」と区別が付かない。
  assert.throws(
    () =>
      runCli(["runs", "--json", "--run", "arun_missing"], {
        config,
        statePath,
        write: () => {},
      }),
    /arun_missing/,
  );
  // 単一照会にページングを重ねる呼び出しは、どちらかが黙って無視されることになる。
  assert.throws(
    () =>
      runCli(["runs", "--json", "--run", ids[0], "--limit", "1"], {
        config,
        statePath,
        write: () => {},
      }),
    /--limit/,
  );
});

// ---------------------------------------------------------------------------
// 4. cleanup の事前確認で削除対象の一覧を出す
// ---------------------------------------------------------------------------

test("fh clean --dry-run names what it would delete without deleting it", (context) => {
  const statePath = isolatedState(context);
  const store = createStateStore(statePath);
  const task = store.createTask({ goal: "retention" });
  const evidence = store.putEvidence({
    kind: "old_log",
    producer: "fake",
    createdAt: EXPIRED_AT,
    artifactPath: "old/log.txt",
  });
  const finding = store.recordReviewFinding({
    taskId: task.id,
    reviewerCapability: "semantic.judge",
    severity: "should",
    uncertainty: "medium",
    summary: "a reviewer sentence that must not reach the preview",
    createdAt: EXPIRED_AT,
  });
  const telemetry = store.recordTelemetryEvent({
    category: "implementation",
    provider: "codex",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  store.close();

  const output = [];
  assert.equal(
    runCli(["clean", "--dry-run", "--now", NOW, "--json"], {
      config,
      statePath,
      write: (line) => output.push(line),
    }),
    0,
  );
  const preview = emitted(output);
  assert.equal(preview.dryRun, true);
  assert.deepEqual(
    preview.targets.raw.evidence.map((row) => row.id),
    [evidence.id],
  );
  assert.equal(preview.targets.raw.evidence[0].artifactPath, "old/log.txt");
  assert.deepEqual(
    preview.targets.raw.reviewFindings.map((row) => row.id),
    [finding.id],
  );
  assert.deepEqual(
    preview.targets.telemetry.map((row) => row.id),
    [telemetry.id],
  );
  assert.equal(preview.targetsTruncated, false);

  // 一覧は「何が消えるか」を出すためのもので、会話内容の再掲ではない。
  assert.ok(!JSON.stringify(preview.targets).includes("must not reach the preview"));

  const survived = createStateStore(statePath);
  assert.equal(survived.listEvidence().length, 1);
  survived.close();
});

test("the dry-run preview is bounded and says so when it truncates", (context) => {
  const statePath = isolatedState(context);
  const store = createStateStore(statePath);
  for (let index = 0; index <= CLEAN_TARGET_PREVIEW_LIMIT; index += 1) {
    store.putEvidence({ kind: "old_log", producer: "fake", createdAt: EXPIRED_AT });
  }
  store.close();

  const output = [];
  runCli(["clean", "--dry-run", "--now", NOW, "--json"], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  const preview = emitted(output);
  assert.equal(preview.targets.raw.evidence.length, CLEAN_TARGET_PREVIEW_LIMIT);
  assert.equal(preview.targetsTruncated, true);
  assert.equal(preview.expiredEvidence, CLEAN_TARGET_PREVIEW_LIMIT + 1);
});

test("a real prune reports no preview, so a target list never implies a deletion happened", (context) => {
  const statePath = isolatedState(context);
  const store = createStateStore(statePath);
  store.putEvidence({ kind: "old_log", producer: "fake", createdAt: EXPIRED_AT });
  store.close();

  const output = [];
  runCli(["clean", "--now", NOW, "--json"], {
    config,
    statePath,
    write: (line) => output.push(line),
  });
  const pruned = emitted(output);
  assert.equal(pruned.dryRun, false);
  assert.equal(pruned.prunedEvidence, 1);
  assert.equal(pruned.targets, null);
});

// ---------------------------------------------------------------------------
// 5. 巻き戻しの失敗が元の例外を隠さない
// ---------------------------------------------------------------------------

test("a failed rollback does not hide the failure that caused it", () => {
  const store = createStateStore(":memory:");
  assert.throws(
    () =>
      store.withTransaction(() => {
        // ROLLBACK を確実に失敗させる。閉じた database への exec は必ず投げる。
        store.close();
        throw new TypeError("the original failure");
      }),
    (error) => {
      assert.match(error.message, /the original failure/);
      assert.match(error.message, /rollback/i);
      assert.equal(error.cause?.message, "the original failure");
      return true;
    },
  );
});

test("a successful rollback still rethrows the original error untouched", () => {
  const store = createStateStore(":memory:");
  const original = new TypeError("the original failure");
  assert.throws(
    () =>
      store.withTransaction(() => {
        throw original;
      }),
    (error) => error === original,
  );
  store.close();
});

// ---------------------------------------------------------------------------
// 6. 想定内の失敗を stack trace で見せない
// ---------------------------------------------------------------------------

test("expected failures describe themselves; unexpected ones keep their stack", () => {
  for (const error of [
    new TypeError("--now must be an ISO 8601 timestamp"),
    new HarnessError("state database must not be a symbolic link"),
    new SyntaxError("Unexpected token b in JSON at position 0"),
    Object.assign(new Error("ENOENT: no such file or directory, open '/x'"), {
      code: "ENOENT",
      syscall: "open",
    }),
  ]) {
    const described = describeCliFailure(error);
    assert.equal(described.expected, true);
    assert.equal(described.exitCode, USAGE);
    assert.equal(described.message, error.message);
    assert.ok(!described.message.includes("    at "));
  }

  // 内部の不整合は握り潰さない。stack ごと出して 70 で終わる。
  const unexpected = new RangeError("internal inconsistency");
  const described = describeCliFailure(unexpected);
  assert.equal(described.expected, false);
  assert.equal(described.exitCode, INTERNAL_ERROR);
  assert.equal(described.message, unexpected.stack);
});

test("the CLI entrypoint reports a usage error without a stack trace", () => {
  for (const [argumentsList, expected] of [
    [["status", "--bogus-flag"], /--bogus-flag/],
    [["approvals", "--approvals-dir", "relative/path"], /--approvals-dir/],
  ]) {
    let failure;
    try {
      execFileSync(process.execPath, [CLI_PATH, ...argumentsList], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
      assert.fail(`fh ${argumentsList.join(" ")} should not have succeeded`);
    } catch (error) {
      failure = error;
    }
    assert.equal(failure.status, USAGE);
    assert.match(failure.stderr, expected);
    // 原因が読めないエラーは、この issue が直そうとしている問題そのもの。
    assert.ok(!failure.stderr.includes("    at "), failure.stderr);
    assert.ok(!failure.stderr.includes("node:internal"), failure.stderr);
  }
});

test("a JSON file the user pointed at is named when it cannot be read", (context) => {
  const directory = temporaryDirectory(context);
  const taskPath = path.join(directory, "task.json");
  writeFileSync(taskPath, "{ not json");
  assert.throws(
    () =>
      runCli(["run", "--task", taskPath, "--json"], {
        config,
        statePath: path.join(directory, "state.db"),
        write: () => {},
      }),
    (error) => {
      // 「どのファイルが壊れていたか」が出ること。SyntaxError の素のメッセージには入らない。
      assert.equal(describeCliFailure(error).expected, true);
      assert.ok(error.message.includes(taskPath), error.message);
      return true;
    },
  );
});

// ---------------------------------------------------------------------------
// 7. サブコマンドの入出力契約が CLI から引ける（#594）
//
// 事故は「`fh approvals --json` の envelope がどこからも引けない」ことから始まった。
// 監視スクリプトが top-level を配列として舐めて型エラーで落ち、`2>/dev/null || true` と
// 組み合わさって「承認要求 0 件」と区別できない空文字列を返し続け、承認要求 2 件を最大
// 42 分放置した。ここのテストが守るのは 2 つ:
//
//   1. `--help` が全コマンドで引けること（`unknown flag --help` に戻らないこと）
//   2. **`--help` が嘘にならないこと** —— 宣言した出力契約が実装と drift しないこと
// ---------------------------------------------------------------------------

// このファイルが実際にコマンドを走らせて、宣言キーと実測キーの一致まで確かめる対象。
const OUTPUT_OBSERVED_HERE = [
  "approvals",
  "clean",
  "doctor",
  "gaps",
  "run",
  "runs",
  "status",
];
// state を持たない git worktree・子プロセス・承認ファイルを要する残り。実行時 assert
// （`createEmitter`）が全コマンド・全分岐で未宣言キーを止めるので、こちらは「宣言に
// 残っているが実装から消えた」向きだけが未観測で残る。名前を書き出しておくのは、
// 上の一覧が黙って縮んだときに気付けるようにするため。
const OUTPUT_NOT_OBSERVED_HERE = [
  "approve",
  "approve-server",
  "candidate",
  "onboard",
  "review",
  "session",
  "verify",
];

test("every command that takes flags also describes itself", () => {
  assert.deepEqual(helpCommandNames(), Object.keys(COMMAND_FLAGS).sort());
  // 分担の宣言が古びていないこと。片方に足して他方を忘れると、下の一致検証が黙って痩せる。
  assert.deepEqual(
    [...OUTPUT_OBSERVED_HERE, ...OUTPUT_NOT_OBSERVED_HERE].sort(),
    helpCommandNames(),
  );
});

test("fh <command> --help answers instead of refusing --help as unknown", () => {
  for (const command of helpCommandNames()) {
    const output = [];
    assert.equal(
      runCli([command, "--help"], { write: (line) => output.push(line) }),
      0,
      command,
    );
    const text = output.join("\n");
    // 受け付けるフラグは COMMAND_FLAGS から描画するので、表に足したフラグは必ず出る。
    for (const flag of [
      ...COMMAND_FLAGS[command].boolean,
      ...COMMAND_FLAGS[command].value,
      ...Object.values(COMMAND_FLAGS[command].actions ?? {}).flatMap((action) => [
        ...action.boolean,
        ...action.value,
      ]),
    ]) {
      assert.ok(text.includes(flag), `fh ${command} --help omitted ${flag}`);
    }
    // 出力形状が読めることがこの機能の存在理由そのもの。
    for (const key of Object.keys(COMMAND_HELP[command].output)) {
      assert.ok(text.includes(key), `fh ${command} --help omitted ${key}`);
    }
  }
});

test("fh approvals --help names the envelope the monitoring script guessed wrong", () => {
  const output = [];
  assert.equal(runCli(["approvals", "--help"], { write: (line) => output.push(line) }), 0);
  const text = output.join("\n");
  assert.match(text, /approvals/);
  assert.match(text, /skipped/);
  // 「top-level は配列ではない」が読めること。取り違えたのはまさにここだった。
  assert.match(text, /never a bare array/);
});

test("fh <command> --help --json hands the contract to a script instead of prose", () => {
  const output = [];
  assert.equal(
    runCli(["approvals", "--help", "--json"], { write: (line) => output.push(line) }),
    0,
  );
  const contract = emitted(output);
  assert.equal(contract.command, "approvals");
  assert.deepEqual(Object.keys(contract.output).sort(), [
    "approvals",
    "pending",
    "purged",
    "skipped",
  ]);
  assert.ok(contract.flags.boolean.includes("--all"));
  assert.ok(contract.flags.value.includes("--approvals-dir"));
  // 形状を推測せず表明できること。envelope が変われば、この照会がまず変わる。
  assert.equal(Object.hasOwn(contract.output, "approvals"), true);
});

test("fh --help lists the commands, and a misspelled command still exits 64", () => {
  const listed = [];
  assert.equal(runCli(["--help"], { write: (line) => listed.push(line) }), 0);
  for (const command of helpCommandNames()) {
    assert.ok(listed.join("\n").includes(command), command);
  }

  // 打ち間違えたコマンド名を「一覧が出たので成功」と読ませない。
  const mistyped = [];
  assert.equal(
    runCli(["aprovals", "--help"], { write: (line) => mistyped.push(line) }),
    USAGE,
  );
  assert.ok(mistyped.join("\n").includes("approvals"));

  // JSON でも同じ契約が引ける。
  const asJson = [];
  runCli(["--help", "--json"], { write: (line) => asJson.push(line) });
  assert.deepEqual(Object.keys(emitted(asJson).commands).sort(), helpCommandNames());
});

test("--help does not widen what assertKnownFlags accepts", () => {
  // `--help` は表に載ったから通るのであって、未知フラグの拒否を迂回するのではない。
  assert.throws(
    () => runCli(["approvals", "--bogus-flag", "--help"], { write: () => {} }),
    /--bogus-flag/,
  );
  assert.throws(
    () => runCli(["session", "launch", "--resume-key", "x", "--help"], { write: () => {} }),
    /--resume-key/,
  );
});

test("an undeclared output key is reported after the payload is written, not instead of it", () => {
  const output = [];
  const emit = createEmitter({ command: "status", asJson: true, write: (line) => output.push(line) });
  assert.throws(
    () => emit({ routes: [], page: {}, surprise: 1 }),
    (error) => {
      assert.match(error.message, /surprise/);
      // 内部の不整合であって利用者の誤りではないので、64 ではなく 70 で終わる。
      assert.equal(describeCliFailure(error).exitCode, INTERNAL_ERROR);
      return true;
    },
  );
  // **payload は失われない。** 子が既に走ったあとの emit もこの経路を通るため、
  // 契約違反を理由に監査証跡を落とすと、事故の再構成手段が丸ごと消える。
  assert.deepEqual(JSON.parse(output[0]), { routes: [], page: {}, surprise: 1 });

  // 契約どおりなら黙って通る。
  assert.doesNotThrow(() => emit({ routes: [], page: {} }));
  // envelope でないものを出すこと自体が契約違反（形状が引けない状態に戻る）。
  assert.deepEqual(undeclaredOutputKeys("status", []), ["<not a JSON object>"]);
  // 未知のコマンドはこの層の担当ではない。
  assert.deepEqual(undeclaredOutputKeys("bogus", { anything: 1 }), []);
});

// 宣言キーが実装から消えた向きの drift。実行時 assert は「増えた」側しか止められないので、
// 実際にコマンドを走らせて、宣言した集合が丸ごと実測されることを確かめる。
test("the declared output keys are exactly the keys these commands emit", (context) => {
  const directory = temporaryDirectory(context);
  const statePath = path.join(directory, "state.db");
  const approvalsDirectory = path.join(directory, "approvals");
  const observed = new Map(OUTPUT_OBSERVED_HERE.map((command) => [command, new Set()]));

  seedAdapterRuns(statePath, 1);
  const runIds = (() => {
    const store = createStateStore(statePath);
    const ids = store.listAdapterRunPage({ limit: 1, offset: 0 }).runs.map((run) => run.id);
    store.putEvidence({ kind: "old_log", producer: "fake", createdAt: EXPIRED_AT });
    store.close();
    return ids;
  })();

  const taskPath = path.join(directory, "task.json");
  writeFileSync(taskPath, JSON.stringify({ goal: "declare the output contract" }));

  const scenarios = [
    ["approvals", ["approvals", "--json", "--approvals-dir", approvalsDirectory]],
    ["approvals", ["approvals", "--purge", "--json", "--approvals-dir", approvalsDirectory]],
    ["clean", ["clean", "--dry-run", "--now", NOW, "--json"]],
    ["clean", ["clean", "--now", NOW, "--json"]],
    ["doctor", ["doctor", "--json"]],
    ["gaps", ["gaps", "--json"]],
    ["run", ["run", "--task", taskPath, "--json"]],
    ["runs", ["runs", "--json"]],
    ["runs", ["runs", "--json", "--run", runIds[0]]],
    ["status", ["status", "--json"]],
  ];
  for (const [command, argumentsList] of scenarios) {
    const output = [];
    runCli(argumentsList, {
      config,
      statePath,
      stateDirectory: directory,
      verifiedModels: {},
      write: (line) => output.push(line),
    });
    for (const key of Object.keys(emitted(output))) observed.get(command).add(key);
  }

  for (const [command, keys] of observed) {
    assert.deepEqual(
      [...keys].sort(),
      Object.keys(COMMAND_HELP[command].output).sort(),
      `fh ${command} --help does not match what fh ${command} emits`,
    );
  }
});

// 実際に走らせられないコマンドについても、消えた名前だけは捕まえる。実装のどこにも
// 現れないキーを `--help` が挙げていたら、それは既に嘘になっている。
test("no declared output key has vanished from the implementation", () => {
  const sources = readdirSync(
    new URL("../home/dot_local/lib/frontier-harness/", import.meta.url),
  )
    .filter((name) => name.endsWith(".mjs") && name !== "command-help.mjs")
    .map((name) =>
      readFileSync(
        new URL(`../home/dot_local/lib/frontier-harness/${name}`, import.meta.url),
        "utf8",
      ),
    )
    .join("\n");
  const orphaned = [];
  for (const command of helpCommandNames()) {
    for (const key of Object.keys(COMMAND_HELP[command].output)) {
      // オブジェクトリテラルの `key:` と短縮記法の `key,` / `key }` のどちらも拾う。
      if (!new RegExp(`\\b${key}\\s*[:,}\\n]`).test(sources)) {
        orphaned.push(`${command}: ${key}`);
      }
    }
  }
  assert.deepEqual(orphaned, []);
});

test("approve-server declares that it has no JSON envelope rather than staying blank", () => {
  // 空の `output` は宣言し忘れと区別が付かないので、その旨を積極的に書かせる。
  for (const command of helpCommandNames()) {
    const help = COMMAND_HELP[command];
    assert.ok(
      Object.keys(help.output).length > 0 || help.outputNote,
      `${command} declares neither output keys nor a reason for having none`,
    );
  }
  assert.deepEqual(COMMAND_HELP["approve-server"].output, {});
  assert.match(COMMAND_HELP["approve-server"].outputNote, /no JSON envelope/);
});

test("the numbers the help quotes are the numbers the code enforces", () => {
  const helpText = (command) => {
    const output = [];
    runCli([command, "--help"], { write: (line) => output.push(line) });
    return output.join("\n");
  };
  // 旧 usage は件数を定数から埋め込んでいた。help 側は文章の一部として書くので、
  // ここで定数と突き合わせておかないと、上限を変えた日に `--help` だけが嘘になる。
  for (const command of ["status", "runs"]) {
    assert.match(helpText(command), new RegExp(`defaults to ${DEFAULT_STATUS_LIMIT}\\b`), command);
    assert.match(helpText(command), new RegExp(`capped at ${MAX_STATUS_LIMIT}\\b`), command);
  }
  assert.match(
    helpText("clean"),
    new RegExp(`at most ${CLEAN_TARGET_PREVIEW_LIMIT} targets per class`),
  );
});
