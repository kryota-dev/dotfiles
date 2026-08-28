// provider 名 → 実行ファイル名の唯一の SSOT。
// cli.mjs（PATH 探索）と doctor.mjs（診断メッセージ）が同じ表を使う。
// 以前は両者が独立したリテラルを持ち、antigravity の値が "agy" と "antigravity" に乖離していた。
export const PROVIDER_COMMANDS = Object.freeze({
  antigravity: "agy",
  claude: "claude",
  codex: "codex",
});

export function providerCommand(provider) {
  return PROVIDER_COMMANDS[provider] ?? provider;
}
