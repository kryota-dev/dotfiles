import path from "node:path";

// 「設定ファイルの置き場所を作業ディレクトリの内容から解決しない」という不変条件の SSOT。
//
// 以前は cli.mjs の resolveConfigPath だけがこれを持っていた。承認チャネルの escalation
// ルールも同じ性質（untrusted repository が同梱したファイルに方針を差し替えられてはならない）
// を要求するため、両者が 1 つの実装を共有する。security 不変条件を複製すると、
// 「片方だけ相対パスを受け付ける」という形で静かに崩れる。
export function resolveTrustedPath({
  explicit,
  environment,
  envKey,
  homeRelative,
  label,
}) {
  if (explicit) return explicit;
  const override = environment[envKey];
  if (override) {
    // 明示的な escape hatch として HOME 配下までは要求しない。
    // ただし相対値は cwd 基準で解決されるため受け付けない。
    if (!path.isAbsolute(override)) {
      throw new TypeError(`${envKey} must be an absolute path`);
    }
    return override;
  }
  const home = environment.HOME;
  if (typeof home !== "string" || !path.isAbsolute(home)) {
    throw new TypeError(`HOME must be an absolute path to resolve the ${label}`);
  }
  return path.join(home, ...homeRelative);
}
