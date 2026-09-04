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

r06 の Claude 設定ディレクトリ（`~/.claude-r06`）には、すべての設定アーティファクト（settings、agents、commands、skills）が `~/.claude` を指すシンボリックリンクのみが含まれます。アカウント間で異なるのは、これらの環境変数がツールに書き込むよう指示するランタイム状態のみです。

`CLV2_HOMUNCULUS_DIR` だけは `~/.claude` / `~/.claude-r06` の外、`~/.local/share/` 配下に完全に置かれています。Claude Code は config dir 配下のすべてのパスを sensitive file として扱い Write に対話承認を要求しますが、CLV2 の解析セッションは headless（`claude --model haiku --print`）で動くためその承認を得ることができず、instinct の書き込みがすべて失敗していました（issue #336）。他のアカウント別変数（`CLAUDE_CONFIG_DIR`、`ECC_AGENT_DATA_HOME`、`ECC_MCP_HEALTH_STATE_PATH`、`GATEGUARD_STATE_DIR`）が config dir 配下のままなのは、それらが Claude Code の Write ツールを経由せず node / shell コードから直接書き込まれるため、このゲートに引っかからないからです。

---

## ランチャーコマンドマトリクス

以下はユーザー向けのエントリポイントです。`claude`/`cld` と `codex`/`cdx` はいずれも `~/.local/launchers/{claude,codex}` にある同じ 2 つのラッパー *スクリプト* に解決されます — `cld`、`cld-r06`、`cdx`、`cdx-r06` はそれらのスクリプトへのシンボリックリンクであり、各ラッパーは `$0`（呼び出された名前）でアカウント選択ロジックを分岐します。インタラクティブ zsh 専用のエイリアスではなく PATH 上の実ファイルであるため、インタラクティブシェル・フック・launchd・Claude Code 自身の Bash ツールなど、どのシェルからでも同一に振る舞います。

