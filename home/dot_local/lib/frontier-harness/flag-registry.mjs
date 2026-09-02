// 各コマンドが受け付けるフラグの唯一の一覧。未知のフラグはここで拒否する。
//
// **なぜ拒否するのか。** `fh` は fail-closed を柱にしている —— `fh session` は揃っていない argv の
// 組み立てを拒み、`fh onboard` は未承認の manifest で exit 2 に落ちる。そのなかでフラグ面だけが
// fail-open で、打ち間違えたフラグを黙って捨てていた。`fh clean --dryrun` は `--dry-run` の
// 打ち間違いだが、確認のつもりの実行がそのまま実プルーンになる（raw evidence 30 日 /
// 集約テレメトリ 180 日で、消えたものは戻らない）。
//
// **なぜ表にするのか。** `fh` は wave orchestration の実行経路そのもので、既知フラグの取りこぼしは
// 子セッションが起動しなくなることを意味する。各コマンドの実装に散らばった「読んでいるフラグ」を
// 1 つの表に集め、テスト（tests/frontier_harness_cli_quality.test.mjs）が
// コマンド実装の側から表の網羅を検証する。

const EMPTY = Object.freeze([]);

// 全コマンドに効く。出力形式の選択も自己記述もコマンドの機能ではないので、各エントリに書かない。
//
// **`--help` はここに載る。** 以前は表から漏れていたため `fh approvals --help` が
// `unknown flag --help` になり、サブコマンドの出力形状を CLI から引く手段が無かった
// （その欠落が、監視スクリプトの形状取り違えを 42 分にわたって沈黙させた）。fail-closed は
// 「未知のフラグを拒む」ことであって「`--help` を拒む」ことではないので、直し方は例外の
// 追加ではなく表への追加になる —— `--help` も他と同じく、表に載っているから通る。
const GLOBAL_BOOLEAN = Object.freeze(["--json", "--help"]);

function spec({ boolean = EMPTY, value = EMPTY, actions } = {}) {
  return Object.freeze({
    boolean: Object.freeze([...GLOBAL_BOOLEAN, ...boolean]),
    value: Object.freeze([...value]),
    actions: actions
      ? Object.freeze(
          Object.fromEntries(
            Object.entries(actions).map(([name, entry]) => [
              name,
              Object.freeze({
                boolean: Object.freeze([...(entry.boolean ?? EMPTY)]),
                value: Object.freeze([...(entry.value ?? EMPTY)]),
              }),
            ]),
          ),
        )
      : null,
  });
}

// `actions` を持つコマンドでは、外側の boolean / value が全サブコマンドに効き、
// `actions` 側はそのサブコマンドだけに効く（`--resume-key` は resume だけ、など）。
export const COMMAND_FLAGS = Object.freeze({
  approvals: spec({ boolean: ["--all", "--purge"], value: ["--approvals-dir"] }),
  approve: spec({
    boolean: ["--allow", "--deny"],
    value: ["--approvals-dir", "--request", "--answers", "--message"],
  }),
  "approve-server": spec({
    value: [
      "--approvals-dir",
      "--session",
      "--rules",
      "--timeout-ms",
      "--progress-interval-ms",
    ],
  }),
  candidate: spec({
    value: ["--worktree"],
    actions: {
      create: { value: ["--task", "--base", "--label"] },
      list: {},
      adopt: { value: ["--candidate"] },
      discard: { value: ["--candidate"] },
    },
  }),
  clean: spec({ boolean: ["--dry-run"], value: ["--now"] }),
  doctor: spec({ boolean: ["--probe"] }),
  gaps: spec(),
  onboard: spec({
    boolean: ["--from-gaps", "--approve"],
    value: ["--manifest", "--request"],
  }),
  review: spec({
    value: ["--worktree"],
    actions: {
      packet: { value: ["--task", "--out", "--base"] },
      record: { value: ["--task", "--findings"] },
    },
  }),
  run: spec({ value: ["--task"] }),
  session: spec({
    value: [
      "--worktree",
      "--prompt-file",
      "--capability",
      "--label",
      "--sandbox",
      "--approvals-dir",
      "--approval-server-command",
      "--timeout-ms",
      "--progress-interval-ms",
      // 完了条件。繰り返して複数のチェックを宣言できる（assertKnownFlags は値を取る
      // フラグの次のトークンを読み飛ばすので、繰り返しはそのまま通る）。
      "--gate",
      "--gate-timeout-ms",
    ],
    actions: {
      launch: { value: ["--session-id"] },
      resume: { value: ["--resume-key"] },
    },
  }),
  runs: spec({ value: ["--limit", "--offset", "--run"] }),
  status: spec({ value: ["--limit", "--offset"] }),
  verify: spec({
    value: [
      "--task",
      "--command",
      "--kind",
      "--worktree",
      "--candidate",
      "--timeout-ms",
    ],
  }),
});

