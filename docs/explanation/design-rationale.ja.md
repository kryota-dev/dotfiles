# なぜこのように設計されているのか

🌐 English (canonical): [design-rationale.md](design-rationale.md)

← [ドキュメント目次](../README.ja.md)

このドキュメントは、リポジトリの根幹となる設計判断——how-to ドキュメントには自然に現れにくい「なぜ」——を解説します。各セクションでは判断内容、それが解決する問題、そしてメカニズムを扱う参照ドキュメントへのリンクを示します。

---

## 複数の個別ダウンロードではなく単一 tarball キャッシュ

**判断:** 採用した <!-- FACT:ecc-skill-count -->127<!-- /FACT --> の ECC スキルと ECC フックランタイムはすべて `.chezmoiexternal.toml` に個別エントリとして宣言されていますが、各エントリは同一の tarball URL（`[ecc].commit` でピンされた ECC アーカイブ）を指しています。同様に、17 の Anthropic システムスキルもすべて同じ `anthropics/skills` アーカイブ URL を参照しています。

**なぜ:** chezmoi は外部アーカイブを URL の SHA-256 をキーとしてキャッシュします。複数のエントリが同一 URL を共有する場合、chezmoi は tarball を一度だけダウンロードしてキャッシュからすべてのエントリを満たします。各スキルを個別 URL からフェッチする代替案では、`chezmoi apply` のたびにスキルごとに 1 回（合計で数百回）のネットワーク通信が必要となり、低速・従量制の回線ではインストールが遅くなり不安定になります。

各エントリの `include` glob と `stripComponents` の値がフィルターとして機能し、単一のキャッシュ済みアーカイブから対象サブディレクトリだけを抽出します。大きな tarball のコストは一度だけ払い、スキルごとに独立したパスという恩恵は保たれます。

メカニクスについては [externals-and-pinning.ja.md](../architecture/externals-and-pinning.ja.md) を参照してください。

---

## タグではなくコミット SHA にピン留めして再現性を確保

**判断:** すべての外部 URL は、ブランチ名やタグではなく不変のコミットハッシュ（`[skills].anthropic_commit`、`[ecc].commit`）を補間します。さらに ECC のバンプは Renovate の `packageRules` で自動マージをブロックしています。

**なぜ:** Git タグはフォースプッシュや削除が可能で、ブランチの先端はマージのたびに移動します。コミットハッシュへのピンは、今日実行しても 2 年後に実行しても `chezmoi apply` が同一バイトをフェッチすることを保証します。`v2.0.0` タグが移動してもフックコードがサイレントに変わることはありません。

ECC は特に、Claude Code セッションの権限で実行される JavaScript フックを配布します。誤操作や悪意あるタグ移動が発生すれば、次回の apply 時にすべてのマシンに新しいフックコードが届くというサプライチェーンリスクがあります。自動マージのブロックにより、ECC のバンプは必ず人によるレビューを経てマージされます。

各外部エントリの `refreshPeriod = "168h"` は実用的な中間層を追加します。7 日以内であれば、明示的なバージョン変更なしでも chezmoi はキャッシュコピーを提供します。その後は次回 apply 時に再ダウンロードされます。

Renovate の `customManager` 正規表現については [externals-and-pinning.ja.md](../architecture/externals-and-pinning.ja.md) を参照してください。

---

## ECC を外部として採用し、再実装よりもフォークを選択

**判断:** ECC（Everything Claude Code）フックランタイムは、プラグインとしてインストールせず chezmoi external として（ソースのみ、`node_modules` なしで）フェッチします。ECC の上流の動作を拡張する必要がある場合——耐久性のある SQLite ガバナンス、アカウント対応の監査ログ、読み取り専用の状態検査 CLI——は、ピン留めされた外部の ECC モジュールを `require()` する薄いフォークとして実装しています。

**なぜ:** ECC はガバナンスキャプチャ、gateguard、CLV2 継続学習など多数の動作をカバーする充実したフックフレームワークを提供しています。その大部分を再実装することはメンテナンスコストが高く利点がありません。最小限のフォークで上流コードを再利用することで、フォークは薄く保たれ、ピンをバンプした際に上流のバグ修正を自動的に取り込めます。

「ソースのみ external」アプローチ（tarball に `node_modules` を含まない）は意図的です。大きなバイナリツリーを `~/.agents/skills/ecc/` に配置するのを避け、フォークが ECC の `sql.js`/`ajv` 依存ではなく `node:sqlite`（mise がピンする Node ≥ 22.5 が提供）を使用するよう強制します。

薄い `ecc-hook.sh` ランチャーは `settings.json` を読みやすくするために存在します。ECC のデフォルト配布では各フックエントリに ~1.5 KB の難読化された `node -e` blob が埋め込まれており、プラグインルートをランタイムスキャンします。External が固定パスにあるため、そのスキャンは不要です。各 blob を `ecc-hook.sh` の一行呼び出しに置き換えることで、フックグラフが一目で理解できるようになります。

