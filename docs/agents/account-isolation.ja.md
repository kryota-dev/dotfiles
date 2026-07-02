# アカウント分離

🌐 English (canonical): [account-isolation.md](account-isolation.md)

← [ドキュメント目次](../README.ja.md)

このページは Claude Code と Codex CLI における個人アカウントと r06（業務）アカウントの分離方法のリファレンスです。
基本原則は「**設定はシンボリックリンク経由で共有、状態は環境変数で分離**」です。

---

## 環境変数テーブル

以下のテーブルはアカウントごとのディレクトリ変数とその値を示します。
これらの変数はエージェントのサブプロセスにインラインでセットされ、シェルの一般的な環境にはエクスポートされません。

| 変数 | 個人（デフォルト）アカウント | 業務（r06）アカウント |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | `~/.claude-r06` |
| `ECC_AGENT_DATA_HOME` | `~/.claude` | `~/.claude-r06` |
| `CLV2_HOMUNCULUS_DIR` | `~/.claude/ecc-homunculus` | `~/.claude-r06/ecc-homunculus` |
| `ECC_MCP_HEALTH_STATE_PATH` | `~/.claude/mcp-health-cache.json` | `~/.claude-r06/mcp-health-cache.json` |
| `GATEGUARD_STATE_DIR` | `~/.claude/.gateguard` | `~/.claude-r06/.gateguard` |
| `CODEX_HOME` | （デフォルト — `~/.codex`） | `~/.codex-r06` |

r06 の Claude 設定ディレクトリ（`~/.claude-r06`）には、すべての設定アーティファクト（settings、agents、commands、skills）が `~/.claude` を指すシンボリックリンクのみが含まれます。アカウント間で異なるのは、これらの環境変数がツールに書き込むよう指示するランタイム状態のみです。

---

## エイリアスマトリクス

以下はユーザー向けのエントリポイントです。各エイリアスは「ハーネス × アカウント」の 2 × 2 マトリクスの 1 セルに対応します。

| エイリアス | ハーネス | アカウント | 効果 |
|---|---|---|---|
| `cld` | Claude Code | 個人 | デフォルトアカウントの環境セットで `claude` を実行 |
| `cld-r06` | Claude Code | 業務（r06） | r06 環境セットで `claude` を実行 |
| `hcld` | Claude Code（happy ラップ） | 個人 | デフォルトアカウントの環境で `happy claude` を実行 |
| `hcld-r06` | Claude Code（happy ラップ） | 業務（r06） | r06 環境で `happy claude` を実行 |
| `claude-config` | Claude Code | 個人 | ECC config-protection + gateguard-fact-force ゲートを無効化；意図的な設定編集用 |
| `cdx` | Codex CLI | 個人 | `codex --profile shared`（デフォルト `~/.codex`）を実行 |
| `cdx-r06` | Codex CLI | 業務（r06） | `CODEX_HOME=$HOME/.codex-r06 codex --profile shared` を実行 |
| `hcdx` | Codex CLI（happy ラップ） | 個人 | `happy codex --profile shared` を実行 |
| `hcdx-r06` | Codex CLI（happy ラップ） | 業務（r06） | `CODEX_HOME=$HOME/.codex-r06 happy codex --profile shared` を実行 |

`happy` 自身の状態（`~/.happy`、つまり `HAPPY_HOME_DIR` のデフォルト）はアカウント間で意図的に**共有**されます — 1 つのスマートフォンペアリングで全アカウントを制御します。アカウントごとに分離されるのは内側の claude/codex 環境のみです。

---

## `_claude_with_home`：Claude Code のアカウント選択の仕組み

Claude Code のエイリアスはすべて `_claude_with_home` という 1 つの zsh ヘルパー関数を呼び出します。

```zsh
_claude_with_home() {
  local home_dir="$1"
  shift
  (($#)) || set -- claude
  CLAUDE_CONFIG_DIR="$home_dir" \
    ECC_AGENT_DATA_HOME="$home_dir" \
    CLV2_HOMUNCULUS_DIR="$home_dir/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    "$@"
}
```

主な特性：

- 環境変数は `"$@"` サブプロセスにのみ**インラインスコープ**されます。親シェルにはエクスポートされません。
- `EXA_API_KEY` と `FIRECRAWL_API_KEY` はサブプロセスにスコープして再エクスポートされ、Claude Code の MCP サーバーがプロセス環境から `${EXA_API_KEY}` プレースホルダーを展開できるようにします。ソース値は `~/.config/zsh/claude-secrets.zsh`（`chezmoi apply` 時に 1Password からレンダリングされる 0600 ファイル。ソースされるがエクスポートされない）から取得されます。
- `cld` は `home_dir` として `"$HOME/.claude"` を渡し、`cld-r06` は `"$HOME/.claude-r06"` を渡します。

ソース：`home/dot_config/zsh/claude.zsh`

---

## 重要：必ずエイリアスを使用すること

ベアバイナリ名での実行はアカウント機構を完全にバイパスします。

| ベア呼び出し | 欠落するもの |
|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` なし — `~/.claude` にフォールバック；`ECC_AGENT_DATA_HOME` 未設定 |
| `codex` | `--profile shared` なし — `$CODEX_HOME/shared.config.toml` がロードされない |

ベアの `claude` 呼び出しはエラーではありませんが、デフォルトアカウントのディレクトリを使用し、エイリアスが提供する ECC/CLV2/gateguard の状態分離が無効になります。`codex` の場合、ベア呼び出しでは SSOT のモデル、パーソナリティ、マルチエージェント機能の設定がすべて失われます。

---

## 関連ドキュメント

- [overview.ja.md](overview.ja.md) — ハーネス × アカウントアーキテクチャの概要
- [claude-code.ja.md](claude-code.ja.md) — Claude Code フック、ECC、CLV2 オブザーバー
- [codex.ja.md](codex.ja.md) — Codex CLI プロファイル設定、フック
- [secrets-1password.ja.md](../getting-started/secrets-1password.ja.md) — API キーを 1Password から 0600 ファイルにレンダリングする方法
