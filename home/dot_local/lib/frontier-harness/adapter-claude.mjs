import path from "node:path";

import {
  parseJsonLines,
  requireInvocationRequest,
  requireSafeArgumentValue,
  sealInvocation,
  walkFlagPairs,
} from "./adapter-contract.mjs";
import {
  requireNonEmptyString,
  requireObject,
  requireToken,
} from "./record-validation.mjs";

// Claude Code の非対話実行。起動形・再開形・結果解釈はすべて #526 の実測に基づく。
const PROVIDER = "claude";

// #526 §1.2.5［原文］: permissions.allow と read-only コマンド集合以外を拒否する mode。
// サンドボックスが包むのは Bash のサブプロセスだけで、Read/Edit/Write は権限システム側なので、
// 「書き込まない」を成立させるには mode 側の指定が要る。
const READ_ONLY_PERMISSION_MODE = "dontAsk";

const SETTING_SOURCES_FLAG = "--setting-sources";
const STRICT_MCP_CONFIG_FLAG = "--strict-mcp-config";
const MCP_CONFIG_FLAG = "--mcp-config";
const PERMISSION_PROMPT_TOOL_FLAG = "--permission-prompt-tool";
const SETTINGS_FLAG = "--settings";
// ［実測 claude 2.1.251］`-p` と `--output-format stream-json` の組合せは `--verbose` を
// 要求する（"When using --print, --output-format=stream-json requires --verbose"）。
// 無いと CLI は NDJSON を 1 行も出さずに exit 1 するので、起動時検査からは
// 「init イベントが無かった」としか見えない。ストリーム形式と対で出す。
const VERBOSE_FLAG = "--verbose";

// 子が届く必要のあるホスト。公式 docs［原文］: "Claude Code pre-allows no domains by default"
// —— つまり `strictAllowlist: true` を allowedDomains 無しで立てると、sandboxed な shell は
// **どのホストへも到達できない**。子は pr-workflow を走らせるので push と gh が要る。
//
// **署名 socket は開けない。** `network.allowUnixSockets` を与えれば 1Password の agent socket
// 経由で commit 署名が通るが、それは自律的に走る子へ「vault の鍵で署名する能力」を渡すことに
// なる。docs も Unix socket の許可を privilege escalation の経路として名指ししている。
// 代わりに子へは「署名を切ってコミットする」ことを session-command.mjs が明示的に伝える
// —— 中間コミットが未署名でも、main へ入る squash コミットは GitHub が署名する。
export const SANDBOX_ALLOWED_DOMAINS = Object.freeze(["github.com", "*.github.com"]);
// #526 §1.6［原文］: `--bare` を付けない `-p` は、信頼していないフォルダでも repository の
// `.mcp.json` の server に接続する。
const PROJECT_MCP_FILE = ".mcp.json";

// この adapter が出してよいフラグと、それが値を取るかどうか（walkFlagPairs の allowlist）。
//
// `--add-dir` と `--dangerously-skip-permissions` がこの表に無いのは意図である。前者は［原文］
// "Grants file access; **most** `.claude/` configuration is not discovered from these directories"
// と限定付きで、残余が特定されていない以上「設定源を増やさない」とは断定できない。
const CLAUDE_FLAGS = Object.freeze({
  "-p": true,
  "--output-format": true,
  "--model": true,
  "--effort": true,
  "--permission-mode": true,
  "--session-id": true,
  "--resume": true,
  [SETTING_SOURCES_FLAG]: true,
  [STRICT_MCP_CONFIG_FLAG]: false,
  [SETTINGS_FLAG]: true,
  [MCP_CONFIG_FLAG]: true,
  [PERMISSION_PROMPT_TOOL_FLAG]: true,
  [VERBOSE_FLAG]: false,
});

