import {
  chmodSync,
  closeSync,
  constants,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

// 改善候補キューの state 置き場と、owner-only 書き込みの安全契約を決める唯一の場所
// （#473 AC-035）。パス解決をこのモジュールに閉じているのは、#344（CLV2 状態を
// アカウント別の親ディレクトリへまとめる）が将来このレイアウトにも及んだときに、
// 変更点が 1 箇所で済むようにするため。#344 の移行そのものはここでは行わない。

const STATE_DIRECTORY_NAME = "agent-improvement";
const QUEUE_FILE_NAME = "queue.json";
// #506 の週次 evaluator が書く health ファイル。このリポジトリのコードは読むだけで、
// 一度も書かない（本 issue のスコープは queue 側だけ）。
const HEALTH_FILE_NAME = "health.json";
const STATE_DIRECTORY_MODE = 0o700;
const STATE_FILE_MODE = 0o600;

// 相対パスは cwd 基準で解決されるため受け付けない。許すと、たまたま cd していた
// リポジトリの中に owner-only の state を作らされる。
function requireAbsolute(value, label) {
  if (typeof value !== "string" || !path.isAbsolute(value)) {
    throw new TypeError(`${label} must be an absolute path`);
  }
  return value;
}

// state ディレクトリと、その「信頼ベース」を一緒に返す。ベースは利用者が設定
// として与える起点（override の親 / XDG_STATE_HOME / HOME）で、ベースより下の
// 要素だけがこの実装の作るものになる。symlink 検査の範囲をこの境界で決める。
function resolveStateLayout(environment) {
  const override = environment.AGENT_IMPROVEMENT_STATE_DIR;
  if (override) {
    const directory = requireAbsolute(override, "AGENT_IMPROVEMENT_STATE_DIR");
    return { directory, base: path.dirname(directory) };
  }
  const stateHome = environment.XDG_STATE_HOME;
  if (stateHome) {
    const base = requireAbsolute(stateHome, "XDG_STATE_HOME");
    return { directory: path.join(base, STATE_DIRECTORY_NAME), base };
  }
  const base = requireAbsolute(environment.HOME, "HOME");
  return {
    directory: path.join(base, ".local", "state", STATE_DIRECTORY_NAME),
    base,
  };
}

export function resolveStateDirectory(environment) {
  return resolveStateLayout(environment).directory;
}

// 読み取り経路用。ディレクトリを作らずに symlink かどうかだけを検査する。
// 葉のファイルだけを検査すると、state ディレクトリ自体を symlink に差し替えられた
// ときに `status` / `next` がリンク先の内容を無警告で表示してしまう。
export function assertStateDirectoryNotSymlink(environment) {
  assertNotSymlink(resolveStateDirectory(environment), "state directory");
}

export function queuePath(environment) {
  return path.join(resolveStateDirectory(environment), QUEUE_FILE_NAME);
}

export function healthPath(environment) {
  return path.join(resolveStateDirectory(environment), HEALTH_FILE_NAME);
}

// 対象パス自身が symlink なら拒否する。存在しない場合は許可（これから作る）。
export function assertNotSymlink(target, label) {
  let stats;
  try {
    stats = lstatSync(target);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  if (stats.isSymbolicLink()) {
    throw new Error(`${label} must not be a symbolic link`);
  }
}

// symlink を追従しないディレクトリ fd を開く。O_NOFOLLOW は最終要素が symlink の
// ときに失敗する（macOS は O_DIRECTORY と併せて ENOTDIR、Linux は ELOOP）。
// `lstat` で検査してから `chmod` する形だと、その 2 つの syscall の間に対象を
// symlink へ差し替えられ、リンク先の権限を書き換えさせられる（check-then-act）。
// fd を握ったまま fchmod すれば、検査と適用が同じ inode に対して行われる。
function openDirectoryNoFollow(directory) {
  try {
    return openSync(
      directory,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
    );
  } catch (error) {
    if (error?.code === "ELOOP" || error?.code === "ENOTDIR") {
      throw new Error("state directory must not be a symbolic link");
    }
    throw error;
  }
}

// `mkdir -p` が作る中間要素も symlink であってはならない。O_NOFOLLOW が守るのは
// 最終要素だけなので、`~/.local/link/agent-improvement` の `link` が symlink だと
// mkdirSync(recursive) はそこへ追従する。
//
// 検査対象はベースより下の要素だけに限る。パス全体を realpath で突き合わせると、
// macOS の `/var -> /private/var` のような OS 由来 symlink で誤検知する
// （`os.tmpdir()` を使う呼び出しがすべて壊れる）。ベース自身とその上流は利用者の
// 設定として信頼し、この実装が作りうる範囲だけを見る。
function assertCreatedComponentsNotSymlink({ directory, base }) {
  const relative = path.relative(base, directory);
  // ベース自身が state ディレクトリのとき（override）は作る要素が無い。
  if (relative === "" || relative.startsWith("..") || path.isAbsolute(relative)) {
    return;
  }
  let current = base;
  for (const segment of relative.split(path.sep)) {
    current = path.join(current, segment);
    assertNotSymlink(current, `state path component ${current}`);
  }
}

export function ensureStateDirectory(environment) {
  const layout = resolveStateLayout(environment);
  const { directory } = layout;
  // 早い段階で分かりやすく失敗させるための事前検査。実際のガードは下の
  // O_NOFOLLOW 付き open で、そちらが競合窓を持たない本体になる。
  assertNotSymlink(directory, "state directory");
  // mkdir の前後で検査する。前に見るのは symlink 経由で何かを作らせないため
  // （後だけだと mkdirSync がリンク先に作ってから気づくことになる）。後に見るのは
  // mkdirSync が新しく作った中間要素も検査対象に入れるため。
  assertCreatedComponentsNotSymlink(layout);
  mkdirSync(directory, { mode: STATE_DIRECTORY_MODE, recursive: true });
  assertCreatedComponentsNotSymlink(layout);

  let descriptor;
  try {
    descriptor = openDirectoryNoFollow(directory);
  } catch (error) {
    if (error?.code !== "EACCES") throw error;
    // umask が owner ビットまで削ると mkdirSync は mode 000 のディレクトリを作り、
    // 以後 open もできない。放置すると壊れたディレクトリが残り、次回以降も同じ
    // 理由で失敗し続ける（自己回復しない）。symlink でないことを確かめてから
    // path 経由で 0700 に直し、O_NOFOLLOW の open をやり直す。
    assertNotSymlink(directory, "state directory");
    chmodSync(directory, STATE_DIRECTORY_MODE);
    descriptor = openDirectoryNoFollow(directory);
  }
  try {
    // mode オプションは umask に削られ、既存ディレクトリには適用されない。
    // owner-only は AC-035 の要件なので、作成経路に関わらず明示的に固定する。
    fchmodSync(descriptor, STATE_DIRECTORY_MODE);
  } finally {
    closeSync(descriptor);
  }
  return directory;
}

// 読み取り経路用。0700/0600 を「矯正」せず「検出」だけする。矯正すると表示が
// 書き込みになり要件 5.3（表示は state へ書かない）を破る。緩いからといって
// 停止もしない —— 停止すると AC-037 の「active 候補の全件を表示」が達成できず、
// 権限も直らないまま一覧だけ失う。
export function inspectStatePermissions(environment) {
  const directory = resolveStateDirectory(environment);
  const warnings = [];
  const targets = [
    [directory, STATE_DIRECTORY_MODE, "state directory"],
    [path.join(directory, QUEUE_FILE_NAME), STATE_FILE_MODE, "queue file"],
    [path.join(directory, HEALTH_FILE_NAME), STATE_FILE_MODE, "health file"],
  ];
  for (const [target, expected, label] of targets) {
    let stats;
    try {
      stats = lstatSync(target);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    const mode = stats.mode & 0o777;
    if ((mode & 0o077) !== 0) {
      warnings.push(
        `${label} is ${mode.toString(8).padStart(3, "0")}, expected ${expected.toString(8)}`,
      );
    }
  }
  return Object.freeze(warnings);
}

export function writeJsonAtomic(environment, targetPath, value, label) {
  ensureStateDirectory(environment);
  assertNotSymlink(targetPath, label);
  // 一時ファイル名は予測可能にしない（先置き symlink による任意ファイル上書きを防ぐ）。
  // flag "wx" = O_CREAT|O_EXCL で、既存ファイル・既存 symlink があれば EEXIST で失敗する。
  const temporaryPath = `${targetPath}.${randomUUID()}.tmp`;
  let renamed = false;
  try {
    // 書き込み自体も try の中に置く。途中で I/O エラーになったとき、外に出していると
    // 中途半端な 0600 の断片が残る。
    writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: STATE_FILE_MODE,
      flag: "wx",
    });
    chmodSync(temporaryPath, STATE_FILE_MODE);
    // rename は宛先が symlink でも dentry ごと置き換える（追従しない）ため、
    // 宛先側 symlink 経由の任意ファイル上書きは構造的に成立しない。
    renameSync(temporaryPath, targetPath);
    renamed = true;
  } finally {
    if (!renamed) rmSync(temporaryPath, { force: true });
  }
  return targetPath;
}
