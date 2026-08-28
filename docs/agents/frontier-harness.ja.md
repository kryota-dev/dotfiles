# Frontier Harness

🌐 English (canonical): [frontier-harness.md](frontier-harness.md)

← [エージェント概要](overview.ja.md)

`frontier-harness`（`fh`）は、進化中の `pr-workflow` の背後で task を capability へ route し、
evidence を記録するモデル非依存の実行レイヤーです。model の自己申告よりも決定論的な検証を上位に置きます。

初期 rollout は **shadow** です。route、verification、review の計画だけを保存し、provider による
書き込み実行は開始しません。既存の `pr-workflow` を保ったまま router の証拠を蓄積するためです。

## 導入と readiness

Antigravity CLI は Homebrew の `antigravity-cli` cask で導入し、global safety settings は
`~/.gemini/antigravity-cli/settings.json` に配置します。keychain を使う対話 login は user が
一度だけ `agy` を起動して行います。harness が API key を保存・複製することはありません。

```bash
fh doctor --json
```

Antigravity は vendor-supported な業務 account mapping を実測するまで personal scope 専用です。
`r06` session では personal credential へ自動 fallback せず、unavailable として fail closed にします。

account scope は `cld` / `codex` launcher が呼び出しごとに設定する `CLAUDE_CONFIG_DIR` と
`CODEX_HOME` の suffix から判定します。両方が未設定のとき、2 つが食い違うとき、想定外の値のときは
いずれも `unknown` に解決し、`accountScope` を宣言した capability は unavailable のままにします。
launcher はこれらを global には export しないため、素の shell から `fh doctor` を実行すると
`accountScope: "unknown"` になります。これは設定漏れではなく意図した fail closed の既定です。

## state と evidence

| 場所 | 内容 | 管理 |
|---|---|---|
| `$HOME/.config/frontier-harness/config.json`、または絶対パスの `FH_CONFIG_PATH` | capability registry、rollout、retention | chezmoi |
| `<repo>/.harness/policy.json` | 承認済み repository capability manifest（`fh onboard` が書き込む。参照して強制するのは onboarding step から） | repository policy |
| 検証済みの `git rev-parse --git-common-dir` 配下の `frontier-harness/` | SQLite state と raw artifact | runtime、全 worktree で共有 |

`fh` は untrusted な checkout の上で動くことを前提とするため、いずれの置き場所も
そのままでは信頼しません。2 つは解決の仕方が異なります。

- **設定パス —— 作業ディレクトリからは決して導出しません。** `HOME` は絶対パスである必要があり、
  `FH_CONFIG_PATH` による上書きも絶対パスに限ります。相対値は作業ディレクトリ基準で解決されるため、
  checkout 済み repository が自前の escalation 方針を差し込めてしまいます。
- **state root —— 作業ディレクトリの git topology から導出し、そのうえで検証します。**
  common directory は、絶対パスであること、symlink でないこと、真正な git metadata ディレクトリで
  あること、そして **現在の作業ツリーが所有していること** を確認してから使います。所有と認めるには、
  作業ツリーの `.git` が報告された git directory を指していることに加えて、次のいずれかが必要です:
  `<toplevel>/.git` であること、admin directory がこの作業ツリーを指し返す linked worktree の
  common directory であること、superproject の metadata 配下にある submodule のディレクトリであること。
  作業ツリー配下にあること（containment）は意図的に要求しません。linked worktree の
  common directory は作業ツリーの外にあるのが正常だからです。
  `git init --separate-git-dir` はサポートしません。その topology は、`.git` を他人の metadata へ
  向け直した repository と区別できないためです。
- **readiness キャッシュ —— account scope ごとに分割**し、`readiness.<scope>.json` として保存します。
  あるプロファイルで確定した結果を別プロファイルが流用しません。

Evidence Bus には diff、command result、log、trace、screenshot、browser recording、accepted decision
を入れます。全文 transcript や hidden reasoning は保存・受け渡ししません。

### 正規化された state schema

