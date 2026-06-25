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
~/.config/zsh/dmux-secrets.zsh      (モード 0600, private_ プレフィックス)
~/.aws/config                        (モード 0600, private_ プレフィックス)
```

`~/.ssh/config` も `private_` 0600 ファイル（`home/private_dot_ssh/config.tmpl` からデプロイ）ですが、1Password からレンダリングされるものでは**ありません**。OS 分岐テンプレートロジックのみを使用しており、`op://` や `onepasswordRead` の参照を一切含みません。

ソースの `.tmpl` ファイルには `op://` 参照のみが含まれています:

- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - Exa API/credential"` および `onepasswordRead "op://kryota.dev/Dotfiles - Firecrawl API/credential"`
- `home/dot_config/zsh/private_dmux-secrets.zsh.tmpl` — `onepasswordRead "op://kryota.dev/Dotfiles - OpenRouter API/credential"`
- `home/private_dot_aws/config.tmpl` — 1Password Secure Note からファイル全体をレンダリングする単一の `onepasswordRead "op://kryota.dev/Dotfiles - AWS Config/notesPlain"` 呼び出し

`private_` chezmoi プレフィックスは、デスティネーションファイルに `0600` を適用するメカニズムです。追加の `chmod` は不要です。

値自体はレンダリング時にシングルクォートされます（chezmoi テンプレート関数 `squote`）。`$` やバッククォートを含むキーは、レンダリングされたファイルがシェルによってソースされる際にシェル展開やコマンド置換を引き起こすことができません。

---

## 2 段階の厳格さ: apply-strict と runtime-graceful

システムは apply 時とランタイムの動作に明確な境界を設けています:

### Apply-strict: `run_once_after_11-validate-1password.sh.tmpl`

このライフサイクルスクリプトは macOS 上で一度だけ実行され、必要な 1Password アイテムが見つからないか到達不能な場合、ゼロ以外の終了コードで `chezmoi apply` を中断します。確認されるアイテムは以下のとおりです:

- `op://kryota.dev/Dotfiles - AWS Config/notesPlain`
- `op://kryota.dev/Dotfiles - Exa API/credential`
- `op://kryota.dev/Dotfiles - Firecrawl API/credential`
- `op://kryota.dev/Dotfiles - OpenRouter API/credential`

`op` がインストールされていない、認証されていない、またはアイテムが読み取れない場合、`chezmoi apply` はフェイルファストします。注意点として、`run_once_after_11` は AFTER フェーズのスクリプトであり、実行時点ではホームディレクトリはすでに変更されています。実際のフェイルファストパスは次の 2 つです: (1) `.tmpl` ファイル内の `onepasswordRead` がテンプレートレンダリング中に apply を中断する（当該ファイルが書き込まれる前）; (2) `run_once_after_11` が後続の重い after フェーズプロビジョニング（mise、MCP、CLV2 等）の前のフェイルファストゲートとして機能する。シークレットが欠落した状態で途中までプロビジョニングされたマシンは、これらいずれかの時点でのクリーンな中断よりも悪い結果をもたらすという考えに基づいています。スクリプトは macOS のみです（`{{ if ne .chezmoi.os "darwin" }}` で早期終了）。CI は 1Password インストールなしで Ubuntu 上で実行されるためです。

### Runtime-graceful: `[[ -r ... ]]` ガードによるソース

シェル起動時、`claude.zsh` と `dmux.zsh` はレンダリングされたシークレットファイルが存在し読み取り可能な場合にのみソースします:

```zsh
[[ -r "${HOME}/.config/zsh/claude-secrets.zsh" ]] && source "${HOME}/.config/zsh/claude-secrets.zsh"
```

マシン上でまだ `chezmoi apply` が実行されていない場合、シークレットファイルは存在せずガードが正常に短絡します。MCP サーバーはシェルがスタートアップ時にエラーになる代わりにキーなしで起動します。各ランチャー関数の `${VAR:-}` デフォルト（後述）は、この graceful degradation をサブプロセスレベルにまで拡張します。

この二段階設計——apply 時は厳格、ランタイムは graceful——は、シークレットがまだプロビジョニングされていない新たにクローンされたマシンでも機能するシェルを提供しながら、プロビジョニング済みで 1Password へのアクセスを失ったマシンの次回 `chezmoi apply` が空のシークレットで黙ってサクセスしないことを保証します。

---

## ソース（export なし）、サブプロセスにスコープして再 export

これはリポジトリで最も重要なシークレット処理の決定です。

**パターン:**

1. `claude.zsh` は `export` なしで `claude-secrets.zsh` をソースします。変数（`EXA_API_KEY`、`FIRECRAWL_API_KEY`）はインタラクティブシェルのローカルスコープに存在しますが、子プロセスには継承されません。
2. ランチャー関数 `_claude_with_home` は特定のサブプロセスにスコープしてインラインで再 export します:

```zsh
_claude_with_home() {
  local home_dir="$1"; shift
  CLAUDE_CONFIG_DIR="$home_dir" \
    EXA_API_KEY="${EXA_API_KEY:-}" \
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
    "$@"
}
```

**なぜソースされたファイルで単に `export` しないのか?**

ソースされたファイル内の `export` は、シェルセッションの存続期間中すべての子プロセス——すべてのサブシェル、すべての外部コマンド、すべてのバックグラウンドジョブ——に変数を漏洩させます。それらのプロセスのいずれかが環境をログに記録したり、コアファイルをダンプしたり、侵害されたりすれば、キーが露出します。

