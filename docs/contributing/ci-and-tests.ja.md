# CI とテスト

🌐 English (canonical): [ci-and-tests.md](ci-and-tests.md)

← [ドキュメント目次](../README.ja.md)

CI はローカルの `make` コマンドを忠実に反映しています。CI 固有の lint ロジックは存在せず、`make lint`・`make lint-node`・`make lint-console`・`make test-node`・`make test-bats` が契約であり、CI はそれを呼び出すだけです。5 つを合わせるとローカルの `make test` と同じ範囲を実行します。

---

## CI == ローカル

`ci.yml` ワークフローは 3 つのジョブを実行します：

| ジョブ | コマンド | ランナー |
|---|---|---|
| `lint` | `make lint`、`make lint-node`、`make lint-console` の順 | `ubuntu-latest` |
| `test` | `make test-node` の後に `make test-bats` | `ubuntu-latest`（needs: lint） |
| `sync-ghq-completion` | `make sync-ghq-completion`（ベンダリングした `_ghq` が変更された場合は自動コミット） | `ubuntu-latest`、同一リポジトリの PR のみ |

両ジョブとも、シェル系ツールを mise の pin から解決します。`run` ステップが `home/dot_config/mise/config.toml` からバージョンを読み取り、インストールステップがその GitHub リリースを取得し、インストール済みバイナリが pin どおりのバージョンを報告することを検証します。lint ジョブは shellcheck と shfmt について、test ジョブは shellcheck について（`tests/shellcheck.bats` と `tests/brew_launcher.bats` が直接実行するため）これを行います。deno については両ジョブで行います — lint ジョブは `make lint-console` を実行し、test ジョブは同ターゲットを直接駆動する `tests/console_lint.bats` を実行するためです。ここで deno を入れるのは console ガードの linter としてのみであり、`make lint-deno` / `make test-deno` は引き続き opt-in で CI では実行されません。`zsh` は両ジョブとも、`bats` と `jq` は test ジョブで、引き続き `apt-get` から入ります。Node.js も同じ「pin を読む」パターンで `actions/setup-node` に渡されます。したがって、これらのバージョンの宣言箇所は mise の pin ただ 1 つです。#475 以前は lint ジョブが shellcheck を一切インストールせず、ランナーイメージ同梱のビルドで暗黙に検査していたため、同じ差分でもローカルの `make lint` が通って CI が落ちることがありました。ワークフローにバージョン literal が復活しないよう、現在は `tests/files.bats` がガードしています。他に CI 固有のロジックは存在しません — `Makefile` が単一情報源です。

コントリビューターはプッシュ前にローカルで `make test` を実行してください — CI が実行するのと同じ 5 つのターゲットを連鎖させます。

### トリガー

`ci.yml` は `main` へのプッシュとプルリクエスト時に発火しますが、関連パスが変更された場合のみです：`home/**`、`tests/**`、`scripts/**`、`Makefile`、`.github/workflows/ci.yml`。`workflow_dispatch` による手動実行もサポートしています。

---

## Bats テストスイート

すべてのテストは `tests/` 以下にあり、`bats tests/*.bats` でまとめて実行されます。ヘルパー `tests/helpers/setup.bash` がすべてのテストファイル向けに `REPO_ROOT` と `HOME_DIR`（= `<repo>/home`）を定義します。

### `tests/files.bats`

`home/` 内に chezmoi ソースファイルが存在することを確認します。主なカテゴリ：

- コアのドットファイルが存在する：`dot_zshrc.tmpl`、`dot_zprofile.tmpl`、`dot_gitconfig.tmpl`、`private_dot_ssh/config.tmpl`、`dot_vimrc`、`dot_tmux.conf`、`dot_inputrc`、`dot_Brewfile`
- chezmoi データファイル：`.chezmoiexternal.toml`、`.chezmoidata.toml`
- 設定ファイル：`starship.toml`、ghostty の config、sheldon の `plugins.toml`
- zsh モジュールが存在する（`git`、`docker`、`claude`、`codex`、`functions`、`completions`、`wtp`、`ghq`）；`aliases.zsh.tmpl` が存在する
- ベンダリングした `_ghq` 補完が `#compdef ghq` で始まる
- ライフサイクルスクリプトが期待するパスに存在する
- Claude と Codex のエージェント定義、レビュアーエージェント、共有スキル
- `dot_claude-r06/` と `dot_codex-r06/` 両方の r06 ワークプロファイルのシンボリックリンクソースが存在する
- 1Password バックドのシークレットテンプレートが `onepasswordRead` を参照する（リテラルキーは含まない）
- ECC フックフォークが `node --check` 構文チェックを通過する
- プロジェクトの `.mcp.json` が `spec-workflow` のみを宣言する（ユーザースコープに移動した `context7` や `deepwiki` は含まない）
- ブートストラップスクリプトが `install/install.sh` に存在する

