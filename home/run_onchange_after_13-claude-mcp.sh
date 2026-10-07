#!/bin/bash
# Claude Code の user スコープの MCP サーバーを登録する。~/.claude.json は Claude Code が
# セッションのたびに書き換えるので、ファイルとして管理せず CLI で登録する（Codex は
# ~/.codex/config.toml に同じサーバーを宣言している）。API キーは ${VAR} のまま登録し、
# Claude Code が起動時に環境変数から展開する。
set -euo pipefail

# shellcheck disable=SC2016
servers=(
  'context7|{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"]}'
  'deepwiki|{"type":"http","url":"https://mcp.deepwiki.com/mcp"}'
  'exa|{"type":"stdio","command":"npx","args":["-y","exa-mcp-server@3.2.1"],"env":{"EXA_API_KEY":"${EXA_API_KEY}"}}'
  'firecrawl|{"type":"stdio","command":"npx","args":["-y","firecrawl-mcp@3.22.0"],"env":{"FIRECRAWL_API_KEY":"${FIRECRAWL_API_KEY}"}}'
)

for entry in "${servers[@]}"; do
  name="${entry%%|*}"
  mise exec -- claude mcp remove "$name" --scope user >/dev/null 2>&1 || true
  mise exec -- claude mcp add-json "$name" "${entry#*|}" --scope user
done
