import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { claudeAdapter } from "../home/dot_local/lib/frontier-harness/adapter-claude.mjs";

// サンドボックスが「設定されている」ことと「実際に拒否する」ことは別である（#535）。
//
// 2026-08-30 の `fh session` 実走で、fake spawn のテストが 1 件も捕まえなかった欠陥が 7 件出た。
// うち 2 件はサンドボックスの実効性そのものだった —— `SANDBOX_ALLOWED_DOMAINS` が空で
// 「許可リストがあるのにどのホストへも到達できない」状態、および `gh` が trustd に阻まれる
// 状態。どちらも設定 JSON を読み返すテストでは成立してしまう形である。
//
// このファイルが見るのは**観測できる副作用**だけである:
//
// - ファイル書き込みは、親プロセスから対象パスの存在を見る。終了コードだけで判定すると
//   「拒否された」と「コマンドが見つからなかった」を取り違える。
// - ネットワークは、同じコマンドを sandbox 無しで先に走らせ（ベースライン）、
//   sandbox 下でだけ失敗することを見る。ベースラインが取れない環境では偽合格させない。
//
// **実 provider の課金枠にも認証情報にも依存しない**（#535 の完了条件）。`claude -p` も
// `codex exec` も起動しない。使うのは、モデルを一切呼ばない 2 つの経路だけである。
//
// ## Claude leg が posture 読み戻しに留まる理由（既知のギャップ）
//
// Codex には `codex sandbox <COMMAND>...` があり、モデル呼び出し無しで任意のコマンドを実
// Seatbelt 下に走らせられる。**Claude Code に同等のサブコマンドは無い**（`claude sandbox`
// 配下は隠しの `status` と Windows 用 `install` だけ。2026-08-30 に総当たりで実測）。
// 封じ込めを実際に踏ませるには `claude -p` の課金セッションが要るため、リポジトリには置かない。
// したがって Claude 側で確認できるのは「vendor 自身が我々の blob をどう解釈したか」までであり、
// **これは封じ込めの証明ではない**。この非対称は意図的に残してある。

// ---------------------------------------------------------------------------
// skip の分類
// ---------------------------------------------------------------------------

// **skip してよい理由の閉じた集合。** #535 の完了条件が名指しするとおり、
// 「サンドボックスが無いから skip」と「テストが壊れているから skip」は区別できなければ
// ならない。前者だけがここに載る。集合に無い失敗は skip ではなく `broken` になり、
// テストを落とす —— 判別できない skip を許した瞬間、この回帰テスト自身が
// #535 の塞ごうとしている fail-open になる。
const SKIP_RUNNER_MISSING = "runner-missing";
const SKIP_NESTED_SANDBOX = "nested-sandbox-unavailable";
const SKIP_SANDBOX_UNSUPPORTED = "sandbox-unsupported";
const SKIP_NO_BASELINE = "no-baseline";

const ALLOWED_SKIP_REASONS = Object.freeze(
  new Set([
    // 対象 CLI がこのマシンに無い（CI コンテナなど）。
    SKIP_RUNNER_MISSING,
    // 外側に既にサンドボックスがあり、入れ子にできない。macOS の Seatbelt は入れ子を
    // 許さず、`sandbox_apply` が `Operation not permitted` で落ちる（実測）。
    // 公式が言う `enableWeakerNestedSandbox` は［原文］"Run the **Linux** sandbox inside an
    // unprivileged container" であって macOS には該当する設定が無い。
    SKIP_NESTED_SANDBOX,
    // vendor 自身が「この環境ではサンドボックスに対応していない」と申告した。
    SKIP_SANDBOX_UNSUPPORTED,
    // プローブの前提が成立しない（sandbox 無しでも失敗する）。ネットワークの無い環境で
    // 「拒否された」と読み違えないための出口。
    SKIP_NO_BASELINE,
  ]),
);

// 入れ子サンドボックスの拒否。実測では `codex sandbox` が終了コード 71 と
// `sandbox-exec: sandbox_apply: Operation not permitted` を返した。文言だけに寄せると
// vendor が包み直したときに黙って `broken` へ倒れるので、両方の綴りを見る。
const NESTED_SANDBOX_PATTERN = /sandbox_apply|sandbox-exec:.*not permitted/i;

function usable() {
  return Object.freeze({ status: "usable" });
}

