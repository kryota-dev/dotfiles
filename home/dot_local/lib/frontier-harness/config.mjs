const ROLLOUTS = new Set(["shadow", "pilot", "default"]);

function requireObject(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
}

function requirePositiveInteger(value, label) {
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`${label} must be a positive integer`);
  }
}

function normalizeCapability(name, capability) {
  requireObject(capability, `capabilities.${name}`);
  for (const key of ["provider", "model", "effort"]) {
    if (typeof capability[key] !== "string" || capability[key].length === 0) {
      throw new TypeError(`capabilities.${name}.${key} must be a non-empty string`);
    }
  }

  if (
    capability.accountScope !== undefined &&
    (typeof capability.accountScope !== "string" ||
      capability.accountScope.length === 0)
  ) {
    throw new TypeError(`capabilities.${name}.accountScope must be a non-empty string`);
  }

  return Object.freeze({ ...capability });
}

export function normalizeConfig(input) {
  requireObject(input, "config");
  if (input.version !== 1) {
    throw new TypeError("config.version must be 1");
  }
  if (!ROLLOUTS.has(input.rollout)) {
    throw new TypeError("config.rollout must be shadow, pilot, or default");
  }

  requireObject(input.retention, "retention");
  requirePositiveInteger(input.retention.rawArtifactsDays, "retention.rawArtifactsDays");
  requirePositiveInteger(
    input.retention.aggregateTelemetryDays,
    "retention.aggregateTelemetryDays",
  );

  requireObject(input.capabilities, "capabilities");
  const capabilities = Object.fromEntries(
    Object.entries(input.capabilities).map(([name, capability]) => [
      name,
      normalizeCapability(name, capability),
    ]),
  );
  if (!capabilities["executor.default"]) {
    throw new TypeError("capabilities.executor.default is required");
  }

  requireObject(input.risk, "risk");
  if (!Array.isArray(input.risk.alwaysEscalate)) {
    throw new TypeError("risk.alwaysEscalate must be an array");
  }

  return Object.freeze({
    version: input.version,
    rollout: input.rollout,
    retention: Object.freeze({ ...input.retention }),
    capabilities: Object.freeze(capabilities),
    risk: Object.freeze({
      alwaysEscalate: Object.freeze([...input.risk.alwaysEscalate]),
    }),
  });
}
