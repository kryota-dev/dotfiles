import { spawn as nodeSpawn } from "node:child_process";

import { readInitHealth } from "./adapter-claude.mjs";
import { requireNonEmptyString } from "./record-validation.mjs";

// sealed invocation を実プロセスとして起こし、構造化出力を stream で解釈する唯一の場所。
//
// **adapter 層はプロセスを起動しない**（adapters.mjs の規約。tests がソースを走査して固定して
// いる）。このファイルはその外側にあり、ファイル名を `adapter-` で始めないのもその検査の
// 対象に入れないためである。
//
// stream で読むのは、起動時検査を**事後検査にしないため**である。`system/init` は最初に流れて
// くるので、そこで `AskUserQuestion` の不在を見つけたら、その場で子を終わらせられる。実行が
// 終わってから健全性を確かめるのでは、gate を失ったまま丸ごと 1 タスク走ったあとになる。

// 保持する stdout の上限。多ターンの子は長時間走るので、全出力をメモリへ溜めない。
// `interpret` が読むのは**終端の result イベント**なので、末尾だけを残せば足りる。
// 先頭を落として困るのは malformed 行の件数（失敗時の注記）だけで、失敗を成功に
// 化かす方向には倒れない。
export const MAX_RETAINED_OUTPUT_BYTES = 1048576;
// SIGTERM から SIGKILL までの猶予。#526 §1.3: SIGTERM は進行中のターンを未完了のまま残す。
export const TERMINATION_GRACE_MS = 5000;
// 起動時検査で終わらせた子の終了コード。#526 §1.3 の「SIGTERM は exit 143」に合わせる。
// シグナルで終わると exitCode が null になるため、成功と読めない値をここで確定させる。
export const TERMINATED_EXIT_CODE = 143;

// 子の git が sandbox 内で TLS 検証を通せるようにする。
//
// ［実測］sandbox はプロキシ経由の egress を課すため、git は OpenSSL 系バックエンドに落ちて
// CA バンドルを読もうとし、その読み取りが sandbox に塞がれて
// `error setting certificate verify locations` で失敗する。secure-transport バックエンドは
// CA ファイルを読まず macOS の trust 評価を使うので通る（`git ls-remote` の成功を実測）。
//
// **各コマンドに `-c` を付ける運用ルールにしない。** 子は git を何度も呼ぶので必ず付け忘れる。
// 環境変数で全呼び出しへ効かせ、利用者側の設定には一切触れない。
const GIT_SSL_BACKEND_KEY = "http.sslBackend";
const GIT_SSL_BACKEND_VALUE = "secure-transport";

// 既存の GIT_CONFIG_* を壊さずに 1 件足す。呼び出し元が既に使っていた場合、上書きすると
// その指定が黙って消える（`GIT_CONFIG_COUNT` は「先頭から何件読むか」なので、末尾へ足す）。
export function withGitTlsBackend(source) {
  const env = { ...source };
  const declared = Number.parseInt(env.GIT_CONFIG_COUNT ?? "0", 10);
  const count = Number.isInteger(declared) && declared >= 0 ? declared : 0;
  env[`GIT_CONFIG_KEY_${count}`] = GIT_SSL_BACKEND_KEY;
  env[`GIT_CONFIG_VALUE_${count}`] = GIT_SSL_BACKEND_VALUE;
  env.GIT_CONFIG_COUNT = String(count + 1);
  return env;
}

const HEARTBEAT_PREFIX = "frontier-harness: child event";
// stderr へ書いてよいのは**イベントの型名だけ**。会話内容を運ばないことに加え、
// provider の出力をそのまま端末へ流さない（制御文字・ANSI を書かない）。
const EVENT_LABEL_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;
const UNKNOWN_EVENT_LABEL = "unknown";

function labelPart(value) {
  return typeof value === "string" && EVENT_LABEL_PATTERN.test(value) ? value : null;
}

function eventLabel(event) {
  const type = labelPart(event?.type) ?? UNKNOWN_EVENT_LABEL;
  const subtype = labelPart(event?.subtype);
  return subtype === null ? type : `${type}/${subtype}`;
}