フックグラフと 3 つのフォークファイルについては [claude-code.ja.md](../agents/claude-code.ja.md) を参照してください。

---

## デュアルアカウントモデル: 設定は共有、状態は分離

**判断:** r06 作業アカウント（`~/.claude-r06`）は、すべての設定ファイル（settings、statusline、agents、commands、skills、CLAUDE.md）を `~/.claude` へ指す 6 つのシンボリックリンクとして実装されています。実行時の状態は、zsh ランチャーエイリアスで設定されるアカウントごとの環境変数によって分岐します。

**なぜ:** 2 つの並列設定ディレクトリを管理する代替案では、設定変更のたびに二重作業が必要となり、必然的にアカウント間でドリフトが生じます。個人セッションと作業セッションで正当に異なる唯一のものが実行時の状態（セッション履歴、ガバナンス DB、ECC 状態、CLV2 インスティンクト、キャッシュ）であるため、適切な分割は「設定は単一 SSOT、状態は 2 つの独立したツリー」です。

環境変数メカニズム（`CLAUDE_CONFIG_DIR`、`ECC_AGENT_DATA_HOME`、`CLV2_HOMUNCULUS_DIR`、`GATEGUARD_STATE_DIR`）は最も軽量なシームです。Claude Code 自体への変更も、設定ファイルのアカウントごとのコピーも、ランタイムの設定マージロジックも不要です。同じ env パターンが dmux にも適用されます（`dmux-r06` は専用の `TMUX_TMPDIR` を設定し、2 つのアカウントのセッションが衝突しないようにします）。

このモデルのリスクは、3 か所（`claude.zsh` の `_claude_with_home`、`dmux.zsh` の `dmux-r06`、`codex.zsh` の `cdx-r06`）でアカウントごとの env セットが定義されることです。`dmux.zsh` のコメントはこれを明示的に同期要件として記載しています。これは受け入れられた重複であり、変更が稀なセットに対する代替案（3 か所から呼ばれる共有 env 構築関数）は、不必要な間接性を追加するだけです。

アカウントごとの全 env 変数とエイリアスマトリクスについては [account-isolation.ja.md](../agents/account-isolation.ja.md) を参照してください。

---

## シークレットはソース（export なし）、サブプロセスにスコープして再 export

**判断:** 1Password レンダリングのキーファイル（`~/.config/zsh/claude-secrets.zsh`、`dmux-secrets.zsh`）は `export` なしでインタラクティブシェルにソースされます。ランチャー関数（`_claude_with_home`、`dmux`、`dmux-r06`）が特定のサブプロセス呼び出しにスコープしてキーをインラインで再 export します。

**なぜ:** ソースされたファイル内の `export` は、セッションの存続期間中、インタラクティブシェルのすべての子プロセス——すべてのサブシェル、すべての外部コマンド、すべてのバックグラウンドジョブ——にキーを漏洩させます。不正プロセスや誤った `env` ログがプロセス環境をキャプチャすれば、キーが露出します。

export なしでのソースは、変数をシェルのローカルスコープに保持し（同じシェルプロセス内では名前でアクセス可能）、子プロセスには伝播しません。サブプロセスにスコープした再 export（`EXA_API_KEY="${EXA_API_KEY:-}" claude`）により、Claude Code が必要とする正確な場所（MCP サーバーの env プレースホルダーを解決する場所）でのみキーが使用可能となり、それ以外では使用できません。

各再 export の `${VAR:-}` デフォルトは、ランタイムの graceful degradation パスです。マシンでまだ `chezmoi apply` が実行されていない場合（シークレットファイルが存在しない場合）、ラッパー関数がエラーになる代わりに MCP サーバーはキーなしで起動します。

シークレットのライフサイクル全体については [secrets-and-isolation.ja.md](secrets-and-isolation.ja.md) を、オンボーディングの手順については [secrets-1password.ja.md](../getting-started/secrets-1password.ja.md) を参照してください。

---

## mise はすべてのツールバージョンを正確にピン

**判断:** すべての言語ランタイムと CLI ツールは `home/dot_config/mise/config.toml` で正確なバージョンにピンされています。範囲指定（`>=`）も `latest` も使いません。

**なぜ:** マシンプロビジョニングモデルは、`chezmoi apply` と `mise install` が動作する再現可能な環境を生成することを前提としています。フローティングバージョンはこれを破壊します。6 か月後の `mise install` 実行が、ECC の `node:sqlite` 使用を壊す Node メジャーバージョンや、CLV2 のインポート解決を変更する Python マイナー、ライフサイクルスクリプトが使用するサブコマンドをリネームした `gh` CLI バージョンを取得する可能性があります。

正確なピンは、CI の `setup-validation.yml` とローカルの `chezmoi apply` が同一のツールをインストールすることも意味します。CI の失敗はローカルで再現可能です。CI の mise キャッシュキーは `config.toml` の SHA-256 なので、ピンバンプは新しいインストールをトリガーします。

