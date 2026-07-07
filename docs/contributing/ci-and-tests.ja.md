# CI とテスト

🌐 English (canonical): [ci-and-tests.md](ci-and-tests.md)

← [ドキュメント目次](../README.ja.md)

CI はローカルの `make` コマンドを忠実に反映しています。CI 固有の lint ロジックは存在せず、`make lint` と `make test-bats` が契約であり、CI はそれを呼び出すだけです。

---

## CI == ローカル

`ci.yml` ワークフローは 3 つのジョブを実行します：

| ジョブ | コマンド | ランナー |
|---|---|---|
| `lint` | `make lint` | `ubuntu-latest` |
| `test` | `make test-bats` | `ubuntu-latest`（needs: lint） |
| `sync-ghq-completion` | `make sync-ghq-completion`（ベンダリングした `_ghq` が変更された場合は自動コミット） | `ubuntu-latest`、同一リポジトリの PR のみ |

lint ジョブは `make lint` を実行する前に、shfmt（`v3.13.1`）を GitHub リリースから、`zsh` を `apt-get` でインストールします。test ジョブは `bats`、`shellcheck`、`zsh` を `apt-get` でインストールします。他に CI 固有のロジックは存在しません — `Makefile` が単一情報源です。

コントリビューターはプッシュ前にローカルで `make lint` と `make test-bats` を実行してください — CI はまったく同じコマンドを実行します。

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

### `tests/statusline.bats`

`dot_claude/executable_statusline.sh` のふるまいテストです。モック JSON をスクリプトにパイプして以下を確認します：

- スクリプトが終了コード 0 でモデル名をレンダリングする。
- コンテキスト残存率が表示される。
- Effort と Cost セグメントが独立したトークンとしてレンダリングされる（フィールドデリミタのリグレッションガード）。
- `CLAUDE_CONFIG_DIR` が `~/.claude-r06` を指しているとき、r06 プロファイルバッジが表示される。
- ハーネスコストのキャッシュファイルが正しいセッションキー付きファイル名で書き込まれる。

### `tests/zsh_aliases.bats`

`_claude_with_home` ヘルパーとアカウントごとのラッパーのふるまいリグレッションガードです。最小限の `zsh -f` 環境（rc ファイルなし）で `claude.zsh` をソースし、基礎となる関数を直接駆動します。主な確認事項：

- `_claude_with_home` が指定したホームディレクトリ配下に複数の環境変数を設定し、指定したコマンドを実行する。テストが確認するのは `CLAUDE_CONFIG_DIR`、`ECC_AGENT_DATA_HOME`、`GATEGUARD_STATE_DIR` の 3 つです（`_claude_with_home` は実行時に `CLV2_HOMUNCULUS_DIR` と `ECC_MCP_HEALTH_STATE_PATH` も設定しますが、bats テストはそれらを確認しません）。
- MCP API キー（`EXA_API_KEY`、`FIRECRAWL_API_KEY`）がサブプロセス環境にエクスポートされるが、親シェルにはエクスポートされない。

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

**両ジョブ**で除外されるファイル（<!-- FACT:ci-both-exclusion-count -->6<!-- /FACT --> ファイル）：

- `home/private_dot_aws/config.tmpl`
- `home/dot_config/zsh/private_claude-secrets.zsh.tmpl`
- `home/run_once_before_00-install-prerequisites.sh.tmpl`
- `home/run_onchange_before_10-brew-bundle.sh.tmpl`
- `home/run_once_after_11-validate-1password.sh.tmpl`
- `home/dot_config/git/private_gitleaks-own.toml.tmpl`

**macOS ジョブのみ**で除外されるファイル：

- `home/run_once_after_90-other-apps.sh.tmpl`
- `home/run_once_after_30-setup-fonts.sh.tmpl` — **古い参照**: このスクリプトはもう存在しません。フォントは `home/.chezmoiexternal.toml` の `["Library/Fonts"]` external を通じて chezmoi エンジン自体がデプロイします。`if [ -f ]` ガードにより、ファイルが存在しなくてもサイレントに処理されます（既知の問題を参照）

新しい 1Password バックドのシークレットテンプレートを追加する際は、両ジョブの除外リストにも追加してください。

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
