// provider 非依存の sandbox policy。
//
// 3 provider は指定の形がまったく違う（Claude は設定 JSON、Codex は起動フラグと再開時の
// config override、Antigravity は権限ポリシー層）。呼び出し側が扱う値をここで 1 つに揃え、
// 起動形と再開形の両方を「同じ policy から描画する」形にするのが目的である。
//
// 語彙を 2 値に絞る理由:
//
// - **「サンドボックス無し」に相当する値を持たない。** 持てば、再開形がそこへ落ちる経路が
//   できる。#526 §2.3 が名指しした「初回だけ pin して再開で弱まる」退行の入口そのものになる。
// - **ネットワーク許可を軸にしない。** 許可リストの記法は #526 でも実測されていない。
//   値だけ作ると「効いていない設定を効いているつもりで記録する」ことになるので、
//   3 adapter ともネットワークを閉じた形だけを描画する（許可の実装は #535 / #502）。
export const SANDBOX_MODES = Object.freeze(["read-only", "workspace-write"]);

const MODE_SET = new Set(SANDBOX_MODES);

export function normalizeSandboxPolicy(input, label = "sandbox policy") {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError(`${label} must be an object`);
  }
  // 未知キーを黙って捨てると、呼び出し側は「指定したつもり」のまま素通りする。
  const unknownKey = Object.keys(input).find((key) => key !== "mode");
  if (unknownKey) {
    throw new TypeError(`${label} contains an unsupported key: ${unknownKey}`);
  }
  if (!MODE_SET.has(input.mode)) {
    throw new TypeError(`${label}.mode must be one of: ${SANDBOX_MODES.join(", ")}`);
  }
  return Object.freeze({ mode: input.mode });
}

// argv から読み戻した実効値は「読み取れなかった」を表すため null になりうる。
// null 同士を一致とみなすと、両方読み取れない adapter が検査を素通りする。
export function sandboxPolicyEquals(a, b) {
  if (!a || !b) return false;
  return a.mode === b.mode;
}

export function describeSandboxPolicy(policy) {
  if (!policy || typeof policy.mode !== "string") return "an unreadable sandbox";
  return policy.mode;
}

export function allowsWrite(policy) {
  return policy?.mode === "workspace-write";
}
