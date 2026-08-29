// task JSON は agent が生成する未検証入力として扱い、境界で正規化する。
// 未指定の安全側フォールバック（oracle 無し扱い）と、呼び出し側による id 上書きの遮断を担う。
function requireStringArray(value, label) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    throw new TypeError(`task.${label} must be an array`);
  }
  for (const entry of value) {
    if (typeof entry !== "string" || entry.length === 0) {
      throw new TypeError(`task.${label} entries must be non-empty strings`);
    }
  }
  return [...value];
}

export function normalizeTask(input) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError("task must be an object");
  }
  if (typeof input.goal !== "string" || input.goal.length === 0) {
    throw new TypeError("task.goal must be a non-empty string");
  }
  if (
    input.hasDeterministicOracle !== undefined &&
    typeof input.hasDeterministicOracle !== "boolean"
  ) {
    throw new TypeError("task.hasDeterministicOracle must be a boolean");
  }

  return Object.freeze({
    goal: input.goal,
    modality: Object.freeze(requireStringArray(input.modality, "modality")),
    risk: Object.freeze(requireStringArray(input.risk, "risk")),
    // task が実行を要求する command / domain。承認済み repository capability manifest との
    // 照合対象になる（#494）。未指定は「何も要求しない」= 空配列で、承認済み manifest が
    // 何であっても照合を通る。宣言しないことで照合を免れるわけではない —— 宣言しなかった
    // command を実際に走らせる経路そのものが、承認境界の外側として塞がれる。
    commands: Object.freeze(requireStringArray(input.commands, "commands")),
    domains: Object.freeze(requireStringArray(input.domains, "domains")),
    // 未指定は「deterministic oracle 無し」= 安全側とみなし、independent review へ昇格させる。
    hasDeterministicOracle: input.hasDeterministicOracle === true,
  });
}
