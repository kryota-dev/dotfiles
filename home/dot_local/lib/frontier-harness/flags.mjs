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

// ページングの offset は 0 が正当な値なので、positiveIntegerFlag では表せない。
export function nonNegativeIntegerFlag(flags, name) {
  const raw = optionalFlagValue(flags, name);
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new TypeError(`${name} must be a non-negative integer`);
  }
  return value;
}

// 同じフラグを複数回渡せる形。`flagValue` は最初の 1 件しか見ないので、繰り返しを黙って
// 捨ててしまう（`--gate a --gate b` が a だけになる）。宣言が 1 つ落ちた gate は
// 「宣言したのに検証されなかった条件」になるので、取りこぼしを沈黙で済ませない。
export function repeatedFlagValues(flags, name) {
  const values = [];
  for (let index = 0; index < flags.length; index += 1) {
    if (flags[index] !== name) continue;
    const value = flags[index + 1];
    // 後続のフラグを値として受け取らない（flagValue と同じ規約）。
    if (!value || value.startsWith("--")) {
      throw new TypeError(`${name} requires a value`);
    }
    values.push(value);
    index += 1;
  }
  return values;
}
