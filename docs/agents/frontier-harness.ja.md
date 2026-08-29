# Frontier Harness

🌐 English (canonical): [frontier-harness.md](frontier-harness.md)

← [エージェント概要](overview.ja.md)

`frontier-harness`（`fh`）は、進化中の `pr-workflow` の背後で task を capability へ route し、
evidence を記録するモデル非依存の実行レイヤーです。model の自己申告よりも決定論的な検証を上位に置きます。

rollout は **pilot** で、その影響範囲は意図的に狭く取っています。`run` は今も route を記録するだけで、
runner を注入しないので rollout が何であれ provider には到達しません。実プロセスを起こすコマンドは
4 つあり、いずれも起こす前に gate を通ります。`fh session` は wave orchestrator が駆動する子セッションを
起動し、`fh verify` は承認済みの決定的チェックを走らせ、`fh candidate` は使い捨ての子ワークツリーを
作って取り込み、`fh review packet` は git から差分を読みます。すべてが `runWithRolloutGuard` を通るので、
rollout を `shadow` に戻せばそのすべてが止まります —— この設定値がラベルではなく非常停止レバーである
理由がここにあります。

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
| `<repo>/.harness/policy.json` | 承認済み repository capability manifest（`fh onboard` が書き込み、route する実行のたびに照合する） | repository policy |
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

SQLite state は schema version 3 です。各レコード種別は正規化され、
それぞれちょうど 1 つの保持クラスに属します。