SQLite state は schema version 2 です。各レコード種別は正規化され、
それぞれちょうど 1 つの保持クラスに属します。

| テーブル | 内容 | 保持 |
|---|---|---|
| `tasks` | 実行の起点になった正規化済み task | 保持 |
| `route_decisions` | 選択した capability、provider、**model、effort**、reviewer | 保持 |
| `evidence` | raw payload への参照、SHA-256 の `content_hash`、所属する task / route | raw |
| `adapter_runs` | adapter 実行 1 回分: capability、provider、model、effort、状態、開始/終了、exit code | raw |
| `verification_results` | 決定的チェック 1 件: 種別、状態、command、exit code、evidence 参照 | raw |
| `review_findings` | 所見 1 件: severity、uncertainty、要約、discriminating experiment、evidence 参照 | raw |
| `approvals` | user が承認した内容: 種別、subject hash、scope、承認者、承認/失効時刻 | **削除しない** |
| `telemetry_events` | 内容を含まない集約値（category、risk、provider/model/effort、所要時間、token 数、結果） | 集約 |

`adapter_runs` には **adapter の起動方式に属する情報を意図的に持たせません**。argv、sandbox 設定、
profile path、対話/非対話モード、conversation ID、作業ディレクトリ、環境変数はいずれも adapter 側の
関心事であり、schema に焼き込むと起動方式が変わるたびに migration をやり直すことになります。

`telemetry_events` には自由記述の列が 1 つもありません。TEXT 列はすべて閉じた enum か短い小文字
token であり、「集約テレメトリは内容を含まない」を規約ではなく schema で強制しています。
集約側の保持期間を長く取れるのはこの性質があるからです。

### 保持期間

raw evidence と実行系レコードは
<!-- FACT:fh-raw-retention-days -->30<!-- /FACT --> 日、内容を含まない集約テレメトリは
<!-- FACT:fh-telemetry-retention-days -->180<!-- /FACT --> 日で保持します。どちらも
`config.json` で変更でき、`retention.mjs` の名前付き既定値と突き合わせて検証しています。
承認は監査証跡でありどちらの窓にも属しません。`fh clean` は approvals を削除しません。

migration は単一 transaction 内で順序付きステップとして適用します。失敗するとバージョンと
列構成の両方が移行前へ巻き戻るため、中断した更新が中途半端な state を残すことはありません。

## onboarding と shadow command

task ごとの permission prompt を避けるため、repository の command/domain/capability manifest を一度だけ
承認します。

```bash
fh onboard --manifest candidate.json
fh onboard --manifest candidate.json --approve --json
fh run --task task.json --json
fh verify --command "npm run test" --json
fh review --task task_example --json
fh status --json
fh clean --dry-run --json
```

未知の command/domain は実行しません。wave boundary での一括承認のために queue へ残す仕組みは
onboarding step で実装予定であり、この shadow foundation には含まれません（現時点の `fh onboard` は
承認済み manifest を記録するだけで、それを参照する command はまだありません）。credential、migration、
external contract、deploy、force push、release、merge は常に明示的な escalation です。

shadow mode の `run`、`verify`、`review` は provider や任意 command を起動せず、正規化した計画を
記録するだけです。`clean` は期限切れの raw レコードと集約テレメトリをそれぞれの窓で処理し、
approvals には手を触れません。`--dry-run` で影響を確認できます。

## worktree と rollout

primary worktree と PR branch は `pr-workflow` が所有します。将来の writable diversified route だけが
`wtp` を使って disposable child worktree を作ります。read-only 調査は worktree を増やしません。
verified かつ clean apply 可能な candidate は primary へ反映できますが、merge と不可逆な外部操作は
常に user が行います。

promotion は shadow → pilot → default です。`--legacy` による rollback flag はその promotion 作業で
実装する予定であり、現時点では未実装です。それまで rollout は `shadow` のままで、CLI 側が
（provider adapter が未実装であることに依存せず）明示的なガードとして shadow を強制します。
