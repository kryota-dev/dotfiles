import {
  parseJsonLines,
  requireInvocationRequest,
  requireSafeArgumentValue,
  sealInvocation,
} from "./adapter-contract.mjs";

// Codex CLI の非対話実行（`codex exec`）。
//
// この adapter が存在する主な理由は #526 §2.3［実測］の非対称である:
// **`codex exec resume` は `-s/--sandbox` も `-C/--cd` も受け付けない。** 受け付けるのは
// `--dangerously-bypass-approvals-and-sandbox`（＝弱める方向だけ）で、サンドボックスを
// 維持したまま再開するには `-c sandbox_mode` の config override を使う必要がある。
const PROVIDER = "codex";

// `codex exec resume` が受け付けないフラグ。再開形にこれらが混ざった invocation は、
// 起動しないか、サンドボックスが設定既定へ戻る。どちらも「要求どおり」ではない。
const FLAGS_REJECTED_ON_RESUME = Object.freeze(["-s", "--sandbox", "-C", "--cd"]);

// この adapter が出してよいフラグの全集合。**denylist ではなく allowlist にする**理由:
// 危険フラグを列挙する方式は Codex に新しいフラグが増えるたび追随が要り、追随漏れが
// そのまま素通りになる。位置引数（session id / prompt）は入力検証で `-` 始まりを弾いてあるので、
// argv 中で `-` から始まる要素は adapter 自身が置いたものだけになり、集合で縛れる。
const ALLOWED_FLAGS = new Set(["--json", "-c", "--sandbox", "-m"]);

function hasOnlyAllowedFlags(argv) {
  // `-c` の値（`key=value`）と `-m` の値（model トークン）は `-` で始まらないため対象外。
  return argv.every((value) => !value.startsWith("-") || ALLOWED_FLAGS.has(value));
}

// 中立語彙（sandbox.mjs）と Codex の語彙はたまたま同じ綴りだが、対応は明示的に持つ。
// 綴りが一致しているだけの素通りを、将来どちらかが変わったときに起こさないため。
const CODEX_SANDBOX_MODES = Object.freeze({
  "read-only": "read-only",
  "workspace-write": "workspace-write",
});

function toCodexMode(mode) {
  if (typeof mode !== "string" || !Object.hasOwn(CODEX_SANDBOX_MODES, mode)) {
    throw new TypeError(`${PROVIDER} cannot express the sandbox mode ${mode}`);
  }
  return CODEX_SANDBOX_MODES[mode];
}

function fromCodexMode(value) {
  const entry = Object.entries(CODEX_SANDBOX_MODES).find(
    ([, codexMode]) => codexMode === value,
  );
  return entry ? entry[0] : null;
}

// #526 §2.3 の `-c sandbox_mode='"read-only"'` はシェルのシングルクォートを剥がすと
// `sandbox_mode="read-only"` になる。argv 配列（シェルを介さない）で渡すときは、
// 二重引用符を値の中に自分で含める必要がある。読み戻すときは逆に剥がす。
function unquote(value) {
  return value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.slice(1, -1)
    : value;
}

function readConfigOverride(argv, key) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== "-c" && argv[index] !== "--config") continue;
    const pair = argv[index + 1];
    if (typeof pair !== "string") continue;
    const separator = pair.indexOf("=");
    if (separator === -1) continue;
    if (pair.slice(0, separator) !== key) continue;
    return unquote(pair.slice(separator + 1));
  }
  return null;
}

function wrapMode(mode) {
  return mode === null ? null : { mode };
}

function readEffectiveSandbox(invocation) {
  const { argv } = invocation;
  // 想定外のフラグが 1 つでも混ざっていたら、いかなる policy とも一致させない。
  // これが「session id や prompt に紛れたフラグ注入」に対する構造的なバックストップになる。
  if (!hasOnlyAllowedFlags(argv)) return null;
  // 承認とサンドボックスを丸ごと外すフラグ。allowlist にも含まれないが、
  // 何を防いでいるかを読み取れるよう明示的にも弾く。
  if (argv.includes("--dangerously-bypass-approvals-and-sandbox")) return null;

  const isResume = argv[0] === "exec" && argv[1] === "resume";
  if (isResume) {
    if (FLAGS_REJECTED_ON_RESUME.some((flag) => argv.includes(flag))) return null;
    return wrapMode(fromCodexMode(readConfigOverride(argv, "sandbox_mode")));
  }

  const index = argv.indexOf("--sandbox");
  if (index === -1) return null;
  return wrapMode(fromCodexMode(argv[index + 1]));
}

