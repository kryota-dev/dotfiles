import { readFileSync } from "node:fs";

import { rejectUnknownKeys, requireObject } from "./record-validation.mjs";
import { resolveTrustedPath } from "./trusted-path.mjs";

// 承認チャネルの escalation ルール（deny ルール）。
//
// このファイルが repository capability manifest（<repo>/.harness/policy.json、#494）と
// 別に存在するのは、失敗の方向が逆だからである。manifest の漏れは fail-closed
// （実行できない）で気づけるが、escalation ルールの漏れは fail-open（人に聞かずに
// 実行される）で気づけない。同居させるとこの非対称が見えなくなる。
//
// したがって baseline は「コード内の定数」として持ち、ファイルからは追加しかできない。
// ルールファイルが存在しない・読めないときでも baseline は完全に有効である。

// ---------------------------------------------------------------------------
// 正規表現の部品
// ---------------------------------------------------------------------------

// シェルのコマンド境界。行頭、または空白 / 区切り記号の直後。
const SHELL_BOUNDARY = String.raw`[\s;&|(){}<>$"'\x60]`;
// 直前の境界 + 省略可能なパス接頭辞。`/usr/bin/git` や `./bin/gh` も拾い、
// `mygit` のような別コマンドは拾わない。
const COMMAND_PREFIX = String.raw`(?:^|${SHELL_BOUNDARY})(?:[\w.~/-]*/)?`;
// 語の終端。`git merge` は拾い、`git merge-base` / `git mergetool` は拾わない。
const WORD_END = String.raw`(?![\w-])`;
// コマンドの後ろに任意個の引数が挟まりうる形。次のコマンドまで越えないよう区切りを除外する。
const SAME_COMMAND = String.raw`[^;&|\n]*?`;
// パス文字列の中の要素境界。`/home/u/.ssh/id_rsa` は拾い、`foo.ssh` は拾わない。
const PATH_BOUNDARY = String.raw`(?:^|[^\w.-])`;

// `<binary> <subcommand>` の形。dashed 形式（`git-merge`）も同時に拾う。
function commandPattern(binaries, subcommand) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})[\s-]+(?:${subcommand})${WORD_END}`;
}

// `<binary> <subcommand> ... <flag>` の形。flag は引数のどこに現れてもよい。
function subcommandFlagPattern(binaries, subcommand, flags) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})[\s-]+(?:${subcommand})${WORD_END}${SAME_COMMAND}\s(?:${flags})(?:[\s=]|$)`;
}

