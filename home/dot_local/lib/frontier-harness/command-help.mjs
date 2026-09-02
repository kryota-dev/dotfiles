// 各コマンドが「何を出すか」の唯一の一覧。`flag-registry.mjs` が入力側の契約（受け付ける
// フラグ）を持つのに対し、こちらは出力側の契約（`--json` が返す top-level キー）を持つ。
//
// **なぜ要るのか。** `fh approvals --json` が `{"approvals": [...], "skipped": [...]}` という
// envelope を返すことは、CLI のどこからも引けなかった。監視スクリプトが top-level を配列として
// 舐めて型エラーで落ち、それが `2>/dev/null || true` と組み合わさって「承認要求 0 件」と
// 区別できない空文字列を返し続け、承認要求 2 件を最大 42 分放置した。実際に叩いて目視するしか
// 形状を知る方法が無い、というのがこの欠落の実害である。
//
// **なぜ実装から検証するのか。** 書きっぱなしの usage 文字列はいずれ嘘になる。`cli.mjs` は
// `emit` を `assertDeclaredOutput` で包み、ここに宣言の無い top-level キーが出た瞬間に内部
// エラーで落とす。「実装にキーを足したが `--help` に書かなかった」——事故を再生産する drift の
// 向き——が、全コマンド・全分岐で構造的に起きなくなる。逆向き（宣言に残っているが実装から
// 消えた）は tests/frontier_harness_cli_quality.test.mjs が、実際に叩けるコマンドについて
// 宣言キー集合と実測キー集合の一致で覆う。
//
// **フラグ一覧は書かない。** synopsis と notes だけを手で持ち、受け付けるフラグの列挙は
// `COMMAND_FLAGS` から生成する。2 か所に書けば必ずずれるので、入力契約の SSOT は 1 つに保つ。

import { COMMAND_FLAGS } from "./flag-registry.mjs";

// `--json` と `--help` は全コマンドに効くので、各エントリの synopsis には書かない。
const GLOBAL_SYNOPSIS_SUFFIX = "[--json] [--help]";

// 出力を持たないコマンドを「宣言し忘れ」と区別する。空の `output` は
// 「JSON envelope を返さない」という積極的な宣言である。
const NO_JSON_OUTPUT = Object.freeze({});

function entry({ summary, synopsis, notes = [], output, outputNote = null }) {
  return Object.freeze({
    summary,
    synopsis: Object.freeze([...synopsis]),
    notes: Object.freeze([...notes]),
    output: Object.freeze({ ...output }),
    outputNote,
  });
}

