# シークレットとアカウント分離の設計

← [ドキュメント目次](../README.ja.md)

🌐 English (canonical): [secrets-and-isolation.md](secrets-and-isolation.md)

このドキュメントは、シークレットとアカウント分離が連携して機能する横断的な設計の「なぜ」を解説します。操作上の手順（どの vault アイテムを作成するか、ゲートの確認方法）については [secrets-1password.ja.md](../getting-started/secrets-1password.ja.md) を参照してください。アカウントごとの env 変数とエイリアスの参照テーブルは [account-isolation.ja.md](../agents/account-isolation.ja.md) を参照してください。

---

## 1Password シークレットがファイルシステムに届くまで

シークレット値は 1Password の `kryota.dev` vault にのみ存在します。git にコミットされたファイルには決して現れません。レンダリングパスは以下のとおりです:

```
1Password vault
    └── op://kryota.dev/<item>/<field>
            │
            │  chezmoi apply
            │  onepasswordRead / op read
            ▼
~/.config/zsh/claude-secrets.zsh    (モード 0600, private_ プレフィックス)
~/.aws/config                        (モード 0600, private_ プレフィックス)
~/.config/git/gitleaks-own.toml     (モード 0600, private_ プレフィックス)
```

`~/.ssh/config` も `private_` 0600 ファイル（`home/private_dot_ssh/config.tmpl` からデプロイ）ですが、1Password からレンダリングされるものでは**ありません**。OS 分岐テンプレートロジックのみを使用しており、`op://` や `onepasswordRead` の参照を一切含みません。

ソースの `.tmpl` ファイルには `op://` 参照のみが含まれています:

- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - Exa API/credential"` および `onepasswordRead "op://kryota.dev/Dotfiles - Firecrawl API/credential"`
- `home/private_dot_aws/config.tmpl` — 1Password Secure Note からファイル全体をレンダリングする単一の `onepasswordRead "op://kryota.dev/Dotfiles - AWS Config/notesPlain"` 呼び出し
- `home/dot_config/git/private_gitleaks-own.toml.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - Redact Patterns/pattern"` で自社名前空間リポジトリ用 gitleaks 設定にクライアント識別子正規表現を注入

`private_` chezmoi プレフィックスは、デスティネーションファイルに `0600` を適用するメカニズムです。追加の `chmod` は不要です。

値自体はレンダリング時にシングルクォートされます（chezmoi テンプレート関数 `squote`）。`$` やバッククォートを含むキーは、レンダリングされたファイルがシェルによってソースされる際にシェル展開やコマンド置換を引き起こすことができません。

---

## 2 段階の厳格さ: apply-strict と runtime-graceful

システムは apply 時とランタイムの動作に明確な境界を設けています:

### Apply-strict: `run_once_after_11-validate-1password.sh.tmpl`

このライフサイクルスクリプトは macOS 上で一度だけ実行され、<!-- FACT:onepassword-vault-item-count -->4<!-- /FACT --> つの必要な 1Password アイテムのいずれかが見つからないか到達不能な場合、ゼロ以外の終了コードで `chezmoi apply` を中断します。確認されるアイテムは以下のとおりです:

- `op://kryota.dev/Dotfiles - AWS Config/notesPlain`
- `op://kryota.dev/Dotfiles - Exa API/credential`
- `op://kryota.dev/Dotfiles - Firecrawl API/credential`
- `op://kryota.dev/Dotfiles - Redact Patterns/pattern`

`op` がインストールされていない、認証されていない、またはアイテムが読み取れない場合、`chezmoi apply` はフェイルファストします。注意点として、`run_once_after_11` は AFTER フェーズのスクリプトであり、実行時点ではホームディレクトリはすでに変更されています。実際のフェイルファストパスは次の 2 つです: (1) `.tmpl` ファイル内の `onepasswordRead` がテンプレートレンダリング中に apply を中断する（当該ファイルが書き込まれる前）; (2) `run_once_after_11` が後続の重い after フェーズプロビジョニング（mise、MCP、CLV2 等）の前のフェイルファストゲートとして機能する。シークレットが欠落した状態で途中までプロビジョニングされたマシンは、これらいずれかの時点でのクリーンな中断よりも悪い結果をもたらすという考えに基づいています。スクリプトは macOS のみです（`{{ if ne .chezmoi.os "darwin" }}` で早期終了）。CI は 1Password インストールなしで Ubuntu 上で実行されるためです。

### Runtime-graceful: readability ガードによるソース

レンダリングされたシークレットファイルは、`claude.zsh` ではなく `claude` ラッパー（`~/.local/launchers/claude`）が、ファイルが存在し読み取り可能で、かつ呼び出し元がまだそのキーを決めていない場合にのみソースします:

```bash
if [ -z "${EXA_API_KEY+x}" ] && [ -r "$HOME/.config/zsh/claude-secrets.zsh" ]; then
  . "$HOME/.config/zsh/claude-secrets.zsh"
fi
```

