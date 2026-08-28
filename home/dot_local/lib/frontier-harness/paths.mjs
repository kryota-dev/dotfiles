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

// symlink ガードと atomic write の唯一の SSOT。
// 以前は cli.mjs / readiness.mjs / state-store.mjs が個別に実装しており、
// 検査の有無と順序が経路ごとに食い違っていた。
// state の権限（ディレクトリ 0700 / ファイル 0600）もここに閉じ、呼び出し側に数値を渡させない。

const STATE_DIRECTORY_MODE = 0o700;
const STATE_FILE_MODE = 0o600;

function lstatOrNull(target) {
  try {
    return lstatSync(target);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

// 対象パス自身が symlink なら拒否する。存在しない場合は許可（これから作る）。
export function assertNotSymlink(target, label) {
  if (lstatOrNull(target)?.isSymbolicLink()) {
    throw new Error(`${label} must not be a symbolic link`);
  }
}

// `mkdir -p` は経路上の symlink を辿るため、最終要素だけを検査しても中間の祖先が symlink なら
// 書き込み先が脱出する（lstat が symlink を辿らないのも最終要素だけ）。かといって祖先を根まで
// 検査することはできない —— macOS の `/var -> /private/var` のような OS 由来 symlink で必ず
// 誤検知し、`os.tmpdir()` を使う経路が全滅する。
//
// そこで「検証できない深さを作らない」形にする: 作るのは既に存在する親の直下 1 段だけで、その
// 親（呼び出し側が信頼ベースとして与えるもの）が symlink なら拒否し、親が無ければ何も作らずに
// 失敗する（fail closed）。現行の呼び出しはいずれも 1 段しか作らず、親は別経路で検証済みである
// （`<gitCommonDir>` は state-root.mjs が symlink 拒否と作業ツリー所有を検証、`<cwd>` は
// プロセス自身）。深いパスが要るようになったら、信頼ベースを引数で受け取る形へ広げる。
//
// 残余リスク: この検査と後続の `mkdirSync` / `openSync` の間に親を symlink へ差し替えられる
// 競合窓は閉じられない（`node:fs` に `mkdirat` / `openat` 相当が無く、親を fd で固定して
// その配下だけを操作する手段が無い）。信頼ベースが通常は他ユーザーの書き込めない場所である
// ことを前提に許容する。
function assertTrustedParent(directory, label) {
  const parent = path.dirname(directory);
  const stats = lstatOrNull(parent);
  if (!stats) {
    throw new Error(`${label} parent directory ${parent} does not exist`);
  }
  if (stats.isSymbolicLink()) {
    throw new Error(`${label} must not be created through a symbolic link`);
  }
  if (!stats.isDirectory()) {
    throw new Error(`${label} parent directory ${parent} is not a directory`);
  }
}

// symlink を追従しない fd を開く。O_NOFOLLOW は最終要素が symlink のときに失敗する
// （macOS は O_DIRECTORY と併せて ENOTDIR、Linux は ELOOP）。
// `lstat` で検査してから path 指定で `chmod` する形だと、その 2 つの syscall の間に対象を
// symlink へ差し替えられ、リンク先の権限を書き換えさせられる（check-then-act）。
// fd を握ったまま fchmod すれば、検査と適用が同じ inode に対して行われる。
function openNoFollow(target, flags, label, message) {
  try {
    return openSync(target, constants.O_RDONLY | constants.O_NOFOLLOW | flags);
  } catch (error) {
    if (error?.code === "ELOOP" || error?.code === "ENOTDIR") {
      throw new Error(`${label} ${message}`);
    }
    throw error;
  }
}

function openDirectoryNoFollow(directory, label) {
  return openNoFollow(
    directory,
    constants.O_DIRECTORY,
    label,
    "must be a directory that is not a symbolic link",
  );
}

// fd を閉じ忘れない形で権限を適用する。
function applyMode(descriptor, mode) {
  try {
    fchmodSync(descriptor, mode);
  } finally {
    closeSync(descriptor);
  }
}

export function ensureDirectory(directory, label) {
  assertTrustedParent(directory, label);
  // 早い段階で分かりやすく失敗させるための事前検査。最終要素に対する実際のガードは下の
  // O_NOFOLLOW 付き open で、そちらは対象自身については競合窓を持たない（親については
  // assertTrustedParent の残余リスクを参照）。
  assertNotSymlink(directory, label);
  try {
    // recursive にしない。recursive は検証していない祖先を辿って作れてしまう。
    mkdirSync(directory, { mode: STATE_DIRECTORY_MODE });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    // 既存物がディレクトリでないことをここで名指しで弾く。下の open の O_DIRECTORY に委ねると
    // 「symlink である」旨のメッセージになり、単なる同名ファイルの診断を誤誘導する。
    const existing = lstatOrNull(directory);
    if (existing && !existing.isSymbolicLink() && !existing.isDirectory()) {
      throw new Error(`${label} exists and is not a directory`);
    }
  }
  // mkdir と open の間に生えた symlink も素通りさせない（多層防御）。
  assertNotSymlink(directory, label);

  let descriptor;
  try {
    descriptor = openDirectoryNoFollow(directory, label);
  } catch (error) {
    if (error?.code !== "EACCES") throw error;
    // umask が owner ビットまで削ると mkdirSync は mode 000 のディレクトリを作り、以後 open も
    // できない。放置すると壊れたディレクトリが残り、次回以降も同じ理由で失敗し続ける
    // （自己回復しない）。symlink でないことを確かめてから path 経由で矯正し、open をやり直す。
    //
    // 残余リスク: ここだけは path 指定の chmod になる（開けないディレクトリの fd は握れず、
    // `node:fs` に `fchmodat` 相当が無い。`lchmodSync` は macOS 限定で Linux には無い）。
    // lstat と chmod の間に対象を symlink へ差し替えられれば、リンク先の mode を 0700 に
    // されうる。fail closed にする案は、異常な umask で state ディレクトリが二度と使えなく
    // なる（現行 cli.mjs:130 の chmod が担っている自己回復の退行）ため採らない。
    // 同型のイディオムは agent-improvement/paths.mjs にもあり、是正するなら両方揃えて行う。
    assertNotSymlink(directory, label);
    chmodSync(directory, STATE_DIRECTORY_MODE);
    descriptor = openDirectoryNoFollow(directory, label);
  }
  // mode オプションは umask に削られ、既存ディレクトリには適用されない。
  // owner-only は state の前提なので、作成経路に関わらず明示的に固定する。
  applyMode(descriptor, STATE_DIRECTORY_MODE);
  return directory;
}

// 既存の state ファイルの権限を、そのファイル記述子に対して固定する。
export function ensureStateFileMode(target, label) {
  applyMode(
    openNoFollow(target, 0, label, "must not be a symbolic link"),
    STATE_FILE_MODE,
  );
  return target;
}

// state ファイルを owner-only で「先に」作る。既に在れば mode を固定するだけ。
//
// ファイルを自分で作るライブラリ（SQLite の DatabaseSync 等）に先を越されると、その作成 mode は
// umask に削られる。umask が owner ビットまで削ると owner が開けないファイルができ、以後 fd を
// 握れないため fchmod で直せなくなる（実測: umask 0700 で mode 0066 —— owner は開けないのに
// group/other からは読み書きできる最悪の状態が残る）。ディレクトリ側と違い path 指定 chmod への
// フォールバックを増やしたくないので、先に O_CREAT|O_EXCL|O_NOFOLLOW で作って fd 経由で固定する。
export function ensureStateFile(target, label) {
  let descriptor;
  try {
    descriptor = openSync(
      target,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      STATE_FILE_MODE,
    );
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    // 既存ファイル（symlink を含む）は検査付きの fd 経由に委ねる。
    return ensureStateFileMode(target, label);
  }
  applyMode(descriptor, STATE_FILE_MODE);
  return target;
}

// 一時ファイル名は予測可能にしない（先置き symlink による任意ファイル上書きを防ぐ）。
// O_CREAT|O_EXCL は、既存ファイル・既存 symlink があれば EEXIST で失敗する。
export function writeJsonAtomic(targetPath, value, label) {
  ensureDirectory(path.dirname(targetPath), `${label} directory`);
  assertNotSymlink(targetPath, label);
  const temporaryPath = `${targetPath}.${randomUUID()}.tmp`;
  const payload = `${JSON.stringify(value, null, 2)}\n`;
  const descriptor = openSync(
    temporaryPath,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
    STATE_FILE_MODE,
  );
  let renamed = false;
  try {
    try {
      // open の mode 引数は umask に削られるため、fd に対して明示的に固定し直す。
      fchmodSync(descriptor, STATE_FILE_MODE);
      writeFileSync(descriptor, payload, { encoding: "utf8" });
    } finally {
      closeSync(descriptor);
    }
    // rename は宛先が symlink でも dentry ごと置き換える（追従しない）ため、
    // 宛先側 symlink 経由の任意ファイル上書きは構造的に成立しない。
    renameSync(temporaryPath, targetPath);
    renamed = true;
  } finally {
    // 書き込みや rename が失敗したとき、0600 の断片を残さない。
    if (!renamed) rmSync(temporaryPath, { force: true });
  }
  return targetPath;
}
