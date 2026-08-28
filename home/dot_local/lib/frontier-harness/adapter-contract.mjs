import path from "node:path";

import {
  TELEMETRY_EFFORTS,
  optionalInteger,
  optionalNonEmptyString,
  optionalStringArray,
  requireEnum,
  requireNonEmptyString,
  requireObject,
  requireToken,
} from "./record-validation.mjs";
import {
  describeSandboxPolicy,
  normalizeSandboxPolicy,
  sandboxPolicyEquals,
} from "./sandbox.mjs";

// adapter が守る契約。vendor 固有の知識はここに持たず、
// 「どの adapter でも成り立っていなければならないこと」だけを持つ。

// 実行結果の正規化語彙。adapter_runs の status 語彙（record-validation.mjs）とは別にする。
// 「成功と判定できない」は状態ではなく判定の結果なので、state へは fail-closed に写像する
// （#526 §3.2: Antigravity は exit 0 / status SUCCESS でも何もしていないことがある）。
export const ADAPTER_OUTCOMES = new Set(["succeeded", "failed", "indeterminate"]);

// 承認要求を外部へ往復させられるか。#526 §7.2 の実測を provider の事実として持つ。
// **ここでは記述するだけで route を塞ぐ判断はしない**（それは #534 の範囲）。
// registry（config.json）へ軸として足す作業も #534 が行うため、設定スキーマは変更しない。
export const APPROVAL_CHANNELS = new Set(["external", "agent-review", "none"]);

// サンドボックスを何が強制するか。#526 が provider ごとに実測した差。
// os = OS 強制（Seatbelt / bwrap）、settings = 設定 JSON 経由、policy = 権限ポリシー層のみ。
export const SANDBOX_ENFORCEMENTS = new Set(["os", "settings", "policy"]);

// 書き込みを伴う実行に使えるか。unenforceable は「封じ込めを保証できない」を意味する。
export const WRITE_ACCESS_LEVELS = new Set(["supported", "unenforceable"]);

export const INVOCATION_PHASES = new Set(["launch", "resume"]);

const ADAPTER_METHODS = Object.freeze([
  "launch",
  "resume",
  "readEffectiveSandbox",
  "interpret",
]);

// registry へ載せる前に adapter の形を検査する。壊れた adapter を実行直前まで運ばない。
export function assertAdapterShape(adapter) {
  requireObject(adapter, "adapter");
  requireToken(adapter.provider, "adapter provider");
  const label = `adapter ${adapter.provider}`;
  requireObject(adapter.capabilities, `${label} capabilities`);
  requireEnum(
    adapter.capabilities.approvalChannel,
    APPROVAL_CHANNELS,
    `${label} capabilities.approvalChannel`,
  );
  requireEnum(
    adapter.capabilities.sandboxEnforcement,
    SANDBOX_ENFORCEMENTS,
    `${label} capabilities.sandboxEnforcement`,
  );
  requireEnum(
    adapter.capabilities.writeAccess,
    WRITE_ACCESS_LEVELS,
    `${label} capabilities.writeAccess`,
  );
  requireNonEmptyString(
    adapter.capabilities.resumeKey,
    `${label} capabilities.resumeKey`,
  );
  for (const method of ADAPTER_METHODS) {
    if (typeof adapter[method] !== "function") {
      throw new TypeError(`${label} must implement ${method}()`);
    }
  }
  return adapter;
}

// capability registry が持つ model / effort を、vendor のコマンドラインへ載せる前に検査する。
//
// Codex は effort と model を `-c key=value` の**値の中へ**埋め込むため、区切り文字を含む値は
// 別の設定キー（たとえば sandbox_mode）を注入しうる。requireToken のパターン
// `/^[a-z][a-z0-9._-]*$/` は引用符・等号・空白を弾くので、この経路をそのまま塞ぐ。
//
// effort は record-validation.mjs の TELEMETRY_EFFORTS を再利用する。これはリポジトリが既に
// 出荷している唯一の effort 語彙で、ここに 2 つ目を作ると drift する（provider ごとの受理値は
// #526 でも未実測なので、provider 別の集合は宣言しない）。
export function requireCapabilityTokens({ model, effort }, label) {
  requireToken(model, `${label} model`);
  requireToken(effort, `${label} effort`);
  requireEnum(effort, TELEMETRY_EFFORTS, `${label} effort`);
  return { model, effort };
}