// 表に載っているフラグ名すべて。テストが「実装が読んでいるフラグ」との差分を取るのに使う。
export function knownFlagNames() {
  const names = new Set();
  for (const entry of Object.values(COMMAND_FLAGS)) {
    for (const name of [...entry.boolean, ...entry.value]) names.add(name);
    for (const action of Object.values(entry.actions ?? {})) {
      for (const name of [...action.boolean, ...action.value]) names.add(name);
    }
  }
  return names;
}

function resolveScope(command, flags) {
  const entry = COMMAND_FLAGS[command];
  // 未知のコマンドはこの層の担当ではない。usage を出す既存の経路に任せる。
  if (!entry) return null;
  if (!entry.actions) {
    return { label: command, boolean: entry.boolean, value: entry.value };
  }
  const action = flags[0];
  const selected = Object.hasOwn(entry.actions, action) ? entry.actions[action] : null;
  // サブコマンドが解決できないときも黙る。`fh review requires packet or record, not ...` の
  // ような名指しのエラーのほうが、フラグの話より先に読まれるべき情報である。
  if (!selected) return null;
  return {
    label: `${command} ${action}`,
    boolean: [...entry.boolean, ...selected.boolean],
    value: [...entry.value, ...selected.value],
  };
}

// `--json` / `--help` が**フラグ位置**に現れたかを調べる。値として渡された文字列がたまたま
// `--json` / `--help` と一致しても、それは値であってフラグではない。
//
// **なぜ要るのか。** `assertKnownFlags` は値を取るフラグの次のトークンを、内容を見ずに値として
// 読み飛ばす（`--timeout-ms -1` を通すための意図的な設計）。そこへ `cli.mjs` が
// `flags.includes("--help")` のような位置非依存の判定を重ねると、
// `fh approve --request <id> --deny --message "--help"` が **承認を記録しないまま help を出して
// exit 0 で終わる**。承認境界を閉じる操作が沈黙して成功に見えるのは、この harness が最も
//避けたい失敗である。走査の規則を 2 か所に書かず、フラグ位置の判定はここに集約する。
//
// 返り値:
//   - `tokens`: フラグ位置に現れたトークンの集合（値は含まない）
//   - `scoped`: スコープが解決したか。`false` は「このコマンド・この action ではフラグを検証
//     できていない」を意味する（`assertKnownFlags` が黙る条件と同じ）
//   - `onlyGlobals`: 全コマンド共通のフラグ以外に、フラグも位置引数も無いか
export function inspectFlags(command, flags) {
  const scope = resolveScope(command, flags);
  // スコープが解決しないと、どのフラグが値を取るのかが分からない。読み飛ばしをやめて
  // 全トークンをフラグ扱いに倒す（`--json` を取りこぼす側ではなく、拾う側に倒す）。
  const valueFlags = new Set(scope?.value ?? EMPTY);
  const globals = new Set(GLOBAL_BOOLEAN);
  const tokens = new Set();
  let onlyGlobals = true;
  for (let index = 0; index < flags.length; index += 1) {
    const token = flags[index];
    if (typeof token !== "string") {
      onlyGlobals = false;
      continue;
    }
    tokens.add(token);
    if (valueFlags.has(token)) {
      // 値は次のトークン。フラグ位置には数えない（`assertKnownFlags` と同じ規則）。
      index += 1;
      onlyGlobals = false;
      continue;
    }
    if (!globals.has(token)) onlyGlobals = false;
  }
  return { tokens, scoped: scope !== null, onlyGlobals };
}

// 未知のフラグをフラグ名付きで拒否する。値を取るフラグの次のトークンは値として読み飛ばす
// （`flagValue` が「後続のフラグを値として受け取らない」規約を持つのと対になる）。
//
// 位置引数（サブコマンド名など）には口を出さない。ここで見るのは `-` で始まるトークンだけである。
export function assertKnownFlags(command, flags) {
  const scope = resolveScope(command, flags);
  if (!scope) return;
  const booleanFlags = new Set(scope.boolean);
  const valueFlags = new Set(scope.value);
  for (let index = 0; index < flags.length; index += 1) {
    const token = flags[index];
    if (typeof token !== "string" || !token.startsWith("-")) continue;
    if (valueFlags.has(token)) {
      // 値は次のトークン。`--timeout-ms -1` のように `-` で始まる値もここで吸収する。
      index += 1;
      continue;
    }
    if (booleanFlags.has(token)) continue;
    const [name] = token.split("=");
    if (name !== token && (valueFlags.has(name) || booleanFlags.has(name))) {
      // `--task=x` は未知のフラグではなく、渡し方の誤り。名指しで直し方を出す。
      throw new TypeError(
        `${name} takes its value as a separate argument: \`${name} <value>\`, not \`${token}\``,
      );
    }
    throw new TypeError(`unknown flag ${token} for \`fh ${scope.label}\``);
  }
}
