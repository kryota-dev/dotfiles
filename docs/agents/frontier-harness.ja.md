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

task は必要なものを自分で宣言します。実行の途中で人が判断しなければならない task には
`requiresApproval`、ファイルを書き換える task には `requiresWrite` を付けます。どちらも既定は false で、
選ばれた provider の宣言と突き合わされます（後述の「承認チャネルと書き込み可否が route を塞ぐ」）。

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
| 作業ツリー由来の設定 | `--setting-sources user` と `--strict-mcp-config` で遮断 | 設定源を足すフラグを出さない（設定は `$CODEX_HOME` 由来） | 設定源を足すフラグを出さない（暗黙の探索は未実測） |
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