| コマンド | ハーネス | アカウント | 効果 |
|---|---|---|---|
| `claude` / `cld` | Claude Code | 個人（fill-gaps） | per-account 環境セットで mise 管理の `claude` バイナリを実行；すでに設定済みの `CLAUDE_CONFIG_DIR` を維持（フック起動の子プロセスが親セッションのアカウントに留まるため）、未設定なら `~/.claude` にデフォルト |
| `cld-r06` | Claude Code | 業務（r06） | 同じラッパー；`CLAUDE_CONFIG_DIR` を無条件に `~/.claude-r06` に強制（override） |
| `claude-config` | Claude Code | 個人 | zsh ヘルパー：ECC config-protection ゲートを無効化してから `claude` ラッパーを呼ぶ；意図的な設定編集用 |
| `cldf` | Claude Code | 個人 | zsh ヘルパー：`claude` ラッパーを `--model claude-fable-5-1` と [Fable オーケストレータープロンプト](#fable-オーケストレーターcldf-系)付きで呼ぶ — main セッションは Fable 5.1、実行は Sonnet subagent に委譲 |
| `cldf-r06` | Claude Code | 業務（r06） | r06 アカウントでの `cldf` |
| `codex` / `cdx` | Codex CLI | `CLAUDE_CONFIG_DIR` に追従（fill-gaps） | brew 管理の `codex` バイナリを実行し、argv に `--profile` がなければ `--profile shared` を注入；`CODEX_HOME` は `CLAUDE_CONFIG_DIR` が設定されていればそれに追従（`.claude-r06` なら `~/.codex-r06`、それ以外は `~/.codex`）、未設定なら明示的な `CODEX_HOME` を尊重するか `~/.codex` にデフォルト |
| `cdx-r06` | Codex CLI | 業務（r06） | 同じラッパー；`CODEX_HOME` を無条件に `~/.codex-r06` に強制（override）；`--profile shared` は引き続き注入 |

個人アカウントについては、`claude` と `cld` は文字通り同じファイルに 2 つの名前でアクセスしているだけです — ラッパーの `$0` 分岐には `cld-r06` 用の分岐しかなく `cld` 専用の分岐はありません — したがって両者に分離上の違いはありません。`codex`/`cdx` も同様です。短縮名が存在するのは `-r06` 系との対称性と手癖のためであり、ベアの名前に何かが欠けているからではありません（[ベア呼び出しはもはやギャップではない](#ベア呼び出しはもはやギャップではない) を参照）。

---

## Fable オーケストレーター（`cldf` 系）

`cldf` / `cldf-r06` エイリアスは Claude Code を**オーケストレーター構成**で起動します。main セッションは `claude-fable-5-1` で俯瞰・立案・統合を担い、タスク実行は Sonnet 系 subagent へ委譲します。これらは `claude` ラッパー（ベアの `claude`/`cld` と同じアカウント分離環境）を `_claude_fable` という薄いヘルパーでラップしており、次を行います:

- main モデルをフル ID `--model claude-fable-5-1`（`fable` エイリアスではない）で pin する。委譲プロンプトの Sonnet 5 世代前提と main モデル世代が silently ずれないようにするためで、モデル世代交代時にはプロンプトとセットで意識的に更新する（エイリアスは現在 [Fable 5.1 に解決される](https://code.claude.com/docs/en/model-config)ため、放っておくと次の世代交代で勝手に動く）。フラグを使うのは、ピッカーを開かずに pin を効かせるため: Claude Code は [main モデルを](https://code.claude.com/docs/en/model-config)セッション内 `/model` > `--model` > `ANTHROPIC_MODEL` > 設定ファイルの `model` > 組織既定 > `ANTHROPIC_DEFAULT_MODEL` の順で解決するので、`--model` は過去に `/model` で保存した既定に勝つ。
- `home/dot_claude/fable-orchestrator-prompt.md`（デプロイ先: `~/.claude/fable-orchestrator-prompt.md`）を、readable なときのみ `--append-system-prompt-file <path>` で指定する。渡すのは **path** で、CLI 側が process 起動時にファイルを読む — プロンプトが伸びても argv には載らない。ファイル不在時（`chezmoi apply` 前 / 手動削除後）でもセッションは正常起動し、オーケストレーター誘導だけが効かない。

#677 以降、このフラグは書いたままの形では CLI に届かない。ラッパーがこれを取り除き、オーケストレータープロンプトと AskUserQuestion 規約を 1 つの合成ファイルに畳んでから渡す（後述の [append-system-prompt の正規化](#append-system-prompt-の正規化)）。`cldf` がオーケストレータープロンプト全文を受け取ることは変わらず、テストで端から端まで固定してある — 単独ではなく連結された形で届くだけである。

プロンプトファイルは意図的に `~/.claude/…` に置き、両アカウントから絶対パスで読む — `hooks-fork/` と同じ「default アカウント配下を両アカウントで共有」前例。

`CLAUDE_CODE_SUBAGENT_MODEL` は**意図的に未設定**にしていますが、理由はこのドキュメントが以前述べていたものとは違います。Claude Code は v2.1.251 以降、[subagent のモデルを次の順で解決](https://code.claude.com/docs/en/sub-agents)します:

1. spawn 時に渡した `model` パラメータ
2. agent 定義の `model:` frontmatter（`inherit` は「main 会話と同じモデル」の意）
3. `CLAUDE_CODE_SUBAGENT_MODEL`
4. main 会話のモデル

v2.1.251 より前はこの環境変数が 1 番目で、spawn 時指定と frontmatter の両方を上書きしていたため、設定すれば実際に「難タスクだけ Fable に escalate する」経路が消えていました。現在は**既定値**に降格しているので、設定してもその経路は潰れません。

それでも未設定のままにしているのは、別の理由からです: 効く範囲が狭く、「subagent の既定モデル」を宣言する場所を 2 つに割るには見合いません。この環境変数が届くのは、frontmatter の `model:` も spawn 時の `model` も持たない spawn だけで:

- `home/dot_claude/agents/` の subagent は全て frontmatter で `model: sonnet` を pin 済みで、規則 2 が規則 3 に勝つため、いずれも影響を受けません。
- built-in のうち `general-purpose` は公式 docs が対象と明記しています（"the `CLAUDE_CODE_SUBAGENT_MODEL` model if you set one and nothing assigns a model another way, otherwise the main conversation's model"）。
- 一方 `Explore` / `Plan` は main 会話のモデルを継承し、公式 docs は "setting `CLAUDE_CODE_SUBAGENT_MODEL` by itself doesn't change the model the built-in Explore and Plan subagents run on" と明記しています。

オーケストレータープロンプトと環境変数の両方に既定を書けば以後ずっと同期し続ける必要が生まれるので、プロンプト側を唯一の宣言箇所とします（既定 `model: sonnet`、難検証のみ `fable` に上げる、`subagent_type: "fork"` は常に親モデルを継承）。代償として `model` を省略した spawn は Fable を継承するため、プロンプトはオーケストレーターに `model` の明示を求めています — `Explore` / `Plan` に届く唯一の手段でもあります。

v2.1.257 で追加された [`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`](https://code.claude.com/docs/en/env-vars) は、subagent / teammate / workflow agent に対して旧来の「全上書き」挙動を（"the built-in Explore and Plan definitions included"）復活させるものです。これは当初の理由のまま未設定にしています: 設定すると escalation 経路が実際に消えるためです。

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
- #677 以降、ラッパーは `exec` の前に argv も書き換えます — 純粋に加算的でない唯一の箇所です。次節を参照。

ソース：`home/dot_local/launchers/executable_claude`

### append-system-prompt の正規化

「判断を仰ぐときは `AskUserQuestion` を使う」規約は `home/dot_claude/ask-user-question-prompt.md`（デプロイ先: `~/.claude/ask-user-question-prompt.md`）に置かれ、instructions ではなく **system prompt** として注入されます。#614 はこれを `CLAUDE.md` に書きましたが守られず（#677 で 1 セッション中に 3 度の違反を実測）、#677 で権威を system prompt へ移しました。`claude.zsh` ではなくラッパーに置くのは、ここが全ての起動経路が通る唯一のファイルだからです — 対話 zsh、hooks、launchd ジョブ、frontier-harness の子セッション、Claude 自身の Bash ツール。

形を決めているのは、実測した CLI（claude 2.1.259）の 3 つの性質です:

| 性質 | 帰結 |
| --- | --- |
| `--append-system-prompt-file` は**複数指定できない** — `.argParser(String)` で宣言されており、後の指定が前の指定を警告なく置き換える | ラッパーは呼び出し側の指定に自分のフラグを**重ねられない**。そこで**畳む**: 呼び出し側の指定を argv から取り除き、そのプロンプトと規約を 1 ファイルに連結し、CLI が許す唯一の出現として渡す |
| フラグは**最初の positional より前**に置く必要がある — サブコマンドの後ろでは `error: unknown option` で abort し、前に置けば root コマンドが解析してサブコマンドは正常に動く | プログラム名直後に前置する。codex ラッパーが `--profile` に使っているのと同じグローバル位置。サブコマンド許可リストの恒久保守は不要 |
| `--append-system-prompt` と `--append-system-prompt-file` は**排他**（`Cannot use both … Please use only one.`, exit 1） | 呼び出し側が content 形式で渡した場合も同じ合成ファイルへ畳む。**両方**渡された場合は両方をそのまま返し、何が誤りかはラッパーではなく CLI が決める |

合成ファイルは `${XDG_CACHE_HOME:-~/.cache}/claude-launcher/` に content-addressed で置かれ、名前は**書き込んだバイト列そのものの SHA-256** です。**既に非空のファイルがあっても再利用せず、毎回書き直します**。内容はこのリポジトリ上のファイル由来なのでパスは事前計算でき、同一 UID の別プロセス（侵害された hook / MCP サーバー / skill）が先にファイルを置ける以上、再利用すればそれが無検証でセッションの system prompt になってしまうからです。それでは規約を注入する意味そのものが失われます。`mv` は rename なので、symlink が置かれていてもエントリごと置換します。弱いダイジェストへのフォールバックはありません — `shasum` も `sha256sum` も無ければ、CRC32 で静かに名付ける代わりに abort します。

さらに 3 点、明記しておきます:

- **値を伴わない**フラグ（argv 末尾の `claude --append-system-prompt`）は、元の位置（末尾）に戻して CLI へ渡します。commander が `argument missing` を報告できるようにするためで、空プロンプトとして畳むとセッションが起動してしまいます — 設計上ここだけが沈黙ドロップになりかねない箇所でした。一方、値が**明示的に空**の場合は別扱いです（commander は受理して無視するため、「呼び出し側プロンプトなし」とみなして規約だけを注入します）。
- argv 走査は他フラグの arity を**知りません**。そのため値がこれらのフラグ名と一致する入力（`claude -p '--append-system-prompt-file'`）はフラグとして誤認識され、次のトークンまで巻き込みます。フル arity テーブルは全オプションの追従が必要で、オプションが 1 つ増えるたびに drift するため、この制限は許容して明記する方針を採りました。codex ラッパーも同じ制限を持ちます。
- `--append-system-prompt <text>` で渡した本文は、従来 argv とプロセスメモリにしか存在しませんでしたが、今はセッションより長生きする 0600 ファイルになります。現状この綴りを使う経路はありませんが、今後使う場合は短命な秘密情報を載せないこと。キャッシュに TTL 掃除を入れていないのは意図的です — content-addressed なので実在するプロンプトの種類数で上限が付き、起動ごとの掃除は「それらのファイルが変わったときにしか増えない集合」を抑えるために全セッションへコストを課すことになります。

`--append-system-prompt-file` は**未文書**です（`.hideHelp()` により `claude --help` に現れない）。それでも依存してよいのは、肝心な一点で**沈黙しない**からです: 未知オプションは無視されずに exit 1 で abort し、読めないプロンプトファイルも同様に abort します。env 変数や user settings に代替経路はありません — `settings.appendSystemPrompt` は enterprise policyHelper の payload からのみ読まれ、それは管理者所有の managed settings に置かれます。

**これは #616 が解こうとした問題の半分しか閉じません。** system prompt も `CLAUDE.md` と同じくセッション開始時に読まれるため、セッション*中*に書いた規約はそのセッションを縛りません。変わるのは権威と目立ちやすさです — 規約が無視された理由が「巨大な `CLAUDE.md` に埋もれていた」ことであれば、そちらが効く半分です。

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
