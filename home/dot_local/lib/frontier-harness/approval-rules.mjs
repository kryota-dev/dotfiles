import { readFileSync } from "node:fs";

import { analyzeShellCommand } from "./approval-command.mjs";
import {
  APPROVAL_RISKS,
  BASELINE_APPROVAL_RULES,
  BASELINE_RULE_IDS,
} from "./approval-rules-baseline.mjs";
import { rejectUnknownKeys, requireObject } from "./record-validation.mjs";
import { resolveTrustedPath } from "./trusted-path.mjs";

// 承認チャネルの escalation ルールの読み込み・検証・照合。
// baseline ルールそのもの（データ）は approval-rules-baseline.mjs にある。
//
// このファイルが repository capability manifest（<repo>/.harness/policy.json、#494）と
// 別に存在するのは、失敗の方向が逆だからである。manifest の漏れは fail-closed
// （実行できない）で気づけるが、escalation ルールの漏れは fail-open（人に聞かずに
// 実行される）で気づけない。同居させるとこの非対称が見えなくなる。

export {
  APPROVAL_RISKS,
  BASELINE_APPROVAL_RULES,
  CONFIG_RISK_VOCABULARY,
} from "./approval-rules-baseline.mjs";

// field セレクタ。
//   "<key>" … input の当該キー（文字列のみ）
//   "paths" … ツールがファイルパスを載せる既知のキー群
//   "all"   … input 全体を JSON 化した文字列（誤検知が増えるため baseline では使わない）
export const APPROVAL_RULE_PATH_KEYS = Object.freeze([
  "file_path",
  "notebook_path",
  "path",
]);

// 追加ルールの正規表現がいくらでも長くなると、照合そのものが停止性の問題になる。
// ルールファイルは HOME 配下の信頼できる場所にしか置けないので境界ではないが、
// 事故で貼り付けた巨大な pattern を弾く程度の上限は置く。
export const APPROVAL_RULE_PATTERN_MAX_LENGTH = 512;

// ここに挙げたツールは、ルールの一致に関わらず必ず user へ問い合わせる。
// approver は一次ソースの裏取りができないので、「事実主張に依存する問いを
// 自動応答しない」（#529 PRD §6 ガード 3）を、自動回答の権能を持たないことで満たす。
export const ALWAYS_ESCALATED_TOOLS = Object.freeze(new Set(["AskUserQuestion"]));

export const ASK_USER_QUESTION_RULE = Object.freeze({
  id: "ask-user-question",
  risk: "user-question",
  tool: "AskUserQuestion",
  field: "-",
  pattern: null,
  reason: "AskUserQuestion は必ず user が答える（approver は代理回答しない）",
});

// コマンド文字列を静的に解釈できなかったとき用。「ルールに一致しなかった」と
// 「そもそも読めなかった」を同じ allow に倒さないための受け皿。
export const OPAQUE_COMMAND_RULE = Object.freeze({
  id: "opaque-command",
  risk: "opaque-command",
  tool: "Bash",
  field: "command",
  pattern: null,
  reason: "コマンドを静的に解釈できないため、ルールの適用可否を判断できない",
});

export const UNMATCHED_RULE = Object.freeze({
  id: "unmatched-default-escalate",
  risk: "unmatched",
  tool: "*",
  field: "-",
  pattern: null,
  reason: "ルールファイルが defaultDecision: escalate を宣言している",
});

// ---------------------------------------------------------------------------
// ルールファイル
// ---------------------------------------------------------------------------

export const APPROVAL_RULES_FILE_VERSION = 1;
export const APPROVAL_DEFAULT_DECISIONS = Object.freeze(
  new Set(["allow", "escalate"]),
);

const RULES_FILE_KEYS = new Set([
  "version",
  "defaultDecision",
  "additionalRules",
]);
// baseline を削除・無効化するキーは意図的に存在しない。ファイルは足すことしかできない。
const RULE_KEYS = new Set(["id", "risk", "tool", "field", "pattern", "reason"]);

function requireNonEmptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} must be a non-empty string`);
  }
  return value;
}

function normalizeAdditionalRule(input, index, seenIds) {
  requireObject(input, `approval rule ${index}`);
  rejectUnknownKeys(input, RULE_KEYS, `approval rule ${index}`);
  const id = requireNonEmptyString(input.id, `approval rule ${index} id`);
  if (BASELINE_RULE_IDS.has(id)) {
    throw new TypeError(
      `approval rule ${index} id collides with a baseline rule: ${id}`,
    );
  }
  if (seenIds.has(id)) {
    throw new TypeError(`approval rule ${index} id is duplicated: ${id}`);
  }
  seenIds.add(id);
  if (!APPROVAL_RISKS.has(input.risk)) {
    throw new TypeError(`approval rule ${index} risk is not a known category`);
  }
  const tool = requireNonEmptyString(input.tool, `approval rule ${index} tool`);
  const field = requireNonEmptyString(
    input.field,
    `approval rule ${index} field`,
  );
  const pattern = requireNonEmptyString(
    input.pattern,
    `approval rule ${index} pattern`,
  );
  if (pattern.length > APPROVAL_RULE_PATTERN_MAX_LENGTH) {
    throw new TypeError(
      `approval rule ${index} pattern exceeds ${APPROVAL_RULE_PATTERN_MAX_LENGTH} characters`,
    );
  }
  try {
    new RegExp(pattern, "i");
  } catch (error) {
    throw new TypeError(
      `approval rule ${index} pattern is not a valid regular expression: ${error.message}`,
    );
  }
  return Object.freeze({
    id,
    risk: input.risk,
    tool,
    field,
    pattern,
    reason: requireNonEmptyString(input.reason, `approval rule ${index} reason`),
  });
}

export function normalizeApprovalRulesFile(input) {
  requireObject(input, "approval rules file");
  rejectUnknownKeys(input, RULES_FILE_KEYS, "approval rules file");
  if (input.version !== APPROVAL_RULES_FILE_VERSION) {
    throw new TypeError("approval rules file version must be 1");
  }
  if (
    input.defaultDecision !== undefined &&
    !APPROVAL_DEFAULT_DECISIONS.has(input.defaultDecision)
  ) {
    throw new TypeError(
      "approval rules file defaultDecision must be allow or escalate",
    );
  }
  const additionalRules = input.additionalRules ?? [];
  if (!Array.isArray(additionalRules)) {
    throw new TypeError("approval rules file additionalRules must be an array");
  }
  const seenIds = new Set();
  return Object.freeze({
    // 既定は allow。ファイルはこれを escalate へ「厳しくする」ことしかできない。
    defaultDecision: input.defaultDecision ?? "allow",
    additionalRules: Object.freeze(
      additionalRules.map((rule, index) =>
        normalizeAdditionalRule(rule, index, seenIds),
      ),
    ),
  });
}

export function resolveApprovalRulesPath(options, environment) {
  return resolveTrustedPath({
    explicit: options.rulesPath,
    environment,
    envKey: "FH_APPROVAL_RULES_PATH",
    homeRelative: [".config", "frontier-harness", "approval-rules.json"],
    label: "frontier-harness approval rules",
  });
}

// baseline と追加ルールを合成し、正規表現を 1 度だけコンパイルする。
export function compileApprovalRules({ defaultDecision, additionalRules }) {
  return Object.freeze({
    defaultDecision,
    rules: Object.freeze(
      [...BASELINE_APPROVAL_RULES, ...additionalRules].map((rule) =>
        Object.freeze({ ...rule, expression: new RegExp(rule.pattern, "i") }),
      ),
    ),
  });
}

// ルールファイルは任意。無ければ baseline のみで動く。
// 逆に、在るのに壊れているときは起動を止める。静かに baseline へ縮退させると、
// user が意図して足した「より厳しいルール」が消えたまま wave が走ってしまう。
export function loadApprovalRules(options = {}, environment = process.env) {
  const rulesPath = resolveApprovalRulesPath(options, environment);
  const readFile = options.readFile ?? ((target) => readFileSync(target, "utf8"));
  let raw;
  try {
    raw = readFile(rulesPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return compileApprovalRules({
      defaultDecision: "allow",
      additionalRules: [],
    });
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new TypeError(
      `approval rules file ${rulesPath} is not valid JSON: ${error.message}`,
    );
  }
  return compileApprovalRules(normalizeApprovalRulesFile(parsed));
}

// ---------------------------------------------------------------------------
// 照合
// ---------------------------------------------------------------------------

function candidateStrings(input, field, analysis) {
  if (field === "all") return [JSON.stringify(input ?? {})];
  if (field === "paths") {
    return APPROVAL_RULE_PATH_KEYS.map((key) => input?.[key]).filter(
      (value) => typeof value === "string",
    );
  }
  // Bash の command は、生文字列に加えて「global option を読み飛ばして正規化した
  // 各セグメント」も候補にする。候補を増やす方向にしか働かないので、既存パターンの
  // 意味を変えないまま `git -C <path> merge` のような形を拾えるようになる。
  if (field === "command" && analysis !== null) return analysis.candidates;
  const value = input?.[field];
  return typeof value === "string" ? [value] : [];
}

// 戻り値は { decision: "allow" | "escalate", rule? }。
// escalate は「自動 deny」ではなく「user へ同期問い合わせする」を意味する。
export function classifyToolCall({ toolName, input }, rules) {
  // AskUserQuestion はルールの一致に関わらず必ず user へ回す。
  if (ALWAYS_ESCALATED_TOOLS.has(toolName)) {
    return { decision: "escalate", rule: ASK_USER_QUESTION_RULE };
  }
  const analysis =
    toolName === "Bash" ? analyzeShellCommand(input?.command) : null;
  for (const rule of rules.rules) {
    if (rule.tool !== "*" && rule.tool !== toolName) continue;
    for (const candidate of candidateStrings(input, rule.field, analysis)) {
      if (rule.expression.test(candidate)) {
        return { decision: "escalate", rule };
      }
    }
  }
  // 解釈できなかったコマンドを「一致しなかった」と同じ allow に倒さない。
  if (analysis?.ambiguous) {
    return { decision: "escalate", rule: OPAQUE_COMMAND_RULE };
  }
  if (rules.defaultDecision === "escalate") {
    return { decision: "escalate", rule: UNMATCHED_RULE };
  }
  return { decision: "allow" };
}
