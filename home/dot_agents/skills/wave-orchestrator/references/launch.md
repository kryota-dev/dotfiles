# wave-orchestrator: 前提チェックと起動の根拠

これは**根拠**である。守るべきこと（規範）は [`../SKILL.md`](../SKILL.md) が持つ。ここにあるのは
その規範がなぜその形なのか —— 実測と、一度踏んだ事故の経緯 —— で、**規範を疑う / 書き換える /
規範が想定していない状況に出たときに読む**。

対応する規範: `SKILL.md`「Phase 0: 前提チェック」「Phase 2: 起動」。

## 承認チャネルが配線されていないと何が起きるか

子は承認チャネルが配線されていなければ **`AskUserQuestion` そのものを失う**（#529 PRD §1.2.1 の
2×2 実測）。これは「止まらなくなった」ではなく「**問えなくなった**」で、外形が同じなのに
blocking gate が静かに消える —— 本リポジトリが最も嫌う沈黙する故障にあたる。だから 3 点の確認を
起動前に置いている。

- **capability が `unavailable` のとき**に別 account へ切り替えたり model 名を推測したりしないのは、
  それが「業務を別区分のアカウントで走らせる」ことに直結するからである。
- **未承認のワークツリーでは `fh session` は子を起こさず、gap を queue して exit 2 で終わる。**
  これは正しい fail-closed であって障害ではない。「このリポジトリで自律的な子セッションを
  走らせてよいか」を人が 1 度承認する境界である。
- **`shadow` の間は `fh session` が route を記録するだけで子を起こさない**（`executed: false`）。
  逆に言えば、`config.json` の `rollout` を `shadow` に戻すことが**そのまま緊急停止になる**。

`fh session` は上記に加えて、**承認 server を起動前に 1 度起こして MCP handshake を通す**。
`approve` ツールが見つからなければ子を起こさない。だから「配線したつもりで実は繋がっていない」
状態で wave が走り出すことはない。

## 子に orchestrator 用の model variant を使わない理由

子は実行者であって orchestrator ではなく、その variant は **model floor を全て pass するため
floor 判定が実質無効化される**。

## tmux の target を ID で渡す理由（zsh history modifier）

`tmux` の `-t` には window ID（`@45`）/ pane ID（`%97`）を渡す。`"$SESS:wave1"` のような文字列
target は **zsh が `:w` `:a` を history modifier として解釈して壊す**（`$SESS:wave1` → cwd が前置され
`ve1` が残る）。ダブルクォートの中でも起きるため、やむを得ず文字列で組む場合は必ずブレースで囲む。

Claude Code の Bash ツールは user の profile から初期化された zsh で動くので、**bash 前提の手順を
そのまま書くと確実に踏む**。失敗は `can't find window: <cwd>` という形で出るため
「ウィンドウ名が違う」と**誤診しやすい**。これは history modifier に限った話ではなく、zsh と bash の
差は監視スクリプト全般に効く（`SKILL.md`「監視スクリプトは zsh で動く」節）。

## 専用セッションを kill しない理由

使い捨ての観測用セッションと違い、これは実作業をホストする。**同名セッションの kill は稼働中の子を
殺す。** 同名ウィンドウが既にあるなら、それは重複起動の兆候として扱う。

ウィンドウ番号の詰め直し（`renumber-windows`）とペインタイトルの表示（`pane-border-status`）は
**利用者の tmux 設定に依存する**。skill 側では設定せず、必要なら利用者の設定で有効にしてもらう
（設定していない環境ではタイトルが見えないだけで、動作そのものは変わらない）。

## `CLAUDE_CONFIG_DIR` を明示しないと何が壊れるか

この変数はランチャー（`cld` 等）が**呼び出しごとに**設定するもので、シェルには export されない。
素のペインには存在しないため、明示しないと `fh` は account を解決できず `unknown` になる。

その状態では account に紐づくパス（codex home 等）が解決されず、`accountScope` を宣言した
capability は拒否され、readiness キャッシュも `unknown` キーで書かれる —— **外形上は正常な起動と
見分けがつかないまま劣化する**。`fh session` は `unknown` を拒否するので起動時には落ちるが、
落ちる前に付けること。

## capability を tier で選ぶのが本 skill の責務である理由

**`fh` は tier を知らない。** `session-command.mjs` は capability を名前で引き（`selectCapability`）、
その `model` / `effort` を `adapter-claude` がそのまま子の argv（`--model` / `--effort`）へ渡すだけで
ある。コメントにも「`model-fitness-check` の contract が決めるものであって routing 判断ではないので、
capability を名前で指定する」と明記されている。**したがって tier → capability の対応付けは
呼び出し側＝本 skill の責務**であり、既定任せにすると全 tier が large 用の設定で走り、trivial/small の
子まで quota を無駄に食う。

**trivial/small を standard へ切り上げるのは、子が `pr-workflow` を全長走らせるからである。**
レビューの統合・裁定を必ず通るので、tier に関わらず §4 の 1 行目 floor（Opus @ high）に掛かる。
切り上げは `pr-workflow` の round-up default と同じ向きの扱いであって、tier 判定の放棄ではない。

