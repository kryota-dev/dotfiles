// CLI フラグの読み出し。cli.mjs と approval-commands.mjs が共有する。

export function flagValue(flags, name) {
  const index = flags.indexOf(name);
  const value = index === -1 ? undefined : flags[index + 1];
  // 後続のフラグを値として受け取らない（`--task --json` の誤解釈を防ぐ）。
  if (!value || value.startsWith("--")) {
    throw new TypeError(`${name} requires a value`);
  }
  return value;
}

// 指定されていなければ undefined。指定されていれば flagValue と同じ検証を通す。
export function optionalFlagValue(flags, name) {
  if (!flags.includes(name)) return undefined;
  return flagValue(flags, name);
}

export function positiveIntegerFlag(flags, name) {
  const raw = optionalFlagValue(flags, name);
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive integer`);
  }
  return value;
}