export const COMMAND_HELP = Object.freeze({
  approvals: entry({
    summary: "List pending approval requests, or drop decided ones",
    synopsis: [
      "fh approvals [--all] [--approvals-dir <abs>]",
      "fh approvals --purge [--approvals-dir <abs>]",
    ],
    notes: [
      "Without --all only pending requests are listed. --purge deletes the requests that",
      "were already decided, together with their answers; it never touches pending ones.",
      "A purge is how a finished wave stops retaining the question text of its escalations.",
    ],
    output: {
      approvals:
        "array of pending (or, with --all, every) request summary; nested in the envelope, never the top level",
      skipped:
        "array of approval files that could not be read, each with the reason; a request that lands here is invisible to `approvals`",
      purged: "--purge only: how many decided requests were deleted",
      pending: "--purge only: how many pending requests were left alone",
    },
    outputNote:
      "--purge returns a different envelope from a listing: {purged, pending, skipped}.",
  }),
  approve: entry({
    summary: "Answer one approval request",
    synopsis: [
      "fh approve --request <id> --allow|--deny [--answers <json>] [--message <text>]",
      "                                        [--approvals-dir <abs>]",
    ],
    notes: [
      "--answers carries the reply to an AskUserQuestion as JSON; --message carries free text.",
      "Answering a request that was already decided is refused, not silently overwritten.",
    ],
    output: {
      requestId: "the request that was answered",
      behavior: '"allow" or "deny"',
      answers: "the structured answers that were recorded, or null",
      toolName: "the tool call the request was raised for",
    },
  }),
  "approve-server": entry({
    summary: "Run the stdio permission prompt tool for a child session",
    synopsis: [
      "fh approve-server --session <id> --approvals-dir <abs> [--rules <abs>]",
      "                  [--timeout-ms <n>] [--progress-interval-ms <n>]",
    ],
    notes: [
      "Speaks the MCP permission-prompt protocol on stdin/stdout, so it prints no envelope",
      "of its own; a child session talks to it, not a person. Path flags must be absolute.",
    ],
    output: NO_JSON_OUTPUT,
    outputNote:
      "This command speaks MCP on stdio and emits no JSON envelope; --json changes nothing.",
  }),
  candidate: entry({
    summary: "Manage disposable child worktrees for write-capable routes",
    synopsis: [
      "fh candidate create --task <task id> [--base <rev>] [--label <l>]",
      "fh candidate list",
      "fh candidate adopt --candidate <id>",
      "fh candidate discard --candidate <id>",
      "fh candidate <action> [--worktree <abs>]",
    ],
    notes: [
      "Adoption requires deterministic checks recorded after creation; a candidate that",
      "conflicts is retained, never discarded.",
    ],
    output: {
      action: 'which action ran: "create", "list", "adopt" or "discard"',
      candidate: "the candidate record the action acted on, or null when none was created",
      candidates: "list only: every live candidate worktree",
      adopted: "adopt only: whether the diff was applied",
      executed: "whether the action was carried out (false under a rollout guard or a manifest gap)",
      executionReason: "why it was not carried out; absent when executed is true",
      verifiedChecks: "adopt only: how many recorded checks the verdict considered",
      evidenceId: "the evidence row recorded for this action",
      gaps: "manifest requests that were not approved; non-empty means exit 2",
      policyIntegrity: "how the approved manifest was verified for this repository",
    },
  }),
  clean: entry({
    summary: "Prune expired raw evidence and aggregate telemetry",
    synopsis: ["fh clean [--dry-run] [--now <iso 8601>]"],
    notes: [
      "--dry-run prunes nothing and lists what it would delete. Raw evidence and aggregate",
      "telemetry expire on their own windows; the approvals ledger is the audit trail and is",
      "never pruned. A dry run lists at most 20 targets per class and sets targetsTruncated",
      "when it cuts the list.",
    ],
    output: {
      cutoff: "the raw-evidence cutoff timestamp (kept under its old name for existing readers)",
      telemetryCutoff: "the aggregate-telemetry cutoff timestamp",
      dryRun: "true when nothing was deleted",
      expiredEvidence: "how many evidence rows were past the raw cutoff",
      prunedEvidence: "how many evidence rows were deleted (0 on a dry run)",
      expiredRaw: "per-class counts of expired raw rows",
      prunedRaw: "per-class counts of deleted raw rows",
      expiredTelemetry: "how many telemetry rows were past the telemetry cutoff",
      prunedTelemetry: "how many telemetry rows were deleted",
      skippedArtifacts: "artifact files that could not be removed, with the reason",
      targets:
        "--dry-run only: what would be deleted, capped per class; null on a real prune, so a target list never implies a deletion happened",
      targetsTruncated: "whether the target list hit its per-class cap",
    },
  }),
  doctor: entry({
    summary: "Report adapter and capability readiness",
    synopsis: ["fh doctor [--probe]"],
    notes: [
      "--probe asks the provider which models it can reach and caches the answer; without it",
      "the cached readiness is read back.",
    ],
    output: {
      accountScope: 'which account profile was resolved ("personal", "r06" or "unknown")',
      rollout: "the configured rollout stage",
      capabilities:
        'map of capability name to {status, ...}; status is "available", "unavailable" or "unverified"',
    },
  }),
  gaps: entry({
    summary: "List command/domain/capability requests the manifest did not approve",
    synopsis: ["fh gaps"],
    notes: [
      "Reads the state root only, so it still answers when config.json is missing — losing",
      "the way to ask why a run stopped is worse than answering without a capability registry.",
    ],
    output: {
      gaps: "array of queued requests, each naming what was asked for and which kind it was",
    },
  }),
  onboard: entry({
    summary: "Review and approve the repository capability manifest",
    synopsis: [
      "fh onboard --manifest <abs>                                  # review; prints a request id",
      "fh onboard --manifest <abs> --approve --request <id>         # approve that review",
      "fh onboard --from-gaps [--approve --request <id>]",
    ],
    notes: [
      "Two steps on purpose: the review run prints the candidate and returns exit 2, and only a",
      "second run with the id it printed writes the approval. --from-gaps builds the candidate",
      "from the approved manifest plus everything queued by `fh gaps`.",
    ],
    output: {
      approved: "false on the review step, true once the manifest was approved",
      manifest: "review step only: the candidate manifest that is waiting for approval",
      approvalHash: "the hash the approval is bound to",
      request: "review step only: {id, expiresAt} — the id to pass back with --approve",
      reason: "review step only: what to do next",
      policyPath: "approval step only: where the approved manifest was written",
      approvalId: "approval step only: the row in the approvals ledger",
      scope: "approval step only: the repository the approval is scoped to",
      gapsIncluded: "--from-gaps review step: queued gaps folded into the candidate",
      gapsApproved: "--from-gaps approval step: queued gaps the approval covered",
      gapsRejected: "--from-gaps: queued gaps that were left out, with the reason",
    },
  }),
  review: entry({
    summary: "Hand a reviewer a packet, and take findings back into the registry",
    synopsis: [
      "fh review packet --task <task id> --out <abs> [--base <rev>]",
      "fh review record --task <task id> --findings <abs>",
      "fh review <action> [--worktree <abs>]",
    ],
    notes: [
      "A packet carries the task, constraints, diff, and verification results, and has no",
      "channel for the writer's conversation.",
    ],
    output: {
      action: 'which action ran: "packet" or "record"',
      taskId: "the task the packet or the findings belong to",
      out: "packet only: where the packet was written, or null when it was not written",
      base: "packet only: the revision the diff was taken against",
      diffTruncated: "packet only: whether the diff hit its size cap",
      verificationResults: "packet only: how many verification results the packet carries",
      reviewerCapability: "record only: the capability the reviewer ran as",
      verdict: "record only: the verdict derived from the findings",
      counts: "record only: findings per severity",
      findingIds: "record only: the rows written to the finding registry",
      evidenceId: "record only: the evidence row recorded for the review",
      executed: "whether the action was carried out",
      executionReason: "why it was not carried out; absent when executed is true",
      rollout: "record only: the configured rollout stage",
      policyIntegrity: "how the approved manifest was verified for this repository",
    },
  }),
  run: entry({
    summary: "Record a shadow route for a task JSON file",
    synopsis: ["fh run --task <abs task file>"],
    notes: [
      "The route is chosen and recorded; an escalation route never starts a provider, so a",
      "task the manifest does not approve is recorded rather than executed.",
    ],
    output: {
      task: "the task as it was normalized and stored",
      decision: "the route that was recorded, including its kind and capability",
      blocked: "capabilities the router refused, each with the axis that refused it",
      blockEvidence: "the evidence row recorded for those refusals, or null",
      executed: "whether a provider was started",
      executionReason: "why it was not started; absent when executed is true",
      rollout: "the configured rollout stage",
      gaps: "manifest requests that were not approved; non-empty means exit 2",
      policyIntegrity: "how the approved manifest was verified for this repository",
    },
  }),
  runs: entry({
    summary: "Show how recorded adapter runs ended, newest first",
    synopsis: [
      "fh runs [--limit <n>] [--offset <n>]",
      "fh runs --run <adapter run id>",
    ],
    notes: [
      "Each listed run carries a count of the verification results linked to it. A count of 0",
      'means no gate was passed — `status: "succeeded"` says only that the turn ended without',
      "an error, not that the gates it was given went green.",
      "--limit defaults to 50 and is capped at 500, the same way `fh status` pages.",
      "--run looks up a single record and cannot be combined with --limit or --offset.",
    ],
    output: {
      runs: "listing only: the page of adapter runs, newest first",
      page: "listing only: {limit, offset, total, returned, hasMore} — hasMore says the page was cut",
      run: "--run only: the single adapter run record",
      verifications: "--run only: the verification results linked to that run",
    },
    outputNote:
      "--run returns {run, verifications}; without it the envelope is {runs, page}. The two shapes never overlap.",
  }),
  session: entry({
    summary: "Launch or resume a child session through the approval channel",
    synopsis: [
      "fh session launch --worktree <abs> --prompt-file <abs> [--session-id <id>]",
      "fh session resume --worktree <abs> --prompt-file <abs> --resume-key <id>",
      "fh session <action> [--capability <name>] [--label <l>] [--sandbox <mode>]",
      "                    [--approvals-dir <abs>] [--approval-server-command <abs>]",
      "                    [--timeout-ms <n>] [--progress-interval-ms <n>]",
      '                    [--gate "[<kind>:]<approved command>"] [--gate-timeout-ms <n>]',
    ],
    notes: [
      "Path flags must be absolute. --capability defaults to session.child.",
      "--gate declares a completion condition; repeat it for more. Each is run after the child",
      "and linked to the run, so a gate that does not pass keeps the session out of `succeeded`.",
      "--gate-timeout-ms caps each gate check, not the approval channel.",
    ],
    output: {
      action: '"launch" or "resume"',
      capability: "the capability the child ran as",
      sessionId: "the id of the child session",
      taskId: "the task row recorded for this session",
      routeId: "the route row recorded for this session",
      accountScope: "only when the account scope could not be resolved: what was seen",
      provider: "the provider that was started",
      model: "the model the capability selected",
      effort: "the effort the capability selected",
      sandbox: "the sandbox mode the child ran under",
      status: 'the session result: "succeeded" only when the child and every gate passed',
      outcome: "the session outcome, kept three-valued so a failed gate does not overwrite it",
      childOutcome: "what the child itself reported, before the gates were considered",
      exitCode: "the child's exit code",
      resumeKey: "the key to pass to `fh session resume`",
      denials: "approval requests the channel denied during the run",
      failureReason: "why the session did not succeed",
      initHealth: "{healthy, problems} from the startup check on the child's first system/init",
      gate: "{status, reason, declared, results} — the completion conditions and how each ended",
      adapterRunId: "the adapter run row; pass it to `fh runs --run`",
      evidenceId: "the evidence row recorded for this session",
      executed: "whether the child was started",
      executionReason: "why it was not started; absent when executed is true",
      rollout: "the configured rollout stage",
      gaps: "manifest requests that were not approved; non-empty means exit 2",
      policyIntegrity: "how the approved manifest was verified for this repository",
    },
  }),
  status: entry({
    summary: "Show recorded route decisions, newest first",
    synopsis: ["fh status [--limit <n>] [--offset <n>]"],
    notes: [
      "Route history accumulates in the state root, so the default is a page, not every row:",
      "--limit defaults to 50 and is capped at 500; anything above the cap is clamped, not refused.",
      "`fh status` holds what was chosen; `fh runs` holds how it ended.",
    ],
    output: {
      routes: "the page of route decisions, newest first",
      page: "{limit, offset, total, returned, hasMore} — hasMore says the page was cut",
    },
  }),
  verify: entry({
    summary: "Run an approved deterministic check and record its result",
    synopsis: [
      "fh verify --task <task id> --command <approved command> [--kind <kind>]",
      "          [--worktree <abs>] [--candidate <id>] [--timeout-ms <n>]",
    ],
    notes: [
      "--kind defaults to test. --candidate runs the check inside a candidate worktree.",
      "Exits 0 only when the check passed.",
    ],
    output: {
      taskId: "the task the result was recorded against",
      checkKind: "the kind the result was recorded as",
      command: "the command that was run",
      candidateId: "the candidate worktree the check ran in, or null",
      timeoutMs: "the timeout that actually applied, after clamping",
      result: "the recorded verification result row, or null when nothing ran",
      evidence: "the evidence row recorded for the check, or null when nothing ran",
      status: '"passed", "failed" or "errored"',
      exitCode: "the check's exit code",
      timedOut: "whether the check was killed by the timeout",
      failureReason: "why the check did not pass",
      executed: "whether the check was run",
      executionReason: "why it was not run; absent when executed is true",
      rollout: "the configured rollout stage",
      gaps: "manifest requests that were not approved; non-empty means exit 2",
      policyIntegrity: "how the approved manifest was verified for this repository",
    },
  }),
});