サブプロセスにスコープした再 export は、キーが必要とされる正確な場所でのみ利用可能であることを意味します。Claude Code は MCP サーバーをスポーンする際にプロセス環境から `${EXA_API_KEY}` を読み取ります。他のプロセスはアクセスできません。

`${VAR:-}` デフォルト（変数が未設定の場合は空文字列）は、シークレットファイルがソースされていない場合でも再 export が安全であることを保証します。MCP サーバーはランチャー関数がエラーになる代わりに空のキーを受け取ります。

**dmux も同じパターンに従います。** `dmux.zsh` は `dmux-secrets.zsh` と `claude-secrets.zsh` の両方をソースします（後者は dmux が `_claude_with_home` なしで `claude` を起動するため）。`dmux` と `dmux-r06` ラッパー関数は、`command dmux` 呼び出しにスコープして 3 つのキー（`OPENROUTER_API_KEY`、`EXA_API_KEY`、`FIRECRAWL_API_KEY`）すべてを再 export します。

---

## CI が `chezmoi apply` 前にシークレットファイルを除外する方法

CI（`setup-validation.yml`）は 1Password にアクセスせずに macOS と Ubuntu で `chezmoi apply` を実行します。アプローチは、apply 実行前にシークレットを含むテンプレートファイルをソースツリーから `/tmp/chezmoi-excluded/` に物理的に移動することです。各ファイルは `if [ -f ]` チェックでガードされているため、エントリが見つからなくてもステップは中断されません:

```yaml
- name: Exclude CI-incompatible files
  run: |
    for f in \
      home/private_dot_aws/config.tmpl \
      home/dot_config/zsh/private_claude-secrets.zsh.tmpl \
      home/dot_config/zsh/private_dmux-secrets.zsh.tmpl \
      home/run_once_before_00-install-prerequisites.sh.tmpl \
      home/run_onchange_before_10-brew-bundle.sh.tmpl \
      home/run_once_after_11-validate-1password.sh.tmpl; do
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

アカウント分離とシークレットスコーピングは、同じメカニズム——サブプロセス境界で設定された環境変数——を共有する 2 つの重複する関心事です。

`_claude_with_home` は両方を同時に行います:

```zsh
_claude_with_home() {
  local home_dir="$1"; shift
  CLAUDE_CONFIG_DIR="$home_dir" \          # アカウント分離
    ECC_AGENT_DATA_HOME="$home_dir" \      # アカウント分離
    CLV2_HOMUNCULUS_DIR="$home_dir/ecc-homunculus" \   # アカウント分離
    ECC_MCP_HEALTH_STATE_PATH="$home_dir/mcp-health-cache.json" \
    GATEGUARD_STATE_DIR="$home_dir/.gateguard" \       # アカウント分離
    EXA_API_KEY="${EXA_API_KEY:-}" \       # シークレットスコーピング
    FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \       # シークレットスコーピング
    "$@"
}
```

ECC 状態、CLV2 インスティンクト、gateguard 状態をアカウントごとに分離する同じ単一のサブプロセス境界が、API キーもそのサブプロセスに限定します。どちらの関心事も別個のメカニズムを必要としません。

`dmux-r06` は Codex アカウント env（`CODEX_HOME`）と専用の tmux ソケット（`TMUX_TMPDIR`）を同じ env 変数セットに追加し、マルチプレクサ層までパターンを拡張します。アカウントごとの env セットを定義する 3 か所（`_claude_with_home`、`dmux-r06`、`cdx-r06`）は同期を保つ必要があります。これは `dmux.zsh` のコメントに記載されており、分離モデルの主なメンテナンス負担です。

r06 設定ディレクトリ（`~/.claude-r06`）は完全に `~/.claude` へのシンボリックリンクです——settings、statusline、agents、commands、skills——設定は単一 SSOT であり、状態ツリーは分岐します。シークレットは設定ディレクトリの意味でアカウントごとではありません。両方のアカウントが同じ API キー（同じ 1Password アイテム）を受け取ります。アカウント分離は、アカウントごとに異なるキーを使用することではなく、状態（セッション、ガバナンス、キャッシュ）に関するものです。

完全な env 変数とエイリアスの参照テーブルは [account-isolation.ja.md](../agents/account-isolation.ja.md) を参照してください。

---

## シークレット値が git に到達しない理由

3 つの補完的なレイヤーがシークレットのコミットを防ぎます:

1. **テンプレートソースファイルは参照のみを含む。** `.tmpl` ファイルは `op://kryota.dev/...` 文字列を保持します。レンダリングされた値はリポジトリ外のデスティネーションパス（`~/.config/zsh/` など）にのみ存在します。

2. **`private_` プレフィックスが `0600` を適用する。** デプロイされたファイルはパーミッション制限されています。誤ったパスへの `git add` は、追跡されたツリー外のファイルを明示的に含める必要があります。

3. **グローバル gitleaks pre-commit フック。** `~/.gitconfig` は `core.hooksPath=~/.config/git/hooks` を設定し、すべてのリポジトリのすべてのコミットに gitleaks スキャンをワイヤリングします。グローバルの `~/.config/git/gitleaks.toml` は `op://` 参照と `onepasswordRead` 呼び出しを明示的に allowlist に追加します。これによりテンプレートソースファイル自体はスキャンをパスしますが、実際のキー値（allowlist パターンに一致しない）はキャッチされます。

`--no-verify` バイパスは設計上存在します（緊急コミット用）が、CI のサーバーサイドが最終的な安全網です。コミットされたシークレットは、pre-commit フックがローカルでバイパスされても CI の gitleaks 実行でキャッチされます。
