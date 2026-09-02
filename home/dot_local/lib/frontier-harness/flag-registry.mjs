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

// 全コマンドに効く。出力形式の選択はコマンドの機能ではないので、各エントリに書かない。
const GLOBAL_BOOLEAN = Object.freeze(["--json"]);

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
