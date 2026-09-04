import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { PassThrough } from "node:stream";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  resolveApprovalsDirectory,
  runApprovalsCommand,
  runApproveCommand,
  startApprovalServerCommand,
} from "../home/dot_local/lib/frontier-harness/approval-commands.mjs";
import {
  APPROVAL_ANSWER_VERSION,
  approvalsDirectory,
  createApprovalQueue,
} from "../home/dot_local/lib/frontier-harness/approval-queue.mjs";
import {
  APPROVAL_RISKS,
  APPROVAL_RULE_PATTERN_MAX_LENGTH,
  BASELINE_APPROVAL_RULES,
  classifyToolCall,
  compileApprovalRules,
  loadApprovalRules,
  normalizeApprovalRulesFile,
} from "../home/dot_local/lib/frontier-harness/approval-rules.mjs";
import {
  AMBIGUOUS_DYNAMIC,
  AMBIGUOUS_NESTED_SHELL,
  AMBIGUOUS_UNKNOWN_OPTION,
  analyzeShellCommand,
} from "../home/dot_local/lib/frontier-harness/approval-command.mjs";
import {
  CONFIG_RISK_VOCABULARY,
} from "../home/dot_local/lib/frontier-harness/approval-rules-baseline.mjs";
import {
  DEFAULT_ESCALATION_TIMEOUT_MS,
  DEFAULT_PROGRESS_INTERVAL_MS,
  LATEST_PROTOCOL_VERSION,
  MAX_ESCALATION_TIMEOUT_MS,
  MCP_STDIO_IDLE_TIMEOUT_MS,
  clampEscalationTimeout,
  createApprovalServer,
  runStdioApprovalServer,
} from "../home/dot_local/lib/frontier-harness/approval-server.mjs";
import { runCli } from "../home/dot_local/lib/frontier-harness/cli.mjs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const CLI_PATH = fileURLToPath(
  new URL("../home/dot_local/lib/frontier-harness/cli.mjs", import.meta.url),
);

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

function temporaryDirectory(context) {
  const directory = mkdtempSync(path.join(tmpdir(), "fh-approval-test-"));
  context.after(() => rmSync(directory, { force: true, recursive: true }));
  return directory;
}

const BASELINE_RULES = compileApprovalRules({
  defaultDecision: "allow",
  additionalRules: [],
});

function classifyBash(command, rules = BASELINE_RULES) {
  return classifyToolCall({ toolName: "Bash", input: { command } }, rules);
}

// 時計は注入する。実時間の sleep を使うと idle timeout を跨ぐテストが書けない。
function createTestClock({ onTick } = {}) {
  let current = Date.UTC(2026, 7, 29, 0, 0, 0);
  let ticks = 0;
  return {
    now: () => current,
    async wait(milliseconds) {
      current += milliseconds;
      ticks += 1;
      await onTick?.(ticks);
    },
    tickCount: () => ticks,
  };
}

function createServerFixture(context, overrides = {}) {
  const directory = path.join(temporaryDirectory(context), "approvals");
  const queue = createApprovalQueue({ directory });
  const notifications = [];
  const clock = overrides.clock ?? createTestClock();
  const server = createApprovalServer({
    queue,
    rules: overrides.rules ?? BASELINE_RULES,
    session: "sess-1",
    cwd: "/workspace",
    timeoutMs: overrides.timeoutMs ?? 5000,
    progressIntervalMs: overrides.progressIntervalMs ?? 1000,
    pollIntervalMs: overrides.pollIntervalMs ?? 1000,
    notify: (message) => notifications.push(message),
    now: clock.now,
    wait: clock.wait,
  });
  return { directory, queue, server, notifications, clock };
}

function approveMessage({
  id = 1,
  toolName,
  input = {},
  toolUseId = "toolu_01",
  progressToken,
}) {
  return {
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: {
      name: "approve",
      arguments: { tool_name: toolName, input, tool_use_id: toolUseId },
      ...(progressToken === undefined ? {} : { _meta: { progressToken } }),
    },
  };
}

function decisionOf(response) {
  assert.equal(response.result.content[0].type, "text");
  return JSON.parse(response.result.content[0].text);
}

function answerRecord(requestId, overrides = {}) {
  return {
    version: APPROVAL_ANSWER_VERSION,
    requestId,
    behavior: "allow",
    message: null,
    answers: null,
    answeredAt: "2026-08-29T00:00:00.000Z",
    ...overrides,
  };
}

const COLOUR_QUESTION = {
  question: "Which colour?",
  header: "Colour",
  multiSelect: false,
  options: [
    { label: "Red", description: "red" },
    { label: "Blue", description: "blue" },
  ],
};

// ---------------------------------------------------------------------------
// escalation ルール
// ---------------------------------------------------------------------------

// 代表コマンドの表。baseline に規則を足してテストを忘れると、
// 末尾の網羅チェックが落ちる（fail-open 側の穴をテスト側で検出する）。
const BASH_RULE_SAMPLES = [
  ["git merge origin/main", "git-merge"],
  ["gh pr merge 123 --squash", "gh-pr-merge"],
  ["git push --force origin main", "git-force-push"],
  ["git push origin --delete feat/x", "git-delete-remote-ref"],
  ["git rebase -i main", "git-history-rewrite"],
  ["git commit --amend --no-edit", "git-amend"],
  ["git reset --hard HEAD~1", "git-hard-reset"],
  ["git branch -D feat/x", "git-branch-delete"],
  ["git checkout -- .", "git-worktree-rollback"],
  ["gh release create v1.0.0", "gh-release"],
  ["npm publish --access public", "package-publish"],
  ["git push --follow-tags", "git-push-tags"],
  ["gh pr create --fill", "gh-external-write"],
  ["gh api /repos/o/r -X POST", "gh-api-write"],
  ["curl -X POST https://example.com", "http-write"],
  ["gh auth token", "credential-command"],
  ["cat ~/.ssh/id_ed25519", "credential-path-command"],
  ["terraform apply -auto-approve", "infrastructure-deploy"],
  ["chezmoi apply -v", "chezmoi-apply"],
  ["npx prisma migrate deploy", "database-migration"],
  ["fh approve --request appreq_x --allow", "approval-channel-command"],
];

const TOOL_INPUT_RULE_SAMPLES = [
  [
    { toolName: "Write", input: { file_path: "/Users/x/.ssh/authorized_keys" } },
    "credential-path-argument",
  ],
  [
    {
      toolName: "Write",
      input: {
        file_path:
          "/repo/.git/frontier-harness/approvals/appreq_0.answer.json",
      },
    },
    "approval-channel-argument",
  ],
];

test("baseline rules escalate every category they cover", () => {
  const covered = new Set();
  for (const [command, ruleId] of BASH_RULE_SAMPLES) {
    const verdict = classifyBash(command);
    assert.equal(verdict.decision, "escalate", command);
    assert.equal(verdict.rule.id, ruleId, command);
    covered.add(ruleId);
  }
  for (const [call, ruleId] of TOOL_INPUT_RULE_SAMPLES) {
    const verdict = classifyToolCall(call, BASELINE_RULES);
    assert.equal(verdict.decision, "escalate", ruleId);
    assert.equal(verdict.rule.id, ruleId);
    covered.add(ruleId);
  }
  const uncovered = BASELINE_APPROVAL_RULES.map((rule) => rule.id).filter(
    (id) => !covered.has(id),
  );
  assert.deepEqual(
    uncovered,
    [],
    `baseline rules without a sample: ${uncovered.join(", ")}`,
  );
});

