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

## 承認チャネル

`claude -p` は `--permission-prompt-tool` を配線したときだけ `AskUserQuestion` を持ち、承認要求も
問いかけも**同期的な MCP ツール呼び出し**として届く。`fh` はその受け口を提供する。wave の子は端末を
持たなくても user に到達でき、画面を読むことも、キーを送ることも、「今まさに未回答か」を推定することも
なくなる —— 呼ばれた時点が問いであり、返り値が回答である。

子セッションには専用の MCP server として配線する。承認チャネルは新しい信頼境界なので、それを
「お願い」ではなく境界にする 2 つのフラグを必ず併せる。

```bash
MCP='{"mcpServers":{"fh-approve":{"command":"fh","args":["approve-server","--session","<session-id>"]}}}'
claude -p --mcp-config "$MCP" --strict-mcp-config --setting-sources user \
  --permission-prompt-tool mcp__fh-approve__approve ...
```

`--strict-mcp-config` はチェックアウト先のリポジトリが approver の横に別の MCP server を注入することを
防ぎ、`--setting-sources user`（または `--bare`）はその `.claude/settings.json` の hooks が走ることを防ぐ。
子の起動そのものは wave orchestrator の仕事であり、このコマンドの範囲ではない。

### escalation ルール

escalation ルールは **repository capability manifest とは別のファイル**に置く。両者は失敗の方向が
逆だからである。manifest の漏れは fail-closed —— 何かが動かず、こちらは気づく。escalation ルールの
漏れは fail-open —— 誰にも聞かずに何かが実行され、こちらは気づかない。同じファイルに置くと、この
非対称が見えなくなる。

その帰結として、設計は意図的に非対称になっている。

- **baseline ルールは `approval-rules.mjs` の定数**であってデータではない。マージ、強制 push、
  履歴書き換え、作業ツリーの巻き戻し、リリース、外部への書き込み、資格情報へのアクセス、デプロイ、
  データベースマイグレーション、そして承認 queue 自身への書き込みを対象とする。どのファイルからも
  削除・無効化できない。
- 任意の `$HOME/.config/frontier-harness/approval-rules.json`（または絶対パスの
  `FH_APPROVAL_RULES_PATH`）は、`additionalRules` による**追加しかできない**。一致しなかった場合の
  既定も `defaultDecision: "escalate"` によって厳しくする方向にしか動かせない。差し引くキーは存在しない。
- パスを作業ディレクトリから導かないのは `config.json` と同じ理由である。チェックアウトされた
  リポジトリが自分用の escalation 方針を持ち込めてはならない。
- 壊れたルールファイルは、静かに baseline へ縮退せず**起動を拒否する**。user が意図して足したルールを
  黙って落とすことこそ、この仕組み全体が防ごうとしている fail-open の退行である。

ルールを照合する前に、コマンド文字列はトークン化され、**binary ごとの arity 表を使って
global option が読み飛ばされる**。したがって `git -C <path> merge` は `git merge` と同じに
認識される。難しい 2 例が正しく出るのはこの表のおかげである。`git -C merge status` では
`merge` は `-C` の**値**であり実際の subcommand は良性の `status`、一方 `git -p merge` では
`-p` が値を取らないので `merge` が本物である。バックスラッシュによる単語分断と `${IFS}` 置換は
正規化して取り除く。コマンド名や subcommand が動的に組み立てられているもの、`sudo` のような
ラッパーや別のシェルを介して実行するものは、そもそも解釈できない —— これらは一致しなかった
場合の既定へ落とさず、エスカレートする。

ルールに一致しても**拒否はしない**。エスカレートする —— user に同期的に問い合わせる。
`AskUserQuestion` はルールに関わらずエスカレートし、approver がそれに自分で答えることはない。
一次ソースでの裏取りができない以上、答える権能そのものを与えない。

どのルールにも一致しなかった呼び出しは allow になる。この方向は構造上 fail-open であり、境界は
2 つある。read-only 相当の呼び出しは prompt tool に届く前に auto-approve されるのでチャネルはそもそも
それらを見ないこと、そして baseline を縮められないことである。shell コマンド文字列に対する照合は
**速度制限であって境界ではない** —— 正規化で安価な小細工は塞がり、解釈できないものはエスカレート
するが、ルールを避けようとして書かれたコマンドは、静的な照合では依然として捕まえられない。