// Codex は prompt と session id を**位置引数**で受け取る。`-` で始まる値はフラグとして
// 解釈されうるので、静かに誤解釈させるくらいなら組み立てを拒否する。
// session id 側にこのガードが無いと、`resume("--full-auto")` のような値がそのまま
// argv のフラグ位置に載る（実測で再現。sandbox の読み戻しは値の妥当性までは見ない）。
function requirePositionalArgument(value, label) {
  if (value.startsWith("-")) {
    throw new TypeError(
      `${PROVIDER} cannot pass ${label} beginning with "-" as a positional argument`,
    );
  }
  return value;
}

function launch(request) {
  const { prompt, model, effort, sandbox } = requireInvocationRequest(
    request,
    `${PROVIDER} launch request`,
  );
  const argv = [
    "exec",
    "--sandbox",
    toCodexMode(sandbox.mode),
    // #526 §2.1: JSONL で thread.started / turn.started / item.* / turn.completed / error が流れる。
    "--json",
    "-m",
    model,
    "-c",
    `model_reasoning_effort=${effort}`,
    requirePositionalArgument(prompt, "a prompt"),
  ];
  return sealInvocation({
    provider: PROVIDER,
    executable: request.executable,
    argv,
    phase: "launch",
    sandbox,
    readEffectiveSandbox,
  });
}

function resume(request) {
  if (!request?.resumeKey) {
    throw new TypeError(`${PROVIDER} resume requires a resumeKey`);
  }
  const { prompt, model, effort, sandbox } = requireInvocationRequest(
    request,
    `${PROVIDER} resume request`,
  );
  const argv = [
    "exec",
    "resume",
    // session id は位置引数なので、フラグに化ける値と argv を壊す値の両方を弾く。
    requirePositionalArgument(
      requireSafeArgumentValue(request.resumeKey, `${PROVIDER} resumeKey`),
      "a resume key",
    ),
    "--json",
    // resume では `-s` が使えないため config override で維持する（#526 §2.3 実測）。
    "-c",
    `sandbox_mode="${toCodexMode(sandbox.mode)}"`,
    // model も再開形で pin する。`codex exec resume --help`（codex-cli 0.150.1）が
    // `-m, --model <MODEL>` を受け付けることを実測で確認した。pin しないと、
    // adapter run に記録した capability の model と実際に走る model が食い違いうる。
    "-m",
    model,
    "-c",
    `model_reasoning_effort=${effort}`,
    requirePositionalArgument(prompt, "a prompt"),
  ];
  return sealInvocation({
    provider: PROVIDER,
    executable: request.executable,
    argv,
    phase: "resume",
    sandbox,
    readEffectiveSandbox,
  });
}

function eventType(event) {
  if (typeof event.type === "string") return event.type;
  if (typeof event.event === "string") return event.event;
  return null;
}

// thread.started が返す識別子のキー名は #526 でも実測されていない。1 つに決め打たず、
// 見つからなければ null を返す（再開キーが無ければ、呼び出し側は再開を組み立てられない）。
function readThreadId(events) {
  for (const event of events) {
    if (eventType(event) !== "thread.started") continue;
    const candidate =
      event.thread_id ?? event.threadId ?? event.thread?.id ?? event.id ?? null;
    if (typeof candidate === "string" && candidate.length > 0) return candidate;
  }
  return null;
}

function interpret(processResult) {
  const { events, malformed } = parseJsonLines(processResult?.stdout);
  const exitCode = processResult?.exitCode ?? null;
  const resumeKey = readThreadId(events);
  const errorEvent = events.find((event) => eventType(event) === "error");
  const completed = events.some((event) => eventType(event) === "turn.completed");

  if (errorEvent) {
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason:
        typeof errorEvent.message === "string" && errorEvent.message.length > 0
          ? `run reported an error event: ${errorEvent.message}`
          : "run reported an error event",
    };
  }
  if (exitCode !== null && exitCode !== 0) {
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason: `run exited with code ${exitCode}`,
    };
  }
  if (!completed) {
    const truncated = malformed > 0 ? ` (${malformed} unparsable output lines)` : "";
    return {
      outcome: "failed",
      exitCode,
      resumeKey,
      denials: [],
      failureReason: `structured output carried no turn completion${truncated}`,
    };
  }
  return {
    outcome: "succeeded",
    exitCode,
    resumeKey,
    denials: [],
    failureReason: null,
  };
}

export const codexAdapter = Object.freeze({
  provider: PROVIDER,
  capabilities: Object.freeze({
    // #526 §2.2: 外部プロセスが承認要求を受け取って返すチャネルは無い。代替は auto_review agent。
    approvalChannel: "agent-review",
    // #526 §2.4［実測］: シェル実行も組み込み patch ツールも sandbox mode で塞がれた。
    sandboxEnforcement: "os",
    writeAccess: "supported",
    resumeKey: "thread-id",
  }),
  launch,
  resume,
  readEffectiveSandbox,
  interpret,
});