export function helpCommandNames() {
  return Object.keys(COMMAND_HELP).sort();
}

// 受け付けるフラグの行は `COMMAND_FLAGS` から生成する。手で書き写すと、フラグを足した
// ときに `--help` だけが古いままになる —— この issue が直そうとしている drift そのもの。
function flagLines(command) {
  const spec = COMMAND_FLAGS[command];
  if (!spec) return [];
  const render = (label, boolean, value) => {
    const names = [
      ...boolean.map((name) => name),
      ...value.map((name) => `${name} <value>`),
    ];
    return names.length > 0 ? `  ${label}: ${names.join(" ")}` : null;
  };
  const lines = [render(`fh ${command}`, spec.boolean, spec.value)];
  for (const [action, entryFlags] of Object.entries(spec.actions ?? {})) {
    lines.push(
      render(`fh ${command} ${action}`, entryFlags.boolean, entryFlags.value),
    );
  }
  return lines.filter((line) => line !== null);
}

function outputLines(command) {
  const help = COMMAND_HELP[command];
  const keys = Object.keys(help.output);
  if (keys.length === 0) {
    return ["Output:", `  ${help.outputNote}`];
  }
  const width = Math.max(...keys.map((key) => key.length));
  return [
    "Output (--json prints an object with these top-level keys, never a bare array):",
    ...keys.map((key) => `  ${key.padEnd(width)}  ${help.output[key]}`),
    ...(help.outputNote ? ["", `  ${help.outputNote}`] : []),
  ];
}