マシン上でまだ `chezmoi apply` が実行されていない場合、シークレットファイルは存在せずガードが正常に短絡します。MCP サーバーはラッパーがエラーになる代わりにキーなしで起動します。ラッパーはあらゆる呼び出し——インタラクティブシェル、フック、launchd、Claude Code 自身の Bash ツール——で実行されるため、このソースは `claude.zsh` によるソースのようにインタラクティブシェルセッションごとに 1 回ではなく、プロセスごとに 1 回発生します。export 時の `${VAR:-}` デフォルト（後述）は、この graceful degradation を exec 先のバイナリまで拡張します。`-z "${EXA_API_KEY+x}"` チェック（未設定 vs 空）により、呼び出し元はラッパー呼び出し前に**空の** `EXA_API_KEY` を export することで web 検索をオプトアウトできます — `morning-radar` はまさにこれを使ってキー読み込みそのものをスキップしています。

この二段階設計——apply 時は厳格、ランタイムは graceful——は、シークレットがまだプロビジョニングされていない新たにクローンされたマシンでも機能するシェルを提供しながら、プロビジョニング済みで 1Password へのアクセスを失ったマシンの次回 `chezmoi apply` が空のシークレットで黙ってサクセスしないことを保証します。

---

## ソース（export なし）、サブプロセスにスコープして再 export

これはリポジトリで最も重要なシークレット処理の決定です。

**パターン:**

