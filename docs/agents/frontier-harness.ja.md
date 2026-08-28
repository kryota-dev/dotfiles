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
| `evidence` | raw payload への参照、内容フィールドに対する SHA-256 の `content_hash`、所属する task / route | raw |
| `adapter_runs` | adapter 実行 1 回分: capability、provider、model、effort、状態、開始/終了、exit code | raw |
| `verification_results` | 決定的チェック 1 件: 種別、状態、command、exit code、evidence 参照 | raw |
| `review_findings` | 所見 1 件: severity、uncertainty、要約、discriminating experiment、evidence 参照 | raw |
| `approvals` | 承認された内容: 種別、subject hash、scope、承認者、承認/失効時刻 | **削除しない** |
| `telemetry_events` | 内容を含まない集約値（category、risk、provider/model/effort、所要時間、token 数、結果） | 集約 |

`adapter_runs` には **adapter の起動方式に属する情報を意図的に持たせません**。argv、sandbox 設定、
profile path、対話/非対話モード、conversation ID、作業ディレクトリ、環境変数はいずれも adapter 側の
関心事であり、schema に焼き込むと起動方式が変わるたびに migration をやり直すことになります。

`content_hash` が同定するのは evidence **レコード**であり、その先の artifact ではありません。
hash の入力に含まれるのは artifact の**パス**であってバイト列ではないため、ディスク上のファイルを
後から書き換えても hash は変わりません。重複排除とレコード同一性のための鍵であって改竄検知では
ないので、バイト列の完全性が必要なら、そのファイルを書いた adapter 側が別途 digest を持つ必要が
あります。

`approvals.granted_by` は記録されたラベルであって、承認の出所の証明ではありません。harness 内の
どのコードも `granted_by = 'user'` を書けますし、列の制約が縛るのは語彙だけです。したがって
承認 1 行を根拠に escalation を免除する実装は、出所を自分で確立しなければなりません。schema は
それを運びません。承認をどう証明し検証するかは、これらの行を書く onboarding 側の設計であって、
行を保存する schema 側の設計ではありません。

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
どのステップを適用するかを決めるバージョンは、**書き込みロックを取った後**に読みます。state は
全 worktree で共有されるため、ロック前に読んだバージョンはステップ実行時には古くなりえます。

state を開くコマンドはすべて migration を行います。`fh clean --dry-run` も例外ではありません。
dry-run が意味するのは「何も削除しない」であって「何も開かない」ではありません。そうしないと、
v1 の DB に対する dry-run は v2 で追加されたレコード種別を数えられないからです。

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

## provider adapter

3 つの CLI は互換ではありません。非対話モードの能力が非対称なので、1 つの汎用ランチャーを
パラメータで切り替えるのではなく、provider ごとに adapter を持ちます。

| | Claude Code | Codex | Antigravity |
|---|---|---|---|
| 起動 | `-p` ＋ `--output-format stream-json` | `codex exec --sandbox <mode> --json` | `-p --output-format json` |
| 再開 | `--resume <session id>` | `codex exec resume <thread id>` | `--conversation <id>` |
| サンドボックス | `--settings` の設定 JSON。`--sandbox` フラグは存在しない | 起動は `--sandbox`、再開は `-c sandbox_mode="…"` | 表現できない（`--sandbox` はファイル書き込みを止めない） |
| 承認チャネル | 外部への往復が可能 | エージェントによるレビュー | 無し |
| 成功判定 | `result` イベント / `is_error` / `permission_denials[]` | `turn.completed` と `error` イベント | 終了コードと status だけでは**判定できない** |

adapter は純粋です。invocation を組み立て、プロセス結果を解釈するだけで、Node の子プロセス API を
import しません（テストがソースを走査して固定しています）。したがって `createAdapterExecutor` は
runner の注入を必須とし、**既定の runner を持ちません** —— 実プロセスの起動はこの層ではなく
rollout の昇格作業に属します。挿入点は `runWithRolloutGuard` の `executor` 引数なので、
`shadow` の間は route が provider に到達しません。

invocation が持つのは provider、実行ファイルの絶対パス、argv 配列、任意の stdin、そして phase だけです。
環境変数や credential の欄はそもそも存在しません。認証は各 CLI 自身のランチャーと keychain が持ち、
harness は token もプロファイルパスも扱いません。

argv へ載る値はすべて先に形を検査します。capability の model と effort は Codex の `-c key=value` の
**値の中**へ入るため、引用符や等号を含む値は別の設定（`sandbox_mode` を含む）を注入しうるからです。
resume 識別子・session id・prompt tool 名にも同じ検査を課しますが、理由は別で、**Codex は session id を
位置引数で受け取る**ため `-` で始まる値がフラグの位置に着地します。Codex ではさらに、argv 中で `-` から
始まる要素を **この adapter 自身が出す集合に限る allowlist** を張っています。どの位置から紛れ込んだ
フラグもサンドボックスの読み戻しで弾かれるので、CLI に新しいフラグが増えるたび追随が要る denylist に
依存しません。

