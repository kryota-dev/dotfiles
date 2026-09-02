import { spawn as nodeSpawn } from "node:child_process";

import { findCommand } from "./command-paths.mjs";
import { collapseWhitespace, manifestEntryRejection } from "./manifest-policy.mjs";

// 承認済みの決定的チェックを実プロセスとして走らせる唯一の場所。
//
// **判定に使うのは終了コードだけである。** 子の stdout / stderr は親へ継承し（人が端末で
// 読めるように）、harness は 1 バイトも受け取らない。受け取らないことが、`verification_results`
// と evidence に自由文が入らないことの構造的な保証になる —— 「載せない」という規約ではなく、
// 「持っていないので載せられない」という性質にする。`child-runner.mjs` が子の stdout を読むのは
// 起動時検査という別の目的があるからで、ここにその必要は無い。
//
// **シェルを介さない。** `shell: true` にすると、承認済み manifest の照合を通った文字列でも
// 展開・連結の解釈が実行時に復活する。argv は承認可能な形（`manifest-policy.mjs` の
// `APPROVABLE_COMMAND`）を再検査したうえで空白で分割して組み立て、`spawn` へそのまま渡す。

// チェックが終わらないまま harness を占有しない上限。テストスイートは分単位で走りうるので
// 短くしすぎず、しかし無限には待たない。
export const DEFAULT_CHECK_TIMEOUT_MS = 900_000;
// 呼び出し側が伸ばせる上限。`approval-server.mjs` が escalation の待機に上限を課しているのと
// 同じ理由で要る —— チェックの実行中はツリーの書き換えを検知できない窓なので、無制限にできると
// その窓を任意に広げられる。**既定値と対で持つ**: 意味の対になる 2 つの定数が別モジュールに
// 割れていると、片方だけ動かしたときにどちらが効いているのか読めなくなる。
export const MAX_CHECK_TIMEOUT_MS = 3_600_000;
// SIGTERM から SIGKILL までの猶予。`child-runner.mjs` と同じ値を使う（2 つ目の規約を作らない）。
export const CHECK_TERMINATION_GRACE_MS = 5_000;
// 時間切れで終わらせたチェックの終了コード。`timeout(1)` の慣習に合わせる。
// シグナルで終わると exitCode が null になるため、成功と読めない値をここで確定させる。
export const TIMED_OUT_EXIT_CODE = 124;

// 承認済みコマンド文字列を argv へ変換する。
//
// 承認可能な形（`npm run <args>` 等、引数は `[A-Za-z0-9_./:@=-]`）を**実行の直前にもう一度**
// 検査する。`manifest-policy.mjs` は承認と照合の時点で同じ検査をしているが、そこと実行の間に
// 文字列が別経路で組み立て直される余地を残さないため、実行側でも独立に確かめる。
export function checkCommandArgv(command) {
  // **承認ゲートと同じ正規化を先に通す。** `matchCommand` は `collapseWhitespace` を掛けてから
  // 文法を見るので、`npm  run   test` のような空白の揺れは承認を通る。ここで畳まずに検査すると
  // 同じ文字列が実行直前に TypeError になり、「承認は通ったのに実行できない」コマンドができる。
  // 畳まずに `split(" ")` すると argv に空要素が混ざる、という二次被害もある。
  const normalized = collapseWhitespace(command);
  const rejection = manifestEntryRejection("commands", normalized);
  if (rejection) {
    throw new TypeError(`verification command is not in an approvable form: ${rejection}`);
  }
  // 正規化後は単一スペース区切りなので、分割で argv が復元できる。
  return normalized.split(" ");
}

// 実行ファイルを PATH から絶対パスで解決する。相対要素・空要素を候補にしないのは
// `command-paths.mjs` と同じ理由（POSIX の zero-length prefix は CWD を指すため、
// untrusted な checkout が同梱した実行ファイルを掴みうる）。
export function resolveCheckExecutable(binary, environment) {
  const resolved = findCommand(binary, environment.PATH ?? "");
  if (!resolved) {
    throw new TypeError(`${binary} is not on PATH as an absolute executable entry`);
  }
  return resolved;
}

function terminalStatus(exitCode) {
  return exitCode === 0 ? "passed" : "failed";
}

// 呼び出し側が指定した制限時間を、既定と上限に収める。
//
// 同じ式を `fh verify` と `fh session --gate` の 2 か所へ書くと、片方だけ上限を外した
// ときに「どちらの経路から入ったかで効く上限が違う」状態を作れてしまう。クランプは
// チェック実行を所有するこのモジュールの責務として 1 か所に置く。
export function resolveCheckTimeoutMs(requested) {
  return Math.min(requested ?? DEFAULT_CHECK_TIMEOUT_MS, MAX_CHECK_TIMEOUT_MS);
}

