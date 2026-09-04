// Bash ツールが渡すコマンド文字列を、escalation ルールが照合できる形へ正規化する。
//
// 生文字列へ正規表現を直接当てると、binary の直後に subcommand が来る形しか拾えない。
// `git -C <path> merge` のように global option を挟んだだけで escalation を素通りし、
// これは wave の子が日常的に書く形なので実運用で確実に踏む。
//
// かといって「option らしきものを読み飛ばす」汎用の正規表現では arity を判定できない:
//
//   - `git -C merge status` … `merge` は `-C` の値で、実際の subcommand は良性の `status`
//   - `git -p merge`        … `-p` は値を取らないので、次を値扱いすると危険な merge を見逃す
//
// よってトークン化したうえで、**binary ごとの global option arity 表**で subcommand を
// 確定させる。表に無い option や動的構築が現れたら解釈を諦め、呼び出し側が escalate へ
// 倒せるよう ambiguous を返す（fail-safe）。

// 解釈を諦める理由。呼び出し側はこれを見て escalate する。
export const AMBIGUOUS_DYNAMIC = "command name or subcommand is built dynamically";
export const AMBIGUOUS_UNKNOWN_OPTION = "an unrecognized global option makes the subcommand ambiguous";
export const AMBIGUOUS_NESTED_SHELL = "the command runs another command through a shell or wrapper";

// 別のコマンドを引数として実行するもの。中身を静的に解釈できないので escalate に倒す。
// `sudo` / `env` のような prefix 系もここに含める。これらの option arity まで正確に
// 追うより、そのまま user に問うほうが安全で、wave の子が使う頻度も低い。
const NESTED_SHELL_BINARIES = new Set([
  "bash",
  "command",
  "dash",
  "doas",
  "env",
  "eval",
  "exec",
  "ksh",
  "nice",
  "nohup",
  "sh",
  "sudo",
  "time",
  "timeout",
  "xargs",
  "zsh",
]);

// subcommand より前に現れる global option だけを列挙する。subcommand 以降の option は
// 走査対象外なので表に載せる必要はない（`git commit --no-verify` の `--no-verify` 等）。
// `--name=value` 形式は値を自分で抱えるため arity 判定が要らない。
const GLOBAL_OPTIONS = Object.freeze({
  git: {
    valued: new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"]),
    flags: new Set([
      "-p",
      "-P",
      "-v",
      "-h",
      "--paginate",
      "--no-pager",
      "--bare",
      "--no-replace-objects",
      "--literal-pathspecs",
      "--glob-pathspecs",
      "--noglob-pathspecs",
      "--icase-pathspecs",
      "--no-optional-locks",
      "--no-advice",
      "--exec-path",
      "--html-path",
      "--man-path",
      "--info-path",
      "--version",
      "--help",
    ]),
  },
  gh: {
    valued: new Set(["-R", "--repo"]),
    flags: new Set(["--help", "--version"]),
  },
  npm: {
    valued: new Set(["--prefix", "-C", "--workspace", "-w", "--registry", "--userconfig", "--globalconfig"]),
    flags: new Set(["--workspaces", "-g", "--global", "--silent", "--version", "-v", "--help"]),
  },
  pnpm: {
    valued: new Set(["--dir", "-C", "--filter", "-F", "--workspace-root", "-w"]),
    flags: new Set(["--recursive", "-r", "--silent", "--version", "-v", "--help"]),
  },
  yarn: {
    valued: new Set(["--cwd"]),
    flags: new Set(["--silent", "--version", "-v", "--help"]),
  },
  bun: {
    valued: new Set(["--cwd", "--config", "-c"]),
    flags: new Set(["--silent", "--version", "-v", "--help"]),
  },
  cargo: {
    valued: new Set(["--config", "-Z", "--color"]),
    flags: new Set(["--offline", "--frozen", "--locked", "-q", "--quiet", "--version", "-V", "--help"]),
  },
  docker: {
    valued: new Set(["--context", "--config", "-H", "--host", "--log-level", "--tlscacert", "--tlscert", "--tlskey"]),
    flags: new Set(["-D", "--debug", "--tls", "--tlsverify", "--version", "-v", "--help"]),
  },
  podman: {
    valued: new Set(["--connection", "-c", "--root", "--runroot", "--url", "--log-level"]),
    flags: new Set(["--remote", "-r", "--version", "-v", "--help"]),
  },
  kubectl: {
    valued: new Set(["--context", "--namespace", "-n", "--kubeconfig", "--cluster", "--user", "--server", "-s"]),
    flags: new Set(["--version", "--help", "-h"]),
  },
  helm: {
    valued: new Set(["--kube-context", "--namespace", "-n", "--kubeconfig", "--registry-config"]),
    flags: new Set(["--debug", "--version", "--help", "-h"]),
  },
  chezmoi: {
    valued: new Set(["--source", "-S", "--destination", "-D", "--config", "-c", "--cache", "--color"]),
    flags: new Set(["--dry-run", "-n", "--verbose", "-v", "--force", "--version", "--help", "-h"]),
  },
  terraform: {
    valued: new Set(["-chdir"]),
    flags: new Set(["-help", "-version", "--help", "--version"]),
  },
});