| テーブル | 内容 | 保持 |
|---|---|---|
| `tasks` | 実行の起点になった正規化済み task | 保持 |
| `route_decisions` | 選択した capability、provider、**model、effort**、reviewer | 保持 |
| `evidence` | raw payload への参照、内容フィールドに対する SHA-256 の `content_hash`、所属する task / route | raw |
| `adapter_runs` | adapter 実行 1 回分: capability、provider、model、effort、状態、開始/終了、exit code | raw |
| `verification_results` | 実際に走った決定的チェック 1 件: 種別、状態、承認済み command、exit code、evidence 参照、**検証した candidate と tree hash** | raw |
| `review_findings` | 所見 1 件: severity、uncertainty、1 行の要約、discriminating experiment、evidence 参照 | raw |
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
どのコードも `granted_by = 'user'` を書けますし、列の制約が縛るのは語彙だけです。そのため
repository onboarding はこの列に依存しません。承認と manifest の結びつけは、正規化した manifest の
SHA-256 を `subject_hash`、解決済み state root を `scope` に持つ `repository_manifest` 行を記録し、
route する実行のたびに `.harness/policy.json` から同じ hash を導き直して突き合わせることで行います。
両者は別のストアにあり、policy は checkout に付いてきますが台帳は付いてきません。したがって承認後に
policy を書き換えると、同梱の hash を辻褄が合うよう再計算しても照合は通りません。この検知が
描く境界と描かない境界は [repository onboarding](#onboarding-と-shadow-command) を参照してください。

使い捨ての candidate worktree は意図的にこのテーブル群に**含めていません**。retention の窓が
その寿命として不適切である理由は [candidate worktree](#candidate-worktree) を参照してください。

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
fh approvals --all --json                              # 決着済みも含める
fh approve --request <id> --allow                      # 通す
fh approve --request <id> --deny --message "..."       # 理由を model へ返して拒否する
fh approve --request <id> --allow --answers '{"Which colour?":"Red"}'   # AskUserQuestion
fh approvals --purge --json                            # wave が終わったら決着済みを捨てる
```

通常は wave orchestrator が仲介する（queue を読み、user に問い、回答を書き戻す）が、user が同じ
コマンドで直接答えることもできる。これは重要で、orchestrator が落ちても pending な承認は決着できる。
`AskUserQuestion` への回答は提示された選択肢に対して**両側**で検証されるため、打ち間違いや手編集した
ファイル経由で「user が表明していない判断」が model に届くことはない。

要求は質問文と選択肢を保持する（答えるために必要だから）。それを保持する場所は他に無いので、
終わった wave がそのテキストを持ち続けないための手段が `fh approvals --purge` である。終端状態に
達した要求とその回答を削除し、**pending は残す**。読めなかった要求も残す —— 状態を確認できていない
記録を消すのは、まだ待っている子を黙って捨てることになる。

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

## onboarding と route の記録

task ごとの permission prompt を避けるため、repository の command/domain/capability manifest を一度だけ
承認します。承認は **2 回の実行**に分かれ、2 回目は 1 回目が発行した request を名指しする必要があります。

```bash
fh onboard --manifest candidate.json                       # レビュー。request id を出力する
fh onboard --manifest candidate.json --approve --request <id> --json
fh run --task task.json --json
fh status --json
fh clean --dry-run --json
fh gaps --json
```

`--request` を伴わない `--approve` は拒否します。request id は推測不能で state root に置かれるため、
1 回の呼び出しが manifest の提案と承認を兼ねることはできません —— id は、レビュー実行が manifest を
人間に読ませるかたちで出力して初めて存在します。request は単回使用で、
<!-- FACT:fh-onboard-request-ttl-ms -->86400000<!-- /FACT --> ms（24 時間）で期限切れになり、
発行したプロセス自身による承認を拒否し、manifest が下で書き換われば通らなくなります。

### 照合が実際に見るもの

`fh run` と `fh verify` は `.harness/policy.json` を読み、その manifest hash を導き直し、この
state root に対する `repository_manifest` 行が承認台帳にあることを要求します。policy を持たない
repository は**空 manifest** として扱われ、すべてが未承認になります。既定は fail-open ではなく
fail-closed です。そのうえで:

- **command** は承認チャネルと同じ解析器でトークン化し、正規化したセグメントとして照合します。
  `npm run test; curl …` は 2 セグメントに割れ、2 本目に一致する承認が無いので拒否されます。
  静的に解釈できないコマンド（動的構築、シェルやラッパー越しの実行）は、推測せず拒否します。
- **domain** は承認済みリストとの完全一致で照合し、manifest 側は内部アドレス・メタデータ用
  アドレスでない domain しか承認できません。`inet_aton` のあらゆる表記を先に解いてから判定するため、
  `169.254.169.254` / `2852039166` / `0251.0376.0251.0376` / `0xA9FEA9FE` / `169.254.43518` は
  すべて同じ 1 つのアドレスとして拒否されます。private、carrier-grade NAT、link-local、multicast、
  reserved、unspecified、IPv4-mapped、NAT64 埋め込みの各レンジも同様です。`localhost` /
  `127.0.0.1` / `::1` は**リテラルとしては**承認できます（ローカル dev サーバは正当な対象だからです）。
  一方、loopback へ*解決する*名前は承認できません。承認は各名前を解決し、答えのいずれかが拒否対象の
  レンジに入れば承認せず、そもそも解決できない名前も承認しません。
- **capability** は router が選んだ capability と照合します。`executor.default` を列挙していない
  manifest は、その route を止めます。

未承認のものは実行しません。route は `escalation` として記録され、要求は state root 内の gap queue へ
書かれ（1 項目 1 ファイル・作成のみなので、並行する wave の子が互いを上書きしません）、コマンドは
終了コード 2 を返します。queue は wave の境界で確認し、同じ 2 段階儀式で一括承認します。

```bash
fh gaps --json
fh onboard --from-gaps                                     # レビュー。request id を出力する
fh onboard --from-gaps --approve --request <id> --json
```

`--from-gaps` は「承認済み manifest ＋ manifest に載せられる queue 項目」を候補として提案し、
残りはバッチ全体を失敗させる代わりに `gapsRejected` として報告します。落ちた項目は未承認のまま
残ります。credential、migration、external contract、deploy、force push、release、merge は常に
明示的な escalation です。

### 承認はどう差し替わるか

approvals 台帳は追記のみで、`fh clean` も削除しません。監査証跡だからです。したがって認可の状態を
台帳だけで表すことはできません —— 「記録済みのどれかに一致すれば有効」とすると、一度承認した
manifest は永久に有効になり、manifest を狭めても実際には何も取り消せず、古い
`.harness/policy.json` を戻すだけで復活してしまいます。

そこで両者を分けています。台帳が記録するのは **何をいつ承認したか**、state root 内のポインタが
記録するのは **いまどの承認が有効か**で、承認をやり直すとポインタが差し替わります。policy の照合とは、
その manifest の hash を導き直してポインタと突き合わせ、ポインタが指す承認が台帳にも残っていることを
確かめることです。

ポインタは repository 単位ではなく **policy ファイルのパス単位**で分けます。state root は同一
repository の全 linked worktree で共有される一方、policy は worktree ごとの
`.harness/policy.json` に存在するため、repository 単位にすると最後に onboarding した worktree が
他の worktree を黙って未承認化してしまいます。パス単位にすることで、承認を時刻順に並べる必要も
無くなります（台帳の id はランダムなので、同時刻の順序に意味を持たせられません）。

### この検知が描かない境界

有効な承認と policy を結びつけることで、承認後に書き換えられた policy、差し替えられた policy、
**過去に承認した内容へ差し戻された policy**、別の repository から持ち込まれた policy を検知できます。
checkout は policy を運びますが、state root は運ばないからです。一方、次の境界は描きません。

- **すでに同一 uid で動いている攻撃者**。ポインタも台帳も policy と同じ手軽さで書き換えられます。
  `approvals.granted_by` と承認ディレクトリに付いている但し書きと同じで、記録は「何が承認されたか」を
  述べるが、「誰が承認したか」を証明しません。
- **自律エージェントによる自己承認**。2 段階儀式は request を作成したプロセス自身による承認を拒否
  するため、1 回の呼び出しでは自己承認できません。2 回なら可能です —— シェルを持つものは
  レビュー実行の出力から request id を読み、2 回目に渡せます。儀式が保証するのは「承認の前に
  manifest がレビューのため出力されたこと」であって、「人間がそれを読んだこと」ではありません。
- **承認後にアドレスが変わる domain**。名前を解決するのは manifest の承認時であって task の実行時では
  ないため、`fh run` と `fh verify` は domain 文字列の一致しか見ません。承認時点では無害なアドレスへ
  解決する名前が、後から内部アドレスを指すようになりえます。実際に接続を開く層がその時点で
  再確認する必要があり、その層は rollout 昇格とともに入ります。
- **`fh review`**。どちらのサブコマンドも capability manifest を参照しません。`record` は正規化した
  finding を registry へ書くだけ、`packet` は読むだけで、provider も repository の command も起動しません。
  ただし `packet` が読むのは**承認済み**の manifest なので、承認の無い repository では reviewer に渡るのは
  生の `.harness/policy.json` ではなく空の制約リストになります。

enforcement 以前に書かれた policy は有効な承認の裏付けが無いため、既存 repository の移行には儀式の
やり直しが必要です。

task は必要なものを自分で宣言します。実行の途中で人が判断しなければならない task には
`requiresApproval`、ファイルを書き換える task には `requiresWrite` を付けます。どちらも既定は false で、
選ばれた provider の宣言と突き合わされます（後述の「承認チャネルと書き込み可否が route を塞ぐ」）。

`run` は provider を起動せず、正規化した route を記録するだけです。これは `shadow` のときだけでなく
**どの rollout でも**成り立ちます —— `runWithRolloutGuard` に runner を渡さないからです。route の記録は
書き込みトランザクションの中で行い、guard を通すのはそこを出てからです。こうしておかないと、将来
executor を配線した時点で `BEGIN IMMEDIATE` を provider 呼び出しの長さだけ握り続け、同じリポジトリの
他の `fh` が全部詰まります。`clean` は期限切れの raw レコードと集約テレメトリをそれぞれの窓で処理し、
approvals には手を触れません。`--dry-run` で影響を確認できます。

## 決定的な検証

```bash
fh verify --task <task id> --command "npm run test" --json
fh verify --task <task id> --command "npm run lint" --kind lint --json
fh verify --task <task id> --candidate <candidate id> --command "npm run test" --json
```

`fh verify` はチェックを実際に走らせ、その結果を記録します。以前は `verification_plan` を 1 行書いて
終わりで、完了の主張が「model がテストは通ったと言った」以上の根拠を持ちませんでした。

その主張より結果を重くしているのは、次の 4 点です。

- **コマンドは事前に承認済みでなければならない。** 何かを起こす前に repository capability manifest と
  照合し、外れれば `fh gaps` に積んで終了コード 2 で止まります。承認可能な文法はプロジェクトの
  タスクランナーと狭い字集合の引数に限られ、`check-runner.mjs` は実行の直前に同じ文法をもう一度
  検査します —— 照合と実行の間で文字列が別のものへ組み立て直される余地を残しません。
- **シェルを介さない。** 承認済み文字列は argv へ分割され、バイナリは PATH 上の絶対パスへ解決され、
  `spawn` へは配列のまま渡ります。`;` や `&&`、`$(…)`、glob が再解釈される段階が存在しません。
- **harness はチェックの出力を受け取らない。** 子の stdout / stderr は端末へ継承され、pipe しません。
  harness が知るのは終了コードだけなので、「自由文が state DB に入らない」は書き方の規約ではなく
  **そもそも受け取っていない**という性質になります。
- **終了コードが判定である。** 0 は `passed`、それ以外は `failed` を記録します。そもそも起動できな
  かったチェック（実行ファイルが `PATH` に無い、`spawn` が失敗した）は例外にせず `errored` として
  記録します —— 「検証を試みたができなかった」という事実も痕跡として残すためです。
  <!-- FACT:fh-check-timeout-ms -->900000<!-- /FACT --> ms（`--timeout-ms` で変更可。ただし
  <!-- FACT:fh-check-max-timeout-ms -->3600000<!-- /FACT --> ms で頭打ちにします。チェックの実行中は
  candidate の書き換えを検知できない唯一の窓だからです）を超えたチェックは
  SIGTERM、猶予の後に SIGKILL で終了させ、終了コード 124 の `errored` として記録します。
  `fh verify` 自身が 0 を返すのは、チェックが通ったときだけです。

チェックは `--worktree`（既定は作業ディレクトリ）で走り、state・manifest・gap queue もすべて同じツリー
から解決します。`fh session` が `--worktree` に対して置いた規則と同じ理由です —— 呼び出し元の
ディレクトリから解決すると、承認済みリポジトリの中から別のツリーを指すだけで承認を持ち回れます。

candidate の中で検証するときは、`--worktree` でそのディレクトリを指すのではなく `--candidate` を使います。
candidate は base commit の detached checkout なので、`.harness/policy.json` が未コミットならそのツリーには
存在せず、`--worktree` で指すと承認境界は「このリポジトリは何も承認していない」と正しく判定します
—— fail-closed としては正しい一方、隔離 → 検証 → 取り込みが通らなくなります。`--candidate` は
**登記簿を経由**してツリーを解決します。そのツリーがこのリポジトリの持ち物であることを保証するのが
登記簿であり、承認は所有元リポジトリのものを使い、candidate のツリーで走るのはチェックだけです。
呼び出し側が渡した path を信用するわけではないので、`--worktree` の境界は弱まりません。

**「承認済み」が実際に何を許しているか。** 承認可能な文法はプロジェクトのタスクランナーですが、その
ランナーはリポジトリ側のスクリプトへ処理を委ねます —— `npm run test` はその時点の `package.json` が
書いてある内容を実行し、その内容は差分とともに変わります。チェックは呼び出し元の環境をそのまま継承し、
ネットワークやファイルシステムの封じ込めも持ちません（`fh session` が provider に対して封をする sandbox は
ここには効きません）。つまりコマンドの承認は「このプログラムは安全」ではなく「このリポジトリのタスク
ランナーを、私の環境で、チェックのたびに実行してよい」に近い意味を持ちます。この経路で最も鋭い縁であり、
検証対象が「まだ誰も読んでいない差分を抱えた candidate」であるときに最も効いてきます。

kill が届くのは harness が起こしたプロセスまでで、その子孫には届きません。自分で孫プロセスを起こし
SIGTERM を無視するテストランナーは、それらを残しうります。process group ごと落とせば直りますが、
今度は harness より長く timeout 分だけ生き残る孤児という、より悪い失敗を作ります。時間切れは
保証ではなく安全弁です。

## review registry

```bash
fh review packet --task <task id> --out <abs path> [--base <rev>] --json
fh review record --task <task id> --findings <abs path> --json
```

レビューは散文ではなく正規化された finding として扱います。`packet` は reviewer が受け取ってよいものを
組み立て、`record` は返ってきた finding を受け取って verdict を返します。2 つを分けているのは権能が
違うからで、`packet` は git を読むだけで何も起こさず、`record` は state を書くだけで repository に触れません。
どちらも provider を起こしません —— それは `fh session` の仕事であり、provider への 2 本目の経路こそ
#537 が作らないと決めたものです。

**packet が運ぶのは task・制約・差分・検証結果の 4 つだけです。** writer の会話履歴はそこに含まれず、
その保証は規約ではなく構造です: `buildReviewPacket` が受け取るのは task id・ワークツリー・base revision
だけで、prompt も transcript も adapter の出力も**渡す口が存在しません**。4 つの出所も writer が
自由に書ける場所ではありません —— 正規化済みの task 行、承認済み manifest、`verification_results`、git です。

`--out` は、既に存在するディレクトリの権限を変更せずに書き出します。state root が要求する 0700 を
課すのは harness 自身が作ったディレクトリだけなので、既存の共有ディレクトリを `--out` に指しても、
そこが黙って他者から見えなくなることはありません。

差分は追跡済みの変更と未追跡の新規ファイルの両方を含み、base commit から流し込んだ使い捨ての
`GIT_INDEX_FILE` を通して作ります。対象ワークツリーの index は決して触りません。ステージング状態は
`pr-workflow` の持ち物だからです。その使い捨て index はワークツリーの git ディレクトリ配下に置くので、
`git add -A` が拾うことはありません。<!-- FACT:fh-review-diff-max-bytes -->1048576<!-- /FACT --> バイトを超える packet は `truncated: true` を立てて切り詰めます
——「差分を全部見た」と reviewer に思わせないためです。packet は `--out` へ書き出し、印字しません。
差分が stdout を経由してログへ流れないようにするためです。

finding のドキュメントは version・reviewer capability・finding 群を宣言し、各 finding は severity・
uncertainty・1 行の要約・任意の反証実験を持ちます。未知キーは黙って捨てず拒否するので、`transcript` や
`rationale` を足せば静かに通るのではなく loud に落ちます。要約は
<!-- FACT:fh-review-text-max-length -->300<!-- /FACT --> 文字を上限とし、印字可能な 1 行でなければなりません
（制御・書式カテゴリに加えて `Zl` / `Zp`、すなわち U+2028 / U+2029 も拒否します。この 2 つは `Cc` にも `Cf` にも
属さない一方、描画される場所のほとんどで改行として扱われるためです）。
この上限が、その列をレビュー本文の貼り付け先にしないための境界です。task id は `--task` が決め、
ドキュメント側からは指定できません —— reviewer が他人の task に finding を紐付けられないようにするためです。

evidence に載るのは件数と verdict だけで、finding そのものは載りません。`must` が 1 件でもあれば verdict は
`blocked` になり `fh review record` は非 0 で終了します。呼び出し側スクリプトが未解決の `must` を
成功として読めないようにするためです。

## 子セッション

`fh session` は provider プロセスを起こす唯一のコマンドです。wave orchestrator のためにあり、
その子は「user に問える」必要のある `pr-workflow` セッションそのものです。

```bash
fh session launch --worktree <abs> --prompt-file <abs> --label feat-537-child
fh session resume --worktree <abs> --prompt-file <abs> --resume-key <session id>
```

**router を通しません。** `chooseRoute` は `executor.default` を選びますが、その provider は
外部の承認チャネルを宣言していないため、人の判断が要る task はすべて escalation になり子が 1 本も
起動しません。そこへ claude fallback を足すのは routing の意味論の変更にあたります。子の model と
effort は `model-fitness-check` の contract が決めるものなので、capability を名前で指定します
（`--capability`、既定 `session.child`）。それ以外は従来どおりです: capability registry が
provider / model / effort を供給し、repository capability manifest がその capability を承認して
いなければ gap を queue して exit 2 で終わり、`checkCapabilityExecutable` が account scope・
model discovery・書き込み封じ込めを再検査し、rollout guard が実行の可否を決めます。

承認チャネルは 3 層で確認します。いずれも警告ではなく拒否します。

1. **構造。** `sealInvocation` は `--permission-prompt-tool` と inline の `--mcp-config` server
   ちょうど 1 つを欠いた argv を組み立てません。配線漏れではプロセスが 1 つも起きません。
2. **起動前。** 宣言した承認 server を 1 度起こし、MCP handshake（`initialize` → `tools/list`）を
   通します。`approve` ツールが公開されなければ —— 存在しない、読めない、遅い、別のプログラムを
   指している —— 子を起こしません。
3. **最初の init イベント。** 子の構造化出力を stream として読み、`system/init` に
   `readInitHealth` を当てます。`AskUserQuestion` が無い、承認 server が接続していない、
   MCP / plugin のエラーを報告している、のいずれかなら**その場で子を終了**し、run を failed として
   記録します。完了後の出力ではなく stream を読むことが、これを「起動時検査」として成立させます ——
   gate が黙って消えた子は最初の 1 秒で止まり、1 タスク分の作業を終えてから診断されることがありません。

init イベントが来ないまま終わった実行も同じ扱いです。検査を読み取れないことは、検査を通ったことの
証拠ではありません。

記録には会話内容が残りません。`adapter_runs` は設計上 prompt や argv の列を持たず、evidence の claim は
固定語彙 ＋ resume key ＋ 健全性の判定 ＋ 拒否されたツールの**名前**だけです。prompt は引数ではなく
ファイルから読むので `fh` 自身の `ps` エントリにも載らず、子の stdout はメモリ上でのみ解釈して
ディスクへ書かず、**`fh` 自身が** stderr へ書くのは liveness の heartbeat としての各イベントの型名だけです。

子自身の stderr は別のストリームで、フィルタせずに継承します。これは意図的です —— `fh session` を
走らせているペインは人が覗く窓であり、tmux から離れるにあたって唯一手放さなかったガードだからです。
その中身を `fh` は制御しませんし、`claude -p` がそこへ何を書くかは実測されていません。よって
**会話内容を含みうる前提**で扱ってください: 覗くのはよいが、永続化しないこと。子の stderr をログ
ファイルへリダイレクトすることが、この設計の唯一譲れない前提（記録に会話内容を残さない）を外側から
破る経路です。

`fh session` は account の選択も運びません。子は PATH から `claude` を解決し、そのランチャーは
継承した `CLAUDE_CONFIG_DIR` を保持するため、子は常に**起動したセッションの account** で走ります。
子を特定の account へ固定したいときは、このコマンドへランチャー名を渡すのではなく、既存のやり方 ——
capability に `accountScope` を宣言し、`checkCapabilityExecutable` に強制させる —— を使ってください。

リポジトリの承認は、コマンドを起動したディレクトリではなく**子が走るワークツリー**に紐づきます。
manifest・承認 scope・state root・子の作業ディレクトリはすべて `--worktree` から解決します。
呼び出し元の cwd から解決すると、承認済みリポジトリから未承認のリポジトリへ子を起動できてしまい、
capability gate が誰も尋ねていない問いに答えることになります。

## provider adapter

3 つの CLI は互換ではありません。非対話モードの能力が非対称なので、1 つの汎用ランチャーを
パラメータで切り替えるのではなく、provider ごとに adapter を持ちます。

| | Claude Code | Codex | Antigravity |
|---|---|---|---|
| 起動 | `-p` ＋ `--output-format stream-json` | `codex exec --sandbox <mode> --json` | `-p --output-format json` |
| 再開 | `--resume <session id>` | `codex exec resume <thread id>` | `--conversation <id>` |
| サンドボックス | `--settings` の設定 JSON。`--sandbox` フラグは存在しない | 起動は `--sandbox`、再開は `-c sandbox_mode="…"` | 表現できない（`--sandbox` はファイル書き込みを止めない） |
| 作業ツリー由来の設定 | `--setting-sources user` と `--strict-mcp-config` で遮断 | 設定源を足すフラグを出さない（設定は `$CODEX_HOME` 由来） | 設定源を足すフラグを出さない（暗黙の探索は未実測） |
| 承認チャネル | 外部への往復が可能 | エージェントによるレビュー | 無し |
| 成功判定 | `result` イベント / `is_error` / `permission_denials[]` | `turn.completed` と `error` イベント | 終了コードと status だけでは**判定できない** |

adapter は純粋です。invocation を組み立て、プロセス結果を解釈するだけで、Node の子プロセス API を
import しません（テストがソースを走査して固定しています）。したがって `createAdapterExecutor` は
runner の注入を必須とし、**既定の runner を持ちません** —— 実プロセスの起動はこの層の外に属します。
唯一の注入元は `fh session` で、runner の実体は `child-runner.mjs` にあります。挿入点は
`runWithRolloutGuard` の `executor` 引数なので、`shadow` の間は route が provider に到達しません。
この runner は非同期です。承認チャネルが消えた子を**作業を始める前に**止める手段が、最初の
`system/init` イベントを読むことしか無いからです。`createAdapterExecutor` は runner が Promise を
返したときだけ Promise を返すので、他の呼び出し側が依存している同期契約は変わりません。

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

### 作業ツリーは子セッションを設定できない

子セッションは、issue 由来のブランチをチェックアウトした worktree の中で走ります。つまり
`.claude/settings.json`・`.claude/settings.local.json`・`.mcp.json` は、信頼境界の外から届きます。
対話モードの CLI はフォルダを信頼する前に確認しますが、`-p` は確認しません。加えて、検証に失敗した
設定ファイルを何も言わずに無視し、セッション最初の hook は構造化イベントが読める時点より前に走ります。
出力を見て問題を検出するのは構造上つねに手遅れなので、遮断は起動フラグで行います。

Claude の invocation はすべて `--setting-sources user` と `--strict-mcp-config` を持ち、
`sealInvocation` がそれをサンドボックスと同じやり方で読み戻します。`readEffectiveConfigIsolation` は
既定値を持たない必須引数で、reader が `true` を返さない invocation は返されません。フラグを外すのは
「うっかりできる間違い」ではなく、**その形自体が存在しない**ということです。例外リストも、信頼済み
worktree の台帳も持ちません。台帳はそれ自体が新しい信頼境界になり、改竄検知が別途必要になるからです。
worktree の hook や skill が本当に要る作業は、対話セッションで行います。

検査と説明は 1 つの導出から作るので、両者が食い違うことがありません。`configSourcesFor` は argv を
「子が読む設定ファイルの集合」へ変換し —— `--setting-sources` が選ぶ user / project / local の設定
ファイルと、`--strict-mcp-config` が抑止する project の `.mcp.json` です —— isolation の reader は
そのどれもが作業ツリーの中に無いことを確認します。テストは一時 worktree に本物の敵対的ファイルを
書き出して導出がそれらを含まないことを確かめ、negative control は 2 つのフラグを外すと同じ 3 ファイルが
戻ってくることを確かめます。後者があるので、前者は自分自身の言い換えになりません。argv の走査が
解釈できないもの —— 未知のフラグ、重複した `--setting-sources`、inline JSON のはずが渡されたパス ——
はすべて「全設定源が有効」に解決され、fail-closed になります。

承認チャネルはその例外ではなく、許可リストとして表現します。`--strict-mcp-config` は `--mcp-config` が
名指しした server しか通さないので、宣言せずに `--permission-prompt-tool` だけを配線すると、prompt tool の
参照先が存在しない子ができあがります —— これは配線しない場合とまったく同じ「gate が静かに消える」失敗です。
そのため adapter は prompt tool と承認 server を**両方揃えるか、両方持たないか**しか受け付けず、server は
inline JSON 文字列でちょうど 1 つだけ宣言し（ファイルパスは作業ツリーから差し替えられます）、その server を
指していない prompt tool を拒否します。宣言が運ぶのはコマンドと引数だけで、env ブロックは運びません。

`readInitHealth` は `system/init` イベントを読み、prompt tool を配線したときに `AskUserQuestion` が
存在するか、宣言した承認 server が接続したか、子が MCP / plugin のエラーを報告したかを返します。
**これは二次的な検査であって、境界ではありません。** 設定ミスの検出には有効ですが、エラーを出さずに
接続して応答するものは素通りしますし、起動時に走る hook はこのイベントが読める時点で既に走り終えています。
実際の起動シーケンスへ配線するのは別の作業です。

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

### 承認チャネルと書き込み可否が route を塞ぐ

上の表の承認チャネルと書き込み可否は、最初から各 adapter が宣言していました。ところが routing の
段階では長らく誰も読んでおらず、`chooseRoute` は可用性しか見ず、書き込みの軸は実行直前に 1 度だけ
参照されるだけでした。そのため、人の判断が要る task が「承認を求められない provider」へ route されえて、
そこではソフト拒否されるか素通しされるかのどちらかになり、いずれにせよ gate は失われていました。

いまは両方の軸を route 段階で突き合わせます。値は実測された場所に置いたままです。adapter の宣言が
唯一の写しで、`provider-capabilities.mjs` がそれを provider 名で引ける表に束ね、router がそれを読みます。
`config.json` へは複製しません。同じ実測事実が 2 箇所にあると、`providers.mjs` が一方で `agy`、
他方で `antigravity` を持つに至ったのと同じことが起きるからです。

- `requiresApproval` の task は、チャネルが `external` の provider へしか route されません。
  エージェント自身のレビューは人の gate ではないので、`agent-review` は要求を満たしません。
- `requiresWrite` の task は、書き込み能力が `supported` の provider へしか route されません。
- adapter が登録されていない provider、語彙外の宣言は、最弱の組（チャネル無し・封じ込め不能）に
  解決されます。adapter の登録漏れは gate を開けるのではなく閉じる方向に倒れます。

要求フラグ自体の既定は *false* で、`hasDeterministicOracle` とは逆向きです。これは意図的です。
oracle の欠落を「oracle 無し」と読むのは reviewer を**足す**方向にしか振れません。一方、承認フラグの
欠落を「承認が要る」と読むと、出荷 registry には外部チャネルを持つ executor が 1 つも無いため
あらゆる route が escalation になり、軸そのものが使えなくなります。fail-closed は供給側が担います。

**塞いだ route を黙って別の provider へ向け直すことはしません。** router が既に持っている fallback が
あればそれを使います。書き込みを伴う browser task は Antigravity へ行けないので、frontend が利用不可の
ときと同じ経路をたどって `executor.default` に着きます。fallback が無い場合 —— `executor.default` 自身が
要求を満たさない場合 —— は escalation になり、provider は起動しません。軸を満たすために役割を跨ぐことも
しません。チャネルを持っているからといって reviewer capability を writer に流用すれば、なぜその provider が
走ったのかを後から説明する手立てが無くなります。

reviewer も軸では塞ぎません。`semantic.judge` は書き込みも人の gate も担わないため、ここで拒否すると
「reviewer を足す」が「escalation」に化けるだけで、安全性は何も買えません。

escalation になった route は、rollout が何であれ provider を起動しません。これが無いと
「塞いだ route は実行せず記録する」は「たまたま rollout が `shadow` だから」成り立っているだけで、
昇格して実起動を配線した瞬間に、塞いだはずの route が provider へ届いてしまいます —— gate は
route 段階では通っているのに実行段で漏れる、という形です。同じガードは、この軸より前から存在する
risk による escalation にも効きます。`shadow` の間は rollout guard が既に executor を呼んで
いないため、挙動は変わりません。

塞いだ route はすべて記録されます。decision は遮断 1 件ごとに capability・provider・軸・要求値・宣言値を
持ち、`fh run` はそれを task と route に紐付いた `route_block` evidence として、route を記録するのと同じ
トランザクションの中で書きます。routes テーブルにはこの 5 つ組を入れる列が無く、足すのは migration に
なるため、理由は evidence 側に置いています。risk による escalation はこの軸より前から存在し、kind と
reason だけで説明が閉じるので、遮断の一覧は持ちません。

### adapter が実行前に検査すること

router は provider 非依存の言葉で可用性を判断し、上記 2 つの宣言軸は config の複製ではなく adapter
registry から読みます。adapter は実行の直前に、同じ discovery 一覧に対して
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

## candidate worktree

```bash
fh candidate create --task <task id> [--base <rev>] [--label <l>] --json
fh candidate list --json
fh candidate adopt --candidate <id> --json
fh candidate discard --candidate <id> --json
```

書き込みを伴う多様化ルートには、レビュー対象のブランチではないどこかに書く場所が要ります。
`fh candidate` はそれに使い捨ての子ワークツリーを与え、そこで生まれたものを外へ出してよいかを
evidence で判定します。

**primary worktree と PR ブランチは `pr-workflow` が所有したままです。** candidate は自分のブランチを
持たない detached checkout なので PR ブランチの代わりにはなれず、取り込みは patch を当てて終わりです
—— commit も push もしません。merge をはじめ不可逆な外部操作は常に user が行います。

**candidate は `wtp` で作りません。** 本リポジトリの `.wtp.yml` は post-create hook で `.env` を新しい
ワークツリーへ symlink します。人が作業するワークツリーには正しい挙動ですが、自律ルートが書き込む
ツリーには不適切です。そのため candidate は hook を持たない `git worktree add --detach` を使います。
ツリーは state root 配下（git common directory の内側）に置くので、primary worktree の `git status` には
現れません。

**取り込みの根拠は主張ではなく実測です。** チェックは `fh verify --candidate <id>` で走らせます。
candidate を取り込むのは、**その candidate に対して記録された** `verification_results` が 1 件以上あり、
そのすべてが passed のときだけです。

揃うべき条件は 3 つあり、それぞれが「1 つ目を偽装する方法」を潰しています:

- **そのチェックがこの candidate を名指ししていること。** 結果は `candidate_id` を持ち、取り込み判定は
  それで照合します。task だけで照合すると、同じ task の別 candidate が得た合格が、一度も検証していない
  candidate の取り込み根拠になってしまいます。
- **チェックが candidate 作成より後であること。** 作成前の緑は、そのツリーの中身について何も言っていません。
- **その後ツリーが動いていないこと。** 結果は `tree_hash`（チェックが実際に見た git tree）も持ちます。
  これは**チェックの前と後の両方**で採り、両者の一致を要求します —— 後だけで採ると「測ったもの」
  ではなく「終わった時点のもの」を記録することになり、チェックは何分も走りうるからです。実行中に
  ツリーが動いた場合、その結果はどのツリーについての判定でもないので、hash を付けず `errored` として
  記録します。取り込み直前に再計算して食い違えば断るので、合格後に candidate へ書き込んで未検証の
  差分を古い判定のまま持ち込むこともできません。`tree_hash` を持たない結果は取り込み根拠にしません
  —— hash が無いことを「問題なし」と扱うのが、この gate を無効化する最も簡単な方法だからです。

取り込みでは hash の取得と patch の生成を**同じ stage 1 回**から行います。別々に読むと、その間に
ツリーが動いたとき「検証したもの」と「適用するもの」がずれます。

未検証・赤・古い判定のいずれかであれば終了コード 2 で断り、ツリーには手を触れません。判定・hash 取得・
diff・適用のすべてが rollout guard の内側にあるので、`shadow` ではここでも git は 1 回も起きません。

`discard` は登記簿の状態ではなく**ツリーの実在**で判断するため冪等です。撤去が途中で失敗すると
ツリーだけが孤児として残りますが、状態だけを見て早期 return すると、それを片付ける手段が無くなります。

**衝突したら作業を残します。** patch が対象ワークツリーへ clean に当たらなければ、candidate を
`conflicted` にし、**ツリーは保持**して終了コード 2 で戻します。承認境界と同じコードなのは、どちらも
「人が見るまで進めない」を意味するからです。rebase も自動解決も行いません —— どちらも、検証済みだった
中身を黙って検証していないものへ変えてしまいます。user が衝突を解消すれば、保持された candidate は
そのまま取り込めます。clean に当たった candidate は取り込んだうえでツリーを撤去します。中身は
対象ワークツリーへ移っているからです。

登記簿はテーブルではなく state root 配下のファイルです。candidate は「ディスク上のディレクトリが今
どうなっているか」という事実なので、retention の窓に入れるといずれ行だけが消えてツリーが残ります
—— 登記簿は「無い」と言うのに `git worktree add` は path 衝突で失敗し続ける、という状態です。同時に
抱えられる candidate は最大
<!-- FACT:fh-candidate-max-live -->8<!-- /FACT --> 件です。1 件がフルチェックアウト 1 本なので、
gap queue のような桁は取れません。

## rollout

promotion は shadow → pilot → default です。rollout は現在 `pilot` で、CLI 側が
（provider adapter が未実装であることに依存せず）明示的なガードとしてこれを強制します。
harness と、それが起こすプロセスの間に立っているのはこのガードだけです。`pilot` が開けている経路は
ちょうど 4 つ —— `fh session`（子 provider）、`fh verify`（承認済みチェック）、`fh candidate`
（使い捨てワークツリーとその取り込み）、`fh review packet` の背後の git 呼び出し —— です。`fh run` は
今も runner を渡しません。surface が広がるのは設定値によってではなく、意図して足した 1 コマンドずつです。

rollback は `rollout` を `shadow` へ書き戻すことです。ガードはプロセスが起きる前に
`executed: false` を返します —— チェックは spawn されず、ワークツリーも作られず、走ったかのような記録も
残りません。`default` への昇格、`--legacy` による rollback flag、次の昇格を正当化するテレメトリの定義は、
いずれも未着手です。
