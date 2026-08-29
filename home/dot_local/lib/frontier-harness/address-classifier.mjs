import { isIP } from "node:net";
import { lookup as dnsLookup } from "node:dns/promises";

// manifest の domain を「ホスト名の形をしているか」ではなく **アドレス** で判定する。
//
// 形式検査だけでは、公開名に見える文字列がクラウドのメタデータ用エンドポイントへ到達する経路を
// 塞げない。塞ぐべき経路は 2 つあり、必要な判定が異なる:
//
//   1. リテラルの偽装 —— `2852039166` / `0251.0376.0251.0376` / `0xA9FEA9FE` / `169.254.43518` は
//      いずれも inet_aton の解釈で 169.254.169.254 になる。ホスト名の正規表現はこれらを
//      「ドットで区切られたラベル」または「単なる文字列」として通してしまう。
//   2. 名前による間接参照 —— 公開 DNS 名の A レコードが内部アドレスを指す。これはリテラルを
//      いくら厳しく見ても捕まらず、**解決してから**判定するしかない。
//
// よってこのファイルは (1) を同期の純関数で、(2) を注入可能な resolver 越しの非同期関数で扱う。
// resolver を注入可能にしているのは、テストをネットワークに依存させないため。

// 明示的に許可する loopback。**リテラル指定のときだけ**許可し、解決結果には適用しない
// （公開名が loopback へ解決する擦り替えを塞ぐため）。ローカル開発サーバは正当な用途なので、
// loopback 全体を拒否はしない。
export const ALLOWED_LOOPBACK_LITERALS = Object.freeze(
  new Set(["localhost", "127.0.0.1", "::1"]),
);

// メタデータ用エンドポイントのホスト名。IP は下の range 表が拾うが、名前で書かれた場合に
// 解決前の段階で落とせるようにしておく。
export const DENIED_HOSTNAMES = Object.freeze(
  new Set(["metadata.google.internal", "metadata.goog", "instance-data"]),
);

// `.internal` は ICANN が私用向けに予約した TLD で、クラウドの内部ゾーンがここに載る
// （`instance-data.ec2.internal` 等）。個別列挙では追い切れないので接尾辞で落とす。
// `.local`（mDNS）は含めない —— メタデータ用エンドポイントではなく、開発環境で正当に使われる。
export const DENIED_HOSTNAME_SUFFIXES = Object.freeze([".internal"]);

// ホスト名 1 ラベルの形。長さ 63 以内、先頭末尾がハイフンでない。
const HOSTNAME_LABEL = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
const MAX_HOSTNAME_LENGTH = 253;

function strictIpv4Parts(text) {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  const bytes = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const value = Number(part);
    if (value > 255) return null;
    bytes.push(value);
  }
  return bytes;
}

// inet_aton の解釈をそのまま再現する。1〜4 個の部分を取り、各部分は 10 進 / 8 進（先頭 0）/
// 16 進（先頭 0x）で書ける。部分が 4 個未満のとき、最後の部分が残りのオクテットすべてを占める
// （`169.254.43518` の `43518` が下位 16bit になるのはこの規則）。
export function parseIpv4Loose(text) {
  if (typeof text !== "string" || text.length === 0) return null;
  // 末尾ドットや空ラベルを inet_aton 側の解釈に委ねない。
  if (text.startsWith(".") || text.endsWith(".") || text.includes("..")) return null;
  const parts = text.split(".");
  if (parts.length > 4) return null;

  const values = [];
  for (const part of parts) {
    let value;
    if (/^0[xX][0-9a-fA-F]+$/.test(part)) {
      value = Number.parseInt(part.slice(2), 16);
    } else if (/^0[0-7]*$/.test(part)) {
      value = Number.parseInt(part, 8);
    } else if (/^[1-9][0-9]*$/.test(part)) {
      value = Number.parseInt(part, 10);
    } else {
      return null;
    }
    if (!Number.isSafeInteger(value) || value < 0) return null;
    values.push(value);
  }

  // 最後以外は 1 オクテット。最後は残りすべてを占める。
  const trailingOctets = 4 - (values.length - 1);
  const trailingMax = 2 ** (8 * trailingOctets) - 1;
  for (let index = 0; index < values.length - 1; index += 1) {
    if (values[index] > 255) return null;
  }
  const last = values.at(-1);
  if (last > trailingMax) return null;

  let result = last;
  for (let index = values.length - 2; index >= 0; index -= 1) {
    result += values[index] * 2 ** (8 * (4 - 1 - index));
  }
  // 32bit を超える値は inet_aton も受け付けない。
  if (result > 0xffffffff) return null;
  return result >>> 0;
}

