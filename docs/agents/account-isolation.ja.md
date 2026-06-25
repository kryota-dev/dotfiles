# アカウント分離

🌐 English (canonical): [account-isolation.md](account-isolation.md)

← [ドキュメント目次](../README.ja.md)

このページは Claude Code、Codex CLI、dmux における個人アカウントと r06（業務）アカウントの分離方法のリファレンスです。
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
| `TMUX_TMPDIR`（dmux のみ） | （デフォルト — `$TMPDIR`） | `~/.dmux-r06`（0700） |

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
| `dmux` | dmux | 個人 | codex PATH シムと API キーをサブプロセスにスコープして dmux を実行 |
| `dmux-r06` | dmux | 業務（r06） | 専用 `TMUX_TMPDIR=~/.dmux-r06` + 完全な r06 環境セットで dmux を実行 |

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

## dmux：専用ソケットによる分離

dmux はセッションをプロジェクト名でキーイングし、新規作成せずに既存セッションに**アタッチ**します。tmux サーバーレベルでアカウント分離がなければ、デフォルトアカウントの dmux セッションが既に存在するディレクトリで `dmux-r06` を実行すると、誤ったアカウントのセッションにアタッチしてしまいます。

解決策は**専用の tmux サーバーソケットディレクトリ**（`TMUX_TMPDIR=~/.dmux-r06`、0700 で作成）です。ソケットディレクトリごとに r06 専用の tmux サーバーとセッション名前空間が確保されるため、アカウント間の衝突が発生しません。

`home/dot_config/zsh/dmux.zsh` より：

```zsh
dmux-r06() {
  local tmpdir="${HOME}/.dmux-r06"
  [[ -d "$tmpdir" ]] || mkdir -m 700 -p "$tmpdir" || return 1
  TMUX_TMPDIR="$tmpdir" \
    PATH="${_DMUX_SHIM_DIR}:${PATH}" \
    CLAUDE_CONFIG_DIR="${HOME}/.claude-r06" \
    ECC_AGENT_DATA_HOME="${HOME}/.claude-r06" \
    CLV2_HOMUNCULUS_DIR="${HOME}/.claude-r06/ecc-homunculus" \
    ECC_MCP_HEALTH_STATE_PATH="${HOME}/.claude-r06/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="${HOME}/.claude-r06/.gateguard" \
    CODEX_HOME="${HOME}/.codex-r06" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    command dmux "$@"
}
```

`dmux-r06` の環境セットは、r06 ホームディレクトリを使った `_claude_with_home` のミラーに `CODEX_HOME`（`cdx-r06` のミラー）と `TMUX_TMPDIR` を加えたものです。

### セッション再利用とシークレットの更新

tmux は `new-session` を実行するクライアントから環境をキャプチャします。その後に `split-window` で作成されたペインはそのキャプチャされたセッション環境を継承します。これが意味すること：

- r06 のパス（`~/.claude-r06`、`~/.codex-r06`）は静的なため、再利用されたセッションでも問題なく正しいアカウントを選択できます。
- 新しくプロビジョニングされたシークレット（例：`chezmoi apply` 後に新しくレンダリングされた `claude-secrets.zsh`）は、実行中の tmux セッションには**自動的に反映されません**。更新するには `tmux -L <socket-name> kill-server` を実行してから `dmux-r06` を再実行してください。

---

## codex PATH シム

dmux は Codex を `sh -c "codex …"` としてスポーンするため、`--profile shared` のようなフラグを自分で渡すことができません。`--profile shared` なしでは、Codex は `$CODEX_HOME/shared.config.toml`（chezmoi 管理の SSOT 静的設定）をロードしません。

`dmux` ラッパーは `~/.config/dmux/bin` を `PATH` の先頭に追加します。そのディレクトリには、dmux ペイン内のすべての codex 呼び出しに `--profile shared` を再注入する `codex` シムスクリプトが含まれています。dmux の PATH サニタイザーは `node_modules/.bin` のみを削除するため、シムディレクトリはペインに引き継がれます。

`dmux`（デフォルトアカウント）と `dmux-r06` の両方が同じ理由で `_DMUX_SHIM_DIR` を PATH の先頭に追加します。

---

## 重要：必ずエイリアスを使用すること

ベアバイナリ名での実行はアカウント機構を完全にバイパスします。

| ベア呼び出し | 欠落するもの |
|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` なし — `~/.claude` にフォールバック；`ECC_AGENT_DATA_HOME` 未設定 |
| `codex` | `--profile shared` なし — `$CODEX_HOME/shared.config.toml` がロードされない |
| `dmux`（シムなし） | ペインが `--profile shared` なしでベアの `codex` をスポーン |

ベアの `claude` 呼び出しはエラーではありませんが、デフォルトアカウントのディレクトリを使用し、エイリアスが提供する ECC/CLV2/gateguard の状態分離が無効になります。`codex` の場合、ベア呼び出しでは SSOT のモデル、パーソナリティ、マルチエージェント機能の設定がすべて失われます。

---

## 関連ドキュメント

- [overview.ja.md](overview.ja.md) — ハーネス × アカウントアーキテクチャの概要
- [claude-code.ja.md](claude-code.ja.md) — Claude Code フック、ECC、CLV2 オブザーバー
- [codex.ja.md](codex.ja.md) — Codex CLI プロファイル設定、フック
- [secrets-1password.ja.md](../getting-started/secrets-1password.ja.md) — API キーを 1Password から 0600 ファイルにレンダリングする方法