function isInitEvent(event) {
  return event?.type === "system" && event?.subtype === "init";
}

// 末尾だけを保持する行バッファ。
function createTailBuffer(limitBytes) {
  const lines = [];
  let bytes = 0;
  return {
    push(line) {
      const size = Buffer.byteLength(line, "utf8") + 1;
      lines.push(line);
      bytes += size;
      // 1 行だけは必ず残す（終端の result イベントを落とさない）。
      while (bytes > limitBytes && lines.length > 1) {
        bytes -= Buffer.byteLength(lines.shift(), "utf8") + 1;
      }
    },
    text() {
      return lines.join("\n");
    },
  };
}

export function createChildRunner({
  cwd,
  permissionPromptTool,
  environment = process.env,
  spawn = nodeSpawn,
  stderr = process.stderr,
  terminationGraceMs = TERMINATION_GRACE_MS,
  retainBytes = MAX_RETAINED_OUTPUT_BYTES,
}) {
  requireNonEmptyString(cwd, "child runner cwd");
  requireNonEmptyString(permissionPromptTool, "child runner permissionPromptTool");
  let health = null;

  function run(invocation) {
    return new Promise((resolve, reject) => {
      let child;
      try {
        child = spawn(invocation.executable, [...invocation.argv], {
          cwd,
          env: withGitTlsBackend(environment),
          // stdin は使わない（1 タスク 1 プロセス）。stdout は解釈のために取り、
          // 子の stderr は親へ継承して人が覗けるようにする。
          stdio: ["ignore", "pipe", "inherit"],
        });
      } catch (error) {
        reject(error);
        return;
      }

      const retained = createTailBuffer(retainBytes);
      let pending = "";
      let sawInit = false;
      let terminated = false;
      let killTimer = null;
      let settled = false;

      const terminate = () => {
        if (terminated) return;
        terminated = true;
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
      };

      const handleLine = (raw) => {
        const line = raw.trim();
        if (!line) return;
        retained.push(line);
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          // 壊れた行は interpret 側が件数として数える。ここでは判定材料にしない。
          return;
        }
        if (event === null || typeof event !== "object") return;
        stderr.write(`${HEARTBEAT_PREFIX} ${eventLabel(event)}\n`);
        if (sawInit || !isInitEvent(event)) return;
        sawInit = true;
        health = readInitHealth(event, { permissionPromptTool });
        if (!health.healthy) terminate();
      };

      if (child.stdout) {
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk) => {
          pending += chunk;
          let index = pending.indexOf("\n");
          while (index !== -1) {
            handleLine(pending.slice(0, index));
            pending = pending.slice(index + 1);
            index = pending.indexOf("\n");
          }
          // 改行を含まないまま伸び続ける出力でメモリを食い潰さない。
          if (pending.length > retainBytes) {
            handleLine(pending);
            pending = "";
          }
        });
      }

      const settle = (code) => {
        if (settled) return;
        settled = true;
        if (killTimer !== null) clearTimeout(killTimer);
        if (pending) handleLine(pending);
        pending = "";
        if (!sawInit) {
          // init を読めないまま終わった実行を健全と読まない。readInitHealth は
          // init イベントでない入力に対して「init イベントではない」を返すので、
          // 判定の語彙をここで作らずそのまま使う。
          health = readInitHealth(null, { permissionPromptTool });
        }
        // 起動時検査で終わらせた子は、終了コードが 0 でも成功と読めないようにする。
        const exitCode =
          terminated && (code === null || code === undefined || code === 0)
            ? TERMINATED_EXIT_CODE
            : (code ?? null);
        resolve({ stdout: retained.text(), exitCode });
      };

      child.on("error", (error) => {
        if (settled) return;
        settled = true;
        if (killTimer !== null) clearTimeout(killTimer);
        reject(error);
      });
      child.on("close", (code) => settle(code));
    });
  }

  return {
    run,
    // 直近の実行で読み取った起動時健全性。実行前は null。
    initHealth: () => health,
  };
}