// `<binary> ... <flag>` の形（subcommand を取らないコマンド用）。
function commandFlagPattern(binaries, flags) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})${WORD_END}${SAME_COMMAND}\s(?:${flags})(?:[\s=]|$)`;
}

function anyOf(...patterns) {
  return patterns.join("|");
}

// ---------------------------------------------------------------------------
// 語彙
// ---------------------------------------------------------------------------

// risk 語彙。前半 6 つは config.risk.alwaysEscalate と共有する値であり、
// 後半は承認チャネル固有のカテゴリである（router の escalation とは粒度が違うため、
// config 側の列挙をここで書き換えることはしない）。
export const APPROVAL_RISKS = Object.freeze(
  new Set([
    "credential",
    "deploy",
    "force-push",
    "merge",
    "migration",
    "release",
    "approval-channel",
    "external-publish",
    "history-rewrite",
    "unmatched",
    "user-question",
    "working-tree-rollback",
  ]),
);

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

export const UNMATCHED_RULE = Object.freeze({
  id: "unmatched-default-escalate",
  risk: "unmatched",
  tool: "*",
  field: "-",
  pattern: null,
  reason: "ルールファイルが defaultDecision: escalate を宣言している",
});

// ---------------------------------------------------------------------------
// baseline ルール（コード内定数。ファイルから削除できない）
// ---------------------------------------------------------------------------

export const BASELINE_APPROVAL_RULES = Object.freeze(
  [
    {
      id: "git-merge",
      risk: "merge",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("git", "merge"),
      reason: "マージは gate を経ずに実行しない",
    },
    {
      id: "gh-pr-merge",
      risk: "merge",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("gh", String.raw`pr[\s-]+merge`),
      reason: "PR のマージは user の判断",
    },
    {
      id: "git-force-push",
      risk: "force-push",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern(
        "git",
        "push",
        String.raw`--force(?:-with-lease|-if-includes)?|-f`,
      ),
      reason: "強制 push は他者の履歴を壊しうる",
    },
    {
      id: "git-delete-remote-ref",
      risk: "force-push",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        subcommandFlagPattern("git", "push", String.raw`--delete|-d`),
        String.raw`${COMMAND_PREFIX}git[\s-]+push${WORD_END}${SAME_COMMAND}\s:`,
      ),
      reason: "リモート参照の削除は取り消せない",
    },
    {
      id: "git-history-rewrite",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "git",
        String.raw`rebase|filter-branch|filter-repo|reflog[\s-]+(?:expire|delete)|update-ref[\s-]+-d`,
      ),
      reason: "履歴の書き換えは取り消せない",
    },
    {
      id: "git-amend",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "commit", String.raw`--amend`),
      reason: "既存コミットの書き換えは履歴を変える",
    },
    {
      id: "git-hard-reset",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "reset", String.raw`--hard`),
      reason: "hard reset は未コミットの作業を失わせる",
    },
    {
      id: "git-branch-delete",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "branch", String.raw`-[dD]|--delete`),
      reason: "ブランチの削除は取り消しに手間がかかる",
    },
    {
      id: "git-worktree-rollback",
      risk: "working-tree-rollback",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("git", "restore|stash"),
        String.raw`${COMMAND_PREFIX}git[\s-]+checkout[\s-]+--\s`,
        subcommandFlagPattern("git", "clean", String.raw`-[a-zA-Z]*f[a-zA-Z]*`),
      ),
      reason:
        "共有作業ツリーの巻き戻しは他セッションの未コミット編集を静かに消す（#524）",
    },
    {
      id: "gh-release",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "gh",
        String.raw`release[\s-]+(?:create|edit|delete|upload)`,
      ),
      reason: "リリースは外部に公開される",
    },
    {
      id: "package-publish",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("npm|pnpm|yarn|bun|uv", "publish"),
        commandPattern("cargo", "publish"),
        commandPattern("gem", "push"),
        commandPattern("twine", "upload"),
        commandPattern("docker|podman", "push"),
      ),
      reason: "パッケージの公開は取り消せない",
    },
    {
      id: "git-push-tags",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern(
        "git",
        "push",
        String.raw`--tags|--follow-tags`,
      ),
      reason: "タグの push はリリース手順の起点になりうる",
    },
    {
      id: "gh-external-write",
      risk: "external-publish",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "gh",
        String.raw`pr[\s-]+(?:create|ready|comment|review|edit|close|reopen)|issue[\s-]+(?:create|comment|edit|close|reopen)|repo[\s-]+(?:create|delete|edit)|workflow[\s-]+run`,
      ),
      reason: "GitHub への書き込みは外部に見える",
    },
    {
      id: "gh-api-write",
      risk: "external-publish",
      tool: "Bash",
      field: "command",
      pattern: String.raw`${COMMAND_PREFIX}gh[\s-]+api${WORD_END}${SAME_COMMAND}\s(?:-X|--method)[\s=]*(?:POST|PUT|PATCH|DELETE)${WORD_END}`,
      reason: "GitHub API への書き込みは外部に見える",
    },
    {
      id: "http-write",
      risk: "external-publish",
      tool: "Bash",
      field: "command",
      pattern: commandFlagPattern(
        "curl|wget|http|xh",
        String.raw`-X[\s=]*(?:POST|PUT|PATCH|DELETE)|--request[\s=]*(?:POST|PUT|PATCH|DELETE)|--data(?:-raw|-binary|-urlencode|-ascii)?|-d|--upload-file|-T|--form|-F`,
      ),
      reason: "外部への送信は取り消せない",
    },
    {
      id: "credential-command",
      risk: "credential",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("op", "read|item|signin|inject|document"),
        commandPattern(
          "security",
          String.raw`find-generic-password|find-internet-password|dump-keychain`,
        ),
        String.raw`${COMMAND_PREFIX}gh[\s-]+auth[\s-]+token${WORD_END}`,
        commandPattern("aws", "sts"),
        commandPattern("gcloud", "auth"),
      ),
      reason: "資格情報の読み出しは user の判断",
    },
    {
      id: "credential-path-command",
      risk: "credential",
      tool: "Bash",
      field: "command",
      pattern: credentialPathPattern(),
      reason: "資格情報を含むパスへのアクセスは user の判断",
    },
    {
      id: "credential-path-argument",
      risk: "credential",
      tool: "*",
      field: "paths",
      pattern: credentialPathPattern(),
      reason: "資格情報を含むパスへのアクセスは user の判断",
    },
    {
      id: "infrastructure-deploy",
      risk: "deploy",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("terraform|tofu", "apply|destroy"),
        commandPattern("kubectl", "apply|delete|rollout|patch|replace"),
        commandPattern("helm", "install|upgrade|uninstall|rollback"),
        commandPattern("flyctl|fly", "deploy"),
        commandPattern("wrangler", "deploy|publish"),
        commandPattern("serverless|sls", "deploy"),
        commandPattern("vercel", "deploy"),
        commandFlagPattern("vercel", String.raw`--prod`),
        String.raw`${COMMAND_PREFIX}(?:gcloud|aws|az)[\s-]+${SAME_COMMAND}\sdeploy${WORD_END}`,
      ),
      reason: "デプロイは外部環境を変える",
    },
    {
      id: "chezmoi-apply",
      risk: "deploy",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("chezmoi", "apply|init|update|destroy|forget"),
      reason: "chezmoi apply はワークツリーの外（HOME）を書き換える",
    },
    {
      id: "database-migration",
      risk: "migration",
      tool: "Bash",
      field: "command",
      pattern: String.raw`${COMMAND_PREFIX}(?:prisma[\s-]+migrate|(?:rails|rake)[\s-]+db:migrate|alembic[\s-]+(?:upgrade|downgrade)|drizzle-kit[\s-]+(?:push|migrate)|supabase[\s-]+db[\s-]+(?:push|reset)|sqlx[\s-]+migrate|atlas[\s-]+migrate[\s-]+apply|knex[\s-]+migrate|artisan[\s-]+migrate|goose[\s-]+(?:up|down)|flyway[\s-]+(?:migrate|clean)|dbmate[\s-]+(?:up|down))${WORD_END}`,
      reason: "マイグレーションはデータを不可逆に変える",
    },
    {
      id: "approval-channel-command",
      risk: "approval-channel",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        approvalChannelPathPattern(),
        String.raw`${COMMAND_PREFIX}(?:fh|frontier-harness)[\s-]+approve`,
      ),
      reason: "承認チャネル自身への書き込みは自己承認を成立させうる",
    },
    {
      id: "approval-channel-argument",
      risk: "approval-channel",
      tool: "*",
      field: "paths",
      pattern: approvalChannelPathPattern(),
      reason: "承認チャネル自身への書き込みは自己承認を成立させうる",
    },
  ].map((rule) => Object.freeze(rule)),
);

// 資格情報が入るパス。関数にしているのは、同じ表現を 2 つのルール
// （Bash のコマンド文字列と、任意ツールのパス引数）が共有するため。
function credentialPathPattern() {
  return anyOf(
    String.raw`${PATH_BOUNDARY}\.(?:ssh|aws|gnupg|docker|kube)/`,
    String.raw`${PATH_BOUNDARY}id_(?:rsa|dsa|ecdsa|ed25519)${WORD_END}`,
    String.raw`${PATH_BOUNDARY}\.netrc${WORD_END}`,
    String.raw`${PATH_BOUNDARY}\.env(?:\.[\w-]+)?${WORD_END}`,
  );
}

function approvalChannelPathPattern() {
  return String.raw`frontier-harness[\\/]approvals|\.answer\.json${WORD_END}`;
}

const BASELINE_RULE_IDS = new Set(
  BASELINE_APPROVAL_RULES.map((rule) => rule.id),
);

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

function candidateStrings(input, field) {
  if (field === "all") return [JSON.stringify(input ?? {})];
  if (field === "paths") {
    return APPROVAL_RULE_PATH_KEYS.map((key) => input?.[key]).filter(
      (value) => typeof value === "string",
    );
  }
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
  for (const rule of rules.rules) {
    if (rule.tool !== "*" && rule.tool !== toolName) continue;
    for (const candidate of candidateStrings(input, rule.field)) {
      if (rule.expression.test(candidate)) {
        return { decision: "escalate", rule };
      }
    }
  }
  if (rules.defaultDecision === "escalate") {
    return { decision: "escalate", rule: UNMATCHED_RULE };
  }
  return { decision: "allow" };
}