test("ordinary development commands stay allowed", () => {
  for (const command of [
    "npm test",
    "ls -la",
    "git status",
    'git commit -m "feat: add"',
    "git log --oneline",
    "git merge-base main HEAD",
    "git mergetool --help",
    "mygit merge",
    "gh pr view 123",
    "gh api /repos/o/r",
    "curl https://example.com",
    "cat README.md",
    "git push origin main",
    "make test",
  ]) {
    assert.equal(classifyBash(command).decision, "allow", command);
  }
});

// レビュー指摘（fail-open）の回帰。global option を挟んだ形はすべて escalate へ倒す。
test("escalation survives global options, short clusters, and force refspecs", () => {
  for (const [command, ruleId] of [
    ["git -C /repo merge main", "git-merge"],
    ["git --no-pager merge main", "git-merge"],
    ["git -c user.name=x push --force", "git-force-push"],
    ["git push -uf origin main", "git-force-push"],
    ["git push origin +main", "git-force-push"],
    ["gh --repo o/r pr merge 1", "gh-pr-merge"],
    ["gh -R o/r release create v1", "gh-release"],
    ["npm --prefix pkg publish", "package-publish"],
    ["yarn --cwd p publish", "package-publish"],
    ["docker --context c push img", "package-publish"],
  ]) {
    const verdict = classifyBash(command);
    assert.equal(verdict.decision, "escalate", command);
    assert.equal(verdict.rule.id, ruleId, command);
  }
});

// 正規表現を「option を読み飛ばす」形へ広げるだけでは、この 2 例を両立できない
// （adversarial verify の反例）。option arity を見て初めて両方正しくなる。
test("option arity decides the subcommand, in both directions", () => {
  // `merge` は -C の値であり、実際の subcommand は良性の status。
  assert.equal(classifyBash("git -C merge status").decision, "allow");
  // -p は値を取らないので、次の merge が本当の subcommand。
  assert.equal(classifyBash("git -p merge").rule.id, "git-merge");
});

test("shell obfuscation is normalized away or escalated as opaque", () => {
  // バックスラッシュ分断と IFS 置換は正規化して本来のルールに当てる。
  assert.equal(classifyBash("g\\it merge origin/main").rule.id, "git-merge");
  assert.equal(
    classifyBash("git${IFS}push${IFS}--force origin main").rule.id,
    "git-force-push",
  );
  // 動的構築・入れ子シェルは解釈できないので opaque として escalate する。
  for (const command of [
    "git $(printf x) origin/main",
    "$(echo git) merge main",
    "eval \"$(echo abc)\"",
    "bash -c 'ls'",
    "sudo apt-get install x",
  ]) {
    assert.equal(classifyBash(command).rule.id, "opaque-command", command);
  }
  // 引数位置の置換までは咎めない（無人 wave が成立しなくなる）。
  for (const command of [
    'echo "$(date)" >> log.txt',
    'git commit -m "$(cat msg.txt)"',
  ]) {
    assert.equal(classifyBash(command).decision, "allow", command);
  }
});

test("an unrecognized global option makes the command ambiguous", () => {
  const analysis = analyzeShellCommand("git --not-a-real-global-option merge x");
  assert.equal(analysis.ambiguous, AMBIGUOUS_UNKNOWN_OPTION);
  assert.equal(analyzeShellCommand("sudo ls").ambiguous, AMBIGUOUS_NESTED_SHELL);
  assert.equal(analyzeShellCommand("$(echo ls)").ambiguous, AMBIGUOUS_DYNAMIC);
  assert.equal(analyzeShellCommand("git status").ambiguous, null);
});

// ---------------------------------------------------------------------------
// #624: テーブル外 binary の動的構築引数
// ---------------------------------------------------------------------------

test("動的構築の報告は binary のテーブルに依存しない", () => {
  // `make` / `go` / `pytest` / `echo` はいずれも GLOBAL_OPTIONS にも
  // SUBCOMMAND_DISPATCHED_BINARIES にも無い。それでも「静的に解釈できない」ことだけは
  // 呼び出し側へ届ける（どう扱うかは呼び出し側が方向ごとに決める）。
  for (const command of [
    "make $(cat /tmp/injected)",
    "make $TARGET",
    "make ${TARGET}",
    "make `cat /tmp/injected`",
    'make -C "$DIR" lint',
    "go $CMD",
    'pytest "$TMPDIR/t"',
    'echo "$(date)" >> log.txt',
  ]) {
    assert.equal(analyzeShellCommand(command).dynamic, true, command);
  }
  // 静的に読み切れるものは dynamic にしない。
  for (const command of [
    "make lint",
    "go test ./...",
    "npm run test",
    "sudo ls",
    "git status",
  ]) {
    assert.equal(analyzeShellCommand(command).dynamic, false, command);
  }
  // `${IFS}` は単語区切りとして展開するので動的構築ではない。ここを dynamic に倒すと
  // 難読化の正規化（`git${IFS}push${IFS}--force` → git-force-push）が効かなくなる。
  assert.equal(
    analyzeShellCommand("git${IFS}push${IFS}--force origin main").dynamic,
    false,
  );
  // 解析対象にならない入力でも戻り値の形は揃える。
  assert.equal(analyzeShellCommand("").dynamic, false);
  assert.equal(analyzeShellCommand(null).dynamic, false);
});

test("dynamic は ambiguous と独立で、escalation 側の判定を変えない", () => {
  // テーブル外 binary の動的構築は dynamic だけが立ち、ambiguous は立たない。
  const analysis = analyzeShellCommand("make $(cat /tmp/injected)");
  assert.equal(analysis.dynamic, true);
  assert.equal(analysis.ambiguous, null);
  // 逆に、ネストシェルは ambiguous だが動的構築ではない。2 つは包含関係にない。
  const nested = analyzeShellCommand("sudo ls");
  assert.equal(nested.ambiguous, AMBIGUOUS_NESTED_SHELL);
  assert.equal(nested.dynamic, false);
  // テーブルに載る binary の dispatch 位置は従来どおり ambiguous でもある。
  const tabled = analyzeShellCommand("git $(printf x) origin/main");
  assert.equal(tabled.ambiguous, AMBIGUOUS_DYNAMIC);
  assert.equal(tabled.dynamic, true);

  // escalation（deny リスト）側は ambiguous だけを見る。dynamic を足したことで同期
  // 問い合わせが 1 件も増えていないことを固定する —— 増やせば無人 wave が止まる。
  for (const command of [
    "make $TARGET",
    "make $(cat /tmp/injected)",
    'make -C "$DIR" lint',
    "go $CMD",
    'pytest "$TMPDIR/t"',
    'echo "$(date)" >> log.txt',
    'git commit -m "$(cat msg.txt)"',
    'cat "$TMPDIR/x"',
    'node "$TMPDIR/p.mjs"',
  ]) {
    assert.equal(classifyBash(command).decision, "allow", command);
  }
});

