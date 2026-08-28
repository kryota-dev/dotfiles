import {
  parseJsonLines,
  requireInvocationRequest,
  sealInvocation,
} from "./adapter-contract.mjs";

// Claude Code の非対話実行。起動形・再開形・結果解釈はすべて #526 の実測に基づく。
const PROVIDER = "claude";

// #526 §1.2.5［原文］: permissions.allow と read-only コマンド集合以外を拒否する mode。
// サンドボックスが包むのは Bash のサブプロセスだけで、Read/Edit/Write は権限システム側なので、
// 「書き込まない」を成立させるには mode 側の指定が要る。
const READ_ONLY_PERMISSION_MODE = "dontAsk";

// #526 §1.5［実測］の設定でサンドボックス境界を確認している
// （cwd 配下への書き込みは成功、$HOME への書き込みとネットワーク接続は拒否）。
//
// - failIfUnavailable: サンドボックスが使えないときに警告して素通しさせない。
// - allowUnsandboxedCommands: 失敗コマンドの sandbox 外リトライを許さない。
// - network.strictAllowlist: ホスト名の許可リストを厳格化する。許可ドメインは指定しない
//   （許可リストの記法は実測していないので、閉じた状態だけを描画する）。
function sandboxSettings() {
  return {
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      autoAllowBashIfSandboxed: true,
      allowUnsandboxedCommands: false,
      network: { strictAllowlist: true },
    },
  };
}

function flagValue(argv, flag) {
  const index = argv.indexOf(flag);
  if (index === -1) return null;
  return argv[index + 1] ?? null;
}

// argv から実効サンドボックスを読み戻す。読み取れない形はすべて null にして、
// sealInvocation 側で「要求と一致しない」として弾かせる。
function readEffectiveSandbox(invocation) {
  const { argv } = invocation;

  // #526 §1.5: サンドボックスが包むのは Bash だけなので、権限システムを丸ごと外すフラグと
  // 併用すると**ファイル書き込みが OS 強制の外へ出る**。混ざっていたら一致させない。
  if (argv.includes("--dangerously-skip-permissions")) return null;
  // #526 §1.1［実測］: `claude -p --sandbox` は unknown option になる。存在しないフラグを
  // 出す adapter は、設定 JSON 側の指定が効いていると誤認している。
  if (argv.includes("--sandbox")) return null;

  const raw = flagValue(argv, "--settings");
  if (raw === null) return null;
  let settings;
  try {
    settings = JSON.parse(raw);
  } catch {
    return null;
  }
  const sandbox = settings?.sandbox;
  if (
    !sandbox ||
    sandbox.enabled !== true ||
    sandbox.failIfUnavailable !== true ||
    sandbox.allowUnsandboxedCommands !== false ||
    sandbox.network?.strictAllowlist !== true
  ) {
    return null;
  }

  const readOnly = flagValue(argv, "--permission-mode") === READ_ONLY_PERMISSION_MODE;
  return { mode: readOnly ? "read-only" : "workspace-write" };
}

function buildArgv({ prompt, model, effort, sandbox, session, permissionPromptTool }) {
  const argv = [
    "-p",
    prompt,
    // #526 §1.4: system/init・assistant・最終 result が NDJSON で流れる。
    "--output-format",
    "stream-json",
    "--model",
    model,
    "--effort",
    effort,
    // #526 R2: `-p` は workspace trust を出さず、壊れた設定を黙って無視する。repository 由来の
    // hooks / MCP は起動フラグで事前に遮断する（起動後の init 検査では手遅れになる）。
    "--setting-sources",
    "user",
    "--strict-mcp-config",
    "--settings",
    JSON.stringify(sandboxSettings()),
  ];
  if (session) argv.push(session.flag, session.value);
  // 承認チャネルの受け口そのものは #533 が作る。ここでは呼び出し側が渡したときだけ配線し、
  // 配線の要否を adapter が判断しない（判断は #534 の capability registry 軸の範囲）。
  if (permissionPromptTool) {
    argv.push("--permission-prompt-tool", permissionPromptTool);
  }
  if (sandbox.mode === "read-only") {
    argv.push("--permission-mode", READ_ONLY_PERMISSION_MODE);
  }
  return argv;
}

