import { createAdapterRegistry } from "./adapters.mjs";

// route 段階が参照する provider 能力の軸（#534）。
//
// 値の正本は各 adapter の `capabilities` 宣言（adapter-*.mjs）であり、このモジュールは
// それを provider 名で引ける表に束ねるだけである。**config.json 側へ複製しない**:
// 同じ実測事実が 2 箇所にあると必ず drift する（providers.mjs の冒頭コメントが記録している
// `agy` / `antigravity` 乖離が前例）。
//
// router はここを経由して初めて「承認できない provider」「封じ込められない provider」を
// 知る。それまで両軸は adapter に宣言されているだけで、実行直前の
// checkCapabilityExecutable() が writeAccess を見るのが唯一の消費先だった。

// 承認チャネルの強さ順。人の判断を外部へ往復させられるのは `external` だけである
// （#526 §7.2 の実測）。`agent-review` は「エージェント内でのレビュー」であって人の gate では
// ないため、`requiresApproval` を満たさない。数値で順序を持つのは、将来 `agent-review` で
// 足りる要求水準を足すときに比較演算だけで済ませるため。
export const APPROVAL_CHANNEL_STRENGTH = Object.freeze({
  none: 0,
  "agent-review": 1,
  external: 2,
});

// `requiresApproval` が要求する水準。人の判断が必須なら外部往復が要る。
export const HUMAN_APPROVAL_CHANNEL = "external";
// `requiresWrite` が要求する水準。`unenforceable` は封じ込めを保証できないことを意味する。
export const ENFORCEABLE_WRITE_ACCESS = "supported";

// 宣言を引けなかった provider の扱い。fail-closed:「宣言が無い = 制約が無い」ではなく
// 「宣言が無い = 何も保証できない」とみなす。逆に倒すと、adapter を 1 つ登録し忘れただけで
// gate が静かに素通しになる。
export const UNKNOWN_PROVIDER_CAPABILITIES = Object.freeze({
  approvalChannel: "none",
  writeAccess: "unenforceable",
});

function approvalChannelStrength(channel) {
  // 語彙外の値は最弱として扱う。継承プロパティ（"constructor" 等）を強さとして拾わない。
  if (typeof channel !== "string" || !Object.hasOwn(APPROVAL_CHANNEL_STRENGTH, channel)) {
    return APPROVAL_CHANNEL_STRENGTH.none;
  }
  return APPROVAL_CHANNEL_STRENGTH[channel];
}

// adapter registry から `provider -> {approvalChannel, writeAccess}` の表を作る。
// enum の検証は registry 登録時に assertAdapterShape() が済ませているため、ここでは繰り返さない
// （語彙の SSOT は adapter-contract.mjs 側に置いたままにする）。
export function providerCapabilityFacts(registry = createAdapterRegistry()) {
  return Object.freeze(
    Object.fromEntries(
      registry.providers().map((provider) => {
        const { approvalChannel, writeAccess } = registry.get(provider).capabilities;
        return [provider, Object.freeze({ approvalChannel, writeAccess })];
      }),
    ),
  );
}

// 既定 registry からの表。import 時に組むと router の import が adapter の形検査を
// 巻き込むため、初回参照まで遅らせる。
let defaultFacts = null;
export function defaultProviderCapabilityFacts() {
  defaultFacts ??= providerCapabilityFacts();
  return defaultFacts;
}

// provider の宣言を最弱値へ正規化して返す。表そのものも設定由来の値で引かれるため、
// router.mjs / adapters.mjs と同じく Object.prototype の継承プロパティを拾わない。
export function resolveProviderCapabilities(facts, provider) {
  if (
    facts === null ||
    typeof facts !== "object" ||
    typeof provider !== "string" ||
    !Object.hasOwn(facts, provider)
  ) {
    return UNKNOWN_PROVIDER_CAPABILITIES;
  }
  const entry = facts[provider];
  if (entry === null || typeof entry !== "object") {
    return UNKNOWN_PROVIDER_CAPABILITIES;
  }
  return Object.freeze({
    // 語彙外の値は「宣言が無い」と同じ扱いにする（多層防御。通常は
    // assertAdapterShape() が registry 登録時に弾いている）。
    approvalChannel: Object.hasOwn(APPROVAL_CHANNEL_STRENGTH, entry.approvalChannel)
      ? entry.approvalChannel
      : UNKNOWN_PROVIDER_CAPABILITIES.approvalChannel,
    writeAccess:
      entry.writeAccess === ENFORCEABLE_WRITE_ACCESS
        ? ENFORCEABLE_WRITE_ACCESS
        : UNKNOWN_PROVIDER_CAPABILITIES.writeAccess,
  });
}

// task の要求（需要）と provider の宣言（供給）を突き合わせ、満たさない軸だけを返す。
// 拒否は例外ではなく理由付きの判定として返す（adapters.mjs の refuse() と同じ考え方）:
// 「承認経路が無いので route しなかった」は記録すべき事実であって、異常終了ではない。
export function unmetRequirements(capabilities, { requiresApproval, requiresWrite } = {}) {
  const unmet = [];
  if (
    requiresApproval === true &&
    approvalChannelStrength(capabilities.approvalChannel) <
      APPROVAL_CHANNEL_STRENGTH[HUMAN_APPROVAL_CHANNEL]
  ) {
    unmet.push({
      axis: "approvalChannel",
      required: HUMAN_APPROVAL_CHANNEL,
      actual: capabilities.approvalChannel,
    });
  }
  if (requiresWrite === true && capabilities.writeAccess !== ENFORCEABLE_WRITE_ACCESS) {
    unmet.push({
      axis: "writeAccess",
      required: ENFORCEABLE_WRITE_ACCESS,
      actual: capabilities.writeAccess,
    });
  }
  return unmet;
}

// reason 文字列用の要約。route を塞いだ事実は evidence に構造化して残すが、
// routes 行の reason だけを見ても何が起きたか読めるようにしておく。
export function describeUnmetRequirements(entries) {
  return entries
    .map((entry) => `${entry.axis} ${entry.required} (declares ${entry.actual})`)
    .join(", ");
}