// argv へ載る「provider が発行した識別子」や外部から渡る名前の検証。
//
// model / effort は requireToken（`/^[a-z][a-z0-9._-]*$/`）で縛れるが、resume 識別子
// （UUID や thread 名）と MCP ツール名（`mcp__fh__approve` のようにアンダースコアを含む）は
// それより広い文字種を取る。一方で **argv に載る以上、フラグとして再解釈されうる値**
// （先頭の `-`）と、`-c key=value` の構造を壊す値（引用符・等号・空白・制御文字）は
// 許してはならない。位置引数として渡る Codex の session id では、これが直接
// フラグ注入になる（`resume("--full-auto")` が argv の session id 位置に載る）。
export const SAFE_ARGUMENT_PATTERN = /^[A-Za-z0-9][\w.-]*$/;
// UUID は 36 文字。thread 名やツール名も短い。長大な値は argv 経由の詰め込みを疑う。
export const SAFE_ARGUMENT_MAX_LENGTH = 128;

export function requireSafeArgumentValue(value, label) {
  requireNonEmptyString(value, label);
  if (value.length > SAFE_ARGUMENT_MAX_LENGTH) {
    throw new TypeError(
      `${label} must be at most ${SAFE_ARGUMENT_MAX_LENGTH} characters`,
    );
  }
  if (!SAFE_ARGUMENT_PATTERN.test(value)) {
    throw new TypeError(`${label} must match ${SAFE_ARGUMENT_PATTERN}`);
  }
  return value;
}

// 起動形・再開形のどちらの入口でも共通に要る値。adapter 固有の追加値（session id や
// permission prompt tool）は各 adapter が自分で検証する。
export function requireInvocationRequest(input, label) {
  requireObject(input, label);
  const prompt = requireNonEmptyString(input.prompt, `${label} prompt`);
  const { model, effort } = requireCapabilityTokens(input, label);
  // argv を組む**前**に policy を確定させる。後回しにすると、sandbox が欠けた要求が
  // 「argv[3] が空文字」のような別レイヤのエラーになり、原因が読めなくなる。
  const sandbox = normalizeSandboxPolicy(input.sandbox, `${label} sandbox`);
  return { prompt, model, effort, sandbox };
}

// 起動形・再開形のどちらを作るときも必ずここを通す。
//
// **要件 2 の中核**: 生成した argv から実効サンドボックスを読み戻し、要求した policy と
// 一致しなければ throw する。「初回だけ pin して再開で弱まる」退行は、テストを待たずに
// その invocation を作った瞬間に失敗する。
export function sealInvocation({
  provider,
  executable,
  argv,
  stdin = null,
  phase,
  sandbox,
  readEffectiveSandbox,
}) {
  requireToken(provider, "invocation provider");
  requireEnum(phase, INVOCATION_PHASES, "invocation phase");
  requireNonEmptyString(executable, "invocation executable");
  // PATH の空要素由来の相対パスを起動しないのと同じ理由（cli.mjs / readiness.mjs）で、
  // 実行ファイルは絶対パスに限る。相対パスは CWD 基準で解決され、untrusted repository が
  // 同梱した実行ファイルを provider として選びうる。
  if (!path.isAbsolute(executable)) {
    throw new TypeError("invocation executable must be an absolute path");
  }
  if (!Array.isArray(argv)) {
    throw new TypeError("invocation argv must be an array");
  }
  argv.forEach((value, index) =>
    requireNonEmptyString(value, `invocation argv[${index}]`),
  );
  if (typeof readEffectiveSandbox !== "function") {
    throw new TypeError("invocation requires a readEffectiveSandbox reader");
  }
  const policy = normalizeSandboxPolicy(sandbox, `${provider} ${phase} sandbox`);

  // credential・プロファイルパス・環境変数を運ぶキーを構造として持たない。
  // 認証は各 CLI のランチャーと keychain が持ち、adapter は触れない。
  const invocation = Object.freeze({
    provider,
    executable,
    argv: Object.freeze([...argv]),
    stdin: stdin === null ? null : requireNonEmptyString(stdin, "invocation stdin"),
    phase,
  });

  const effective = readEffectiveSandbox(invocation);
  if (!sandboxPolicyEquals(effective, policy)) {
    throw new Error(
      `${provider} ${phase} invocation would run under ${describeSandboxPolicy(effective)} ` +
        `instead of the requested ${describeSandboxPolicy(policy)}`,
    );
  }
  return invocation;
}