// 1 コマンド分の usage。`fh <command> --help` が出す本文そのもの。
export function renderCommandHelp(command) {
  const help = COMMAND_HELP[command];
  if (!help) return renderUsage();
  const flags = flagLines(command);
  return [
    "Usage:",
    ...help.synopsis.map((line) => `  ${line}`),
    `  (every form also accepts ${GLOBAL_SYNOPSIS_SUFFIX})`,
    "",
    help.summary,
    ...(help.notes.length > 0 ? ["", ...help.notes] : []),
    ...(flags.length > 0 ? ["", "Accepted flags:", ...flags] : []),
    "",
    ...outputLines(command),
    "",
    `\`fh ${command} --help --json\` prints this contract as JSON.`,
  ].join("\n");
}

// コマンド一覧。詳細は各コマンドの `--help` が持つので、ここでは 1 行ずつに留める
// （以前はこの文字列がコマンドごとの説明を全部抱えており、増やすほど読めなくなっていた）。
export function renderUsage() {
  const names = helpCommandNames();
  const width = Math.max(...names.map((name) => name.length));
  return [
    "Usage: frontier-harness <command> [flags] [--json] [--help]",
    "",
    "Every command refuses a flag it does not know, by name.",
    "`fh <command> --help` prints that command's flags and the top-level keys its",
    "--json output carries; add --json to get the same contract as JSON.",
    "",
    "Commands:",
    ...names.map(
      (name) => `  ${name.padEnd(width)}  ${COMMAND_HELP[name].summary}`,
    ),
  ].join("\n");
}