1. `private_claude-secrets.zsh.tmpl` は `export` を伴わずレンダリングされます——プレーンな `KEY='value'` 代入です。
2. `claude` ラッパーはこれを自分自身の短命なプロセス内でソースし（インタラクティブシェルではありません — [アカウント分離 env モデルとの組み合わせ](#アカウント分離-env-モデルとの組み合わせ) を参照）、本物の `claude` バイナリを `exec` する直前に変数（`EXA_API_KEY`、`FIRECRAWL_API_KEY`）を export します:

```bash
if [ -z "${EXA_API_KEY+x}" ] && [ -r "$HOME/.config/zsh/claude-secrets.zsh" ]; then
  . "$HOME/.config/zsh/claude-secrets.zsh"
fi
# ...
export EXA_API_KEY="${EXA_API_KEY:-}"
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"
exec "$real" "$@"
```

**なぜソースされたファイルで単に `export` しないのか?**

インタラクティブシェルがソースするファイル内の `export` は、シェルセッションの存続期間中すべての子プロセス——すべてのサブシェル、すべての外部コマンド、すべてのバックグラウンドジョブ——に変数を漏洩させます。ラッパー自身のプロセス内（インタラクティブシェルではない）でソースする場合でも、シークレットファイル自体に素の `export` を書くのは、ラッパー自身の `export` 文——どの変数を exec 先のバイナリに届けるかを決める唯一の場所——と冗長になり、明確さも劣ります。

ラッパープロセス自体が子プロセスを生成するのではなく `exec` で置き換わるため、export された変数は必要とするプロセス——本物の `claude` バイナリとそれがスポーンするもの（MCP サーバー）——に正確にスコープされ、ラッパーを起動したインタラクティブシェルには一切触れません。Claude Code は MCP サーバーをスポーンする際にプロセス環境から `${EXA_API_KEY}` を読み取ります。他のプロセスはこれを見ません。

`${VAR:-}` デフォルト（変数が未設定の場合は空文字列）は、シークレットファイルがソースされていない場合でも export が安全であることを保証します。MCP サーバーはラッパーがエラーになる代わりに空のキーを受け取ります。

---

## CI が `chezmoi apply` 前にシークレットファイルを除外する方法

CI（`setup-validation.yml`）は 1Password にアクセスせずに macOS と Ubuntu で `chezmoi apply` を実行します。アプローチは、apply 実行前にシークレットを含むテンプレートファイルをソースツリーから `/tmp/chezmoi-excluded/` に物理的に移動することです。各ファイルは `if [ -f ]` チェックでガードされているため、エントリが見つからなくてもステップは中断されません:

```yaml
- name: Exclude CI-incompatible files
  run: |
    for f in \
      home/private_dot_aws/config.tmpl \
      home/dot_config/zsh/private_claude-secrets.zsh.tmpl \
      home/run_once_before_00-install-prerequisites.sh.tmpl \
      home/run_onchange_before_10-brew-bundle.sh.tmpl \
      home/run_once_after_11-validate-1password.sh.tmpl \
      home/dot_config/git/private_gitleaks-own.toml.tmpl; do
      if [ -f "$f" ]; then mv "$f" /tmp/chezmoi-excluded/; fi
    done
    # macOS ジョブはさらに除外:
    # home/run_once_after_90-other-apps.sh.tmpl
    # home/run_once_after_30-setup-fonts.sh.tmpl  (古い参照 — スクリプト削除済み、if ガードで許容)
```

注: `home/private_dot_ssh/config.tmpl` は除外されません——このファイルには `op://` や `onepasswordRead` の参照が含まれておらず、1Password インストールなしで apply できます。

これらのファイルがない状態で、chezmoi は `op read` や `onepasswordRead` を呼び出そうとしないため、1Password インストールなしで apply が成功します。CI のデプロイ済みホームディレクトリにはシークレットファイルが欠落していますが、それは許容されます——CI は実行時のシークレット可用性ではなく構造的な正確さ（ファイルが存在するか、ツールが解決するか、zsh がクリーンに起動するか）を検証します。

新しい 1Password バックドテンプレートを追加する際は、ライフサイクルスクリプトの `ITEMS` 配列（`run_once_after_11-validate-1password.sh.tmpl`）と CI 除外ステップの両方を同時に更新する必要があります。この 2 か所が必要な vault アイテムの完全なセットを列挙する唯一の場所です。

---

## アカウント分離 env モデルとの組み合わせ

アカウント分離とシークレットスコーピングは、同じメカニズム——ラッパーのプロセス境界で、本物のバイナリを `exec` する直前に export される環境変数——を共有する 2 つの重複する関心事です。

`claude` ラッパー（`~/.local/launchers/claude`）は両方を同時に行います:

```bash
export CLAUDE_CONFIG_DIR                                              # アカウント分離
export ECC_AGENT_DATA_HOME="$CLAUDE_CONFIG_DIR"                       # アカウント分離
export CLV2_HOMUNCULUS_DIR="$HOME/.local/share/ecc-homunculus-${homunculus_slug}"  # アカウント分離、config dir 外（#336）
export ECC_MCP_HEALTH_STATE_PATH="$CLAUDE_CONFIG_DIR/mcp-health-cache.json"
export GATEGUARD_STATE_DIR="$CLAUDE_CONFIG_DIR/.gateguard"            # アカウント分離
export EXA_API_KEY="${EXA_API_KEY:-}"                                 # シークレットスコーピング
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"                     # シークレットスコーピング
exec "$real" "$@"
```

ECC 状態、CLV2 インスティンクト、gateguard 状態をアカウントごとに分離する同じ単一のプロセス境界が、API キーもそのサブプロセスに限定します。どちらの関心事も別個のメカニズムを必要としません。

`codex` ラッパー（`~/.local/launchers/codex`）は Codex アカウント env（`CODEX_HOME`）についてこのパターンをミラーし、Codex CLI まで拡張します。#345 以前は、アカウントごとの env セットは手動で同期を保つ必要がある 2 か所——zsh ヘルパー `_claude_with_home`（`claude.zsh`）と `cdx-r06` エイリアス（`codex.zsh`）——で定義されており、これが分離モデルの主なメンテナンス負担でした。#345 はこの重複を除去します：各ラッパーが自分のハーネスの env セットを定義する唯一の場所になり、zsh エイリアスではなく PATH 上の実スクリプトであるため、`cld`/`cld-r06`/`cdx`/`cdx-r06`、素の `claude`/`codex`、フック、launchd、Claude Code 自身の Bash ツールのいずれからも同一に到達します——ドリフトしうる 2 つ目のコピーはもう残っていません。

r06 設定ディレクトリ（`~/.claude-r06`）は完全に `~/.claude` へのシンボリックリンクです——settings、statusline、agents、commands、skills——設定は単一 SSOT であり、状態ツリーは分岐します。シークレットは設定ディレクトリの意味でアカウントごとではありません。両方のアカウントが同じ API キー（同じ 1Password アイテム）を受け取ります。アカウント分離は、アカウントごとに異なるキーを使用することではなく、状態（セッション、ガバナンス、キャッシュ）に関するものです。

完全な env 変数とエイリアスの参照テーブルは [account-isolation.ja.md](../agents/account-isolation.ja.md) を参照してください。

---

## シークレット値が git に到達しない理由

3 つの補完的なレイヤーがシークレットのコミットを防ぎます:

1. **テンプレートソースファイルは参照のみを含む。** `.tmpl` ファイルは `op://kryota.dev/...` 文字列を保持します。レンダリングされた値はリポジトリ外のデスティネーションパス（`~/.config/zsh/` など）にのみ存在します。

2. **`private_` プレフィックスが `0600` を適用する。** デプロイされたファイルはパーミッション制限されています。誤ったパスへの `git add` は、追跡されたツリー外のファイルを明示的に含める必要があります。

3. **グローバル gitleaks pre-commit フック。** `~/.gitconfig` は `core.hooksPath=~/.config/git/hooks` を設定し、すべてのリポジトリのすべてのコミットに gitleaks スキャンをワイヤリングします。グローバルの `~/.config/git/gitleaks.toml` は `op://` 参照と `onepasswordRead` 呼び出しを明示的に allowlist に追加します。これによりテンプレートソースファイル自体はスキャンをパスしますが、実際のキー値（allowlist パターンに一致しない）はキャッチされます。

`--no-verify` バイパスは設計上存在します（緊急コミット用）が、CI のサーバーサイドが最終的な安全網です。コミットされたシークレットは、pre-commit フックがローカルでバイパスされても CI の gitleaks 実行でキャッチされます。
