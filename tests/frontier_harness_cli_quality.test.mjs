import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import { normalizeConfig } from "../home/dot_local/lib/frontier-harness/config.mjs";
import {
  CLEAN_TARGET_PREVIEW_LIMIT,
  DEFAULT_STATUS_LIMIT,
  MAX_STATUS_LIMIT,
  runCli,
} from "../home/dot_local/lib/frontier-harness/cli.mjs";
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