### `tests/shellcheck.bats`

- `{{` を含む行を除去した後、すべての `run_*.sh.tmpl` ライフサイクルスクリプトに対して shellcheck（`make lint` と同じフラグ）を実行する。
- `home/dot_config/zsh/*.zsh` と `*.zsh.tmpl` ファイルがすべて存在することを確認する。

### `tests/zsh_syntax.bats`

各 zsh モジュールに個別に `zsh -n` を実行します。対象モジュール：`aliases.zsh.tmpl`（`sed '/{{/d'` 後）、`git.zsh`、`docker.zsh`、`claude.zsh`、`codex.zsh`、`functions.zsh`、`completions.zsh`、`wtp.zsh`、`ghq.zsh`。

### `tests/console_lint.bats`

#520 で退役した `stop:check-console-log` hook の移送先である `make lint-console`（#522）の振る舞いテストです。ターゲットの `CONSOLE_LINT_ROOTS` 変数を上書きして `BATS_TEST_TMPDIR` の fixture ツリーへ検査対象を向けることで、リポジトリに違反を植え込まずに失敗ケースを検証します。カバー範囲：素の `console.log` は失敗する；`console.error` / `console.warn` も失敗する（ルールは `console.log` 単独ではなく `console.*`）；`// deno-lint-ignore no-console` コメントは自身の行だけを除外し、同じファイル内の 2 つ目の呼び出しは除外しない；対応する console 呼び出しより長生きしたディレクティブは `ban-unused-ignore` として報告される；ファイル単位の `// deno-lint-ignore-file no-console`（および裸のもの）は拒否され、無関係なルールだけを指定したものはそのまま通る；`process.stdout.write` は通る；文字列リテラル内の `console.log` は通る（テキストではなく AST ベースの検査であること）；宣言した 8 拡張子それぞれが個別に走査されることを確認する；任意の深さのネストも走査される；空のツリーは黙って成功せず失敗する；既定 roots が実際に `home/` と `tests/` の両方を覆う（他のケースはすべて roots を上書きするため、`Makefile` の使い捨てコピーに対して駆動する）；deno 不在は skip ではなく致命的である；リポジトリ本体は通る；`server.ts` の除外が `make lint-deno` を壊さない；ターゲットが `make test` に配線されている；CI の両ジョブがバージョンを重複させずに mise の pin から deno を解決し、ターゲット自体は lint ジョブに束縛されている。

これらはテキストへのアサーションではなくターゲット自体を駆動します。存在はするが何も検出しなくなったガードは、テキスト的なアサーションをすべて通過してしまい、それがこの issue の発端となった失敗モードだからです。deno が無いときに skip しないのも同じ理由です。

### `tests/statusline.bats`

`dot_claude/executable_statusline.sh` のふるまいテストです。モック JSON をスクリプトにパイプして以下を確認します：

