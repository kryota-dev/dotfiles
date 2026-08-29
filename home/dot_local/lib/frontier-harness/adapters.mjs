import path from "node:path";

import { antigravityAdapter } from "./adapter-antigravity.mjs";
import { claudeAdapter } from "./adapter-claude.mjs";
import { codexAdapter } from "./adapter-codex.mjs";
import {
  adapterRunStatusFor,
  assertAdapterShape,
  normalizeAdapterResult,
  requireCapabilityTokens,
} from "./adapter-contract.mjs";
import { providerCommand } from "./providers.mjs";
import { requireObject } from "./record-validation.mjs";
import { allowsWrite, normalizeSandboxPolicy } from "./sandbox.mjs";

// provider adapter の registry と、capability registry との接続点。
//
// router は provider 非依存の可用性だけを見る（executable の有無・account scope・
// discovery 済み model 一覧）。vendor 固有の検査（effort の描画可否、書き込みの封じ込め可否）と、
// **実行直前の exact model ID の再検査**はここが持つ。再検査は重複ではない:
// route を決めてから実行するまでに readiness キャッシュは TTL 失効しうる。

// fake adapter は含めない。含めると、設定の取り違えで本物の route が fake に落ちても
// 誰も気づかない（adapter-fake.mjs は明示的に注入して使う）。
const DEFAULT_ADAPTERS = Object.freeze([
  antigravityAdapter,
  claudeAdapter,
  codexAdapter,
]);

export function createAdapterRegistry({ adapters = DEFAULT_ADAPTERS } = {}) {
  if (!Array.isArray(adapters)) {
    throw new TypeError("adapter registry requires an array of adapters");
  }
  // Object リテラルではなく Map を使う。provider 名は設定由来なので、
  // "constructor" のような継承プロパティを adapter として拾わせない。
  const byProvider = new Map();
  for (const adapter of adapters) {
    assertAdapterShape(adapter);
    if (byProvider.has(adapter.provider)) {
      throw new TypeError(`adapter registry has two adapters for ${adapter.provider}`);
    }
    byProvider.set(adapter.provider, adapter);
  }
  return Object.freeze({
    get(provider) {
      return byProvider.get(provider) ?? null;
    },
    providers() {
      return [...byProvider.keys()].sort();
    },
  });
}

function refuse(reason) {
  return { executable: false, reason };
}

// 実行してよいかを検査する。拒否は例外ではなく理由付きの判定として返す:
// 「利用不可だったので実行しなかった」は記録すべき事実であって、異常終了ではない。
export function checkCapabilityExecutable({
  accountScope,
  adapter,
  availability,
  capability,
  executablePath,
  sandbox,
}) {
  requireObject(capability, "capability");
  requireObject(availability, "availability");

  if (!adapter) {
    return refuse(`no adapter is registered for provider ${capability.provider}`);
  }
  if (adapter.provider !== capability.provider) {
    return refuse(
      `adapter ${adapter.provider} cannot run a ${capability.provider} capability`,
    );
  }

  const command = providerCommand(capability.provider);
  // Object.prototype の継承プロパティを可用性として拾わない（router.mjs と同じ扱い）。
  if (!Object.hasOwn(availability, capability.provider)) {
    return refuse(`${command} availability is unknown`);
  }
  const entry = availability[capability.provider];
  if (!entry || entry.available !== true) {
    return refuse(`${command} is unavailable`);
  }
  // router と同じ規則: discovery 一覧があるときだけ exact model ID を照合する。
  // 規則を片方だけ厳しくすると、route できたのに実行だけ拒否される（またはその逆）が起きる。
  if (Array.isArray(entry.models) && !entry.models.includes(capability.model)) {
    return refuse(`${command} model discovery did not report ${capability.model}`);
  }
  // account scope も router の可用性規則の一部である（router.mjs の isAvailable 末尾）。
  // model だけ再検査して scope を落とすと、多層防御が軸ごとに非対称になる。
  // 出荷 config の frontend.primary は実際に accountScope を持ち、docs は r06 セッションから
  // personal credential への fallback を禁じているので、ここは落としてはいけない軸である。
  // scope を解決できない呼び出し（accountScope 未指定）は、scope 付き capability を拒否する。
  if (capability.accountScope && capability.accountScope !== accountScope) {
    return refuse(
      `account scope ${accountScope ?? "unknown"} does not have a ${capability.accountScope} mapping for ${command}`,
    );
  }

  try {
    requireCapabilityTokens(capability, `capability ${capability.provider}`);
  } catch (error) {
    // 形の壊れた capability は「実行できない理由」であって、異常終了ではない。
    if (!(error instanceof TypeError)) throw error;
    return refuse(error.message);
  }

  if (typeof executablePath !== "string" || !path.isAbsolute(executablePath)) {
    return refuse(`${command} executable must be resolved to an absolute path`);
  }

  if (allowsWrite(sandbox) && adapter.capabilities.writeAccess !== "supported") {
    return refuse(
      `${command} cannot contain a write-capable run (${adapter.capabilities.writeAccess})`,
    );
  }

  return { executable: true, reason: null };
}