test("the risk vocabulary contains every value the shipped config escalates on", () => {
  const config = JSON.parse(
    readFileSync("home/dot_config/frontier-harness/config.json", "utf8"),
  );
  for (const risk of config.risk.alwaysEscalate) {
    assert.ok(
      CONFIG_RISK_VOCABULARY.has(risk),
      `config risk ${risk} is missing from the approval vocabulary`,
    );
    assert.ok(APPROVAL_RISKS.has(risk), risk);
  }
});

test("AskUserQuestion escalates regardless of the rules", () => {
  const verdict = classifyToolCall(
    { toolName: "AskUserQuestion", input: { questions: [COLOUR_QUESTION] } },
    BASELINE_RULES,
  );
  assert.equal(verdict.decision, "escalate");
  assert.equal(verdict.rule.id, "ask-user-question");
  assert.equal(verdict.rule.risk, "user-question");
});

test("a missing rules file leaves the baseline fully in force", (context) => {
  const home = temporaryDirectory(context);
  const rules = loadApprovalRules({}, { HOME: home });
  assert.equal(rules.defaultDecision, "allow");
  assert.equal(rules.rules.length, BASELINE_APPROVAL_RULES.length);
  assert.equal(classifyBash("git merge origin/main", rules).decision, "escalate");
});

test("a rules file can add rules but cannot remove or weaken the baseline", (context) => {
  const home = temporaryDirectory(context);
  const rulesPath = path.join(home, "approval-rules.json");
  writeFileSync(
    rulesPath,
    JSON.stringify({
      version: 1,
      additionalRules: [
        {
          id: "house-deploy-script",
          risk: "deploy",
          tool: "Bash",
          field: "command",
          pattern: "scripts/deploy\\.sh",
          reason: "house deploy script",
        },
      ],
    }),
  );
  const rules = loadApprovalRules({ rulesPath }, {});
  // 追加ルールは効く。
  assert.equal(classifyBash("./scripts/deploy.sh", rules).rule.id, "house-deploy-script");
  // baseline は 1 件も減っていない。
  assert.equal(rules.rules.length, BASELINE_APPROVAL_RULES.length + 1);
  assert.equal(classifyBash("git merge origin/main", rules).rule.id, "git-merge");
  // baseline を外そうとするキーはスキーマ上存在しない。
  for (const key of ["rules", "baseline", "disable", "removeRules"]) {
    assert.throws(
      () => normalizeApprovalRulesFile({ version: 1, [key]: [] }),
      /unsupported key/,
    );
  }
});

test("rules file entries are validated at the boundary", () => {
  const rule = {
    id: "extra",
    risk: "deploy",
    tool: "Bash",
    field: "command",
    pattern: "deploy",
    reason: "extra",
  };
  assert.throws(
    () =>
      normalizeApprovalRulesFile({
        version: 1,
        additionalRules: [{ ...rule, id: "git-merge" }],
      }),
    /collides with a baseline rule/,
  );
  assert.throws(
    () =>
      normalizeApprovalRulesFile({
        version: 1,
        additionalRules: [rule, { ...rule }],
      }),
    /duplicated/,
  );
  assert.throws(
    () =>
      normalizeApprovalRulesFile({
        version: 1,
        additionalRules: [{ ...rule, risk: "not-a-risk" }],
      }),
    /risk is not a known category/,
  );
  assert.throws(
    () =>
      normalizeApprovalRulesFile({
        version: 1,
        additionalRules: [{ ...rule, pattern: "(" }],
      }),
    /not a valid regular expression/,
  );
  assert.throws(
    () =>
      normalizeApprovalRulesFile({
        version: 1,
        additionalRules: [
          { ...rule, pattern: "a".repeat(APPROVAL_RULE_PATTERN_MAX_LENGTH + 1) },
        ],
      }),
    /exceeds/,
  );
  assert.throws(() => normalizeApprovalRulesFile({ version: 2 }), /version must be 1/);
});

test("defaultDecision can only tighten the unmatched default", () => {
  const strict = compileApprovalRules(
    normalizeApprovalRulesFile({ version: 1, defaultDecision: "escalate" }),
  );
  assert.equal(classifyBash("npm test", strict).decision, "escalate");
  assert.equal(classifyBash("npm test", strict).rule.id, "unmatched-default-escalate");
  assert.throws(
    () => normalizeApprovalRulesFile({ version: 1, defaultDecision: "skip" }),
    /must be allow or escalate/,
  );
});

test("the rules file is never resolved from the working directory", (context) => {
  assert.throws(
    () => loadApprovalRules({}, { FH_APPROVAL_RULES_PATH: "relative.json" }),
    /must be an absolute path/,
  );
  assert.throws(() => loadApprovalRules({}, {}), /HOME must be an absolute path/);
  const rulesPath = path.join(temporaryDirectory(context), "broken.json");
  writeFileSync(rulesPath, "{ not json");
  assert.throws(() => loadApprovalRules({ rulesPath }, {}), /not valid JSON/);
});

// ---------------------------------------------------------------------------
// 承認 queue
// ---------------------------------------------------------------------------

function createQueueFixture(context) {
  const directory = path.join(temporaryDirectory(context), "approvals");
  return { directory, queue: createApprovalQueue({ directory }) };
}

function createPendingRequest(queue, overrides = {}) {
  return queue.createRequest({
    sessionId: "sess-1",
    cwd: "/workspace",
    toolName: "Bash",
    toolUseId: "toolu_01",
    input: { command: "git merge origin/main" },
    escalation: { ruleId: "git-merge", risk: "merge", reason: "マージ" },
    timeoutAt: "2026-08-29T08:00:00.000Z",
    ...overrides,
  });
}

test("the queue records a request, its answer, and its outcome", (context) => {
  const { queue } = createQueueFixture(context);
  const request = createPendingRequest(queue);
  assert.match(request.id, /^appreq_[0-9a-f]{32}$/);
  assert.equal(request.status, "pending");

  assert.equal(queue.listRequests({ status: "pending" }).requests.length, 1);
  assert.equal(queue.readAnswer(request.id, request), null);

  queue.writeAnswer(request.id, answerRecord(request.id));
  assert.equal(queue.readAnswer(request.id, request).behavior, "allow");

  const stored = queue.recordOutcome(request.id, {
    status: "allowed",
    behavior: "allow",
    decidedBy: "user",
  });
  assert.equal(stored.status, "allowed");
  assert.equal(stored.decision.decidedBy, "user");
  assert.equal(queue.listRequests({ status: "pending" }).requests.length, 0);
});

test("request identifiers are validated before they become paths", (context) => {
  const { queue } = createQueueFixture(context);
  for (const id of ["../../etc/passwd", "appreq_zz", "", "appreq_0"]) {
    assert.throws(() => queue.readRequest(id), /must match appreq_/);
  }
});

test("an approval request is answered exactly once", (context) => {
  const { queue } = createQueueFixture(context);
  const request = createPendingRequest(queue);
  queue.writeAnswer(request.id, answerRecord(request.id));
  assert.throws(
    () => queue.writeAnswer(request.id, answerRecord(request.id, { behavior: "deny" })),
    /answered once/,
  );
  assert.equal(queue.readAnswer(request.id, request).behavior, "allow");
});

test("a symbolic link cannot stand in for the approvals directory", (context) => {
  const root = temporaryDirectory(context);
  const elsewhere = path.join(root, "elsewhere");
  mkdirSync(elsewhere);
  const directory = path.join(root, "approvals");
  symlinkSync(elsewhere, directory);
  assert.throws(
    () => createApprovalQueue({ directory }),
    /must not be a symbolic link/,
  );
});

