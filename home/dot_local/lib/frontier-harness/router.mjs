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

function decision({ capability, config, kind, reason, reviewerCapability }) {
  const selected = config.capabilities[capability];
  return {
    kind,
    capability,
    provider: selected.provider,
    model: selected.model,
    effort: selected.effort,
    reason,
    ...(reviewerCapability ? { reviewerCapability } : {}),
  };
}

export function chooseRoute({ accountScope, availability, config, task }) {
  const risks = task.risk ?? [];
  const blockedRisk = risks.find((risk) =>
    config.risk.alwaysEscalate.includes(risk),
  );
  if (blockedRisk) {
    return {
      kind: "escalation",
      capability: null,
      provider: null,
      reason: `risk ${blockedRisk} requires user escalation`,
    };
  }

  const frontend = config.capabilities["frontend.primary"];
  const wantsBrowser = (task.modality ?? []).includes("browser");
  if (wantsBrowser && isAvailable(frontend, availability, accountScope)) {
    return decision({
      capability: "frontend.primary",
      config,
      kind: "single-worker",
      reason: "browser modality selects the available frontend provider",
    });
  }

  const executor = config.capabilities["executor.default"];
  if (!isAvailable(executor, availability, accountScope)) {
    return {
      kind: "escalation",
      capability: null,
      provider: null,
      reason: "executor.default is unavailable",
    };
  }

  const frontendUnavailable =
    wantsBrowser && !isAvailable(frontend, availability, accountScope);
  const reason = frontendUnavailable
    ? "frontend provider is unavailable for this account scope; using executor.default"
    : "default executor is available";
  const reviewer = config.capabilities["semantic.judge"];
  // AC-023: oracle の有無が確定していない task は「oracle 無し」= 安全側として扱い、
  // independent review へ昇格させる（`=== false` の厳密比較では未指定が素通りする）。
  const hasDeterministicOracle = task.hasDeterministicOracle === true;
  if (
    !hasDeterministicOracle &&
    isAvailable(reviewer, availability, accountScope)
  ) {
    return decision({
      capability: "executor.default",
      config,
      kind: "writer-plus-reviewer",
      reason: `${reason}; no deterministic oracle requires independent review`,
      reviewerCapability: "semantic.judge",
    });
  }

  return decision({
    capability: "executor.default",
    config,
    kind: "single-worker",
    reason,
  });
}