デメリット——ピンが古くなる——は意図的に対処されています。Renovate は mise 管理バージョン（`mise` データソース経由）を監視し、ツールバンプの PR を開きます。これは他の依存関係変更と同様にレビューしてマージされます。

mise 設定の全構造については [dev-tooling.ja.md](../architecture/dev-tooling.ja.md) を参照してください。

---

## macOS が真のターゲット、Linux は CI のためだけに存在

**判断:** このリポジトリは macOS ファーストです。すべての OS 条件分岐（テンプレートとライフサイクルスクリプト内）は `darwin` をプライマリケースとして扱い、`linux` は CI 互換性のためのフォールバックのみです。Linux サポートは `setup-validation.yml` が Ubuntu/Linuxbrew で通過するのに十分な程度にのみ実装されています。

**なぜ:** オーナーの実際の作業環境は macOS です。Linux を完全サポートターゲットにすることは、`brew cask`、`mas`、macOS システム環境設定、1Password デスクトップ SSH エージェントソケットパス、Ghostty ターミナル、cask 経由のフォントインストールなど多くの macOS 固有の懸念事項を二分岐で扱う必要があります。CI 検証ジョブのみが Linux を使用する場合、そのコストはメリットを超えます。

`.brewfile-linux-exclude` ファイルがこの境界の SSOT です。Ubuntu CI ジョブが `brew bundle` を実行する前に Linux 非互換の Brewfile 行をフィルタリングする `grep -E` パターンを列挙しています。ライフサイクルスクリプトと CI ワークフローの両方がこのファイルを参照することで、2 つが乖離しません。

テンプレートは `{{ if ne .chezmoi.os "darwin" }}` を使用して Linux 非互換ブロック（例: `Library/` の ignore パターン、Moralerspace フォント external、macOS defaults、フォントライフサイクルスクリプト）をスキップします。

`.brewfile-linux-exclude` SSOT パターンについては [dev-tooling.ja.md](../architecture/dev-tooling.ja.md) を、CI マトリクスについては [ci-and-tests.ja.md](../contributing/ci-and-tests.ja.md) を参照してください。

---

## `make apply` なし、デフォルトターゲットは help

**判断:** Makefile は `apply` ターゲットを公開していません。`make` を単独で実行するとターゲット一覧が出力されます（help がデフォルト）。dotfiles を適用するには `chezmoi apply -v` を直接実行する必要があります。

**なぜ:** `chezmoi apply` は `$HOME` を変更します。ユーザーのホームディレクトリのファイルを書き込み、移動し、場合によっては削除します。`make apply` ターゲット——特にプロジェクトを探索する際に `make` を誤って実行したコントリビューターによってトリガーされる可能性があるもの——は、意図しないホームディレクトリ変更という受け入れがたいリスクをもたらします。明示的な `chezmoi apply` の呼び出しを要求することで意図を強制します。

`make help` デフォルトはドキュメントとしても機能します。利用可能なターゲット（`lint`、`test`、`benchmark`、`dump-brewfile`、`sync-ghq-completion`）はすべて読み取り専用またはリポジトリツリーにスコープされており、ホームディレクトリには作用しません。

`make` ターゲット一覧については [local-dev.ja.md](../contributing/local-dev.ja.md) を参照してください。

---

## プラグインインストールではなくフォークとしての ECC

**判断:** ECC は `npm install -g` や Claude Code プラグインとしてインストールされません。chezmoi external（ソースのみの tarball）としてフェッチされ、固定パス（`~/.agents/skills/ecc/`）に配置され、`CLAUDE_PLUGIN_ROOT` を明示的に設定する `ecc-hook.sh` ランチャーで呼び出されます。

**なぜ:** プラグインインストールパス（`npm install -g`）は ECC を chezmoi の管理外に置き、バージョンが制御されず更新が不透明になります。chezmoi externals の使用により、リポジトリ内の他のすべての外部依存関係と同じ SHA ピン + refresh-period + Renovate バンプワークフローが得られます。バージョンは `.chezmoidata.toml` で宣言され、tarball URL は固定され、バンプは PR レビューを経てマージされます。

external の「ソースのみ」の性質（ECC tarball には JavaScript ソースが含まれ、ビルド済みの `node_modules` ツリーは含まれない）は受け入れられたトレードオフです。フォークは Node 組み込み（`node:sqlite`）か ECC ソースツリー自体から `require()` できるモジュールのみを使用する必要があります。実際には、この制約がよりシンプルで監査しやすいフォークコードを生み出しています。

この判断は上記の SHA ピンの根拠と組み合わさります。フックサブプロセス内で実行される ECC ソースは、ピンされたコミットのバイトそのものであり、chezmoi の URL-SHA256 キャッシュで検証されます。npm レジストリも、バージョン交渉も、`package-lock.json` のドリフトもありません。

外部宣言については [externals-and-pinning.ja.md](../architecture/externals-and-pinning.ja.md) を、ランチャーとフォークの動作については [claude-code.ja.md](../agents/claude-code.ja.md) を参照してください。
