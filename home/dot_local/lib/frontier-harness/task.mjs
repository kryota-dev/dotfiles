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

// 未指定は許すが、指定されたのに boolean でない値は loud に落とす。
// 「壊れた宣言」を「未指定」として黙って既定値へ丸めると、gate が効かなかったことに気づけない。
function optionalBoolean(value, label) {
  if (value !== undefined && typeof value !== "boolean") {
    throw new TypeError(`task.${label} must be a boolean`);
  }
  return value === true;
}

export function normalizeTask(input) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError("task must be an object");
  }
  if (typeof input.goal !== "string" || input.goal.length === 0) {
    throw new TypeError("task.goal must be a non-empty string");
  }

  return Object.freeze({
    goal: input.goal,
    modality: Object.freeze(requireStringArray(input.modality, "modality")),
    risk: Object.freeze(requireStringArray(input.risk, "risk")),
    // 未指定は「deterministic oracle 無し」= 安全側とみなし、independent review へ昇格させる。
    hasDeterministicOracle: optionalBoolean(
      input.hasDeterministicOracle,
      "hasDeterministicOracle",
    ),
    // 人の判断が必須か（#534）。承認チャネルを持たない provider へは route しない。
    //
    // **既定の向きが hasDeterministicOracle と逆である理由**: oracle は未指定を安全側
    // （oracle 無し）に倒しても reviewer が「追加」されるだけで、コストが増える方向にしか振れない。
    // 一方 requiresApproval を未指定で true に倒すと、出荷 config には approvalChannel が
    // `external` の executor が 1 つも無いため**あらゆる route が escalation になり**、軸そのものが
    // 使えなくなる。ここは宣言された要求だけを見て、安全側の担保は供給側の fail-closed
    // （provider-capabilities.mjs: 宣言を引けない provider は最弱値）に委ねる。
    requiresApproval: optionalBoolean(input.requiresApproval, "requiresApproval"),
    // 書き込みを伴うか（#534 が #536 の registry 表現分を吸収）。
    // 封じ込めを保証できない provider へは route しない。
    requiresWrite: optionalBoolean(input.requiresWrite, "requiresWrite"),
  });
}