function seal({ request, phase, session }) {
  const { prompt, model, effort, sandbox } = requireInvocationRequest(
    request,
    `${PROVIDER} ${phase} request`,
  );
  return sealInvocation({
    provider: PROVIDER,
    executable: request.executable,
    argv: buildArgv({
      prompt,
      model,
      effort,
      sandbox,
      session,
      permissionPromptTool: request.permissionPromptTool,
    }),
    phase,
    sandbox,
    readEffectiveSandbox,
  });
}

// #526 §1.3［実測］: 呼び出し側が `--session-id` で採番でき、`-p --resume <uuid>` で
// 別ディレクトリからでも文脈を保ったまま再開できる。採番しない場合は CLI 側が発番し、
// その値は構造化出力の session_id から読み取る。
function launch(request) {
  const sessionId = request.sessionId;
  return seal({
    request,
    phase: "launch",
    session: sessionId ? { flag: "--session-id", value: sessionId } : null,
  });
}

function resume(request) {
  if (!request?.resumeKey) {
    throw new TypeError(`${PROVIDER} resume requires a resumeKey`);
  }
  return seal({
    request,
    phase: "resume",
    session: { flag: "--resume", value: request.resumeKey },
  });
}

function isResultEvent(event) {
  if (event.type === "result") return true;
  // `--output-format json` の envelope は type を持たない（#526 §1.4）。
  return (
    typeof event.session_id === "string" &&
    (Object.hasOwn(event, "result") || Object.hasOwn(event, "is_error"))
  );
}

// 拒否されたツールは**名前だけ**を残す。tool_input はコマンド文字列やファイル内容を含みうる。
function denialNames(event) {
  if (!Array.isArray(event.permission_denials)) return [];
  return event.permission_denials
    .map((denial) => denial?.tool_name)
    .filter((name) => typeof name === "string" && name.length > 0);
}

function interpret(processResult) {
  const { events, malformed } = parseJsonLines(processResult?.stdout);
  const exitCode = processResult?.exitCode ?? null;
  const result = events.filter(isResultEvent).at(-1);

  if (!result) {
    // #526 §1.3: SIGTERM は exit 143 で、進行中のターンは未完了のまま残る。
    // 終端イベントが無い実行は、終了コードが 0 でも「完了した」と読まない。
    const truncated = malformed > 0 ? ` (${malformed} unparsable output lines)` : "";
    return {
      outcome: "failed",
      exitCode,
      failureReason: `structured output carried no result event${truncated}`,
      denials: [],
      resumeKey: null,
    };
  }

  const denials = denialNames(result);
  const failed = result.is_error === true || (exitCode !== null && exitCode !== 0);
  return {
    outcome: failed ? "failed" : "succeeded",
    exitCode,
    resumeKey: typeof result.session_id === "string" ? result.session_id : null,
    denials,
    failureReason: failed
      ? (typeof result.subtype === "string" && result.subtype.length > 0
          ? `run reported ${result.subtype}`
          : "run reported an error result")
      : null,
  };
}

export const claudeAdapter = Object.freeze({
  provider: PROVIDER,
  capabilities: Object.freeze({
    // #526 §1.2.3［実測］: 承認も AskUserQuestion も prompt tool 経由で外部へ往復できる。
    approvalChannel: "external",
    // #526 §1.5: OS 強制だが対象は Bash のみ。設定 JSON で有効化するので settings とする。
    sandboxEnforcement: "settings",
    writeAccess: "supported",
    resumeKey: "session-id",
  }),
  launch,
  resume,
  readEffectiveSandbox,
  interpret,
});