function cidr(dotted, prefixLength, reason) {
  const bytes = strictIpv4Parts(dotted);
  const base =
    ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
  const mask = prefixLength === 0 ? 0 : (0xffffffff << (32 - prefixLength)) >>> 0;
  return { base: (base & mask) >>> 0, mask, reason };
}

// 到達させたくない IPv4 レンジ。「内部アドレス」と「メタデータ用エンドポイント」を核とし、
// 公開インターネット上のホストとして意味を持たないレンジも併せて落とす。
const BLOCKED_IPV4 = Object.freeze([
  cidr("0.0.0.0", 8, "unspecified address range"),
  cidr("10.0.0.0", 8, "private address range"),
  cidr("100.64.0.0", 10, "carrier-grade NAT range"),
  cidr("127.0.0.0", 8, "loopback address range"),
  cidr("169.254.0.0", 16, "link-local range used by cloud metadata endpoints"),
  cidr("172.16.0.0", 12, "private address range"),
  cidr("192.0.0.0", 24, "IETF protocol assignment range"),
  cidr("192.0.2.0", 24, "documentation range"),
  cidr("192.168.0.0", 16, "private address range"),
  cidr("198.18.0.0", 15, "benchmarking range"),
  cidr("198.51.100.0", 24, "documentation range"),
  cidr("203.0.113.0", 24, "documentation range"),
  cidr("224.0.0.0", 4, "multicast range"),
  cidr("240.0.0.0", 4, "reserved range"),
]);

export function classifyIpv4(value) {
  for (const { base, mask, reason } of BLOCKED_IPV4) {
    if (((value & mask) >>> 0) === base) return reason;
  }
  return null;
}

function readUint32(bytes, offset) {
  return (
    ((bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3]) >>>
    0
  );
}

// isIP で形を確定させてから 16 バイトへ展開する。末尾がドット 4 つ組の形
// （`::ffff:169.254.169.254`）は、先に 2 つの 16bit グループへ畳んでから展開する。
export function parseIpv6(text) {
  if (typeof text !== "string" || isIP(text) !== 6) return null;
  let value = text;
  const dotted = /(\d{1,3}(?:\.\d{1,3}){3})$/.exec(value);
  if (dotted) {
    const quad = strictIpv4Parts(dotted[1]);
    if (!quad) return null;
    const high = ((quad[0] << 8) | quad[1]).toString(16);
    const low = ((quad[2] << 8) | quad[3]).toString(16);
    value = `${value.slice(0, dotted.index)}${high}:${low}`;
  }

  const halves = value.split("::");
  if (halves.length > 2) return null;
  const toGroups = (part) => (part === "" ? [] : part.split(":"));
  const head = toGroups(halves[0]);
  const tail = halves.length === 2 ? toGroups(halves[1]) : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 0) return null;
  const groups = [
    ...head,
    ...Array.from({ length: halves.length === 2 ? missing : 0 }, () => "0"),
    ...tail,
  ];
  if (groups.length !== 8) return null;

  const bytes = new Uint8Array(16);
  for (let index = 0; index < 8; index += 1) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(groups[index])) return null;
    const group = Number.parseInt(groups[index], 16);
    bytes[index * 2] = (group >>> 8) & 0xff;
    bytes[index * 2 + 1] = group & 0xff;
  }
  return bytes;
}

export function classifyIpv6(bytes) {
  const zeroThrough = (end) => bytes.subarray(0, end).every((byte) => byte === 0);

  // IPv4-mapped（::ffff:0:0/96）と NAT64（64:ff9b::/96）は IPv4 を埋め込んでいるので、
  // 埋め込まれたアドレスを IPv4 と同じ表で判定する。片方だけ見ると擦り替えの余地が残る。
  if (zeroThrough(10) && bytes[10] === 0xff && bytes[11] === 0xff) {
    return classifyIpv4(readUint32(bytes, 12));
  }
  if (
    bytes[0] === 0x00 &&
    bytes[1] === 0x64 &&
    bytes[2] === 0xff &&
    bytes[3] === 0x9b &&
    bytes.subarray(4, 12).every((byte) => byte === 0)
  ) {
    return classifyIpv4(readUint32(bytes, 12));
  }
  if (zeroThrough(12)) {
    const embedded = readUint32(bytes, 12);
    if (embedded === 0) return "unspecified address";
    if (embedded === 1) return "loopback address";
    // IPv4-compatible 表記は廃止済みで、公開先を指す正当な理由が無い。
    return classifyIpv4(embedded) ?? "deprecated IPv4-compatible address";
  }
  if (bytes[0] === 0xff) return "multicast address";
  if ((bytes[0] & 0xfe) === 0xfc) return "unique local address";
  if (bytes[0] === 0xfe && (bytes[1] & 0xc0) === 0x80) return "link-local address";
  return null;
}