// docs/en/settings の scope 表［原文］に対応する。managed settings は --setting-sources の語彙に
// 無く、作業ツリーからも書けないのでここでは扱わない。
const SETTING_SOURCE_FILES = Object.freeze({
  user: ({ home }) => path.join(home, ".claude", "settings.json"),
  project: ({ worktree }) => path.join(worktree, ".claude", "settings.json"),
  local: ({ worktree }) => path.join(worktree, ".claude", "settings.local.json"),
});

const ALL_SETTING_SOURCES = Object.freeze(Object.keys(SETTING_SOURCE_FILES));
const USER_SETTING_SOURCE = "user";

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
      network: {
        strictAllowlist: true,
        allowedDomains: [...SANDBOX_ALLOWED_DOMAINS],
      },
    },
  };
}

function flagValue(argv, flag) {
  const index = argv.indexOf(flag);
  if (index === -1) return null;
  return argv[index + 1] ?? null;
}

// この adapter は位置引数を持たないので、argv 全体をフラグ/値の対として走査できる
// （走査そのものは adapter-contract.mjs、表の中身だけがここの vendor 知識）。
function walkArgv(argv) {
  return walkFlagPairs(argv, CLAUDE_FLAGS);
}

// ファイルパスか inline JSON かを見分ける。`--settings` も `--mcp-config` も［原文］
// 「ファイルまたは文字列」を受けるので、値の形でしか区別できない。
//
// **未実測**: 値が inline JSON としてもファイル名としても解釈しうるとき、CLI がどちらを先に
// 採るかは一次ソースに記載がない。仮に「同名のファイルがあれば優先」であれば、この adapter が
// 出す固定の inline JSON 文字列と同名のファイルを作業ツリーへ置く shadowing が理論上成立する
// （多くの CLI は先頭が `{` かで先に判定するため成立しない公算が大きいが、確認できていない）。
// 実起動を扱う #537 で実測する。ここでは JSON として読める値を inline とみなす。
function parseInlineJsonObject(value) {
  try {
    const parsed = JSON.parse(value);
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

// #526 §1.6［原文］: 無指定の `-p` は repository の `.claude/settings.json` の hooks を実行する。
// つまり「指定が無い」は「全部読む」なので、解釈できない形はすべて全源に倒す（fail-closed）。
function settingSourcesOf(values) {
  const declared = values.get(SETTING_SOURCES_FLAG);
  if (!declared || declared.length !== 1) return ALL_SETTING_SOURCES;
  const names = declared[0]
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
  if (names.length === 0) return ALL_SETTING_SOURCES;
  // 未知の源名を「読まれない」と決めつけない。
  if (names.some((name) => !Object.hasOwn(SETTING_SOURCE_FILES, name))) {
    return ALL_SETTING_SOURCES;
  }
  return names;
}

function freezeUniquePaths(paths) {
  return Object.freeze([...new Set(paths)]);
}

// argv から「この invocation で子が読む設定ファイル」の絶対パスを導出する。
//
// **enforce（遮断できているか）と説明（子が何を読むか）を同じ導出から作る**ための関数である。
// readEffectiveConfigIsolation はこの結果を見て判定し、挙動テストは実ファイルを置いた作業ツリーに
// 対してこの結果を検証する。2 つを別実装にすると、テストが主張する読み込み対象と本番が遮断する
// 対象が必ず drift する。
export function configSourcesFor(invocation, { worktree, home }) {
  requireNonEmptyString(worktree, "config sources worktree");
  requireNonEmptyString(home, "config sources home");
  const values = walkArgv(invocation?.argv);
  const paths = [];

  if (values === null) {
    for (const name of ALL_SETTING_SOURCES) {
      paths.push(SETTING_SOURCE_FILES[name]({ worktree, home }));
    }
    paths.push(path.join(worktree, PROJECT_MCP_FILE));
    return freezeUniquePaths(paths);
  }

  for (const name of settingSourcesOf(values)) {
    paths.push(SETTING_SOURCE_FILES[name]({ worktree, home }));
  }
  // パスで渡された設定ファイルは作業ツリーから差し替えられうるので、設定源として数える。
  for (const flag of [SETTINGS_FLAG, MCP_CONFIG_FLAG]) {
    for (const value of values.get(flag) ?? []) {
      if (parseInlineJsonObject(value) === null) paths.push(path.resolve(worktree, value));
    }
  }
  // ［原文］`--strict-mcp-config` は "Only use MCP servers from `--mcp-config`, ignoring all other
  // MCP configurations"。無ければ repository の `.mcp.json` が読まれる。
  if (!values.has(STRICT_MCP_CONFIG_FLAG)) {
    paths.push(path.join(worktree, PROJECT_MCP_FILE));
  }
  return freezeUniquePaths(paths);
}

// isolation 判定に使う probe。実在しないパスでよい（この判定はファイルシステムに触れない）。
// 「作業ツリー配下か否か」だけを見分けられればよいので、互いに包含しない固定値を置く。
const WORKTREE_PROBE = `${path.sep}frontier-harness-worktree-probe`;
const HOME_PROBE = `${path.sep}frontier-harness-home-probe`;

function isInsideWorktreeProbe(candidate) {
  const relative = path.relative(WORKTREE_PROBE, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

// ツール名は `mcp__<server>__<tool>`。server key は requireToken（`_` を含まない）で縛るので、
// `__` での 3 分割は一意になる。形が違うものからは key を取り出さない（fail-closed）。
function approvalServerKeyOf(tool) {
  if (typeof tool !== "string") return null;
  const parts = tool.split("__");
  return parts.length === 3 && parts[0] === "mcp" && parts[1].length > 0 && parts[2].length > 0
    ? parts[1]
    : null;
}

function promptToolTargets(tool, serverKey) {
  return approvalServerKeyOf(tool) === serverKey;
}

// 宣言された MCP server。ファイルパス指定は作業ツリーから差し替えられうるので、
// 許可リストとしては inline JSON だけを認める。
function declaredApprovalServer(value) {
  const servers = parseInlineJsonObject(value)?.mcpServers;
  if (!servers || typeof servers !== "object" || Array.isArray(servers)) return null;
  const keys = Object.keys(servers);
  return keys.length === 1 ? { key: keys[0], server: servers[keys[0]] } : null;
}

// 外部ツール接続の許可リスト。
//
// #526 §1.2.1［実測］: prompt tool を配線しないと、子は「user に問う」能力そのものを失う。
// 一方 `--strict-mcp-config` は `--mcp-config` 由来以外の MCP 設定を無視するので、宣言が無ければ
// server が 1 つも載らず、prompt tool の参照先が存在しない子ができあがる。どちらも gate が
// 静かに消える失敗なので、「承認 server をちょうど 1 つ宣言し、prompt tool がそれを指す」以外の
// 形を成立させない。宣言だけがある形も認めない（承認チャネル以外の接続を子へ入れないため）。
function approvalChannelIsAllowlisted(values) {
  const tools = values.get(PERMISSION_PROMPT_TOOL_FLAG) ?? [];
  const configs = values.get(MCP_CONFIG_FLAG) ?? [];
  if (tools.length === 0) return configs.length === 0;
  if (tools.length !== 1 || configs.length !== 1) return false;
  const declared = declaredApprovalServer(configs[0]);
  if (declared === null) return false;
  // 宣言の**中身**も読み戻す。組み立て側だけが制約を持つと、そちらが緩む退行を seal が
  // 捕まえられない（sandbox / 設定源と同じく、封印は読み戻しで成立させる）。
  if (approvalServerViolation(declared.key, declared.server) !== null) return false;
  return promptToolTargets(tools[0], declared.key);
}

// argv から「作業ツリーが子セッションを設定できるか」を読み戻す。sealInvocation はこれが true を
// 返さない invocation を組み立てさせない（#538 の完了条件「起動フラグを外した状態で子を起動できない」）。
function readEffectiveConfigIsolation(invocation) {
  const values = walkArgv(invocation?.argv);
  if (values === null) return false;
  if (!approvalChannelIsAllowlisted(values)) return false;
  return configSourcesFor(invocation, {
    worktree: WORKTREE_PROBE,
    home: HOME_PROBE,
  }).every((candidate) => !isInsideWorktreeProbe(candidate));
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

  const raw = flagValue(argv, SETTINGS_FLAG);
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
  // strictAllowlist が立っていることだけを見ると、広げた allowlist を忍ばせた argv が
  // 「サンドボックスされている」として封印を通る。宣言した許可リストと同一であることまで
  // 読み戻す（他のフラグと同じく、読み取れない形・食い違う形は一致とみなさない）。
  const domains = sandbox.network?.allowedDomains;
  if (
    !Array.isArray(domains) ||
    domains.length !== SANDBOX_ALLOWED_DOMAINS.length ||
    !SANDBOX_ALLOWED_DOMAINS.every((domain, index) => domains[index] === domain)
  ) {
    return null;
  }

  const readOnly = flagValue(argv, "--permission-mode") === READ_ONLY_PERMISSION_MODE;
  return { mode: readOnly ? "read-only" : "workspace-write" };
}

// 承認 server の宣言。`env` は受け取らない —— invocation が環境変数・credential のチャネルを
// 持たないという不変条件と揃える（認証は各 CLI のランチャーと keychain が持つ）。
const APPROVAL_SERVER_ARGUMENT_MAX_LENGTH = 256;
const CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/;

// 宣言が運んでよいキー。`env` を名指しで禁じるのではなく、運んでよいものを列挙する
// （新しいキーが増えたとき、禁止リストの追随漏れが素通りにならない）。
const ALLOWED_APPROVAL_SERVER_KEYS = new Set(["command", "args"]);

function approvalArgumentViolation(value, index) {
  if (typeof value !== "string" || value.length === 0) {
    return `args[${index}] must be a non-empty string`;
  }
  if (value.length > APPROVAL_SERVER_ARGUMENT_MAX_LENGTH) {
    return `args[${index}] must be at most ${APPROVAL_SERVER_ARGUMENT_MAX_LENGTH} characters`;
  }
  if (CONTROL_CHARACTERS.test(value)) {
    return `args[${index}] must not contain control characters`;
  }
  return null;
}

// 承認 server 宣言が満たすべき制約。**組み立て（approvalServerConfig）と読み戻し
// （approvalChannelIsAllowlisted）が同じこの 1 つの検証器を通る**ので、片方だけが緩む退行を
// seal が構築時に捕まえられる。違反があればその内容を、無ければ null を返す。
function approvalServerViolation(key, server) {
  try {
    // 同じ形の正規表現を 2 つ持つと必ず drift するので、build 時と同じ検証器をそのまま通す。
    requireToken(key, "key");
  } catch (error) {
    return error.message;
  }
  if (server === null || typeof server !== "object" || Array.isArray(server)) {
    return "must declare the server as an object";
  }
  const unexpected = Object.keys(server).find(
    (name) => !ALLOWED_APPROVAL_SERVER_KEYS.has(name),
  );
  if (unexpected !== undefined) {
    // `env` はここに落ちる。invocation が環境変数・credential のチャネルを持たないという
    // 既存の不変条件と揃える（認証は各 CLI のランチャーと keychain が持つ）。
    return `must not carry ${unexpected}`;
  }
  if (typeof server.command !== "string" || server.command.length === 0) {
    return "command must be a non-empty string";
  }
  // sealInvocation が executable に課すのと同じ理由。相対パスは子の CWD（＝作業ツリー）基準で
  // 解決され、untrusted repository が同梱した実行ファイルを承認 server に据えられる。
  if (!path.isAbsolute(server.command)) return "command must be an absolute path";
  if (!Array.isArray(server.args)) return "args must be an array";
  for (const [index, value] of server.args.entries()) {
    const violation = approvalArgumentViolation(value, index);
    if (violation !== null) return violation;
  }
  return null;
}

function approvalServerConfig(input, promptTool) {
  requireObject(input, `${PROVIDER} approvalServer`);
  const { key, ...server } = input;
  if (server.args === undefined) server.args = [];
  const violation = approvalServerViolation(key, server);
  if (violation !== null) {
    throw new TypeError(`${PROVIDER} approvalServer ${violation}`);
  }
  if (!promptToolTargets(promptTool, key)) {
    throw new TypeError(
      `${PROVIDER} permissionPromptTool must name the declared approval server (mcp__${key}__<tool>)`,
    );
  }
  return { mcpServers: { [key]: server } };
}

function buildArgv({
  prompt,
  model,
  effort,
  sandbox,
  session,
  permissionPromptTool,
  approvalServer,
}) {
  const argv = [
    "-p",
    prompt,
    // #526 §1.4: system/init・assistant・最終 result が NDJSON で流れる。
    "--output-format",
    "stream-json",
    VERBOSE_FLAG,
    "--model",
    model,
    "--effort",
    effort,
    // #526 R2: `-p` は workspace trust を出さず、壊れた設定を黙って無視する。repository 由来の
    // hooks / MCP は起動フラグで事前に遮断する（起動後の init 検査では手遅れになる）。
    // この 2 つを外した argv は sealInvocation が組み立てさせない（readEffectiveConfigIsolation）。
    SETTING_SOURCES_FLAG,
    USER_SETTING_SOURCE,
    STRICT_MCP_CONFIG_FLAG,
    SETTINGS_FLAG,
    JSON.stringify(sandboxSettings()),
  ];
  if (session) argv.push(session.flag, session.value);
  // 承認チャネルの受け口そのものは #533 が作り、配線の要否は #534 の capability registry が決める。
  // ここでは「配線するなら承認 server をちょうど 1 つ inline で宣言する」形だけを組み立てる。
  //
  // **未実測の組合せ（#534 への申し送り）**: `read-only` は下で `--permission-mode dontAsk` を
  // 出すが、#526 §1.2.5［原文］の dontAsk 行は節見出しのとおり「prompt tool を**配線しない**
  // 場合」の挙動であり、§1.2.1 の 2×2 実測にも dontAsk は含まれない。つまり
  // 「dontAsk ＋ prompt tool 配線」で AskUserQuestion が通るかは**どちらの一次ソースでも
  // 確定していない**。ここで拒否も許可も決め打たず、組合せの可否は #533 の受け口の形と
  // #534 の registry 軸で決める（本 issue のスコープ外）。
  if (permissionPromptTool !== undefined || approvalServer !== undefined) {
    if (!permissionPromptTool || !approvalServer) {
      throw new TypeError(
        `${PROVIDER} requires permissionPromptTool and approvalServer together: ` +
          "a prompt tool without a declared server has nothing behind it under --strict-mcp-config, " +
          "and a declared server without a prompt tool is an extra MCP server in the child",
      );
    }
    const tool = requireSafeArgumentValue(
      permissionPromptTool,
      `${PROVIDER} permissionPromptTool`,
    );
    argv.push(MCP_CONFIG_FLAG, JSON.stringify(approvalServerConfig(approvalServer, tool)));
    argv.push(PERMISSION_PROMPT_TOOL_FLAG, tool);
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
      approvalServer: request.approvalServer,
    }),
    phase,
    sandbox,
    readEffectiveSandbox,
    readEffectiveConfigIsolation,
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
    session: sessionId
      ? {
          flag: "--session-id",
          value: requireSafeArgumentValue(sessionId, `${PROVIDER} sessionId`),
        }
      : null,
  });
}

function resume(request) {
  if (!request?.resumeKey) {
    throw new TypeError(`${PROVIDER} resume requires a resumeKey`);
  }
  return seal({
    request,
    phase: "resume",
    session: {
      flag: "--resume",
      // フラグの値として渡るが、値を新しいフラグと再解釈する引数パーサもありうる。
      // model / effort と同じ水準で形を縛り、`-` 始まりを通さない。
      value: requireSafeArgumentValue(request.resumeKey, `${PROVIDER} resumeKey`),
    },
  });
}

// 起動時の健全性確認。**事前遮断の代替ではない**。
//
// 正常に接続して応答するもの（＝エラーを出さないもの）はこの検査を素通りするし、起動直後に走る
// hook はこのイベントが読める時点**より前**に実行される（#526 §1.6 / R2）。安全境界はあくまで
// buildArgv が出す事前遮断フラグであり、この検査はその上に載る二次的な確認である
// —— 設定ミスの検出には有効だが、単独では境界にならない。
export const INIT_PROBLEM_NOT_AN_INIT_EVENT =
  "the structured event was not a system init event";
export const INIT_PROBLEM_APPROVAL_TOOL_MISSING =
  "the child cannot ask the user: AskUserQuestion is absent from its tools";
export const INIT_PROBLEM_APPROVAL_SERVER_UNAVAILABLE =
  "the declared approval server did not report a connected status";
export const INIT_PROBLEM_MCP_SERVER_ERRORS = "the child reported MCP server errors";
export const INIT_PROBLEM_PLUGIN_ERRORS = "the child reported plugin errors";

const ASK_USER_QUESTION_TOOL = "AskUserQuestion";
// #526 §1.4 は system/init が mcp_servers を運ぶことまでを記録している。status の語彙は
// "connected" 以外を実測していないので、読み取れない形は健全と判定しない（fail-closed）。
const CONNECTED_STATUS = "connected";

function isInitEvent(event) {
  return event?.type === "system" && event?.subtype === "init";
}

function hasEntries(value) {
  if (Array.isArray(value)) return value.length > 0;
  if (value !== null && typeof value === "object") return Object.keys(value).length > 0;
  return false;
}

function approvalServerConnected(event, permissionPromptTool) {
  // 形式は buildArgv 側で検証済みだが、この関数は起動シーケンス（配線は #537）から任意の
  // 文字列を渡されうる。許可リストと同じ導出を通し、形が違うものを健全と判定しない。
  const key = approvalServerKeyOf(permissionPromptTool);
  if (key === null) return false;
  const servers = Array.isArray(event.mcp_servers) ? event.mcp_servers : [];
  return servers.some(
    (server) => server?.name === key && server?.status === CONNECTED_STATUS,
  );
}

function initHealth(problems) {
  return Object.freeze({
    healthy: problems.length === 0,
    // 拒否ツールと同じ作法で、**問題の名前だけ**を運ぶ。provider の生の出力は運ばない。
    problems: Object.freeze([...problems]),
  });
}

export function readInitHealth(event, { permissionPromptTool = null } = {}) {
  if (!isInitEvent(event)) return initHealth([INIT_PROBLEM_NOT_AN_INIT_EVENT]);

  const problems = [];
  if (permissionPromptTool) {
    // #526 §1.2.1［実測］: AskUserQuestion の可用性は prompt tool の有無だけで決まる。
    // 配線したのに現れないなら、gate が消えたまま実行が続く（最も嫌う沈黙する故障）。
    const tools = Array.isArray(event.tools) ? event.tools : [];
    if (!tools.includes(ASK_USER_QUESTION_TOOL)) {
      problems.push(INIT_PROBLEM_APPROVAL_TOOL_MISSING);
    }
    if (!approvalServerConnected(event, permissionPromptTool)) {
      problems.push(INIT_PROBLEM_APPROVAL_SERVER_UNAVAILABLE);
    }
  }
  if (hasEntries(event.mcp_server_errors)) problems.push(INIT_PROBLEM_MCP_SERVER_ERRORS);
  if (hasEntries(event.plugin_errors)) problems.push(INIT_PROBLEM_PLUGIN_ERRORS);
  return initHealth(problems);
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
  readEffectiveConfigIsolation,
  interpret,
  // 契約の一部ではなく Claude 固有の追加。他 provider は system/init 相当の構造化イベントを
  // 持たないので、共通メソッドには昇格させない。起動シーケンスへの配線は #537。
  readInitHealth,
});