function unavailable(reason, detail) {
  return Object.freeze({ status: "unavailable", reason, detail: detail ?? "" });
}

function broken(detail) {
  return Object.freeze({ status: "broken", detail });
}

// spawnSync の結果を 3 値に分類する。**未知の失敗はすべて `broken`** に落とす
// （fail-closed）。ここを「分からなければ skip」にすると、壊れたテストが緑のまま残る。
function classifySandboxRunner(result) {
  if (result?.error) {
    const { code, message } = result.error;
    // 対象 CLI がインストールされていない。
    if (code === "ENOENT") return unavailable(SKIP_RUNNER_MISSING, message ?? "");
    // タイムアウト・権限エラーなどは「無い」ではなく「壊れている」。
    return broken(`the runner could not be spawned (${code ?? message})`);
  }
  // シグナルで殺された、あるいは終了コードが取れなかった。
  if (result?.status === null || result?.status === undefined) {
    return broken(`the runner did not exit normally (signal ${result?.signal ?? "unknown"})`);
  }
  if (result.status === 0) return usable();

  const output = `${result.stderr ?? ""}\n${result.stdout ?? ""}`;
  if (NESTED_SANDBOX_PATTERN.test(output)) {
    return unavailable(SKIP_NESTED_SANDBOX, output.trim());
  }
  return broken(`the runner exited with ${result.status}: ${output.trim()}`);
}

// `unavailable` のときだけ skip して false を返す。`broken` は skip させずに落とす。
// 呼び出し側は戻り値が false なら即 return する。
function skipUnlessUsable(t, verdict) {
  if (verdict.status === "usable") return true;
  if (verdict.status === "broken") {
    assert.fail(
      `the sandbox is broken here, not absent, so this must not be skipped: ${verdict.detail}`,
    );
  }
  assert.ok(
    ALLOWED_SKIP_REASONS.has(verdict.reason),
    `${verdict.reason} is not an allowed reason to skip a sandbox effectiveness test`,
  );
  // skip した経路は「未検証」であって「合格」ではない。理由を出力に残す。
  t.diagnostic(`sandbox effectiveness unverified here: ${verdict.reason} ${verdict.detail}`);
  t.skip(`sandbox unavailable: ${verdict.reason}`);
  return false;
}

// ---------------------------------------------------------------------------
// プローブの土台
// ---------------------------------------------------------------------------

const PROBE_TIMEOUT_MS = 60_000;

// 拒否されるべきホスト。IANA が予約している安定したホスト名で、どの provider の
// 許可リストにも載っていない。
const FORBIDDEN_HOST = "https://example.com";

// **プローブが実際に走ったことの印。** 「拒否された」と「そもそもシェルが起動しなかった」は、
// 副作用の不在としては見分けが付かない —— 起動に失敗した runner を封じ込めの成功と読むのが、
// #535 の言う fail-open の典型である。標準出力へ先に印を出し、それが返ってきたときだけ
// 「拒否された」と読む。標準出力への書き込みは sandbox の対象外なので read-only でも通る。
//
// この印が届くのは `codex sandbox` が子の stdio をそのまま通すからである（実測: 入れ子
// サンドボックスが拒否されたとき、`sandbox-exec` 自身の stderr がこちらまで届いた）。
// 通らなくなればここが「シェルが走らなかった」として落ちる —— 黙って合格はしない。
const PROBE_MARKER = "fh-probe-ran";

function writeCommand(target) {
  // 単一引用符で括る。プローブのパスは mkdtemp / homedir 由来なので引用符を含まない。
  return `echo ${PROBE_MARKER}; printf probe > '${target}'`;
}

function networkCommand() {
  return `echo ${PROBE_MARKER}; curl -sS -m 10 -o /dev/null ${FORBIDDEN_HOST}`;
}

function probeRan(result) {
  return String(result?.stdout ?? "").includes(PROBE_MARKER);
}

function assertProbeRan(result, label) {
  assert.ok(
    probeRan(result),
    `${label}: the sandboxed shell never ran, so its silence is not evidence of a denial ` +
      `(exit ${result?.status}, stderr ${String(result?.stderr ?? "").trim()})`,
  );
}

function runUnsandboxed(command, cwd) {
  return spawnSync("/bin/sh", ["-c", command], {
    cwd,
    encoding: "utf8",
    timeout: PROBE_TIMEOUT_MS,
  });
}