`fh approve-server` は `--session` / `--approvals-dir` / `--rules` / `--timeout-ms` /
`--progress-interval-ms` を受ける。パスを取る 2 つのフラグは絶対パスでなければならない
（ルールファイルを作業ディレクトリから解決しないのと同じ理由である）。

### user への到達経路

escalation は state root へ 1 要求 1 ファイルで書かれる。複数の子が同時に止まっても競合しない。

| ファイル | writer | 内容 |
|---|---|---|
| `<state root>/frontier-harness/approvals/<id>.request.json` | `approve-server` | tool call、一致したルール、決着後の outcome |
| `<state root>/frontier-harness/approvals/<id>.answer.json` | responder | user の判断 |

各ファイルの writer はちょうど 1 つなので、同時更新で何かが失われることがない。answer は rename では
なく `O_EXCL` + `link(2)` で公開するため、1 要求は 1 度だけ答えられ、2 番目の writer は先着を黙って
上書きするのではなく失敗する。

responder は 2 系統が交換可能で、queue はどちらが使われているかを前提にしない。

```bash
fh approvals --json                                    # 何が待っていて、なぜ待っているか
fh approve --request <id> --allow                      # 通す
fh approve --request <id> --deny --message "..."       # 理由を model へ返して拒否する
fh approve --request <id> --allow --answers '{"Which colour?":"Red"}'   # AskUserQuestion
```

通常は wave orchestrator が仲介する（queue を読み、user に問い、回答を書き戻す）が、user が同じ
コマンドで直接答えることもできる。これは重要で、orchestrator が落ちても pending な承認は決着できる。
`AskUserQuestion` への回答は提示された選択肢に対して**両側**で検証されるため、打ち間違いや手編集した
ファイル経由で「user が表明していない判断」が model に届くことはない。

### 待機の時間

permission prompt tool は呼び出し元をブロックするので、escalation の窓は両側から限られる。

| 値 | 意味 |
|---|---|
| <!-- FACT:fh-approval-timeout-ms -->28800000<!-- /FACT --> ms（8 時間） | escalation が自動 deny するまでの待機上限（`--timeout-ms`。<!-- FACT:fh-approval-max-timeout-ms -->86400000<!-- /FACT --> ms でクランプし、`MCP_TOOL_TIMEOUT` の既定を必ず下回る） |
| <!-- FACT:fh-approval-progress-interval-ms -->60000<!-- /FACT --> ms | 待機中に `notifications/progress` を送る間隔（`--progress-interval-ms`） |

progress 通知は `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`（stdio では 30 分）をリセットするために送る。
これが無いと、寝ている user が答えるよりはるかに早く呼び出しが打ち切られる。idle timeout 以上の
間隔は、受け付けたうえで静かに無意味になるのではなく、起動時に拒否する。

窓が閉じると要求は自動 deny になり、記録には tool 入力・セッション・tool use id が残る。子は
きれいに終わり、その escalation は後から辿れる。stdin のクローズやシグナルも、status を変えて同じ
ことをする。**user が既に記録した判断はそれらすべてに優先する** —— shutdown と入れ違いに届いた回答は
deny に化けず、そのまま尊重される。

### これが守らないもの

同じ user で動くプロセスはすべて承認 queue に書き込める。要求を出して待っている子自身も例外ではない。
自己承認しようとする子はそれができるし、ファイル権限をどう並べても変わらない —— responder を別の uid で
動かす以外にない。これは state schema の `approvals.granted_by` に付いている但し書きと同じものである。
記録は「誰が承認したか」を述べるが、それを証明はしない。承認ディレクトリを参照するコマンドを
エスカレートする baseline ルールは多層防御であって、境界ではない —— これもコマンド文字列に対する
照合なので上記の限界をそのまま引き継ぎ、それを避けるように書かれたコマンドには当たらない。

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
