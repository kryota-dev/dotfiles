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
| `CLV2_HOMUNCULUS_DIR` | `~/.local/share/ecc-homunculus-default` | `~/.local/share/ecc-homunculus-r06` |
| `ECC_MCP_HEALTH_STATE_PATH` | `~/.claude/mcp-health-cache.json` | `~/.claude-r06/mcp-health-cache.json` |
| `GATEGUARD_STATE_DIR` | `~/.claude/.gateguard` | `~/.claude-r06/.gateguard` |
| `CODEX_HOME` | （デフォルト — `~/.codex`） | `~/.codex-r06` |
| `CODE_EXPL_STORE_ROOT` | `~/.claude/code-explanations` | `~/.claude-r06/code-explanations` |
| `CODE_EXPL_PORT` | `7788` | `7789` |

r06 の Claude 設定ディレクトリ（`~/.claude-r06`）には、すべての設定アーティファクト（settings、agents、commands、skills）が `~/.claude` を指すシンボリックリンクのみが含まれます。アカウント間で異なるのは、これらの環境変数がツールに書き込むよう指示するランタイム状態のみです。

`CLV2_HOMUNCULUS_DIR` だけは `~/.claude` / `~/.claude-r06` の外、`~/.local/share/` 配下に完全に置かれています。Claude Code は config dir 配下のすべてのパスを sensitive file として扱い Write に対話承認を要求しますが、CLV2 の解析セッションは headless（`claude --model haiku --print`）で動くためその承認を得ることができず、instinct の書き込みがすべて失敗していました（issue #336）。他のアカウント別変数（`CLAUDE_CONFIG_DIR`、`ECC_AGENT_DATA_HOME`、`ECC_MCP_HEALTH_STATE_PATH`、`GATEGUARD_STATE_DIR`）が config dir 配下のままなのは、それらが Claude Code の Write ツールを経由せず node / shell コードから直接書き込まれるため、このゲートに引っかからないからです。

`CODE_EXPL_STORE_ROOT` と `CODE_EXPL_PORT` は [Chatshelf](claude-code.ja.md) プラグインをアカウント別に分離します。各アカウントの PostToolUse 登録フックと SessionStart の viewer サーバーはそれぞれ自分の `code-explanations/` ストアに書き込み、r06 の viewer は `7789` を bind するので両アカウントのサーバーを同時に起動できます（`server.mjs` は `EADDRINUSE` で `exit 0` するため、`7788` を共有すると後から起動したアカウントが黙って相手の shelf を配信してしまいます）。これらは他の node 書き込み変数と同様 config dir 配下に置かれ、claude ラッパー（後述）が注入します。だからこそフックと viewer は — exec された claude の子プロセスとして — これらを継承します。ひとつだけ上流由来の制約が残ります。`server.mjs` は transcript を `~/.claude/projects` 固定で読み `CLAUDE_CONFIG_DIR` を見ないため、r06 アカウントでは viewer のセッション preview と `claude://resume` 補助が r06 セッションを解決できません。これは transcript 紐付きの preview のみが劣化するもので、アカウント別の shelf 分離（プライバシー境界）には影響しません。

---

## ランチャーコマンドマトリクス

以下はユーザー向けのエントリポイントです。`claude`/`cld` と `codex`/`cdx` はいずれも `~/.local/launchers/{claude,codex}` にある同じ 2 つのラッパー *スクリプト* に解決されます — `cld`、`cld-r06`、`cdx`、`cdx-r06` はそれらのスクリプトへのシンボリックリンクであり、各ラッパーは `$0`（呼び出された名前）でアカウント選択ロジックを分岐します。インタラクティブ zsh 専用のエイリアスではなく PATH 上の実ファイルであるため、インタラクティブシェル・フック・launchd・Claude Code 自身の Bash ツールなど、どのシェルからでも同一に振る舞います。

