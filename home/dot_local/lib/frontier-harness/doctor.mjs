function providerCommand(provider) {
  return {
    antigravity: "antigravity",
    claude: "claude",
    codex: "codex",
  }[provider];
}

export function createDoctorReport({
  accountScope,
  commandPaths,
  config,
  verifiedProviders = [],
}) {
  const verified = new Set(verifiedProviders);
  const capabilities = Object.fromEntries(
    Object.entries(config.capabilities).map(([name, capability]) => {
      const command = providerCommand(capability.provider);
      const executable = commandPaths[capability.provider] ?? null;
      if (!executable) {
        return [
          name,
          {
            status: "unavailable",
            reason: `${command} executable is unavailable`,
          },
        ];
      }
      if (
        capability.accountScope &&
        capability.accountScope !== accountScope
      ) {
        return [
          name,
          {
            status: "unavailable",
            reason: `account scope ${accountScope} does not have a ${capability.accountScope} mapping`,
          },
        ];
      }
      if (capability.provider === "antigravity" && !verified.has("antigravity")) {
        return [
          name,
          {
            status: "unverified",
            reason: "authentication and model availability have not been probed",
          },
        ];
      }
      return [
        name,
        {
          status: "available",
          executable,
          model: capability.model,
          effort: capability.effort,
        },
      ];
    }),
  );

  return {
    accountScope,
    rollout: config.rollout,
    capabilities,
  };
}