test("one corrupt request file does not hide the rest of the queue", (context) => {
  const { directory, queue } = createQueueFixture(context);
  const request = createPendingRequest(queue);
  writeFileSync(
    path.join(directory, `appreq_${"0".repeat(32)}.request.json`),
    "{ not json",
  );
  const listed = queue.listRequests({ status: "pending" });
  assert.deepEqual(
    listed.requests.map((entry) => entry.id),
    [request.id],
  );
  assert.equal(listed.skipped.length, 1);
  assert.match(listed.skipped[0].reason, /not valid JSON/);
});

// ---------------------------------------------------------------------------
// MCP protocol
// ---------------------------------------------------------------------------

test("initialize answers with a supported protocol version", async (context) => {
  const { server } = createServerFixture(context);
  for (const requested of ["2025-06-18", "2025-03-26", "2024-11-05"]) {
    const response = await server.handleMessage({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: requested },
    });
    assert.equal(response.result.protocolVersion, requested);
  }
  // 未知の版はエラーにせず、server の最新版を返す（MCP spec の version negotiation）。
  const fallback = await server.handleMessage({
    jsonrpc: "2.0",
    id: 2,
    method: "initialize",
    params: { protocolVersion: "1999-01-01" },
  });
  assert.equal(fallback.result.protocolVersion, LATEST_PROTOCOL_VERSION);
  assert.deepEqual(fallback.result.capabilities, { tools: {} });
});

test("the server exposes only the approve tool and answers the core methods", async (context) => {
  const { server } = createServerFixture(context);
  const tools = await server.handleMessage({
    jsonrpc: "2.0",
    id: 1,
    method: "tools/list",
  });
  assert.deepEqual(
    tools.result.tools.map((tool) => tool.name),
    ["approve"],
  );
  assert.deepEqual(
    (await server.handleMessage({ jsonrpc: "2.0", id: 2, method: "ping" })).result,
    {},
  );
  assert.equal(
    await server.handleMessage({ jsonrpc: "2.0", method: "notifications/initialized" }),
    null,
  );
  const unknown = await server.handleMessage({
    jsonrpc: "2.0",
    id: 3,
    method: "resources/list",
  });
  assert.equal(unknown.error.code, -32601);
});

test("malformed approval arguments are rejected instead of approved", async (context) => {
  const { server, queue } = createServerFixture(context);
  for (const args of [undefined, {}, { tool_name: 7 }, { tool_name: "Bash", input: 3 }]) {
    const response = await server.handleMessage({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "approve", arguments: args },
    });
    assert.equal(response.error.code, -32602);
  }
  const wrongTool = await server.handleMessage({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "something-else", arguments: {} },
  });
  assert.equal(wrongTool.error.code, -32602);
  assert.equal(queue.listRequests({}).requests.length, 0);
});

// ---------------------------------------------------------------------------
// 承認の決定
// ---------------------------------------------------------------------------

test("an unmatched tool call is allowed without touching the queue", async (context) => {
  const { server, queue } = createServerFixture(context);
  const response = await server.handleMessage(
    approveMessage({ toolName: "Bash", input: { command: "npm test" } }),
  );
  assert.deepEqual(decisionOf(response), {
    behavior: "allow",
    updatedInput: { command: "npm test" },
  });
  assert.equal(queue.listRequests({}).requests.length, 0);
});

test("a command that matches an escalation rule is never allowed without a user answer", async (context) => {
  const { server, queue } = createServerFixture(context, {
    timeoutMs: 5000,
    pollIntervalMs: 1000,
    progressIntervalMs: 1000,
  });
  const response = await server.handleMessage(
    approveMessage({
      toolName: "Bash",
      input: { command: "git merge origin/main" },
      progressToken: 7,
    }),
  );
  const decision = decisionOf(response);
  // 回答が無いまま上限に達したら deny。allow へ倒れる経路はない。
  assert.equal(decision.behavior, "deny");
  assert.equal(Object.hasOwn(decision, "updatedInput"), false);

  const [stored] = queue.listRequests({}).requests;
  assert.equal(stored.status, "timed_out");
  assert.equal(stored.decision.decidedBy, "timeout");
  assert.equal(stored.escalation.ruleId, "git-merge");
  assert.equal(stored.input.command, "git merge origin/main");
  assert.equal(stored.toolUseId, "toolu_01");
  assert.equal(stored.sessionId, "sess-1");
  // 「allow として記録された要求」は 1 件も存在しない。
  assert.equal(queue.listRequests({ status: "allowed" }).requests.length, 0);
});

test("a user allow answer is applied and recorded", async (context) => {
  let pendingId = null;
  const clock = createTestClock({
    onTick: (ticks) => {
      if (ticks !== 2 || !pendingId) return;
      fixture.queue.writeAnswer(pendingId, answerRecord(pendingId));
    },
  });
  const fixture = createServerFixture(context, { clock, timeoutMs: 60000 });
  const call = fixture.server.handleMessage(
    approveMessage({ toolName: "Bash", input: { command: "git merge main" } }),
  );
  await Promise.resolve();
  pendingId = fixture.queue.listRequests({ status: "pending" }).requests[0].id;
  const decision = decisionOf(await call);
  assert.deepEqual(decision, {
    behavior: "allow",
    updatedInput: { command: "git merge main" },
  });
  const [stored] = fixture.queue.listRequests({}).requests;
  assert.equal(stored.status, "allowed");
  assert.equal(stored.decision.decidedBy, "user");
});

test("a user deny answer carries its message back to the model", async (context) => {
  let pendingId = null;
  const clock = createTestClock({
    onTick: (ticks) => {
      if (ticks !== 2 || !pendingId) return;
      fixture.queue.writeAnswer(
        pendingId,
        answerRecord(pendingId, {
          behavior: "deny",
          message: "orchestrator policy: merge is never proxied",
        }),
      );
    },
  });
  const fixture = createServerFixture(context, { clock, timeoutMs: 60000 });
  const call = fixture.server.handleMessage(
    approveMessage({ toolName: "Bash", input: { command: "git merge main" } }),
  );
  await Promise.resolve();
  pendingId = fixture.queue.listRequests({ status: "pending" }).requests[0].id;
  assert.deepEqual(decisionOf(await call), {
    behavior: "deny",
    message: "orchestrator policy: merge is never proxied",
  });
  assert.equal(fixture.queue.listRequests({}).requests[0].status, "denied");
});

test("AskUserQuestion answers are merged into updatedInput", async (context) => {
  let pendingId = null;
  const clock = createTestClock({
    onTick: (ticks) => {
      if (ticks !== 2 || !pendingId) return;
      fixture.queue.writeAnswer(
        pendingId,
        answerRecord(pendingId, { answers: { "Which colour?": "Red" } }),
      );
    },
  });
  const fixture = createServerFixture(context, { clock, timeoutMs: 60000 });
  const input = { questions: [COLOUR_QUESTION] };
  const call = fixture.server.handleMessage(
    approveMessage({ toolName: "AskUserQuestion", input }),
  );
  await Promise.resolve();
  pendingId = fixture.queue.listRequests({ status: "pending" }).requests[0].id;
  assert.deepEqual(decisionOf(await call), {
    behavior: "allow",
    updatedInput: { questions: [COLOUR_QUESTION], answers: { "Which colour?": "Red" } },
  });
});