// subcommand でルールが決まる binary。この集合に限り「最初の引数が動的に組み立てられて
// いる」ことを解釈不能として扱う。`echo "$(date)"` のように subcommand の概念が無い
// コマンドまで巻き込むと、引数の置換を使う日常的な操作がすべてエスカレートしてしまい、
// 無人 wave の目的そのものを損なう。
//
// **帰属基準は「escalation ルールが subcommand ごと名指しする binary であること」**で
// あって、「第 1 引数が何を実行するか決めること」ではない。ここが立てる ambiguous が
// 防ぐのは「subcommand を読み違えて deny ルールを見逃す」ことだけなので、その binary を
// subcommand 込みで名指すルールが 1 本も無ければ、防ぐ対象そのものが存在しない。
// 現メンバーは全員 approval-rules-baseline.mjs のいずれかのルールに名指しされている。
//
// この基準により `make` / `go` / `pytest` は**入れない**。manifest が承認しうる runner
// （manifest-policy.mjs の `APPROVABLE_*`）ではあるが baseline ルールが名指ししないので、
// 足しても `make -C "$DIR" lint` / `pytest -k "$PAT"` が同期問い合わせに変わるだけで、
// 見逃しうるルールは 1 本も増えない。承認済みコマンドとの照合を fail-closed に保つ役目は
// この集合ではなく、下の `analyzeShellCommand` が返す `dynamic` が別経路で担っている。
const SUBCOMMAND_DISPATCHED_BINARIES = new Set([
  ...Object.keys(GLOBAL_OPTIONS),
  "alembic",
  "artisan",
  "atlas",
  "aws",
  "az",
  "dbmate",
  "drizzle-kit",
  "fh",
  "fly",
  "flyctl",
  "flyway",
  "frontier-harness",
  "gcloud",
  "gem",
  "goose",
  "knex",
  "op",
  "prisma",
  "rails",
  "rake",
  "security",
  "serverless",
  "sls",
  "sqlx",
  "supabase",
  "tofu",
  "twine",
  "uv",
  "vercel",
  "wrangler",
]);

// `${IFS}` / `$IFS` は bash の既定 IFS が空白なので、単語区切りとして扱う。
// これを展開せずに照合すると、区切りを IFS に置き換えるだけでルールを回避できる。
const IFS_REFERENCE = /^\$\{IFS\}|^\$IFS(?![A-Za-z0-9_])/;

function createToken() {
  return { text: "", dynamic: false };
}