**具体的な model / effort を skill に書かない理由**: 値の SSOT は
`~/.config/frontier-harness/config.json`（capability registry）と `/model-fitness-check` の contract の
2 つで、本 skill はその対応名だけを持つ。**再掲すると 3 箇所目の drift 源になる。**

**新しい capability 名は対象リポジトリの manifest 承認が要る**（Phase 0 の儀式と同じ）。未承認なら
`fh session` は子を起こさず exit 2 で終わるので、**そこで気付ける** —— 静かに既定へ落ちることはない。

## `--profile` がこの経路で運べない機序

子は PATH から `claude` を解決し、そのランチャーは継承した `CLAUDE_CONFIG_DIR` を保持するので、
**子は必ず親と同じ account で走る**。親と異なる profile を指定されたとき黙って親の account で
起動しないのは、**業務を別区分のアカウントで走らせることに直結する**からである。

capability 側に `accountScope` を宣言して固定する経路が成立するのは、`checkCapabilityExecutable` が
それを**実行直前に強制する**ため。

## 子の stderr を永続化しない理由

`fh` 自身が書くのはイベントの型名だけだが、**子の生の stderr はそのまま継承される**（人が覗く窓を
保つための意図的な設計）。その中身は実測されていないので、**会話内容を含みうる前提で扱う**。
ペインで覗くのはよいが、`> child.log 2>&1` のようにリダイレクトして永続化すると、それが
「記録に会話内容を残さない」を外側から破る経路になる。

## 起動フラグを手で組み立てない理由

事前遮断（`--setting-sources user` / `--strict-mcp-config`）と承認チャネルの配線は `fh` が
sealed invocation として組み立て、**揃っていない argv は組み立て自体が拒否される**。手で書くと、
その保証の外に出る。

## ワークツリーが承認境界である機序

Phase 0 の承認はリポジトリ単位ではなく**ワークツリー単位**である。main で 1 度通しても linked
worktree からの `fh session launch` は exit 2 で止まる（子は 1 本も起きない。fail-closed は正しく
効いている）。manifest・承認 scope・state は `--worktree` から解決されるので、別リポジトリを指せば
「そのリポジトリの承認」が問われる（呼び出し元の cwd の承認では通らない）。

**`.harness/policy.json` をコピーしても通らない。設計上そうなっている。** 有効な承認はポインタが
持ち、それは **policy の絶対パスをキーに引かれる**（`session-command.mjs` が `repositoryRoot` を
`--worktree` そのものに取り、policy は `<そのパス>/.harness/policy.json` に解決される）。
コピーで通るようにすると、**過去に承認した内容へ policy を差し戻すだけで承認が復活する** ——
それを防ぐための形なので、近道は塞がっているのが正しい。台帳の scope 自体は
`<gitCommonDir>/frontier-harness` で main と共有されており、**共有されないのはポインタだけ**である。

**承認しても `fh gaps` は掃けない。** queue を消すのは `--from-gaps` の経路だけである
（`onboard-commands.mjs` の `if (fromGaps) gapQueue.clear(...)`）。`--manifest` で承認しても gap は
残るので、**「gap が残っている＝未承認」と読まない**。承認の有無は `fh session` が通るかで見る。

**新しいワークツリーで `--from-gaps` を使わない理由**: 候補は
`candidateFromGaps(approved.manifest, gaps)` で組まれるが、そのワークツリーの `approved.manifest` は
（ポインタが無いので）**空**である。gap に載っているものだけの候補になり、**既存の承認済み
capability が落ちる**。

## 依存を orchestrator 側で先に入れる理由

子は sandbox 下で走るため、依存のインストールを完走できないことがある —— [実測] `pnpm install` が、
依存パッケージの同梱する `.gitmodules` という**ファイル名**への書き込みで拒否され、4 ワークツリー
すべてで node_modules が未完のまま残った（cwd 内のどこであれ同名ファイルは書けない）。これは `fh` の
規則ではなく **Claude Code の sandbox 側の保護**なので、**子の側では回避できない**。

子に入れさせて失敗すると、その子は「環境が壊れている」ところから始まり、原因の切り分けに turn を
費やしたうえで本来の作業に届かない。

## 起動と監視の arm を分けてはいけない理由

分けて書くと、**「子は走っているが監視は無い」という状態が手順の途中に正当に存在してしまう**。
子は非同期に承認を投げてくるので、その隙間に投げられた要求は誰にも届かない —— [実測] 同じ wave で
2 回踏んだ。1 回目は arm したが jq が沈黙して壊れており **42 分**放置。2 回目は resume 後に
**arm し直さなかった**。どちらも user の指摘で発覚しており、**user から見た症状は同じ**
（「進捗が来ない」）。

**「報告します」と書く前に、報告経路が存在することを確かめる。** 上の 2 回はいずれも、報告を
約束した時点で報告経路が無かった。検知器の故障と張り忘れは原因が違うが症状が同じなので、
**宣言時点の自己点検が唯一の共通の防壁**になる。

同じことは `fh session resume` にも要る（[`resume-and-teardown.md`](resume-and-teardown.md)）。
resume も「子が走り出す」操作である。