test("an answer that was not offered is denied rather than approved", async (context) => {
  let pendingId = null;
  const clock = createTestClock({
    onTick: (ticks) => {
      if (ticks !== 2 || !pendingId) return;
      // CLI を迂回して不正な回答を置く。読み出し側の検証がここで効く。
      fixture.queue.writeAnswer(
        pendingId,
        answerRecord(pendingId, { answers: { "Which colour?": "Green" } }),
      );
    },
  });
  const fixture = createServerFixture(context, { clock, timeoutMs: 60000 });
  const call = fixture.server.handleMessage(
    approveMessage({ toolName: "AskUserQuestion", input: { questions: [COLOUR_QUESTION] } }),
  );
  await Promise.resolve();
  pendingId = fixture.queue.listRequests({ status: "pending" }).requests[0].id;
  const decision = decisionOf(await call);
  assert.equal(decision.behavior, "deny");
  assert.match(decision.message, /label that was not offered/);
  const [stored] = fixture.queue.listRequests({}).requests;
  assert.equal(stored.status, "denied");
  assert.equal(stored.decision.decidedBy, "validation");
});

test("progress notifications keep the call alive past the stdio idle timeout", async (context) => {
  const timeoutMs = 3600000;
  const { server, notifications, queue } = createServerFixture(context, {
    timeoutMs,
    progressIntervalMs: DEFAULT_PROGRESS_INTERVAL_MS,
    pollIntervalMs: DEFAULT_PROGRESS_INTERVAL_MS,
  });
  const decision = decisionOf(
    await server.handleMessage(
      approveMessage({
        toolName: "Bash",
        input: { command: "gh pr merge 1" },
        progressToken: "tok-1",
      }),
    ),
  );

  // 待った時間は stdio の idle timeout（30 分）を大きく超える。
  assert.ok(timeoutMs > MCP_STDIO_IDLE_TIMEOUT_MS);
  const elapsedBeforeIdleTimeout = Math.floor(
    MCP_STDIO_IDLE_TIMEOUT_MS / DEFAULT_PROGRESS_INTERVAL_MS,
  );
  assert.ok(
    notifications.length >= elapsedBeforeIdleTimeout,
    `expected at least ${elapsedBeforeIdleTimeout} progress notifications, got ${notifications.length}`,
  );
  for (const [index, message] of notifications.entries()) {
    assert.equal(message.method, "notifications/progress");
    assert.equal(message.params.progressToken, "tok-1");
    // progress は単調増加でなければならない（MCP spec）。
    assert.equal(message.params.progress, index + 1);
    assert.match(message.params.message, /waiting for a user decision/);
  }
  // 子は異常終了せず、自動 deny と状態保存で終わる。
  assert.equal(decision.behavior, "deny");
  const [stored] = queue.listRequests({}).requests;
  assert.equal(stored.status, "timed_out");
  assert.equal(stored.timeoutAt, "2026-08-29T01:00:00.000Z");
});

test("no progress token means no progress notifications", async (context) => {
  const { server, notifications } = createServerFixture(context, {
    timeoutMs: 5000,
    pollIntervalMs: 1000,
    progressIntervalMs: 1000,
  });
  await server.handleMessage(
    approveMessage({ toolName: "Bash", input: { command: "git merge main" } }),
  );
  assert.deepEqual(notifications, []);
});

test("concurrent escalations resolve independently and in any order", async (context) => {
  const MERGE = "git merge main";
  const PUBLISH = "npm publish";
  let sawBothWaiting = false;
  const fixture = createServerFixture(context, {
    clock: createTestClock({
      onTick: () => {
        // 要求の同一性はコマンドで引く。listRequests の順序は createdAt が同着だと
        // id（UUID）順になるため、到着順を仮定したテストは非決定になる。
        const byCommand = new Map(
          fixture.queue
            .listRequests({})
            .requests.map((entry) => [entry.input.command, entry]),
        );
        const merge = byCommand.get(MERGE);
        const publish = byCommand.get(PUBLISH);
        if (!merge || !publish) return;
        if (merge.status === "pending" && publish.status === "pending") {
          sawBothWaiting = true;
        }
        // 到着順の逆から解決しても、それぞれの呼び出しが自分の回答を受け取る。
        if (!fixture.queue.hasAnswer(publish.id)) {
          fixture.queue.writeAnswer(
            publish.id,
            answerRecord(publish.id, { behavior: "deny", message: "no release today" }),
          );
          return;
        }
        if (!fixture.queue.hasAnswer(merge.id)) {
          fixture.queue.writeAnswer(merge.id, answerRecord(merge.id));
        }
      },
    }),
    timeoutMs: 60000,
  });
  const [firstDecision, secondDecision] = (
    await Promise.all([
      fixture.server.handleMessage(
        approveMessage({ id: 1, toolName: "Bash", input: { command: MERGE } }),
      ),
      fixture.server.handleMessage(
        approveMessage({ id: 2, toolName: "Bash", input: { command: PUBLISH } }),
      ),
    ])
  ).map(decisionOf);

  assert.ok(sawBothWaiting, "both children must be able to wait at the same time");
  assert.equal(firstDecision.behavior, "allow");
  assert.deepEqual(firstDecision.updatedInput, { command: MERGE });
  assert.equal(secondDecision.behavior, "deny");
  assert.equal(secondDecision.message, "no release today");

  const stored = new Map(
    fixture.queue.listRequests({}).requests.map((entry) => [entry.input.command, entry]),
  );
  assert.equal(stored.size, 2);
  assert.equal(stored.get(MERGE).status, "allowed");
  assert.equal(stored.get(PUBLISH).status, "denied");
});

test("an answer that lands with the shutdown is honoured, not discarded", async (context) => {
  let pendingId = null;
  const clock = createTestClock({
    onTick: (ticks) => {
      if (ticks !== 2 || !pendingId) return;
      // user の回答と shutdown が入れ違いに起きる状況。記録済みの判断が優先され、
      // 監査記録も「user が答えた」と正しく残らなければならない。
      fixture.queue.writeAnswer(pendingId, answerRecord(pendingId));
      fixture.server.abort("the client closed its side of the connection");
    },
  });
  const fixture = createServerFixture(context, { clock, timeoutMs: 60000 });
  const call = fixture.server.handleMessage(
    approveMessage({ toolName: "Bash", input: { command: "git merge main" } }),
  );
  await Promise.resolve();
  pendingId = fixture.queue.listRequests({ status: "pending" }).requests[0].id;
  assert.equal(decisionOf(await call).behavior, "allow");
  const [stored] = fixture.queue.listRequests({}).requests;
  assert.equal(stored.status, "allowed");
  assert.equal(stored.decision.decidedBy, "user");
});