// bash の単語分割・引用・エスケープを、照合に必要な範囲でだけ再現する。
// 完全なシェル文法の実装ではない（それが要るなら実行前解釈そのものを別設計にすべき）。
function tokenize(command) {
  const segments = [];
  let tokens = [];
  let current = null;
  let index = 0;

  const endToken = () => {
    if (current !== null) {
      tokens.push(current);
      current = null;
    }
  };
  const endSegment = () => {
    endToken();
    if (tokens.length > 0) segments.push(tokens);
    tokens = [];
  };
  const add = (character) => {
    if (current === null) current = createToken();
    current.text += character;
  };
  const markDynamic = () => {
    if (current === null) current = createToken();
    current.dynamic = true;
  };

  while (index < command.length) {
    const character = command[index];

    if (character === "\\") {
      // 単語内のバックスラッシュは次の 1 文字そのものを表す。`g\it` を `git` として
      // 扱わないと、1 文字挟むだけでルールを回避できてしまう。
      index += 1;
      if (index < command.length) {
        add(command[index]);
        index += 1;
      }
      continue;
    }

    if (character === "'") {
      index += 1;
      if (current === null) current = createToken();
      while (index < command.length && command[index] !== "'") {
        add(command[index]);
        index += 1;
      }
      index += 1;
      continue;
    }

    if (character === '"') {
      index += 1;
      if (current === null) current = createToken();
      while (index < command.length && command[index] !== '"') {
        if (command[index] === "\\") {
          index += 1;
          if (index < command.length) {
            add(command[index]);
            index += 1;
          }
          continue;
        }
        if (command[index] === "$" || command[index] === "`") markDynamic();
        add(command[index]);
        index += 1;
      }
      index += 1;
      continue;
    }

    if (character === "$" || character === "`") {
      const ifs = IFS_REFERENCE.exec(command.slice(index));
      if (ifs) {
        endToken();
        index += ifs[0].length;
        continue;
      }
      markDynamic();
      add(character);
      index += 1;
      continue;
    }

    if (character === " " || character === "\t") {
      endToken();
      index += 1;
      continue;
    }

    if (character === "\n" || character === ";") {
      endSegment();
      index += 1;
      continue;
    }

    if (character === "&" || character === "|") {
      endSegment();
      index += 1;
      if (command[index] === character) index += 1;
      continue;
    }

    if (character === "(" || character === ")" || character === "{" || character === "}") {
      endSegment();
      index += 1;
      continue;
    }

    add(character);
    index += 1;
  }

  endSegment();
  return segments;
}

function binaryName(text) {
  const separator = Math.max(text.lastIndexOf("/"), text.lastIndexOf("\\"));
  return (separator === -1 ? text : text.slice(separator + 1)).toLowerCase();
}

// global option を読み飛ばして subcommand 以降を返す。表に無い option に当たったら
// 「読み飛ばしてよいか」を判断できないので、諦めて ambiguous を返す。
function skipGlobalOptions(binary, tokens) {
  const table = GLOBAL_OPTIONS[binary];
  // 表が無い binary には読み飛ばすべき global option が無いものとして、そのまま返す。
  //
  // **ここでトークンの dynamic を検査しないのは意図的である。** `ambiguous` は escalation
  // （deny リスト）側で user への同期問い合わせに直結し、無人 wave をその場で止める。表に
  // 無い binary の大半は `cat "$TMPDIR/x"` のように第 1 引数が「実行するもの」ではなく
  // データなので、ここで倒すと日常操作が軒並み止まる（上の SUBCOMMAND_DISPATCHED_BINARIES
  // のコメントと同じ理由）。
  //
  // **allowlist 側の fail-closed はこの非対称に依存していない。** `analyzeShellCommand` が
  // `ambiguous` とは別に返す `dynamic` を manifest-policy.mjs の `commandSegments` が読み、
  // テーブルの有無に関わらず照合を拒否する。`commandSegments` / `matchCommand` の一致判定を
  // 触るときは、この分業を壊していないかを確かめること。
  if (!table) return { rest: tokens, ambiguous: null };
  let index = 0;
  while (index < tokens.length) {
    const token = tokens[index];
    if (token.dynamic) return { rest: null, ambiguous: AMBIGUOUS_DYNAMIC };
    const { text } = token;
    if (text === "--") {
      index += 1;
      break;
    }
    if (text === "-" || !text.startsWith("-")) break;
    const equals = text.indexOf("=");
    const name = equals === -1 ? text : text.slice(0, equals);
    if (table.flags.has(name)) {
      index += 1;
      continue;
    }
    if (table.valued.has(name)) {
      // `--name=value` は値を自分で抱えるので次のトークンを消費しない。
      index += equals === -1 ? 2 : 1;
      continue;
    }
    return { rest: null, ambiguous: AMBIGUOUS_UNKNOWN_OPTION };
  }
  return { rest: tokens.slice(index), ambiguous: null };
}