// アドレス文字列（IPv4 の各種表記 / IPv6）を判定する。IP として解釈できない場合は null。
export function classifyAddressLiteral(text) {
  const ipv4 = parseIpv4Loose(text);
  if (ipv4 !== null) return { isAddress: true, reason: classifyIpv4(ipv4) };
  const ipv6 = parseIpv6(text);
  if (ipv6 !== null) return { isAddress: true, reason: classifyIpv6(ipv6) };
  return { isAddress: false, reason: null };
}

function isHostname(text) {
  if (text.length === 0 || text.length > MAX_HOSTNAME_LENGTH) return false;
  const labels = text.split(".");
  // 単一ラベルは公開名として解決先が環境依存になる。loopback リテラルだけを別途許可する。
  if (labels.length < 2) return false;
  if (!labels.every((label) => HOSTNAME_LABEL.test(label))) return false;
  // 数字だけの TLD は名前ではなくアドレスの書き損じなので受け付けない。
  return /[A-Za-z]/.test(labels.at(-1));
}

// manifest に書かれた 1 件の domain を、解決前に判定する。
// 戻り値は拒否理由（null なら現時点で拒否する理由が無い）。
export function classifyDomainLiteral(domain) {
  if (typeof domain !== "string" || domain.length === 0) {
    return "domain must be a non-empty string";
  }
  if (ALLOWED_LOOPBACK_LITERALS.has(domain)) return null;

  const literal = classifyAddressLiteral(domain);
  if (literal.isAddress) {
    return literal.reason
      ? `${domain} is a blocked address (${literal.reason})`
      : null;
  }

  const lowered = domain.toLowerCase();
  if (DENIED_HOSTNAMES.has(lowered)) {
    return `${domain} is a known cloud metadata hostname`;
  }
  if (DENIED_HOSTNAME_SUFFIXES.some((suffix) => lowered.endsWith(suffix))) {
    return `${domain} is inside a reserved internal zone`;
  }
  if (!isHostname(domain)) return `${domain} is not a valid hostname`;
  return null;
}

function defaultLookup(hostname) {
  return dnsLookup(hostname, { all: true, verbatim: true });
}

// 名前を解決し、解決先のいずれかが拒否対象なら throw する。
//
// loopback リテラルの許可はここでは適用しない。`localhost` そのものは解決を省いて許可するが、
// 別の名前が loopback へ解決した場合は拒否する（AC-014）。解決できない名前も承認しない
// （fail-closed。承認境界で「わからない」を許可側へ倒さない）。
export async function assertResolvedDomainAllowed(domain, options = {}) {
  const literalReason = classifyDomainLiteral(domain);
  if (literalReason) throw new TypeError(`manifest.domains rejects ${literalReason}`);
  // リテラル指定の loopback と、判定済みの IP リテラルは解決する必要が無い。
  if (ALLOWED_LOOPBACK_LITERALS.has(domain)) return;
  if (classifyAddressLiteral(domain).isAddress) return;

  const lookup = options.lookup ?? defaultLookup;
  let entries;
  try {
    entries = await lookup(domain);
  } catch (error) {
    throw new TypeError(
      `manifest.domains cannot approve ${domain}: address resolution failed (${error.message})`,
    );
  }
  const addresses = (Array.isArray(entries) ? entries : [entries])
    .map((entry) => (typeof entry === "string" ? entry : entry?.address))
    .filter((address) => typeof address === "string" && address.length > 0);
  if (addresses.length === 0) {
    throw new TypeError(
      `manifest.domains cannot approve ${domain}: address resolution returned no address`,
    );
  }
  for (const address of addresses) {
    const classified = classifyAddressLiteral(address);
    if (!classified.isAddress) {
      throw new TypeError(
        `manifest.domains cannot approve ${domain}: ${address} is not a usable address`,
      );
    }
    if (classified.reason) {
      throw new TypeError(
        `manifest.domains rejects ${domain}: it resolves to ${address}, a blocked address (${classified.reason})`,
      );
    }
  }
}
