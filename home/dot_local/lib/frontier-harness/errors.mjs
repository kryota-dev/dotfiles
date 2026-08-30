import { INTERNAL_ERROR, USAGE } from "./exit-codes.mjs";

// 「利用者に見せる失敗」と「内部の不整合」を分ける唯一の場所。
//
// 想定内の失敗に stack trace を出すと、直せる誤り（打ち間違えたフラグ、存在しないファイル、
// git working tree の外での実行）が、直せない不具合と同じ見た目で届く。原因が読めないエラーは
// #508 が直そうとしている問題そのものなので、想定内と判断できたものは**メッセージだけ**を出す。
//
// 逆に、想定していない例外まで 1 行へ潰すと、再現に必要な情報が消える。分類できないものは
// stack ごと残し、終了コードでも区別する（64 = 直せる誤り / 70 = 内部の不整合）。

// harness が自分で投げる「拒否」。invariant の違反（symlink 経由の書き込み、所有していない
// state root など）は例外の型で表す。`TypeError` は引数の誤りに使っているため、意味の違う
// 2 つを同じ型に相乗りさせない。
export class HarnessError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = "HarnessError";
  }
}

// Node の system error（fs / child_process）。errno を持つ例外はメッセージが既に
// 「何がどのパスで失敗したか」を含むので、そのまま出せば足りる。
function isSystemError(error) {
  return (
    typeof error?.code === "string" &&
    /^E[A-Z]+$/.test(error.code) &&
    typeof error?.syscall === "string"
  );
}

function isExpected(error) {
  // 引数の誤り。CLI の検証はすべてここへ集まる。
  if (error instanceof TypeError) return true;
  // harness 自身の拒否（HarnessError を継承する GitWorktreeUnavailableError を含む）。
  if (error instanceof HarnessError) return true;
  // 外部入力の JSON が壊れている。
  if (error instanceof SyntaxError) return true;
  return isSystemError(error);
}

// `{ message, exitCode, expected }` を返す。呼び出し側（cli.mjs の entrypoint）は
// この結果をそのまま stderr と exitCode に写すだけでよい。
export function describeCliFailure(error) {
  if (isExpected(error)) {
    return { message: error.message, exitCode: USAGE, expected: true };
  }
  return {
    message: error?.stack ?? String(error),
    exitCode: INTERNAL_ERROR,
    expected: false,
  };
}
