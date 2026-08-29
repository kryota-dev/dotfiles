import { accessSync, constants } from "node:fs";
import path from "node:path";

import { PROVIDER_COMMANDS } from "./providers.mjs";

// PATH からの実行ファイル解決と、そこから導かれる provider 可用性。
//
// cli.mjs から切り出したのは、承認 server の実行ファイル解決（approval-channel.mjs）と
// 子セッションの起動（session-command.mjs）が同じ解決規則を要るからである。cli.mjs に
// 置いたままだと、cli.mjs → session-command.mjs → cli.mjs の循環 import になる。

export function findCommand(command, searchPath) {
  for (const directory of searchPath.split(path.delimiter)) {
    // 空要素・相対パスは CWD 基準で解決されるため候補にしない。
    // POSIX は PATH の zero-length prefix を CWD と定義しており、そのまま join すると
    // untrusted repository が同梱した実行ファイルを provider として選んでしまう。
    if (!directory || !path.isAbsolute(directory)) continue;
    const candidate = path.join(directory, command);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // PATH の次候補を確認する。
    }
  }
  return null;
}

export function defaultCommandPaths(environment) {
  const searchPath = environment.PATH ?? "";
  return Object.fromEntries(
    Object.entries(PROVIDER_COMMANDS).map(([provider, command]) => [
      provider,
      findCommand(command, searchPath),
    ]),
  );
}

export function providerAvailability(commandPaths, verifiedModels = {}) {
  return Object.fromEntries(
    Object.keys(PROVIDER_COMMANDS).map((provider) => {
      const executable = Boolean(commandPaths[provider]);
      if (provider !== "antigravity") {
        return [provider, { available: executable, models: null }];
      }
      const models = Object.hasOwn(verifiedModels, "antigravity")
        ? verifiedModels.antigravity
        : null;
      const verified = Array.isArray(models) && models.length > 0;
      return [
        provider,
        { available: executable && verified, models: verified ? models : null },
      ];
    }),
  );
}