| コマンド | ハーネス | アカウント | 効果 |
|---|---|---|---|
| `claude` / `cld` | Claude Code | 個人（fill-gaps） | per-account 環境セットで mise 管理の `claude` バイナリを実行；すでに設定済みの `CLAUDE_CONFIG_DIR` を維持（フック起動の子プロセスが親セッションのアカウントに留まるため）、未設定なら `~/.claude` にデフォルト |
| `cld-r06` | Claude Code | 業務（r06） | 同じラッパー；`CLAUDE_CONFIG_DIR` を無条件に `~/.claude-r06` に強制（override） |
| `claude-config` | Claude Code | 個人 | zsh ヘルパー：ECC config-protection + gateguard-fact-force ゲートを無効化してから `claude` ラッパーを呼ぶ；意図的な設定編集用 |
| `cldf` | Claude Code | 個人 | zsh ヘルパー：`claude` ラッパーを `--model claude-fable-5` と [Fable 5 オーケストレータープロンプト](#fable-5-オーケストレーターcldf-系)付きで呼ぶ — main セッションは Fable 5、実行は Sonnet subagent に委譲 |
| `cldf-r06` | Claude Code | 業務（r06） | r06 アカウントでの `cldf` |
| `codex` / `cdx` | Codex CLI | `CLAUDE_CONFIG_DIR` に追従（fill-gaps） | brew 管理の `codex` バイナリを実行し、argv に `--profile` がなければ `--profile shared` を注入；`CODEX_HOME` は `CLAUDE_CONFIG_DIR` が設定されていればそれに追従（`.claude-r06` なら `~/.codex-r06`、それ以外は `~/.codex`）、未設定なら明示的な `CODEX_HOME` を尊重するか `~/.codex` にデフォルト |
| `cdx-r06` | Codex CLI | 業務（r06） | 同じラッパー；`CODEX_HOME` を無条件に `~/.codex-r06` に強制（override）；`--profile shared` は引き続き注入 |

個人アカウントについては、`claude` と `cld` は文字通り同じファイルに 2 つの名前でアクセスしているだけです — ラッパーの `$0` 分岐には `cld-r06` 用の分岐しかなく `cld` 専用の分岐はありません — したがって両者に分離上の違いはありません。`codex`/`cdx` も同様です。短縮名が存在するのは `-r06` 系との対称性と手癖のためであり、ベアの名前に何かが欠けているからではありません（[ベア呼び出しはもはやギャップではない](#ベア呼び出しはもはやギャップではない) を参照）。

---

## Fable 5 オーケストレーター（`cldf` 系）

`cldf` / `cldf-r06` エイリアスは Claude Code を**オーケストレーター構成**で起動します。main セッションは `claude-fable-5` で俯瞰・立案・統合を担い、タスク実行は Sonnet 系 subagent へ委譲します。これらは `claude` ラッパー（ベアの `claude`/`cld` と同じアカウント分離環境）を `_claude_fable` という薄いヘルパーでラップしており、次を行います:

- main モデルをフル ID `--model claude-fable-5`（`fable` エイリアスではない）で pin する。委譲プロンプトの Sonnet 5 世代前提と main モデル世代が silently ずれないようにするためで、モデル世代交代時にはプロンプトとセットで意識的に更新する。
- `home/dot_claude/fable-orchestrator-prompt.md`（デプロイ先: `~/.claude/fable-orchestrator-prompt.md`）を、readable なときのみ `--append-system-prompt-file <path>` で指定する。渡すのは **path** で、CLI 側が process 起動時にファイルを読む — プロンプトが伸びても argv には載らない。ファイル不在時（`chezmoi apply` 前 / 手動削除後）でもセッションは正常起動し、オーケストレーター誘導だけが効かない。

プロンプトファイルは意図的に `~/.claude/…` に置き、両アカウントから絶対パスで読む — `hooks-fork/` と同じ「default アカウント配下を両アカウントで共有」前例。

`CLAUDE_CODE_SUBAGENT_MODEL` は**意図的に未設定**にしています。この環境変数は per-invocation `model` param と agent frontmatter より最優先で全 subagent を固定するため、設定してしまうと「難タスクだけ Fable に escalate する」経路が消えます。代わりにオーケストレータープロンプトが subagent のモデル選択を誘導します（既定 `model: sonnet`、難検証のみ `fable` に上げる、`subagent_type: "fork"` は常に親モデルを継承する点に注意）。

ソース: `home/dot_config/zsh/claude.zsh`（`_claude_fable` ヘルパー。`CLAUDE_CONFIG_DIR` を明示的に設定してから `claude` ラッパーを呼ぶ）。

---

## claude ラッパー：Claude Code のアカウント選択の仕組み

Claude Code の per-account 環境注入は `~/.local/launchers/claude`（ソース: `home/dot_local/launchers/executable_claude`）という 1 つのスクリプトに集約されており、`claude` / `cld` / `cld-r06` としてアクセスされます — 後者 2 つはこのスクリプトへのシンボリックリンクで、ラッパーは `$0` で分岐します：

```bash
case "${0##*/}" in
  cld-r06)
    # -r06 name: select the work account unconditionally (override).
    CLAUDE_CONFIG_DIR="$HOME/.claude-r06"
    ;;
  *)
    # claude / cld: fill-gaps only, so an inherited account survives.
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    ;;
esac

# ... config dir のベースネームから homunculus_slug を導出 ...
# ... 呼び出し元が EXA_API_KEY をすでに決めていなければ claude-secrets.zsh をソース ...
# ... `mise which claude` で pin 正しい mise 管理バイナリを解決 ...

export CLAUDE_CONFIG_DIR
export ECC_AGENT_DATA_HOME="$CLAUDE_CONFIG_DIR"
export CLV2_HOMUNCULUS_DIR="$HOME/.local/share/ecc-homunculus-${homunculus_slug}"
export ECC_MCP_HEALTH_STATE_PATH="$CLAUDE_CONFIG_DIR/mcp-health-cache.json"
export GATEGUARD_STATE_DIR="$CLAUDE_CONFIG_DIR/.gateguard"
export EXA_API_KEY="${EXA_API_KEY:-}"
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"

exec "$real" "$@"
```

主な特性：

- ラッパーは短命なスクリプトプロセスです：環境変数を自分自身のプロセスにエクスポートしてから、その場で本物の `claude` バイナリへ `exec` します — ラッパープロセス自体が置き換わるだけで子プロセスを生成しないため、起動元のインタラクティブシェルには何も漏れません。
- homunculus slug は config dir のベースネームから `run_onchange_after_14` と同じ 3 分岐で導出されます：`.claude` → `default`、`.claude-*` → サフィックス、それ以外 → 先頭のドットを除去。
- `EXA_API_KEY` と `FIRECRAWL_API_KEY` はラッパー自身が `~/.config/zsh/claude-secrets.zsh`（`chezmoi apply` 時に 1Password からレンダリングされる 0600 ファイル）からソースします — ただし呼び出し元がそのキーをすでに決めている場合（空文字であっても）はソースしません。これにより `morning-radar` は空の `EXA_API_KEY` を export することで web 検索をオプトアウトできます。`claude.zsh` はこのファイルを自分ではソースしなくなりました。
- `real` は（このラッパー自身を再解決してしまう PATH 経由ではなく）`mise which claude` で解決されるため、pin 正しい mise 管理バイナリが常に実行されます。`CLAUDE_LAUNCHER_BIN` はテスト用にこれを上書きします。本物のバイナリが解決できない場合、ラッパーは誤ったバイナリをサイレントに実行する代わりに大きく失敗します（exit 127）。

ソース：`home/dot_local/launchers/executable_claude`

---

## ベア呼び出しはもはやギャップではない

ベアのバイナリ名（`claude`、`codex`）での実行は、#345 より前はアカウント機構を完全にバイパスしていました — per-account 環境と（Codex の場合）`--profile shared` を注入するのは zsh エイリアス（`cld`、`cdx` など）だけでした。このギャップは解消されています：`claude` と `codex` は PATH 上で `cld`/`cld-r06`、`cdx`/`cdx-r06` と同じラッパースクリプトに解決されます。これが機能するのは `~/.local/launchers` が mise のシムディレクトリと Homebrew の `bin` の両方より PATH 上で前に来るよう維持されているためです — `dot_zshrc.tmpl` での静的な prepend に加え、`mise activate` の**後**に登録される `precmd` フック（mise は自身の `precmd` フックで毎プロンプトごとに自分のシムディレクトリを再 prepend するため、こちらは mise の後に実行されて勝つ必要がある）、そして launchd の morning-radar スクリプトが自身のハードコードされた PATH の先頭に同じディレクトリを prepend します。

インタラクティブ zsh 専用のエイリアスではなく PATH 上の実ファイルであるため、ラッパーはエイリアスが届かなかった文脈——フックプロセス、launchd ジョブ、Claude Code 自身の Bash ツールが実行するコマンド——からも動作します。アカウント選択ロジックのコピーが 1 つしかないため、呼び出し元ごとのエイリアス定義が必要としていたであろう手コピーの環境ブロックが、呼び出し箇所間でドリフトすることがありません。

残る唯一の違いは「ラップされているか / ベアか」ではなく fill-gaps か override かです：

| 呼び出し | 挙動 |
|---|---|
| `claude` / `cld` | fill-gaps：すでに設定済みの `CLAUDE_CONFIG_DIR`（例：親の `cld-r06` セッションから継承）を維持し、なければ個人アカウントにデフォルト |
| `cld-r06` | override：継承した値に関わらず業務アカウントを強制 |
| `codex` / `cdx` | fill-gaps：`CODEX_HOME` は設定済みの `CLAUDE_CONFIG_DIR` に追従（authoritative — 不一致な継承済み `CODEX_HOME` すら上書き）、なければ明示的な `CODEX_HOME` を尊重するか `~/.codex` にデフォルト |
| `cdx-r06` | override：継承した値に関わらず `CODEX_HOME=~/.codex-r06` を強制 |

---

## 関連ドキュメント

- [overview.ja.md](overview.ja.md) — ハーネス × アカウントアーキテクチャの概要
- [claude-code.ja.md](claude-code.ja.md) — Claude Code フック、ECC、CLV2 オブザーバー
- [codex.ja.md](codex.ja.md) — Codex CLI プロファイル設定、フック
- [secrets-1password.ja.md](../getting-started/secrets-1password.ja.md) — API キーを 1Password から 0600 ファイルにレンダリングする方法
