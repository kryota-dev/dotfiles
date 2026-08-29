import {
  defaultProviderCapabilityFacts,
  describeUnmetRequirements,
  resolveProviderCapabilities,
  unmetRequirements,
} from "./provider-capabilities.mjs";

function isAvailable(capability, availability, accountScope) {
  if (!capability) return false;
  // Object.prototype の継承プロパティ（constructor 等）を可用性として拾わない。
  if (!Object.hasOwn(availability, capability.provider)) return false;
  const entry = availability[capability.provider];
  if (!entry || entry.available !== true) return false;
  // provider が verified でも、この capability の model が検出されていなければ使えない。
  if (Array.isArray(entry.models) && !entry.models.includes(capability.model)) {
    return false;
  }
  return !capability.accountScope || capability.accountScope === accountScope;
}

// task の要求（requiresApproval / requiresWrite）を、その capability が使う provider の
// 宣言と突き合わせる。満たさない軸を「どの capability の、どの provider が、どの軸で、
// 何を要求され、何を宣言していたか」の 5 つ組で返す（#534）。
function capabilityBlockers({ capability, capabilityName, providerCapabilities, task }) {
  const declared = resolveProviderCapabilities(
    providerCapabilities,
    capability.provider,
  );
  return unmetRequirements(declared, task).map((unmet) => ({
    capability: capabilityName,
    provider: capability.provider,
    ...unmet,
  }));
}

// 遮断が無かった route に空配列を生やさない（reviewerCapability と同じ spread 規約）。
function withBlocked(blocked) {
  return blocked.length > 0 ? { blocked: Object.freeze([...blocked]) } : {};
}

function escalation(reason, blocked = []) {
  return {
    kind: "escalation",
    capability: null,
    provider: null,
    reason,
    ...withBlocked(blocked),
  };
}

function decision({
  blocked,
  capability,
  config,
  kind,
  reason,
  reviewerCapability,
}) {
  const selected = config.capabilities[capability];
  return {
    kind,
    capability,
    provider: selected.provider,
    model: selected.model,
    effort: selected.effort,
    reason,
    ...(reviewerCapability ? { reviewerCapability } : {}),
    ...withBlocked(blocked),
  };
}

export function chooseRoute({
  accountScope,
  availability,
  config,
  // provider の能力宣言は adapter registry が正本。テストから注入できるようにしつつ、
  // 既定では出荷 adapter の宣言を使う（config.json 側へ複製しない）。
  providerCapabilities = defaultProviderCapabilityFacts(),
  task,
}) {
  const risks = task.risk ?? [];
  const blockedRisk = risks.find((risk) =>
    config.risk.alwaysEscalate.includes(risk),
  );
  if (blockedRisk) {
    // risk による escalation には `blocked` を付けない。こちらは kind と reason だけで
    // 説明が閉じる（どの risk 名で escalate したかが reason に入る）のに対し、承認チャネル /
    // 書き込み可否による遮断は 5 つ組で初めて説明が閉じるため、扱いを分けている。
    return escalation(`risk ${blockedRisk} requires user escalation`);
  }

  // 塞いだ route は捨てずに持ち回る。cli.mjs がこれを evidence へ書き、
  // 「なぜその provider で走らなかったか」を後から追えるようにする。
  const blocked = [];

  const frontend = config.capabilities["frontend.primary"];
  const wantsBrowser = (task.modality ?? []).includes("browser");
  const frontendAvailable =
    wantsBrowser && isAvailable(frontend, availability, accountScope);
  let frontendBlockers = [];
  if (frontendAvailable) {
    frontendBlockers = capabilityBlockers({
      capability: frontend,
      capabilityName: "frontend.primary",
      providerCapabilities,
      task,
    });
    if (frontendBlockers.length === 0) {
      return decision({
        blocked,
        capability: "frontend.primary",
        config,
        kind: "single-worker",
        reason: "browser modality selects the available frontend provider",
      });
    }
    blocked.push(...frontendBlockers);
  }

  const executor = config.capabilities["executor.default"];
  if (!isAvailable(executor, availability, accountScope)) {
    return escalation("executor.default is unavailable", blocked);
  }

  const executorBlockers = capabilityBlockers({
    capability: executor,
    capabilityName: "executor.default",
    providerCapabilities,
    task,
  });
  if (executorBlockers.length > 0) {
    // executor.default 自身が要件を満たさないときは代替を発明しない。承認チャネルや
    // 書き込み可否を理由に capability の役割（executor / reviewer / frontend）を跨いで
    // 流用すると、registry の役割定義が壊れ、なぜその provider で走ったのかを追えなくなる。
    blocked.push(...executorBlockers);
    return escalation(
      `executor.default (${executor.provider}) does not satisfy ${describeUnmetRequirements(executorBlockers)}`,
      blocked,
    );
  }

  let reason = "default executor is available";
  if (frontendBlockers.length > 0) {
    // 既に router が持っている fallback（frontend が使えないときは executor.default）を
    // そのまま再利用する。軸のために新しい代替規則を作らない。
    reason = `frontend provider does not satisfy ${describeUnmetRequirements(frontendBlockers)}; using executor.default`;
  } else if (wantsBrowser && !frontendAvailable) {
    reason =
      "frontend provider is unavailable for this account scope; using executor.default";
  }
  const reviewer = config.capabilities["semantic.judge"];
  // AC-023: oracle の有無が確定していない task は「oracle 無し」= 安全側として扱い、
  // independent review へ昇格させる（`=== false` の厳密比較では未指定が素通りする）。
  const hasDeterministicOracle = task.hasDeterministicOracle === true;
  // reviewer には承認チャネル / 書き込み可否の軸を適用しない。reviewer は task の書き込みも
  // 人の gate も担わないため、ここで遮断すると「review を足そうとしたら escalation になった」
  // という、安全性に寄与しない後退になる。軸は task を実行する capability にだけ効かせる。
  if (
    !hasDeterministicOracle &&
    isAvailable(reviewer, availability, accountScope)
  ) {
    return decision({
      blocked,
      capability: "executor.default",
      config,
      kind: "writer-plus-reviewer",
      reason: `${reason}; no deterministic oracle requires independent review`,
      reviewerCapability: "semantic.judge",
    });
  }

  return decision({
    blocked,
    capability: "executor.default",
    config,
    kind: "single-worker",
    reason,
  });
}