test("closing stdin aborts pending requests instead of leaving them hanging", async (context) => {
  const directory = path.join(temporaryDirectory(context), "approvals");
  const queue = createApprovalQueue({ directory });
  const input = new PassThrough();
  const output = new PassThrough();
  const lines = [];
  output.setEncoding("utf8");
  output.on("data", (chunk) => lines.push(chunk));

  const transport = runStdioApprovalServer({
    input,
    output,
    createServer: (send) =>
      createApprovalServer({
        queue,
        rules: BASELINE_RULES,
        cwd: "/workspace",
        timeoutMs: 60000,
        // 実時計だが、abort は次のポーリングで拾われるので数 ms で終わる。
        pollIntervalMs: 5,
        progressIntervalMs: 5000,
        notify: send,
      }),
  });
  input.write(
    `${JSON.stringify(approveMessage({ toolName: "Bash", input: { command: "git merge main" } }))}\n`,
  );
  input.end();
  assert.equal(await transport.finished, 0);

  const decision = JSON.parse(
    JSON.parse(lines.join("")).result.content[0].text,
  );
  assert.equal(decision.behavior, "deny");
  const [stored] = queue.listRequests({}).requests;
  assert.equal(stored.status, "aborted");
  assert.equal(stored.decision.decidedBy, "shutdown");
});

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function runApprovalCli(argumentsList, stateDirectory) {
  const lines = [];
  const code = runCli(argumentsList, {
    config: {},
    cwd: "/workspace",
    stateDirectory,
    environment: { PATH: "" },
    write: (line) => lines.push(line),
  });
  return { code, output: lines.length > 0 ? JSON.parse(lines.join("\n")) : null };
}

test("fh approvals lists pending requests and fh approve answers one", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const queue = createApprovalQueue({
    directory: approvalsDirectory(stateDirectory),
  });
  const request = createPendingRequest(queue);

  const listed = runApprovalCli(["approvals", "--json"], stateDirectory);
  assert.equal(listed.code, 0);
  assert.equal(listed.output.approvals.length, 1);
  assert.equal(listed.output.approvals[0].id, request.id);
  assert.equal(listed.output.approvals[0].risk, "merge");
  assert.equal(listed.output.approvals[0].input.command, "git merge origin/main");

  const answered = runApprovalCli(
    ["approve", "--request", request.id, "--allow", "--json"],
    stateDirectory,
  );
  assert.equal(answered.code, 0);
  assert.equal(answered.output.behavior, "allow");
  assert.equal(queue.readAnswer(request.id, request).behavior, "allow");
});

test("an approval request cannot be answered twice", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const queue = createApprovalQueue({
    directory: approvalsDirectory(stateDirectory),
  });
  const request = createPendingRequest(queue);
  runApprovalCli(["approve", "--request", request.id, "--deny", "--json"], stateDirectory);
  assert.throws(
    () =>
      runApprovalCli(
        ["approve", "--request", request.id, "--allow", "--json"],
        stateDirectory,
      ),
    /already has an answer/,
  );
  queue.recordOutcome(request.id, {
    status: "denied",
    behavior: "deny",
    decidedBy: "user",
  });
  assert.throws(
    () =>
      runApprovalCli(
        ["approve", "--request", request.id, "--allow", "--json"],
        stateDirectory,
      ),
    /already denied/,
  );
});

test("fh approve refuses a message it cannot deliver on allow", (context) => {
  // ［実測 2026-08-30］allow の応答へ `message` を足しても、子には届かない。
  // 承認サーバーを patch して `{behavior:"allow", updatedInput, message:"MARKER-7Q4X"}`
  // を返し、実際の子セッションで AskUserQuestion に答えたところ、子が受け取ったのは
  //   Your questions have been answered: "続行しますか"="はい". ...
  // の 1 行だけで、MARKER-7Q4X は届かなかった（選択肢の description と、選ばれなかった
  // ラベルも同様に配送されない）。Claude Code は allow 応答の余分なフィールドを捨てる。
  //
  // したがって allow には自由文の配送経路が無い。#533 のプロトコルもそう規定している
  // （`{"behavior":"allow","updatedInput":{...}}` / `{"behavior":"deny","message":"..."}`）。
  //
  // **黙って捨てるのが害である。** orchestrator は訂正や文脈を添えたつもりで allow し、
  // 届いた前提で監視を続けてしまう（実際に起きた）。ここで落とせば、その場で分かる。
  const stateDirectory = temporaryDirectory(context);
  const directory = approvalsDirectory(stateDirectory);
  const queue = createApprovalQueue({ directory });
  const emit = () => {};
  const request = createPendingRequest(queue, {
    toolName: "AskUserQuestion",
    input: { questions: [COLOUR_QUESTION] },
    escalation: {
      ruleId: "ask-user-question",
      risk: "user-question",
      reason: "user が答える",
    },
  });

  assert.throws(
    () =>
      runApproveCommand({
        queue,
        emit,
        flags: [
          "--request",
          request.id,
          "--allow",
          "--answers",
          '{"Which colour?":"Red"}',
          "--message",
          "この注記は子へ届かない",
        ],
      }),
    /--message cannot be delivered with --allow/,
  );

  // 落ちたのだから、回答も書かれていない。半端に決着した要求を残さない。
  assert.equal(queue.hasAnswer(request.id), false);
  assert.equal(queue.readRequest(request.id).status, "pending");

  // --message を外せば通る。
  assert.equal(
    runApproveCommand({
      queue,
      emit,
      flags: [
        "--request",
        request.id,
        "--allow",
        "--answers",
        '{"Which colour?":"Red"}',
      ],
    }),
    0,
  );
  assert.equal(queue.hasAnswer(request.id), true);
});

test("fh approve still carries a message on deny", (context) => {
  // deny だけが自由文を運べる。allow を塞いだあとの唯一の経路なので、
  // ここが動き続けることを固定する。
  const stateDirectory = temporaryDirectory(context);
  const directory = approvalsDirectory(stateDirectory);
  const queue = createApprovalQueue({ directory });
  const emit = () => {};
  const request = createPendingRequest(queue, {
    toolName: "AskUserQuestion",
    input: { questions: [COLOUR_QUESTION] },
    escalation: {
      ruleId: "ask-user-question",
      risk: "user-question",
      reason: "user が答える",
    },
  });

  assert.equal(
    runApproveCommand({
      queue,
      emit,
      flags: ["--request", request.id, "--deny", "--message", "本文を直してから出して"],
    }),
    0,
  );
  assert.equal(
    queue.readAnswer(request.id, queue.readRequest(request.id)).message,
    "本文を直してから出して",
  );
});

test("fh approve validates answers before writing them", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const directory = approvalsDirectory(stateDirectory);
  const queue = createApprovalQueue({ directory });
  const emit = () => {};
  const request = createPendingRequest(queue, {
    toolName: "AskUserQuestion",
    input: { questions: [COLOUR_QUESTION] },
    escalation: {
      ruleId: "ask-user-question",
      risk: "user-question",
      reason: "user が答える",
    },
  });

  assert.throws(
    () =>
      runApproveCommand({
        queue,
        emit,
        flags: ["--request", request.id, "--allow", "--answers", '{"Which colour?":"Green"}'],
      }),
    /label that was not offered/,
  );
  assert.throws(
    () =>
      runApproveCommand({
        queue,
        emit,
        flags: ["--request", request.id, "--allow", "--answers", "{oops"],
      }),
    /must be valid JSON/,
  );
  assert.throws(
    () => runApproveCommand({ queue, emit, flags: ["--request", request.id] }),
    /exactly one of --allow or --deny/,
  );
  // 検証に落ちた試行は answer を残していない。
  assert.equal(queue.hasAnswer(request.id), false);

  assert.equal(
    runApproveCommand({
      queue,
      emit,
      flags: ["--request", request.id, "--allow", "--answers", '{"Which colour?":"Blue"}'],
    }),
    0,
  );
  assert.deepEqual(queue.readAnswer(request.id, request).answers, {
    "Which colour?": "Blue",
  });
});