### サンドボックスは構築時に封印される

Codex は起動時には `-s/--sandbox` を受け付けますが、再開時には受け付けません。`codex exec resume` が
受け付けるサンドボックス関連のフラグは、封じ込めを**弱める**ものだけです。この非対称を手で書くと、
再開したときだけ設定既定へ静かに戻る実行ができあがります。

そのため起動形・再開形のどちらも `sealInvocation` を通して作ります。この関数は、いま生成した argv から
実効サンドボックスを読み戻し、呼び出し側が要求した policy と一致しなければ throw します。config override を
書き忘れた再開形は、レビューで気づかれるときではなく**組み立てた時点で**失敗します。`resume` は
sandbox policy を必須引数として受け取るので、「policy 無しの再開」という形自体が存在しません。

policy の語彙は意図的に小さくしてあります。`read-only` と `workspace-write` の 2 値で、
「サンドボックス無し」に相当する値は持ちません（持てば再開経路がそこへ落ちうるため）。
ネットワークの軸も持ちません（許可リストの記法が実測されていないため）。ただし
**ネットワークの実効性は provider ごとに異なり、harness はそれを一律とは主張しません**。
Claude は設定 JSON の strict allowlist、Codex は `workspace-write` の既定 off（いずれも実測）ですが、
**Antigravity のネットワーク既定は確認されておらず、adapter もそれを制御する argv を出しません**。

### Antigravity は実装するが read-only に留める

Antigravity は、承認できないツール呼び出しをソフト拒否するとき、終了コード 0・status `SUCCESS`・
空の応答本文を返します。呼び出し側が終了コードと status だけを見ると、何も起きていない実行を
成功として記録することになります。そのためこの adapter は成功を報告しません。判定**できる**失敗
（非 0 の終了コード、明示的な失敗 status）だけを失敗として報告し、それ以外は *indeterminate* を返します。
これは新しい status 値を作らず、理由付きの `failed` な adapter run へ写像されます。応答本文の非空判定と
標準エラーの走査による本当の成功判定は、別の作業です。

`--sandbox` はファイル書き込みを止めず、シェル実行を壊すだけです。`--dangerously-skip-permissions` は
唯一持っている境界を外します。adapter はどちらも出さず、書き込みを伴う invocation の組み立てを拒否し、
書き込み能力を `unenforceable` と宣言します。

### adapter が実行前に検査すること

router は provider 非依存の言葉で可用性を判断します。adapter は実行の直前に、同じ discovery 一覧に対して
exact model ID を再検査します（route 決定から実行までの間に readiness キャッシュは失効しうるため）。
そのうえで、router にはできない検査を足します。

- `model` と `effort` は安全なトークンであること。Codex は両方を `-c key=value` の値に埋め込むため、
  引用符や等号を含む値は別の設定（`sandbox_mode` を含む）を注入しうる。
- `effort` は harness が既に出荷している語彙に属すること。adapter が 2 つ目の語彙を作らない。
  provider ごとの受理値は実測されていないので、provider 別の集合も主張しない。
- capability の account scope が解決済みの scope と一致すること。これは router 側の規則でもあり、
  ここで落とすと多層防御が軸ごとに非対称になります（出荷 registry は実際に personal 限定の capability を
  宣言しており、`r06` セッションがそこへ fallback してはいけません）。
- 封じ込めを保証できない adapter に対しては、書き込みを伴う実行を拒否する。

拒否は例外ではなく戻り値としての判定です。runner は呼ばれず、結果には provider が起動しなかったことが
残り、route の選び直しは呼び出し側の判断のままです。`availability` は関数でも渡せます。値で渡すと
executor の生成時に固定され、「実行直前に再検査する」が規約頼みになるためです。
この層は capability registry の schema を変更しません。

## worktree と rollout

primary worktree と PR branch は `pr-workflow` が所有します。将来の writable diversified route だけが
`wtp` を使って disposable child worktree を作ります。read-only 調査は worktree を増やしません。
verified かつ clean apply 可能な candidate は primary へ反映できますが、merge と不可逆な外部操作は
常に user が行います。

promotion は shadow → pilot → default です。`--legacy` による rollback flag はその promotion 作業で
実装する予定であり、現時点では未実装です。それまで rollout は `shadow` のままで、CLI 側が
（provider adapter が未実装であることに依存せず）明示的なガードとして shadow を強制します。
adapter が実装された今、route と provider の間に立っているのはこのガードだけです。adapter は
既定の runner を持たないので、昇格作業は runner の配線を明示的に行う必要があります。
