function isAvailable(capability, availability, accountScope) {
  if (!capability || !availability[capability.provider]) {
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
  if (
    task.hasDeterministicOracle === false &&
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