// `-uf` のような短縮フラグのクラスタは、そのままだと `-f` を要求するルールに一致しない。
// 元のトークンを残したうえで 1 文字ずつに展開したものを併記する（照合対象を増やすだけで、
// 意味解釈には使わない）。
function expandShortClusters(tokens) {
  const expanded = [];
  for (const token of tokens) {
    expanded.push(token);
    if (/^-[A-Za-z]{2,}$/.test(token)) {
      for (const character of token.slice(1)) expanded.push(`-${character}`);
    }
  }
  return expanded;
}

// 照合候補を作る。戻り値の `candidates` は「生文字列 + 正規化した各セグメント」で、
// ルールはこのいずれかに一致すれば escalate になる（候補を増やす方向にしか働かない）。
//
// **`ambiguous` と `dynamic` を分けているのは、呼び出し元 2 つで安全な向きが逆だから。**
//
//   - escalation（approval-rules.mjs の `classifyToolCall`）… ambiguous は user への同期
//     問い合わせになる。増やすと、誰も見ていない wave の子がそこで止まる。
//   - allowlist（manifest-policy.mjs の `commandSegments`）… 解釈不能なら照合を拒否する。
//     増やしても止まるのは未承認のコマンドだけで、人は呼ばれない。
//
// 1 つのフラグで両方を制御すると、片側を安全にしたぶん他方が壊れる。そこで
// `ambiguous`（＝ どのルールが当たるべきか判定できない）は escalation 側だけが読み、
// `dynamic`（＝ トークンのどこかが実行時に組み立てられる）は allowlist 側だけが読む。
// `dynamic` は binary のテーブルに一切依存しないので、表に載らない binary であっても
// 承認済みコマンドとの照合は fail-closed になる。
export function analyzeShellCommand(command) {
  if (typeof command !== "string" || command.length === 0) {
    return { candidates: [], ambiguous: null, dynamic: false };
  }
  const candidates = [command];
  let ambiguous = null;
  let dynamic = false;
  for (const tokens of tokenize(command)) {
    // 下の分岐は解釈を諦めた時点で continue するので、`dynamic` はそれより前に立てる。
    // 後ろに置くと「諦めたセグメントの動的構築」だけが漏れる。
    if (tokens.some((token) => token.dynamic)) dynamic = true;
    const [head, ...rest] = tokens;
    if (head.dynamic) {
      ambiguous ??= AMBIGUOUS_DYNAMIC;
      continue;
    }
    const binary = binaryName(head.text);
    if (NESTED_SHELL_BINARIES.has(binary)) {
      ambiguous ??= AMBIGUOUS_NESTED_SHELL;
      continue;
    }
    const skipped = skipGlobalOptions(binary, rest);
    if (skipped.ambiguous) {
      ambiguous ??= skipped.ambiguous;
      continue;
    }
    // subcommand 位置が動的に組み立てられていると、どのルールが当たるべきかを
    // 判定できない。引数側の置換（`git commit -m "$(...)"` 等）までは咎めない。
    if (skipped.rest[0]?.dynamic && SUBCOMMAND_DISPATCHED_BINARIES.has(binary)) {
      ambiguous ??= AMBIGUOUS_DYNAMIC;
    }
    const words = expandShortClusters(skipped.rest.map((token) => token.text));
    candidates.push([binary, ...words].join(" "));
  }
  return { candidates, ambiguous, dynamic };
}