// 承認済みチェックを 1 本走らせ、`verification_results` に入る形の結果だけを返す。
//
// 例外は spawn 自体が失敗したときにも投げない。「起動できなかった」は記録すべき事実であって
// 異常終了ではない（`adapters.mjs` の refuse と同じ扱い）。呼び出し側は status を見る。
// `async` にしてあるのは、引数の検証（承認可能な形か、実行ファイルが PATH にあるか）も
// **reject として**返すためである。同期 throw と reject が混ざると、呼び出し側は
// try/catch と .catch の両方を書かないと取りこぼす。
export async function runDeterministicCheck({
  command,
  cwd,
  environment = process.env,
  spawn = nodeSpawn,
  timeoutMs = DEFAULT_CHECK_TIMEOUT_MS,
  terminationGraceMs = CHECK_TERMINATION_GRACE_MS,
}) {
  // 承認可能な形でないコマンドは**使い方の誤り**なので throw する（呼び出し側の引数が違う）。
  const argv = checkCommandArgv(command);
  // 一方、実行ファイルが PATH に無いのは**環境の問題**であって、spawn が EACCES で落ちるのと
  // 同じ種類の「チェックを開始できなかった」である。片方だけ例外にすると、npm 未導入の環境では
  // 検証を試みた事実そのものが記録に残らない。結果として記録する側へ揃える。
  let executable;
  try {
    executable = resolveCheckExecutable(argv[0], environment);
  } catch (error) {
    return {
      status: "errored",
      exitCode: null,
      timedOut: false,
      failureReason: `the verification command could not be started: ${error.message}`,
    };
  }

  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(executable, argv.slice(1), {
        cwd,
        // `environment` を明示的に渡す。渡さなくても Node は `process.env` を継承するので
        // **本番では偶然一致する**が、それはこの引数がチェックの環境を制御している証拠にならない。
        // 将来ここで資格情報を間引く強化を入れたとき、黙って無視される形にしておかない。
        env: environment,
        // stdin は使わない（決定的チェックは対話しない）。stdout / stderr は親へ継承する
        // ので、harness はチェックの出力を一切保持しない。
        stdio: ["ignore", "inherit", "inherit"],
      });
    } catch (error) {
      resolve({
        status: "errored",
        exitCode: null,
        timedOut: false,
        failureReason: `the verification command could not be started: ${error.message}`,
      });
      return;
    }

    // **残余リスク**: kill が届くのは直接の子だけである。`npm run test` のようにチェックが
    // 自分で孫プロセスを起こす場合、孫は SIGTERM / SIGKILL を受け取らずに残りうる。
    // process group ごと落とす（`detached: true` + `process.kill(-pid)`）形は、逆に親が
    // 死んでも 15 分走り続ける孤児を作るため採らない。時間切れは安全弁であって常用経路ではない。
    let settled = false;
    let timedOut = false;
    let killTimer = null;
    const deadline = setTimeout(() => {
      timedOut = true;
      try {
        child.kill("SIGTERM");
      } catch {
        // 既に終了している。close で決着させる。
      }
      killTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // 同上。
        }
      }, terminationGraceMs);
      // 猶予タイマーで event loop を延命させない。
      killTimer.unref?.();
    }, timeoutMs);
    deadline.unref?.();

    const settle = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      if (killTimer !== null) clearTimeout(killTimer);
      resolve(result);
    };

    child.on("error", (error) =>
      settle({
        status: "errored",
        exitCode: null,
        timedOut,
        failureReason: `the verification command could not be started: ${error.message}`,
      }),
    );
    child.on("close", (code) => {
      if (timedOut) {
        settle({
          status: "errored",
          exitCode: TIMED_OUT_EXIT_CODE,
          timedOut: true,
          failureReason: `the verification command exceeded ${timeoutMs} ms and was terminated`,
        });
        return;
      }
      const exitCode = code ?? null;
      const status = terminalStatus(exitCode);
      settle({
        status,
        exitCode,
        timedOut: false,
        // 失敗理由は終了コードだけから組み立てる。子の出力は読んでいないので、
        // ここに自由文が混ざる経路そのものが存在しない。
        failureReason:
          status === "passed" ? null : `the verification command exited with code ${exitCode}`,
      });
    });
  });
}