// `runWithRolloutGuard(config, context, executor)` の executor を作る。
//
// **既定の runner を持たない。** adapter 層はプロセスを起動せず、Node の子プロセス API を
// import すらしない（テストがソースを走査して固定している）。実起動は呼び出し側が注入し、
// その配線は rollout 昇格（#502）の範囲。それまでは shadow guard が executor を呼ばない。
export function createAdapterExecutor({
  accountScope,
  registry = createAdapterRegistry(),
  availability,
  capability,
  capabilityName,
  request,
  runner,
  clock = () => new Date().toISOString(),
}) {
  if (typeof runner !== "function") {
    throw new TypeError(
      "createAdapterExecutor requires an injected runner; the adapter layer starts no process itself",
    );
  }
  requireObject(capability, "capability");
  requireObject(request, "adapter execution request");
  // availability は関数でも渡せる。値で渡すと executor 生成時のスナップショットに固定され、
  // 生成から実行までの間に readiness が失効しても「実行直前に再検査した」ことにならない。
  if (typeof availability !== "function") {
    requireObject(availability, "availability");
  }
  const readAvailability = () =>
    typeof availability === "function" ? availability() : availability;
  const sandbox = normalizeSandboxPolicy(request.sandbox, "execution sandbox");
  const adapter = registry.get(capability.provider);

  const identity = {
    capability: capabilityName,
    provider: capability.provider,
    model: capability.model,
    effort: capability.effort,
  };

  return () => {
    const verdict = checkCapabilityExecutable({
      accountScope,
      adapter,
      availability: readAvailability(),
      capability,
      executablePath: request.executable,
      sandbox,
    });
    if (!verdict.executable) {
      return Object.freeze({
        ...identity,
        outcome: "refused",
        ranProvider: false,
        reason: verdict.reason,
        sandbox,
      });
    }

    const invocationRequest = {
      ...request,
      sandbox,
      model: capability.model,
      effort: capability.effort,
    };
    // truthiness で分岐すると、空文字の resume key が黙って新規 launch に化ける
    // （＝別セッションの二重起動）。null / undefined だけを「再開しない」とみなし、
    // それ以外は adapter.resume へ渡して adapter 側の検証で loud に落とす。
    const invocation =
      request.resumeKey === undefined || request.resumeKey === null
        ? adapter.launch(invocationRequest)
        : adapter.resume(invocationRequest);

    const startedAt = clock();
    const result = normalizeAdapterResult(
      adapter.interpret(runner(invocation)),
      capability.provider,
    );
    const finishedAt = clock();

    return Object.freeze({
      ...identity,
      outcome: result.outcome,
      status: adapterRunStatusFor(result.outcome),
      ranProvider: true,
      phase: invocation.phase,
      resumeKey: result.resumeKey,
      denials: result.denials,
      failureReason: result.failureReason,
      exitCode: result.exitCode,
      startedAt,
      finishedAt,
      // sealInvocation が「この argv はこの policy どおりに動く」ことを構築時に確認済みなので、
      // これは要求値ではなく**その実行で有効だった値**である（#526 §7.3-4）。
      // adapter_runs は起動方式の列を持たないため、記録先は evidence 側になる。
      sandbox,
    });
  };
}
