// rollout policy を「出力に載せる値」ではなく「実行を止めるガード」として消費する。
// provider adapter が未実装であることに shadow の安全性を依存させないための境界。
const SHADOW = "shadow";

export function isProviderExecutionAllowed(config) {
  return config.rollout !== SHADOW;
}

export function assertProviderExecutionAllowed(config, context) {
  if (!isProviderExecutionAllowed(config)) {
    throw new Error(`shadow rollout forbids provider execution for ${context}`);
  }
}

// executor が渡されていても、shadow の間は呼び出さない。
// Step 4 で adapter を実装する際、この関数を経由させることで
// 「ガードを書き忘れて provider が起動する」経路を構造的に塞ぐ。
export function runWithRolloutGuard(config, context, executor) {
  if (!isProviderExecutionAllowed(config)) {
    return {
      executed: false,
      reason: `shadow rollout records ${context} without provider execution`,
    };
  }
  if (typeof executor !== "function") {
    return {
      executed: false,
      reason: `provider adapter for ${context} is not implemented yet`,
    };
  }
  assertProviderExecutionAllowed(config, context);
  return { executed: true, result: executor() };
}
