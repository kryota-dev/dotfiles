import { providerCommand } from "./providers.mjs";

export function createDoctorReport({
  accountScope,
  commandPaths,
  config,
  verifiedModels = {},
}) {
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
      if (capability.provider === "antigravity") {
        const models = Object.hasOwn(verifiedModels, "antigravity")
          ? verifiedModels.antigravity
          : null;
        if (!Array.isArray(models) || models.length === 0) {
          return [
            name,
            {
              status: "unverified",
              reason: "authentication and model availability have not been probed",
            },
          ];
        }
        // AC-038: exact model ID の availability を検査する。
        // provider が verified でも、設定した model が discovery 結果に無ければ使えない。
        if (!models.includes(capability.model)) {
          return [
            name,
            {
              status: "unverified",
              reason: `${command} model discovery did not report ${capability.model}`,
            },
          ];
        }
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