test("approvals listing tolerates an empty queue", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const queue = createApprovalQueue({
    directory: approvalsDirectory(stateDirectory),
  });
  assert.deepEqual(runApprovalsCommand({ queue, emit: () => {}, flags: [] }), 0);
});

test("the escalation timeout is clamped below the MCP tool timeout", () => {
  assert.equal(clampEscalationTimeout(DEFAULT_ESCALATION_TIMEOUT_MS), DEFAULT_ESCALATION_TIMEOUT_MS);
  assert.equal(clampEscalationTimeout(999999999), MAX_ESCALATION_TIMEOUT_MS);
  // MCP_TOOL_TIMEOUT の既定（100000000 ms）を必ず下回る。
  assert.ok(MAX_ESCALATION_TIMEOUT_MS < 100000000);
});

test("approve-server refuses a progress interval that cannot beat the idle timeout", (context) => {
  const home = temporaryDirectory(context);
  const directory = path.join(home, "approvals");
  assert.throws(
    () =>
      startApprovalServerCommand({
        flags: ["--progress-interval-ms", String(MCP_STDIO_IDLE_TIMEOUT_MS)],
        environment: { HOME: home },
        cwd: "/workspace",
        directory,
        stdin: new PassThrough(),
        stdout: new PassThrough(),
        stderr: new PassThrough(),
        signals: { on: () => {} },
      }),
    /stdio idle timeout/,
  );
  assert.throws(
    () =>
      startApprovalServerCommand({
        flags: ["--timeout-ms", "0"],
        environment: { HOME: home },
        cwd: "/workspace",
        directory,
        stdin: new PassThrough(),
        stdout: new PassThrough(),
        stderr: new PassThrough(),
        signals: { on: () => {} },
      }),
    /must be a positive integer/,
  );
});

const MULTI_QUESTION = {
  question: "Which colours?",
  header: "Colours",
  multiSelect: true,
  options: [
    { label: "Red", description: "red" },
    { label: "Blue", description: "blue" },
  ],
};

test("a multi-select question requires an array of labels on both sides", (context) => {
  const { queue } = createQueueFixture(context);
  const request = createPendingRequest(queue, {
    toolName: "AskUserQuestion",
    input: { questions: [MULTI_QUESTION] },
    escalation: { ruleId: "ask-user-question", risk: "user-question", reason: "user が答える" },
  });
  // 書き込み側: scalar は拒否する。
  assert.throws(
    () =>
      runApproveCommand({
        queue,
        emit: () => {},
        flags: ["--request", request.id, "--allow", "--answers", '{"Which colours?":"Red"}'],
      }),
    /array of labels/,
  );
  // 読み出し側: CLI を迂回して置かれた scalar も拒否する。
  queue.writeAnswer(
    request.id,
    answerRecord(request.id, { answers: { "Which colours?": "Red" } }),
  );
  assert.throws(() => queue.readAnswer(request.id, request), /array of labels/);
});

test("an existing symlink cannot stand in for an answer file", (context) => {
  const { directory, queue } = createQueueFixture(context);
  const request = createPendingRequest(queue);
  const elsewhere = path.join(directory, "decoy.json");
  writeFileSync(elsewhere, "{}");
  symlinkSync(elsewhere, path.join(directory, `${request.id}.answer.json`));
  assert.throws(
    () => queue.writeAnswer(request.id, answerRecord(request.id)),
    /answered once/,
  );
});

test("two concurrent fh approve processes leave exactly one answer", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const directory = approvalsDirectory(stateDirectory);
  const request = createPendingRequest(createApprovalQueue({ directory }));
  const run = (behavior) => {
    try {
      execFileSync(
        process.execPath,
        [CLI_PATH, "approve", "--approvals-dir", directory, "--request", request.id, behavior, "--json"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      );
      return true;
    } catch {
      return false;
    }
  };
  // 逐次だが別プロセス。link(2) の EEXIST が 2 件目を必ず落とす。
  const outcomes = [run("--allow"), run("--deny")];
  assert.equal(outcomes.filter(Boolean).length, 1);
  const stored = createApprovalQueue({ directory }).readAnswer(
    request.id,
    createApprovalQueue({ directory }).readRequest(request.id),
  );
  assert.equal(stored.behavior, "allow");
});

test("fh approvals exposes the questions an AskUserQuestion request asked", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const queue = createApprovalQueue({ directory: approvalsDirectory(stateDirectory) });
  createPendingRequest(queue, {
    toolName: "AskUserQuestion",
    input: { questions: [COLOUR_QUESTION, MULTI_QUESTION] },
    escalation: { ruleId: "ask-user-question", risk: "user-question", reason: "user が答える" },
  });
  const listed = runApprovalCli(["approvals", "--json"], stateDirectory);
  const [entry] = listed.output.approvals;
  assert.equal(entry.toolName, "AskUserQuestion");
  assert.deepEqual(
    entry.input.questions.map((question) => question.question),
    ["Which colour?", "Which colours?"],
  );
  assert.deepEqual(entry.input.questions[1].options.map((o) => o.label), ["Red", "Blue"]);
  assert.equal(entry.input.questions[1].multiSelect, true);
});

test("approve-server refuses to start on an unusable rules file or queue", (context) => {
  const home = temporaryDirectory(context);
  const io = {
    stdin: new PassThrough(),
    stdout: new PassThrough(),
    stderr: new PassThrough(),
    signals: { on: () => {} },
  };
  // 壊れたルールファイルは静かに baseline へ縮退させず、起動を拒否する。
  const rulesPath = path.join(home, "rules.json");
  writeFileSync(rulesPath, "{ not json");
  assert.throws(
    () =>
      startApprovalServerCommand({
        flags: ["--rules", rulesPath],
        environment: { HOME: home },
        cwd: "/workspace",
        directory: path.join(home, "approvals"),
        ...io,
      }),
    /not valid JSON/,
  );
  // 相対パスのフラグは作業ディレクトリ由来になるため拒否する。
  // --rules は rules の解決経路、--approvals-dir は queue の解決経路で弾かれる。
  assert.throws(
    () =>
      startApprovalServerCommand({
        flags: ["--rules", "rules.json"],
        environment: { HOME: home },
        cwd: "/workspace",
        directory: path.join(home, "approvals"),
        ...io,
      }),
    /must be an absolute path/,
  );
  assert.throws(
    () =>
      resolveApprovalsDirectory({
        flags: ["--approvals-dir", "approvals"],
        stateDirectory: () => home,
      }),
    /must be an absolute path/,
  );
  // symlink の queue ディレクトリも拒否する。
  const target = path.join(home, "real");
  mkdirSync(target);
  const linked = path.join(home, "linked");
  symlinkSync(target, linked);
  assert.throws(
    () =>
      startApprovalServerCommand({
        flags: [],
        environment: { HOME: home },
        cwd: "/workspace",
        directory: linked,
        ...io,
      }),
    /must not be a symbolic link/,
  );
});