// `codex sandbox` は「Run commands within a Codex-provided sandbox」（`--help` 原文）で、
// モデルも認証も使わない。sandbox mode は `-c sandbox_mode` の config override で与える
// —— `-C/--cd` を渡すと `--permission-profile` が必須になる（実測）ので、作業ディレクトリは
// spawn 側の cwd で与える。
//
// **`sandbox_workspace_write.network_access` を pin しない**のは意図である。adapter は
// 利用者の `~/.codex/config.toml` の上で `codex exec --sandbox workspace-write` を走らせるので、
// そこでネットワークが開いていれば子でも開いている。ここで上書きすると、実効設定ではなく
// このテストが書いた設定を測ることになる。
function runUnderCodexSandbox({ mode, cwd, command }) {
  return spawnSync(
    "codex",
    ["sandbox", "-c", `sandbox_mode="${mode}"`, "--", "/bin/sh", "-c", command],
    { cwd, encoding: "utf8", timeout: PROBE_TIMEOUT_MS },
  );
}

function makeWorkspace() {
  return mkdtempSync(path.join(tmpdir(), "fh-sandbox-probe-"));
}

let codexVerdict = null;

// codex の preflight。**これは同時に対照でもある**: `workspace-write` で作業ツリー内への
// 書き込みが通ることまで確かめる。ここを見ないと、runner が何をやっても失敗する環境で
// 「すべて拒否された」を封じ込めの成功と読み違える（この種の偽合格が #535 の主題である）。
function codexSandboxVerdict() {
  if (codexVerdict) return codexVerdict;
  const workspace = makeWorkspace();
  try {
    const marker = path.join(workspace, "preflight.txt");
    const result = runUnderCodexSandbox({
      mode: "workspace-write",
      cwd: workspace,
      command: writeCommand(marker),
    });
    const verdict = classifySandboxRunner(result);
    if (verdict.status === "usable" && !probeRan(result)) {
      codexVerdict = broken("codex exited cleanly without running the shell it was handed");
      return codexVerdict;
    }
    if (verdict.status === "usable" && !existsSync(marker)) {
      codexVerdict = broken(
        "codex reported success but the workspace write it was asked to make never landed",
      );
      return codexVerdict;
    }
    codexVerdict = verdict;
    return codexVerdict;
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// skip 判断そのもののテスト（サンドボックスの有無に関係なく必ず走る）
// ---------------------------------------------------------------------------

test("a missing runner is an allowed skip, not a failure", () => {
  const verdict = classifySandboxRunner({
    error: Object.assign(new Error("spawnSync codex ENOENT"), { code: "ENOENT" }),
  });
  assert.equal(verdict.status, "unavailable");
  assert.equal(verdict.reason, SKIP_RUNNER_MISSING);
});

test("an outer sandbox that refuses nesting is an allowed skip", () => {
  // 実測（本ファイルを書いた環境）: `codex sandbox -- /usr/bin/true` が
  // 終了コード 71 と次の 1 行で落ちる。
  const verdict = classifySandboxRunner({
    status: 71,
    stderr: "sandbox-exec: sandbox_apply: Operation not permitted\n",
    stdout: "",
  });
  assert.equal(verdict.status, "unavailable");
  assert.equal(verdict.reason, SKIP_NESTED_SANDBOX);
});

test("a runner that exits cleanly is usable", () => {
  assert.equal(classifySandboxRunner({ status: 0, stderr: "", stdout: "" }).status, "usable");
});

test("an unrecognised runner failure is broken, never a skip", () => {
  // 実測: 未知の mode 名は終了コード 1 と `unknown variant` で落ちる。入れ子不可とは
  // まったく別の失敗なので、skip に混ぜてはいけない。
  const misconfigured = classifySandboxRunner({
    status: 1,
    stderr: "Error: unknown variant `nonsense`, expected one of `read-only`\n",
    stdout: "",
  });
  assert.equal(misconfigured.status, "broken");

  const timedOut = classifySandboxRunner({
    error: Object.assign(new Error("timeout"), { code: "ETIMEDOUT" }),
  });
  assert.equal(timedOut.status, "broken");

  const killed = classifySandboxRunner({ status: null, signal: "SIGKILL" });
  assert.equal(killed.status, "broken");
});

test("only the closed set of reasons can turn into a skip", () => {
  const calls = [];
  const recorder = {
    skip: (m) => calls.push(["skip", m]),
    diagnostic: (m) => calls.push(["diagnostic", m]),
  };

  assert.equal(skipUnlessUsable(recorder, usable()), true);
  assert.deepEqual(calls, []);

  assert.equal(skipUnlessUsable(recorder, unavailable(SKIP_NESTED_SANDBOX, "nested")), false);
  assert.deepEqual(
    calls.map(([kind]) => kind),
    ["diagnostic", "skip"],
  );

  // 集合に無い理由は、たとえ `unavailable` の形をしていても通さない。
  assert.throws(
    () => skipUnlessUsable(recorder, unavailable("i-gave-up", "")),
    /not an allowed reason to skip/,
  );
  // `broken` は skip に化けない —— これが fail-open を締め出す最後の砦である。
  const before = calls.length;
  assert.throws(
    () => skipUnlessUsable(recorder, broken("the runner segfaulted")),
    /broken here, not absent/,
  );
  assert.equal(calls.length, before, "a broken runner must not be reported as a skip");
});

test("a probe that never ran is not read as a denial", () => {
  // 副作用が無いことは、拒否の証拠にも「起動しなかった」証拠にもなる。印が返って
  // きていなければ、拒否として読んではいけない。
  assert.throws(
    () => assertProbeRan({ status: 1, stdout: "", stderr: "codex: could not start" }, "read-only"),
    /never ran/,
  );
  assert.doesNotThrow(() =>
    assertProbeRan({ status: 1, stdout: `${PROBE_MARKER}\n`, stderr: "" }, "read-only"),
  );
});

// ---------------------------------------------------------------------------
// Codex: 実際の封じ込め（ファイル書き込み）
// ---------------------------------------------------------------------------

test("codex denies a workspace write under read-only and allows it under workspace-write", (t) => {
  const verdict = codexSandboxVerdict();
  if (!skipUnlessUsable(t, verdict)) return;

  const workspace = makeWorkspace();
  t.after(() => rmSync(workspace, { recursive: true, force: true }));

  // 同じコマンドを 2 つの mode で走らせる。結果が反転することが、拒否が policy から
  // 来ていること（コマンドの綴り間違いや権限の偶然ではないこと）の証明になる。
  const denied = path.join(workspace, "read-only.txt");
  const readOnly = runUnderCodexSandbox({
    mode: "read-only",
    cwd: workspace,
    command: writeCommand(denied),
  });
  assertProbeRan(readOnly, "read-only");
  assert.equal(existsSync(denied), false, "read-only let a write into the workspace land");

  const allowed = path.join(workspace, "workspace-write.txt");
  const writable = runUnderCodexSandbox({
    mode: "workspace-write",
    cwd: workspace,
    command: writeCommand(allowed),
  });
  assertProbeRan(writable, "workspace-write");
  assert.equal(
    existsSync(allowed),
    true,
    "workspace-write blocked a write it is supposed to allow, so the denial above proves nothing",
  );
});

test("codex denies a write outside the workspace, and stops once the mode is weakened", (t) => {
  const verdict = codexSandboxVerdict();
  if (!skipUnlessUsable(t, verdict)) return;

  // #526 付録 A-5 と同じ形の外部プローブ。$HOME は workspace-write の書き込み可能
  // ルートに含まれない。
  const outside = path.join(
    homedir(),
    `.fh-sandbox-effectiveness-probe-${process.pid}-${Date.now()}`,
  );
  t.after(() => rmSync(outside, { force: true }));

  const workspace = makeWorkspace();
  t.after(() => rmSync(workspace, { recursive: true, force: true }));

  // ベースライン: sandbox 無しでそこへ書けること。書けない環境で「拒否された」と
  // 読むのは偽合格なので、その場合は assert せず skip する。
  const baseline = runUnsandboxed(writeCommand(outside), workspace);
  // ベースラインのシェルすら起動していないなら、それは「書けない環境」ではなく壊れている。
  if (!probeRan(baseline)) {
    skipUnlessUsable(t, broken(`the unsandboxed baseline never ran: ${baseline.stderr}`));
    return;
  }
  if (!existsSync(outside)) {
    skipUnlessUsable(
      t,
      unavailable(SKIP_NO_BASELINE, `${outside} is not writable without a sandbox`),
    );
    return;
  }
  rmSync(outside, { force: true });

  for (const mode of ["read-only", "workspace-write"]) {
    const blocked = runUnderCodexSandbox({ mode, cwd: workspace, command: writeCommand(outside) });
    assertProbeRan(blocked, mode);
    assert.equal(existsSync(outside), false, `${mode} let a write outside the workspace land`);
  }

  // **設定を弱めると同じプローブが通る**（#535 の完了条件の機械化）。これが通らない場合、
  // 上の 2 件は封じ込めではなく別の理由で失敗していたことになる。
  const opened = runUnderCodexSandbox({
    mode: "danger-full-access",
    cwd: workspace,
    command: writeCommand(outside),
  });
  assertProbeRan(opened, "danger-full-access");
  assert.equal(
    existsSync(outside),
    true,
    "weakening the mode did not change the outcome, " +
      "so the denials above are not attributable to the sandbox",
  );
});

// ---------------------------------------------------------------------------
// Codex: 実際の封じ込め（ネットワーク）
// ---------------------------------------------------------------------------

test("codex denies outbound network, and stops denying it when the mode is weakened", (t) => {
  const verdict = codexSandboxVerdict();
  if (!skipUnlessUsable(t, verdict)) return;

  const workspace = makeWorkspace();
  t.after(() => rmSync(workspace, { recursive: true, force: true }));

  // ネットワークの拒否は終了コードでしか観測できないので、ベースラインが要る。
  // sandbox 無しで届かないホストは、sandbox 下で届かなくても何も証明しない。
  const baseline = runUnsandboxed(networkCommand(), workspace);
  if (!probeRan(baseline)) {
    skipUnlessUsable(t, broken(`the unsandboxed baseline never ran: ${baseline.stderr}`));
    return;
  }
  if (baseline.status !== 0) {
    const detail = `${FORBIDDEN_HOST} is unreachable without a sandbox here`;
    skipUnlessUsable(t, unavailable(SKIP_NO_BASELINE, detail));
    return;
  }

  for (const mode of ["read-only", "workspace-write"]) {
    const blocked = runUnderCodexSandbox({ mode, cwd: workspace, command: networkCommand() });
    assertProbeRan(blocked, mode);
    assert.notEqual(blocked.status, 0, `${mode} let an outbound connection through`);
  }

  const opened = runUnderCodexSandbox({
    mode: "danger-full-access",
    cwd: workspace,
    command: networkCommand(),
  });
  assertProbeRan(opened, "danger-full-access");
  assert.equal(
    opened.status,
    0,
    "weakening the mode did not restore network access, " +
      "so the denials above are not attributable to the sandbox",
  );
});

// ---------------------------------------------------------------------------
// Claude: vendor 側の posture 読み戻し
// ---------------------------------------------------------------------------

// `claude sandbox status`［--help 原文］: "Print the effective sandbox posture (enabled, its
// source, strict mode, filesystem policy) ... as one JSON line"。モデルを呼ばないので
// 認証も課金も要らず、入れ子サンドボックスにも当たらない。
//
// **これは封じ込めの証明ではない。** 証明しているのは「adapter が出す blob を Claude Code
// 自身がどう解釈したか」までである。それでも、我々が JSON を読み返すだけのテストには
// 原理的に見えないもの —— キー名の drift や、blob が黙って無視される経路 —— を捕まえる。
//
// **posture が写すのは 5 つの sandbox ノブのうち 2 つだけである**（実測 claude 2.1.251。
// 実 blob を 1 ノブずつ弱めて確認した）:
//
// | posture の欄 | 追随するノブ |
// |---|---|
// | `enabled` | `sandbox.enabled` |
// | `strictMode` | `sandbox.allowUnsandboxedCommands`（false ＝ strict） |
//
// `network.strictAllowlist` / `network.allowedDomains` / `failIfUnavailable` /
// `filesystem` を弱めても posture は動かない。**綴りが近いので取り違えやすいが、
// `strictMode` は allowlist の厳格さではなく「失敗したコマンドを sandbox の外で
// 再試行させない」ことを指す。** これら 4 つの実効性はここでは確認できず、
// `codex` leg のような実封じ込めプローブか、`claude -p` の課金セッションを要する。
const CLAUDE_STATUS_VERSION = 2;

function claudeSandboxPosture(settingsBlob) {
  return spawnSync(
    "claude",
    [
      // 実行マシンの user settings を読ませない。読ませると、この検査は
      // 「blob が posture を立てたか」ではなく「このマシンの設定がどうだったか」を測る。
      "--setting-sources",
      "",
      "--settings",
      settingsBlob,
      "sandbox",
      "status",
    ],
    { encoding: "utf8", timeout: PROBE_TIMEOUT_MS },
  );
}

// 1 行 JSON を取り出す。更新通知などが混ざっても壊れないよう、statusVersion を持つ行を探す。
function parsePosture(stdout) {
  for (const line of String(stdout ?? "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed === "object" && "statusVersion" in parsed) return parsed;
    } catch {
      // JSON でない行は読み飛ばす。
    }
  }
  return null;
}

function claudeSettingsBlob() {
  const invocation = claudeAdapter.launch({
    prompt: "probe the sandbox posture",
    executable: "/usr/local/bin/claude",
    model: "gpt-5.6-terra",
    effort: "xhigh",
    sandbox: { mode: "workspace-write" },
    // adapter が実際に描く形に揃える（filesystem ブロックを含む blob を食わせる）。
    codexHome: path.join(tmpdir(), "fh-codex-home-probe"),
  });
  return invocation.argv[invocation.argv.indexOf("--settings") + 1];
}

// posture を読むか、読めない理由を分類する。ここでも「読めなかった」は skip ではない。
function readPosture(settingsBlob) {
  const result = claudeSandboxPosture(settingsBlob);
  const verdict = classifySandboxRunner(result);
  if (verdict.status !== "usable") return { verdict, posture: null };
  const posture = parsePosture(result.stdout);
  if (!posture) {
    return {
      verdict: broken(`claude sandbox status printed no posture line: ${result.stdout}`),
      posture: null,
    };
  }
  if (posture.statusVersion !== CLAUDE_STATUS_VERSION) {
    // 契約 drift は黙らせない。skip にすると、形が変わった日から検査が消える。
    return {
      verdict: broken(
        `claude sandbox status moved to statusVersion ${posture.statusVersion}; ` +
          "re-read the fields before trusting this check again",
      ),
      posture: null,
    };
  }
  if (posture.supported !== true) {
    return {
      verdict: unavailable(SKIP_SANDBOX_UNSUPPORTED, "claude reports the sandbox as unsupported"),
      posture: null,
    };
  }
  return { verdict: usable(), posture };
}

test("claude reads the adapter's settings blob back as a policy-driven sandbox", (t) => {
  const { verdict, posture } = readPosture(claudeSettingsBlob());
  if (!skipUnlessUsable(t, verdict)) return;

  // 「有効になっている」だけでなく「我々が渡した policy が源である」ことまで見る。
  // source を見ないと、マシン側の設定でたまたま立っている状態と区別できない。
  assert.equal(posture.enabled, true);
  assert.equal(posture.enabledSource, "policy");
  // ＝ `allowUnsandboxedCommands: false` が効いている。失敗したコマンドを sandbox の外へ
  // 出す escape hatch が閉じているということで、#535 の言う fail-open の 1 経路にあたる。
  assert.equal(posture.strictMode, true);
  assert.equal(posture.strictModeSource, "policy");
  assert.equal(posture.unavailableReason, null);
});

test("weakening the settings blob drops the posture claude reports", (t) => {
  const pinned = JSON.parse(claudeSettingsBlob());

  // 弱め方は #535 の完了条件（「設定を弱めると当該テストが失敗する」）を機械化するために
  // 選んである。**posture が追随するノブに限ってある** —— `strictAllowlist` を落としても
  // posture は動かないので（上の表）、ここに混ぜると「弱めても検知できない」ことを
  // 検知したつもりになる。
  const weakened = {
    "the sandbox block removed": (settings) => {
      delete settings.sandbox;
    },
    "the sandbox switched off": (settings) => {
      settings.sandbox.enabled = false;
    },
    "the unsandboxed retry re-opened": (settings) => {
      settings.sandbox.allowUnsandboxedCommands = true;
    },
  };

  for (const [label, weaken] of Object.entries(weakened)) {
    const settings = structuredClone(pinned);
    weaken(settings);
    const { verdict, posture } = readPosture(JSON.stringify(settings));
    if (!skipUnlessUsable(t, verdict)) return;
    assert.ok(
      posture.enabled !== true || posture.strictMode !== true,
      `${label} left the posture intact, so this check cannot detect a weakened sandbox`,
    );
  }
});