- スクリプトが終了コード 0 でモデル名をレンダリングする。
- コンテキスト残存率が表示される。
- Effort と Cost セグメントが独立したトークンとしてレンダリングされる（フィールドデリミタのリグレッションガード）。
- `CLAUDE_CONFIG_DIR` が `~/.claude-r06` を指しているとき、r06 プロファイルバッジが表示される。
- ハーネスコストのキャッシュファイルが正しいセッションキー付きファイル名で書き込まれる。
- rate-limits スナップショットが profile 単位・フィールド単位検証・lax な umask 下でも 0600 であり、`effort` を含まない（#449）。
- [請求デルタ契約](../agents/claude-code.ja.md#請求デルタコスト): quota 内では `incl.` マーカー、stdin に `rate_limits` が無ければ生の合計、ウィンドウ消化後は起点を超えた増分。起点はリセットの遅いウィンドウに紐付き、そのウィンドウのロールオーバー前に引き継がれ、ロールオーバー時には取り直され、ウィンドウに余裕が戻れば破棄され、日跨ぎで日次残差を繰り越し、負の増分を 0 にクランプし、session 単位に保たれ、0600 で書き込まれる。

請求関連のアサーション実行前に、USD→JPY レートと `ccusage` の日次合計を使い捨ての `XDG_CACHE_HOME` へ seed します。これにより表示金額が固定される**と同時に**、バックグラウンドのレート／使用量更新が発火しなくなるため、テストスイートはネットワークを必要としません。

### `tests/zsh_aliases.bats`

統合された claude/codex ランチャーラッパースクリプト（`home/dot_local/launchers/executable_{claude,codex}`）と、`claude.zsh` に残る zsh ヘルパーのふるまいリグレッションガードです。ラッパーは直接駆動されます：テストは chezmoi のレイアウトを模したランチャーディレクトリ（2 つのラッパースクリプトと `cld`/`cld-r06`/`cdx`/`cdx-r06` の `$0` ディスパッチ用シンボリックリンク）と、スタブの「本物」バイナリを構築します — `CLAUDE_LAUNCHER_BIN`/`CODEX_LAUNCHER_BIN` が本物バイナリの解決を上書きするため、ラッパーはこのスタブを exec し、受け取った env と argv をダンプします — そのため mise/brew/codex のインストールは不要です（CI セーフ）。主な確認事項：

- **アカウント選択。** `claude`/`cld` は個人アカウントの per-account env（`CLAUDE_CONFIG_DIR`、`ECC_AGENT_DATA_HOME`、`CLV2_HOMUNCULUS_DIR`、`GATEGUARD_STATE_DIR`）を導出し、互いに同一に振る舞います；`cld-r06` は業務アカウントを無条件に選択します。専用のテストが fill-gaps/override の分離不変条件を pin します：素の `claude` は継承した r06 の `CLAUDE_CONFIG_DIR` を維持し（フック起動の子プロセスが親セッションのアカウントに留まる）、`cld-r06` は継承した個人アカウントを r06 へ上書きします。別のテストは `CLV2_HOMUNCULUS_DIR` がどちらのアカウントでも config dir 配下に解決されないことを確認します（#336）。
- **observer knobs とシークレット。** `ECC_OBSERVER_TIMEOUT_SECONDS`、`OBSERVER_ACTIVE_HOURS_START`/`END`、`ECC_OBSERVER_MAX_TURNS` が正しくデフォルトし、override 可能であること。ラッパーは MCP キーファイルを自ら source してキーを export しますが、呼び出し元がすでに決めたキー（`morning-radar` が web 検索をオプトアウトするための空文字を含む）は上書きしません。`claude-config` の `ECC_DISABLED_HOOKS_EXTRA` プレフィックスは、ラッパーの完全な env 継承を通じて exec されたプロセスに届きます。
- **フェイルラウド。** 両ラッパーとも、本物のバイナリが解決できない場合はサイレントに何もしない代わりに、診断メッセージ付きで非ゼロ終了します。
- **Codex のアカウント選択。** `codex`/`cdx` は `CLAUDE_CONFIG_DIR` に追従します（不一致な継承済み `CODEX_HOME` がアカウントをまたいでリークしてはいけないケースを含む — #345 が塞ぐクロスアカウントリーク）；`cdx-r06` は `CODEX_HOME` を無条件に上書きします；明示的な `CODEX_HOME` は `CLAUDE_CONFIG_DIR` がスコープにない場合のみ尊重されます。
- **`--profile shared` の注入。** argv に `--profile`/`-p` フラグがない場合にのみ注入されます（`--profile x`、`--profile=x`、`-p x`、`-px` のすべての形式）；プロンプト引数内の `--profile` という部分文字列は誤って注入を抑制しません；走査はリテラルの `--` で停止します；フラグは常にサブコマンド（`exec`、`exec review`）より前に挿入されます。
- **残存する zsh ヘルパー。** `_claude_fable`（`claude-fable-5-1` を pin し、readable な場合はオーケストレータープロンプトファイルを追加し、fable フラグより前に呼び出し元自身のフラグを通す）、`cldf`/`cldf-r06`（アカウントごとに Fable オーケストレーターを配線）、`claude-config`（フックのオプトアウトをプレフィックスし、デフォルトアカウントを pin する）は、従来どおり `claude.zsh` をソースする `zsh -fc` で駆動されます。

### `tests/skill_provenance.bats`

5 カテゴリのスキル来歴ポリシーを決定論的にソース側で強制します。chezmoi や外部ツールは不要で、`awk` と `grep` のみで動作します。主な確認事項：

- `home/dot_agents/skills/` 以下のすべてのディレクトリが、空でない（curated）か `.chezmoiexternal.toml` で宣言されている（external）かのどちらかである。
- 同一スキルが curated と external の両方に同時に存在しない。
- `AGENTS.md.tmpl` が 5 つのカテゴリすべてを文書化している。
- ECC が external として宣言されている（curated ではない）。
- `.chezmoidata.toml` の `[ecc].skills` リストに 100 件以上のユニークなエントリが含まれている。
- `.chezmoiexternal.toml` の ECC スキル range ブロックが `url`、`include`、`stripComponents=3` 構造を保持している。

awk パーサーは `[ecc]` テーブルの `skills` 配列のみにスコープを絞っています — そのセクションのインデントを変更したり、テーブルヘッダーを移動したりすると、テストが参照するものが変わる可能性があります。`>=100` カウントと重複なしチェックがガードとして機能します。

---

## `setup-validation.yml` — エンドツーエンドの apply

このワークフローは 2 つのプラットフォームで実際の `chezmoi init --apply` を実行し、デプロイされた状態を確認します。

### マトリクス

| ジョブ | ランナー | Homebrew | キャッシュパス |
|---|---|---|---|
| `setup-validation-macos` | `macos-latest` | システム Homebrew | `/opt/homebrew/Cellar`、`/opt/homebrew/opt`、`/opt/homebrew/Library/Taps`、`~/Library/Caches/Homebrew`（その後 "Relink cached Homebrew formulas" ステップが続く） |
| `setup-validation-ubuntu` | `ubuntu-latest` | Linuxbrew（`/home/linuxbrew/.linuxbrew`） | Linuxbrew インストール全体 |

### ステップ：CI 非互換ファイルの除外

`chezmoi apply` の前に、両ジョブは CI 環境では `op` の呼び出しやインタラクティブ/インストールステップの実行を試みないよう、一連のファイルを `/tmp/chezmoi-excluded/` に移動します。各ファイルは `for f in …; do if [ -f "$f" ]; then mv …; fi; done` ループ内で移動されるため、エントリが見つからなくてもステップは中断されません。

**両ジョブ**で除外されるファイル（<!-- FACT:ci-both-exclusion-count -->7<!-- /FACT --> ファイル）：

- `home/private_dot_aws/config.tmpl`
- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl`
- `home/run_once_before_00-install-prerequisites.sh.tmpl`
- `home/run_onchange_before_10-brew-bundle.sh.tmpl`
- `home/run_once_after_11-validate-1password.sh.tmpl`
- `home/dot_config/git/private_gitleaks-own.toml.tmpl`
- `home/dot_config/ntfy/private_server.yml.tmpl`

**macOS ジョブのみ**で除外されるファイル：

- `home/run_once_after_90-other-apps.sh.tmpl`
- `home/run_once_after_30-setup-fonts.sh.tmpl` — **古い参照**: このスクリプトはもう存在しません。フォントは `home/.chezmoiexternal.toml` の `["Library/Fonts"]` external を通じて chezmoi エンジン自体がデプロイします。`if [ -f ]` ガードにより、ファイルが存在しなくてもサイレントに処理されます（既知の問題を参照）

エントリの多くは 1Password バックドのテンプレート（apply 時に `op` を呼ぶ）です。`home/dot_config/ntfy/private_server.yml.tmpl` は例外で、base-url が除去された（#337）ことで 1Password を読まなくなりましたが、コンテナ専用パスのみの 0600 設定でありレンダリングに CI 上の価値がないため、除外リストには残しています。apply 時に `op` を呼ぶ（またはその他の理由で CI 非互換な）新しいテンプレートを追加する際は、両ジョブの除外リストにも追加してください。

### Brewfile の処理

CI では `dot_Brewfile` から `tap` と `brew` 行のみを抽出します（`grep -E '^(tap |brew )'`）。Ubuntu ジョブはさらに、`.brewfile-linux-exclude` を通じて Linux 非互換フォーミュラをフィルタリングします。macOS ジョブはこのフィルタを適用しません。

### 検証ステップ（両ジョブ共通）

apply 後、両ジョブは以下を確認します：

1. **デプロイされたファイル**：`~/.zshrc`、`~/.zprofile`、`~/.gitconfig`、`~/.ssh/config`、`~/.config/starship.toml`、`~/.config/sheldon/plugins.toml`、`~/.config/mise/config.toml` が存在する。
2. **zsh モジュールのデプロイ**：`~/.config/zsh/{aliases,git,docker,claude,functions,completions,wtp,ghq}.zsh` が存在する。
3. **ghq 設定**：`ghq.root = ~/ghq`、`ghq.user = kryota-dev`、`~/.config/zsh/completions/_ghq` が存在する。
4. **mise ツール**：`node`、`python`、`go` が `~/.local/share/mise/installs` 以下で解決される。
5. **クリーンな zsh 起動**：`zsh -i -c exit` の stderr に `command not found`、`parse error`、`not found` にマッチする出力がない。

macOS ジョブは `~/.config/ghostty/config` も確認します。

---

## `benchmark.yml` — 週次 cron

`schedule`（毎週月曜日 00:00 UTC）と `workflow_dispatch` で実行されます。`macos-latest` で動作します。

ジョブは Homebrew で chezmoi、sheldon、starship をインストールし、`home/dot_config/sheldon/plugins.toml` と `home/dot_config/zsh/*.zsh` ファイルを `~/.config/` にコピーし、`.zsh.tmpl` モジュールを `chezmoi execute-template` でレンダリングし、`sheldon lock` を実行してから、`/usr/bin/time zsh -i -c exit` を 10 回実行して計測します。

### ローカルベンチマークとの既知の乖離

`benchmark.yml` は `scripts/benchmark.sh` を**呼び出しません**。ワークフロー YAML 内に 10 回のループをインラインで実装し、sheldon/zsh 環境を手動で再構築しています。ローカルの `make benchmark` は `scripts/benchmark.sh` を呼び出し、`bc` で平均を計算し、反復回数の設定をサポートしています。CI とローカルの実装は同じもの（zsh インタラクティブ起動コスト）を計測しますが、実装が異なります。これは別途修正として追跡されています。

---

## `renovate-triage.yml` — 週次 Renovate トリアージ

`schedule`（毎週月曜日 00:00 UTC = 09:00 JST）と `workflow_dispatch` で、`ubuntu-latest` 上で実行されます。[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) を automation モード（`prompt` 入力を渡し、`@claude` メンション不要）で実行し、open な Renovate PR を **read-only** でトリアージします。`gh` で PR を収集し、リスク / CI 状態 / semver で分類し、要注意のものを分析したうえで、Dependency Dashboard（Issue #12）に統合サマリーコメントを、分析対象の各 PR に個別詳細コメントを投稿します。インラインした prompt は日本語で記述しており、投稿されるコメントも日本語になります（agent 定義や Fable orchestrator prompt と同じ規約）。

このワークフローは**決してマージしません** — マージは `renovate-sweep` skill（`home/dot_agents/skills/renovate-sweep/SKILL.md`。プロンプトにインラインした分類ルールの概念的な source of truth）経由でローカル・人間承認のまま行われます。read-only は多層防御で担保します: ジョブは `contents: read` + `issues: write` + `pull-requests: write` のみを付与し（`contents: write` なし）、`--allowedTools` の allowlist には読み取り専用の `gh` サブコマンドと、作成専用のコメント wrapper（`scripts/renovate-triage-comment.sh`。Issue #12 か open な Renovate PR にのみコメントを作成し、編集・削除はしない。`tests/renovate_triage_comment.bats` で検証）1 つだけを含めます。エージェントは任意の Bash を持たず（読み取り専用の `gh` サブコマンドと wrapper のみ。`echo`/`printenv`/`cat` 等は不可）、プロンプトは取得データを信頼せずシークレットの出力を禁止します。（subprocess env scrub `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は意図的に無効です: bubblewrap を必須とし、action は `allowed_non_write_users` モードでしかインストールしないため、設定すると Claude Code が起動に失敗しました。）認証は job スコープの `github.token` を明示的に渡し（`id-token: write` を要する OIDC 経路へのフォールバックを避ける）、`CLAUDE_CODE_OAUTH_TOKEN` リポジトリシークレット（`claude setup-token` で発行）を使用します。アクションの ref は他のすべての `uses:` と同様に SHA ピン + Renovate で `automerge: false` + 追跡されます。

---

## 再利用可能ワークフローと SHA ピン

3 つの追加ワークフローが `kryota-dev/actions` の再利用可能ワークフローにコミット SHA でピンして委譲しています：

| ワークフロー | 再利用ターゲット | トリガー |
|---|---|---|
| `actions-lint.yml` | `kryota-dev/actions/.github/workflows/actions-lint.yml@<sha>` | `.github/workflows/**` に触れる PR |
| `codeql.yml` | `kryota-dev/actions/.github/workflows/codeql.yml@<sha>` | main へのプッシュ/PR |
| `setup-pr.yml` | `kryota-dev/actions/.github/workflows/…@<sha>` | PR オープン時 |

すべてのワークフローはトップレベルに `permissions: {}` を設定し、ジョブごとに最小限のパーミッションのみを付与します。チェックアウトは `persist-credentials: false` を使用します（ghalint ポリシー 013）。

### Renovate と ECC ピニング

`.github/renovate.json5` がすべての依存関係の更新を管理します。`customManager` の正規表現が `.chezmoidata.toml` の ECC `version` と `commit` フィールドを一緒に更新します。`packageRule` によって ECC パッケージは**自動マージ禁止**です — ECC の更新は実行可能なフックコードを含むため、手動レビューが必要です。`.chezmoiexternal.toml` エントリの 168 時間の外部更新間隔（`refreshPeriod`）は Renovate のバンプとは別です。

---

## 既知の問題（ここでは修正しない）

**1. `home/.chezmoi.toml` がソースツリーに存在しない。**

Ubuntu の `setup-validation` ジョブは以下を実行します：

```yaml
cp home/.chezmoi.toml ~/.config/chezmoi/chezmoi.toml
```

ソースツリーには `home/.chezmoi.toml` が存在しません。この `cp` は `if [ -f ]` ガードなしで実行されており、GitHub Actions のデフォルト `set -e -o pipefail` 下ではファイルが存在しないため `cp` がエラーとなり**ステップが中断**されます — apply は進みません。この結果、`setup-validation.yml` は最近のランで失敗しています。`.chezmoidata.toml` は明示的な設定なしに自動ロードされるため、この `cp` 自体が不要です。これは実際のバグとして別途修正が追跡されています。

**2. `benchmark.yml` が起動ループをインラインで再実装している。**

上述の通り、CI ベンチマークは `scripts/benchmark.sh` を呼び出さず、ワークフロー YAML 内に 10 回のループをインラインで実装しています。ローカルスクリプトへの改善（設定可能な反復回数、コールドスタート計測など）が CI に自動反映されません。別途修正として追跡されています。

**3. `setup-validation.yml` が古い `run_once_after_30-setup-fonts.sh.tmpl` を参照している。**

`setup-validation.yml` の macOS 除外リストには `home/run_once_after_30-setup-fonts.sh.tmpl` への参照が残っています。このスクリプトはもう存在しません——フォントは `home/.chezmoiexternal.toml` の `["Library/Fonts"]` external を通じて chezmoi エンジン自体がデプロイするようになりました。除外ループの `if [ -f "$f" ]` ガードにより CI が失敗することはありませんが、別途クリーンアップとして追跡されています。

---

## 関連ドキュメント

- Makefile ターゲットと lint フラグ：[local-dev.ja.md](local-dev.ja.md)
- ワークツリーと環境のセットアップ：[worktrees-and-env.ja.md](worktrees-and-env.ja.md)
- スキル来歴ポリシーと ECC 外部管理：[../agents/skills-provenance.ja.md](../agents/skills-provenance.ja.md)