test("the stdio transport writes JSON-RPC and nothing else to stdout", async (context) => {
  const directory = path.join(temporaryDirectory(context), "approvals");
  const queue = createApprovalQueue({ directory });
  const input = new PassThrough();
  const output = new PassThrough();
  const errorOutput = new PassThrough();
  const stdout = [];
  const stderr = [];
  output.setEncoding("utf8");
  output.on("data", (chunk) => stdout.push(chunk));
  errorOutput.setEncoding("utf8");
  errorOutput.on("data", (chunk) => stderr.push(chunk));

  const transport = runStdioApprovalServer({
    input,
    output,
    errorOutput,
    createServer: (send) =>
      createApprovalServer({
        queue,
        rules: BASELINE_RULES,
        cwd: "/workspace",
        timeoutMs: 60000,
        pollIntervalMs: 5,
        notify: send,
        log: (line) => errorOutput.write(`log: ${line}\n`),
      }),
  });
  input.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })}\n`);
  input.write(`${JSON.stringify(approveMessage({ id: 2, toolName: "Bash", input: { command: "npm test" } }))}\n`);
  input.end();
  assert.equal(await transport.finished, 0);

  for (const line of stdout.join("").trim().split("\n")) {
    const message = JSON.parse(line);
    assert.equal(message.jsonrpc, "2.0");
  }
});

test("a signal aborts pending requests and lets the process finish", async (context) => {
  const directory = path.join(temporaryDirectory(context), "approvals");
  const queue = createApprovalQueue({ directory });
  const handlers = new Map();
  const input = new PassThrough();
  const output = new PassThrough();
  const stderr = new PassThrough();
  stderr.resume();

  // stdin を閉じずに signal を発火する（実運用の SIGTERM と同じ状況）。
  const finished = startApprovalServerCommand({
    flags: ["--approvals-dir", directory, "--timeout-ms", "600000", "--progress-interval-ms", "1000"],
    environment: { HOME: temporaryDirectory(context) },
    cwd: "/workspace",
    directory,
    stdin: input,
    stdout: output,
    stderr,
    signals: { on: (signal, handler) => handlers.set(signal, handler) },
  });
  output.resume();
  input.write(
    `${JSON.stringify(approveMessage({ toolName: "Bash", input: { command: "git merge main" } }))}\n`,
  );
  // 要求が pending になるまで待つ（実時計だがポーリング間隔は既定 1s 未満で収束する）。
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (queue.listRequests({ status: "pending" }).requests.length === 1) break;
    await new Promise((resolve) => setImmediate(resolve));
  }
  handlers.get("SIGTERM")("SIGTERM");
  assert.equal(await finished, 0);
  const [stored] = queue.listRequests({}).requests;
  assert.equal(stored.status, "aborted");
  assert.equal(stored.decision.decidedBy, "shutdown");
});

test("the approvals directory falls back to the state root layout", (context) => {
  const stateDirectory = temporaryDirectory(context);
  const request = createPendingRequest(
    createApprovalQueue({ directory: approvalsDirectory(stateDirectory) }),
  );
  const stored = JSON.parse(
    readFileSync(
      path.join(stateDirectory, "approvals", `${request.id}.request.json`),
      "utf8",
    ),
  );
  assert.equal(stored.id, request.id);
});

// ---------------------------------------------------------------------------
// 後始末（#537: 質問文と選択肢を wave の終了後に残さない）
// ---------------------------------------------------------------------------

test("purging drops decided requests and their answers but keeps pending ones", (context) => {
  const { queue } = createQueueFixture(context);
  const decided = createPendingRequest(queue);
  const pending = createPendingRequest(queue, { toolUseId: "toolu_02" });

  queue.writeAnswer(decided.id, answerRecord(decided.id));
  queue.recordOutcome(decided.id, {
    status: "allowed",
    behavior: "allow",
    decidedBy: "user",
  });

  const result = queue.purgeDecided();
  assert.equal(result.purged, 1);
  assert.equal(result.pending, 1);
  assert.deepEqual(result.skipped, []);

  // 決着済みは要求も回答も消える。pending はどちらも残る。
  assert.throws(() => queue.readRequest(decided.id), /does not exist/);
  assert.equal(queue.hasAnswer(decided.id), false);
  assert.equal(queue.readRequest(pending.id).status, "pending");
  assert.equal(queue.listRequests().requests.length, 1);
});

test("purging drops an answered request whose status never advanced", (context) => {
  // status を pending から動かすのは approve-server だけである。子（と server）が answer を
  // consume する前に死ぬと、**回答は書かれているのに status は pending のまま**残る。
  // その状態では purge が status を見て飛ばし、`approve` は hasAnswer で拒否するため、
  // 要求が永久に居座る。実運用で wave 1 本ごとに 1 件溜まり、orchestrator の監視が
  // 「子が回答を待っている」と誤読する原因にもなった。
  const { queue } = createQueueFixture(context);
  const answered = createPendingRequest(queue);
  const untouched = createPendingRequest(queue, { toolUseId: "toolu_02" });

  // recordOutcome を呼ばない ＝ server が死んだ状況。
  queue.writeAnswer(answered.id, answerRecord(answered.id));
  assert.equal(queue.readRequest(answered.id).status, "pending");

  const result = queue.purgeDecided();
  assert.equal(result.purged, 1);
  // 本当に答えを待っている要求は残す（この skill が守ってきた性質）。
  assert.equal(result.pending, 1);
  assert.throws(() => queue.readRequest(answered.id), /does not exist/);
  assert.equal(queue.readRequest(untouched.id).status, "pending");
});

test("purging leaves a request it could not read", (context) => {
  const { directory, queue } = createQueueFixture(context);
  const decided = createPendingRequest(queue);
  queue.recordOutcome(decided.id, {
    status: "denied",
    behavior: "deny",
    decidedBy: "user",
  });
  // 壊れた要求ファイル。pending でないことを確認できないものを消すのは fail-open。
  const brokenId = `appreq_${"a".repeat(32)}`;
  writeFileSync(path.join(directory, `${brokenId}.request.json`), "{ not json");

  const result = queue.purgeDecided();
  assert.equal(result.purged, 1);
  assert.equal(result.skipped.length, 1);
  assert.equal(existsSync(path.join(directory, `${brokenId}.request.json`)), true);
});

test("fh approvals --purge reports what it removed without listing content", (context) => {
  const { directory, queue } = createQueueFixture(context);
  const decided = createPendingRequest(queue);
  queue.recordOutcome(decided.id, {
    status: "allowed",
    behavior: "allow",
    decidedBy: "user",
  });

  const output = [];
  assert.equal(
    runCli(["approvals", "--purge", "--approvals-dir", directory, "--json"], {
      write: (line) => output.push(line),
    }),
    0,
  );
  const report = JSON.parse(output.pop());
  assert.deepEqual(report, { purged: 1, pending: 0, skipped: [] });
  // 一覧ではないので、要求の中身（コマンド文字列）は出力に現れない。
  assert.equal(output.join("").includes("git merge"), false);
});

test("AskUserQuestion escalates no matter what the rules say", () => {
  // approver は一次ソースの裏取りができないので、選択肢への回答を代理しない。
  // 経路が tmux から承認チャネルへ移っても、この不変条件は動かない（#529 PRD §6 ガード 3）。
  const permissive = compileApprovalRules({
    defaultDecision: "allow",
    additionalRules: [],
  });
  const verdict = classifyToolCall(
    { toolName: "AskUserQuestion", input: { questions: [] } },
    permissive,
  );
  assert.equal(verdict.decision, "escalate");
  assert.equal(verdict.rule.risk, "user-question");
});