// 構造化出力は JSONL でも単一 JSON でも来る。壊れた行の件数は捨てずに返す:
// 「終端イベントが見つからなかった」理由が truncation なのかを呼び出し側が言い分けられる。
export function parseJsonLines(text) {
  const events = [];
  let malformed = 0;
  for (const line of String(text ?? "").split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
        events.push(parsed);
      } else {
        malformed += 1;
      }
    } catch {
      malformed += 1;
    }
  }
  return { events, malformed };
}

// failure_reason は provider 由来の生メッセージを運ぶ。denials からツール入力を落としたのと
// 同じ配慮を長さにも効かせる（保持期間のある state へ、際限なく provider の出力を流し込まない）。
// 長い理由で結果ごと失うより切り詰めるほうが有用なので、throw ではなく truncate する。
export const FAILURE_REASON_MAX_LENGTH = 512;

function boundedFailureReason(value, label) {
  const reason = optionalNonEmptyString(value, label);
  if (reason === null || reason.length <= FAILURE_REASON_MAX_LENGTH) return reason;
  return `${reason.slice(0, FAILURE_REASON_MAX_LENGTH - 1)}\u2026`;
}

// adapter が返す結果の正規化。adapter ごとに形が揺れると、下流の写像がすべて壊れる。
export function normalizeAdapterResult(input, label) {
  requireObject(input, `${label} result`);
  return Object.freeze({
    outcome: requireEnum(input.outcome, ADAPTER_OUTCOMES, `${label} result outcome`),
    // provider 非依存の「再開キー」1 本にする（#526 §7.3-1）。
    // session_id / thread id / conversation_id の別は adapter の内側に閉じる。
    resumeKey: optionalNonEmptyString(input.resumeKey, `${label} result resumeKey`),
    failureReason: boundedFailureReason(
      input.failureReason,
      `${label} result failureReason`,
    ),
    // 拒否された操作は**ツール名だけ**を持つ。ツールの入力（コマンド文字列やファイル内容）は
    // credential を含みうるので運ばない（#526 §7.3-3 が求めるのは「gate に当たった事実」）。
    denials: Object.freeze(optionalStringArray(input.denials, `${label} result denials`)),
    exitCode: optionalInteger(input.exitCode, `${label} result exitCode`),
  });
}

// 「成功と判定できない」を成功として記録しないための fail-closed 写像。
// adapter_runs の status 語彙（planned / running / succeeded / failed / cancelled）に
// 新しい値を足さずに、判定不能を failureReason 付きの failed として残す。
const OUTCOME_STATUSES = Object.freeze({
  succeeded: "succeeded",
  failed: "failed",
  indeterminate: "failed",
});

export function adapterRunStatusFor(outcome) {
  // Object.prototype の継承プロパティ（constructor 等）を状態として拾わない。
  if (typeof outcome !== "string" || !Object.hasOwn(OUTCOME_STATUSES, outcome)) {
    throw new TypeError(
      `adapter outcome must be one of: ${[...ADAPTER_OUTCOMES].sort().join(", ")}`,
    );
  }
  return OUTCOME_STATUSES[outcome];
}

// 実行結果を adapter_runs のレコード入力へ落とす。
//
// argv・サンドボックス設定・再開キー・拒否一覧は**意図的に落とす**。adapter_runs は
// 起動方式に属する列を持たない設計（#492）で、起動方式は #526 の結論で変わりうるからである。
// 「その実行で有効だったサンドボックス」と拒否一覧は evidence 側が持つべき項目なので、
// 実行結果には残したままレコード入力からだけ外す。
export function toAdapterRunInput(execution, { taskId, routeId }) {
  requireObject(execution, "adapter execution");
  if (execution.ranProvider !== true) {
    throw new TypeError(
      "a refused execution never started a provider and has no adapter run to record",
    );
  }
  return {
    taskId: requireNonEmptyString(taskId, "adapter run taskId"),
    routeId: requireNonEmptyString(routeId, "adapter run routeId"),
    capability: execution.capability,
    provider: execution.provider,
    model: execution.model,
    effort: execution.effort,
    status: adapterRunStatusFor(execution.outcome),
    startedAt: execution.startedAt,
    finishedAt: execution.finishedAt,
    exitCode: execution.exitCode,
    failureReason: execution.failureReason,
  };
}