// 機械可読な契約。監視スクリプトが形状を推測せず、依存する形を表明・検証できるようにする
// （この issue の事故は、形状を推測するしか手が無かったことから始まった）。
export function commandHelpJson(command) {
  const help = COMMAND_HELP[command];
  const spec = COMMAND_FLAGS[command];
  return {
    command,
    summary: help.summary,
    synopsis: [...help.synopsis],
    flags: {
      boolean: [...(spec?.boolean ?? [])],
      value: [...(spec?.value ?? [])],
      actions: Object.fromEntries(
        Object.entries(spec?.actions ?? {}).map(([action, actionFlags]) => [
          action,
          { boolean: [...actionFlags.boolean], value: [...actionFlags.value] },
        ]),
      ),
    },
    output: { ...help.output },
    outputNote: help.outputNote,
  };
}

export function usageJson() {
  return {
    usage: "frontier-harness <command> [flags] [--json] [--help]",
    commands: Object.fromEntries(
      helpCommandNames().map((name) => [name, COMMAND_HELP[name].summary]),
    ),
  };
}

// 宣言されていない top-level キーの一覧。空配列なら契約どおり。
export function undeclaredOutputKeys(command, value) {
  const help = COMMAND_HELP[command];
  // 未知のコマンドはこの層の担当ではない。usage を出す既存の経路に任せる。
  if (!help) return [];
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    // envelope でないものを出しているなら、それ自体が契約違反である
    // （形状が発見できない、というこの issue の欠落そのものに戻る）。
    return ["<not a JSON object>"];
  }
  return Object.keys(value).filter((key) => !Object.hasOwn(help.output, key));
}

// **payload を書き出したあとに呼ぶこと。** ここで落ちるのは内部の不整合（実装が契約より
// 先に進んだ）であって、利用者の誤りではない。子が既に走ったあとの経路も通るため、先に
// 例外を投げると監査証跡が丸ごと消える —— それはこの harness が最も避けたい失敗である。
//
// TypeError / HarnessError / SyntaxError のいずれでもない素の Error を投げるので、
// describeCliFailure は「想定外」に分類し、stack ごと exit 70 で終わる。
export function assertDeclaredOutput(command, value) {
  const undeclared = undeclaredOutputKeys(command, value);
  if (undeclared.length === 0) return;
  throw new Error(
    `fh ${command} emitted ${undeclared.length} top-level key(s) that its output contract does not declare: ${undeclared.join(", ")}. ` +
      "Add them to COMMAND_HELP in command-help.mjs so `fh " +
      `${command} --help\` stops lying about the shape.`,
  );
}
