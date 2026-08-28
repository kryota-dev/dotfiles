import { createHash } from "node:crypto";

// canonical JSON と SHA-256 の唯一の実装。
// 以前は cli.mjs だけが approval hash 用に持っていたが、evidence の content hash も
// 同じ正規化を必要とする。実装を 2 箇所に分けると、片方だけキー順の扱いが変わったときに
// 「同じ内容なのに hash が違う」という静かな不整合が生まれる。

// オブジェクトのキー順に依存しない表現へ畳む。配列は順序自体が内容なので保持する。
export function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

export function sha256Hex(value) {
  return createHash("sha256")
    .update(JSON.stringify(canonicalize(value)))
    .digest("hex");
}

// sha256Hex の出力形。外部から受け取った hash を境界で検査するために使う。
export const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/;
