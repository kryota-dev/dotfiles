---
name: model-fitness-check
description: |
  現在のセッションの model / effort が、実行しようとしている作業の §4 contract を満たすかを検出し、満たさなければ実装・レビュー実行に入る前に停止する共有ゲート。skill はセッションの model / effort を変更できない（`/model` `/effort` は user のみ）ため、「検出 → 提案 → 停止」を担う。
  `pr-workflow` / `sdd` / `multi-review` が各 entry から呼ぶ。contract テーブルはこの skill が唯一の SSOT。
argument-hint: "<work tier>（例: orchestration / large / trivial-small）"
---

# model-fitness-check

セッションの model / effort が作業の要求水準（§4 contract）を満たすかを検査し、満たさない場合は**実装・レビュー実行に入る前に停止**して user に切り替えを提案する共有ゲート。

## SSOT としての位置づけ

**§4 contract テーブルはこの skill が唯一の SSOT**。`pr-workflow` / `sdd` / `multi-review` はこのテーブルを複製せず、各 entry から本 skill を 1 行で呼ぶだけにする（複製すると Codex pin が 3 箇所で drift した失敗を Claude 側で再演することになる）。

## Frontier Harness への段階移行（AC-034 compatibility shim）

`frontier-harness` は route の readiness を `/execution-readiness-check` で確認する。これは
**adapter capability・account scope・rollout・permission manifest** を見る gate であり、
**セッション自身の model / effort floor は判定しない**（`execution-readiness-check` 本文が
「current session が特定 model かどうかを判定しない」と明言している）。両者は**直交する**ため、
片方が他方を代替しない。

### shim 契約（移行期間中の挙動）

本 skill は 2 release の間、`execution-readiness-check` を呼ぶ compatibility shim として振る舞う。
すなわち **本 skill が起動されたら、§4 の floor 判定に加えて
`/execution-readiness-check <呼び出し元の task / review context>` も起動する**（同一セッションで
既に起動済みなら再起動しない —— 「idempotency」節と同じ扱い）。これにより `wave-orchestrator` や
user の直接起動といった legacy invocation でも readiness gate が働く。

### 移行期間中の呼び出し側の責務

`pr-workflow` / `sdd` / `multi-review` は、移行期間中 **両方の gate を明示的に呼ぶ**。floor 判定を
readiness gate で置き換えてはならない —— それは blocking gate の静かな無効化であり、
`wave-orchestrator` が名指しで禁じている退行そのものになる。

### 削除条件

全 legacy caller が `/execution-readiness-check` を直接呼ぶよう移行し、pilot telemetry が
十分に蓄積されるまで、この §4 contract と over-provision gate を削除・弱体化してはならない。
shim の撤去は、その条件が満たされたことを確認したうえで別 PR で行う。

## §4 contract（Model/effort テーブル）

テーブルが規定するのは**セッション自身**の model / effort であり、**委譲先 worker の tier は各 agent 定義の frontmatter が SSOT**（例: adversarial verification 行は「その作業を主導するセッション」に Opus @ xhigh を要求するのであって、`adversarial-verifier` agent が Opus であるべきという意味ではない）。

| 作業 | Model | Effort | 行種別 |
|------|-------|--------|--------|
| `pr-workflow` の分類 / GATE / 統合; `sdd` Phase 1–3 の spec 執筆; `multi-review` の統合・裁定 | Opus | high（既定。ゲートは言及しない） | **floor**（blocking） |
| large tier / PRD 審議 / adversarial verification / 横断設計 | Opus | xhigh | **floor**（blocking） |
| trivial / small tier のみ | Sonnet | high | **cost hint**（non-blocking FYI） |
| Fable-orchestrator セッション（`cldf` 系） | Fable | セッション既定 | floor 判定は常に pass（monotonic ルール）。over-provision 閾値ゲートは適用 |

### 行の優先順位（tier が trivial/small のとき）

**1 行目と 3 行目は同時に当たりうる。** `pr-workflow` セッションは tier に関係なく分類 / GATE / 統合を
行うので 1 行目に該当し、その tier が trivial/small なら 3 行目にも該当する。**このときは 3 行目が勝つ**
——そう読まないと 3 行目は `pr-workflow` セッションに対して永久に発火せず、行そのものが死ぬ。

したがって 1 行目の floor が実際に効くのは、**tier が standard 以上のセッション**と、tier の概念を持たない
`sdd` Phase 1–3 / `multi-review` の統合・裁定である。

この優先順位は**機械的な tier →（model, effort）写像が成立するために必要**である。`wave-orchestrator` は
これに基づいて子セッションの capability を選ぶ（`session.child.small` / `session.child.standard` /
`session.child`）ので、ここが曖昧なままだと選択が実装者ごとにぶれる。

## capability 順序（monotonic）

能力順序を **Fable > Opus > Sonnet > Haiku** と定義する。同一 family 内では **generation が効く**。

判定は **2 パス**で構成する（詳細は「判定と出力」）。**floor パス（上方向）を通過しても判定は終わらず、必ず over-provision パス（下方向）に進む**——ここが over-provision ゲートに到達する唯一の経路なので、floor パスを「無条件 silent pass」で早期 return してはならない:

1. **floor パス**: 「現在の tier ≥ 行が要求する tier」なら floor をパスする（floor の switch 提案は出さず、プロンプトも出さない）。下回る場合のみ floor 行で blocking する。
2. **over-provision パス**: floor 通過後、「現在の tier が行の要求より上位（過剰）」かつ trivial/small なら、FYI + カウンタ + 閾値ゲートに進む（「over-provision 閾値ゲート」）。floor と要求が同 tier（過剰でない）なら何もせず終了する。

- **Fable / cldf セッションは floor 行（上方向）の switch 提案を受けない**。Fable は全 floor の要求を満たす（monotonic の最上位）うえ、`fable-orchestrator-prompt.md` で独自の委譲契約を持つため、Opus 契約に合わせる上方向の提案は構造的に矛盾する。下方向（過剰スペックの解消）は over-provision パスの対象で、**Fable セッションも免除されない**。
- over-provisioning（Fable で trivial をこなす等）は毎回は停止しないが、累積が閾値を超えたら 1 回だけ blocking する（「over-provision 閾値ゲート」参照）。cldf でも exit → profile に応じた `cld` / `cld-r06` の `--continue` で orchestrator 契約ごと降りられるため、「是正不能」ではない。

## model の検出

1. **主経路**: セッションの system-prompt に埋め込まれた model identity（自己申告。「You are powered by ...」等）を読む。
   **主経路が Fable と解決したら、副経路の cross-check はスキップする**（floor 判定を pass にするだけで、判定は終了せず over-provision パスに進む —— Fable も over-provision ゲートの対象だから）。`cldf` 系は `--model claude-fable-5` を argv で渡す（`home/dot_config/zsh/claude.zsh` の `_claude_fable`）ため settings.json とは**構造的に必ず乖離**し、cross-check は常に偽陽性になる。
2. **副経路（cross-check）**: **主経路が Fable 以外のときのみ実行する**。`~/.claude/settings.json` の `model` を Read で読む（`cld-r06` セッションでも同じパスでよい —— `~/.claude-r06/settings.json` は `~/.claude/settings.json` への symlink であり、両アカウントは 1 つの settings.json を共有する。chezmoi source: `dot_claude-r06/symlink_settings.json.tmpl`）。これは `/model` によるセッション内変更を反映しない可能性があるため、**主経路と乖離したら silent に解決せず surface する**（どちらが有効かを user に提示して確認）。

### 正規化ルール

- `[1m]` などの context-window suffix を除去してから比較する。
- alias（`opus` / `sonnet` / `haiku` / `fable`）を現行 generation に解決する。
- **family + generation** で比較する。
- 判定不能な unknown 文字列は **fail-safe**（silent pass せず、チェックを提示する）。

## effort の検出

このセッションの effort: ${CLAUDE_EFFORT}

直上の 1 行が、この skill における**唯一の展開箇所**である。Claude Code は skill 本文のテキストに対して実行時に文字列置換を行い、`${...}` 形式のプレースホルダをセッションの値へ置き換える。以降の本文では波括弧を省いて `CLAUDE_EFFORT` と表記する —— **リテラルで書くと解説文の中でも展開されてしまい、文が意味を失う**（実機検証で確認済み）。展開される値は effort レベル文字列（`low` / `medium` / `high` / `xhigh` 等）で、`CLAUDE_SESSION_ID` / `CLAUDE_SKILL_DIR` / `CLAUDE_PROJECT_DIR` も同様に展開される。一方 `CLAUDE_PID` は**展開されずリテラルのまま残る**（実測）。これは Bash の環境変数ではなく**skill 本文限定のテンプレート展開**であり、子プロセス（Bash tool 経由のシェル等）からは読めない（`echo $CLAUDE_EFFORT` は空になる）。

**丸めの制約**: 展開を行う実装は、解決できない値を黙って `high` に丸める（`typeof e==="string") return x(e) ? e : "high"; return "high"`）。そのため `CLAUDE_EFFORT` が `high` を返したとき、「本当に high」と「解決できずに丸められた」を**区別できない**。この制約は判定に反映する:

- **high を要求する行**で `CLAUDE_EFFORT` が `high` のとき: pass 扱いでよい（丸めの結果でも実際の high でも要求は満たされる）。
- **xhigh を要求する行**で `CLAUDE_EFFORT` が `high` のとき: 乖離を断言せず、「xhigh か、検出できず high に丸められたか」を user に確認する（fail-safe。silent に mismatch とも pass とも決めつけない）。

## 判定と出力

判定は capability 節の 2 パス（floor → over-provision）に沿って進む。**floor パスが pass でもそこで終了せず、over-provision パスに進む**（これがゲートに到達する唯一の経路）。作業の行種別に応じて次のように分岐する:

### floor 行（Opus @ high / Opus @ xhigh）で mismatch

`AskUserQuestion` で **blocking** し、次の 4 択を提示する:

1. **すでに要求水準を満たしている（変更不要）**: 検出が誤りで、実際には現在の model / effort が要求を満たしている場合に選ぶ。選択後は switch 提案を出さず、そのまま進める。
2. **switch して再実行**: literal な切り替えコマンドを表示する（例: `/model opus`、xhigh 行なら加えて `/effort xhigh`）。user が切り替えてから再開。
3. **continue anyway**: 検出通り不足している前提で、このまま進む。
4. **abort**: 作業を中止する。

選択肢 1 は実運用で「検出が誤りで、実際には要求水準を満たしていた」ケースが起き、提示された 3 択（switch / continue anyway / abort）のどれも正解でなかったために追加した。

- **effort は xhigh を要求する行でのみ言及する**。既定 high で足りる行では effort に一切触れない（`/effort` コマンドも出さない）。
- effort は `CLAUDE_EFFORT`（「effort の検出」参照）から読む。ただし xhigh 要求行で `CLAUDE_EFFORT` が `high` の場合、丸めの制約により「本当に high」と「解決できなかった」を区別できないため、乖離を断言せず**提示して確認する**（silent に mismatch と決めつけない）。

### trivial / small 行

この行は over-provision パスの本体（現在 tier > 要求 tier の過剰ケース）。**non-blocking の一行 FYI** に留める。「trivial/small tier は Sonnet で十分（現在より下げればコストが浮く）」程度の cost hint を出すだけで、**workflow を止めない**。trivial/small は分類が実行前に終わらないため、ここで停止させると軽い path の摩擦を最大化する。

FYI を出すたびに over-provision カウンタを +1 する（「over-provision 閾値ゲート」参照）。毎回の FYI は non-blocking のまま維持し、blocking は閾値超過時の 1 回に限定する。

### 検出不能時の fallback

model 検出が主経路・副経路とも失敗した場合、**silent skip せず**、常にチェック内容（要求水準と現在の不確実性）を提示する（fail-safe）。

## over-provision 閾値ゲート

trivial/small の毎回 FYI とは別に、**過剰スペックの累積**を「カウンタ × 実測 quota 圧力」の 2 シグナルで監視し、閾値超過時のみ 1 回 blocking する。サブスクリプション（Max / Team）では over-provision の実害は金額ではなく **quota（全モデル共有プール）のクラウドアウト**——Fable / Opus で軽作業を続けると、重作業に必要な quota が先に尽きる——なので、圧力シグナルと組み合わせ、quota に余裕がある間は止めない（alert fatigue の回避。blocking の希少性が floor 停止の信頼性を支える）。

### シグナル 1: over-provision カウンタ（セッション内）

- 「現在の tier が行の要求より上位」と判定するたび（trivial/small FYI を出すたび）にカウンタを +1 する。
- セッション内でのみ保持する（永続化しない）。**floor 判定の idempotency とは別カウンタ**（idempotency は同一判定の再提示の抑制、本カウンタは累積の検出で、性質が逆）。
- ゲート発火時、および continue anyway 選択時にリセットする。
- **compaction 対策**: カウンタを会話記憶だけに置くと context compaction で黙って 0 に戻り、特に red 帯（2 件）でゲートが実質死ぬ。カウンタを更新するたびに現在値を可視な形で残し（例: FYI 行末に `[over-provision: N]`）、compaction 後はその最新値を継承する。idempotency（二値の pass/continue-anyway）より復元が難しいため、この明示記録が必要。

### シグナル 2: 実測 quota 圧力（statusline snapshot）

`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate_limits_<profile>.json` を Read する（statusline が stdin の `rate_limits` を書き出す snapshot。**パスは writer と同じ XDG フォールバック式で解決し、`~/.cache` 決め打ちにしない** —— `XDG_CACHE_HOME` を設定した環境で誤って「snapshot 無し」と誤判定しないため。`<profile>` は `CLAUDE_CONFIG_DIR` の basename、既定 `.claude`）。**圧力値は `five_hour` と `seven_day` の `used_percentage` の大きい方（`max(5h, 7d)`）を使う**——ゲートが framing する harm は週次共有プールのクラウドアウト（`seven_day`）だが、短期バースト枯渇（`five_hour`）も捕捉したいので、圧力の高い方で発火判定する。片方のウィンドウが欠落していれば残る一方を使う。

- **staleness / 欠損ガード**: 次のいずれかで quota 不明として count-only fallback（下表）に切り替える —— (a) ファイルが無い、(b) `ts` が 15 分より古い、(c) `five_hour` と `seven_day` の `used_percentage` が**どちらも**欠落・非数値（writer は無効なウィンドウを省くため、fresh でも片方だけ／両方無いことがある）。**片方でも有効なら count-only にせず、有効な側の値で圧力を評価する**。silent skip はしない（fail-safe）。
- **Team プランの rate_limits（`cld-r06` で live 検証済み）**: 公式ドキュメント（`code.claude.com/docs/en/statusline`）は `rate_limits` を「Claude.ai subscribers (Pro/Max) が最初の API 応答後」にのみ現れると明記し Team / Enterprise を列挙しない。しかし **`cld-r06`（Team premium seat）の実 stdin では `five_hour` / `seven_day` とも populate されることを実機確認済み**（docs の Pro/Max-only 列挙は Team premium に対して不完全）。よって cld-r06 でもシグナル 2（実測圧力）は利用可能で、yellow/red 帯に到達する（count-only 固定ではない）。count-only fallback は真の欠損時——最初の API 応答前・stale snapshot・両ウィンドウ欠落（docs: 各ウィンドウは独立に absent になりうる）——のための fallback として維持する。

### 発火条件（named constants）

帯域は statusline `pct_color` の色閾値（50 / 80）と一致させる:

| 圧力 = max(5h, 7d) | 帯域 | 発火閾値（カウンタ） |
|---|---|---|
| < 50 | green | 発火しない（FYI のみ） |
| 50–79 | yellow | `OVERPROVISION_GATE_YELLOW = 5` 件 |
| ≥ 80 | red | `OVERPROVISION_GATE_RED = 2` 件 |
| snapshot 無し / stale / 両窓欠落 | 不明 | `OVERPROVISION_GATE_FALLBACK = 5` 件（count-only） |

### 発火時の提示（`AskUserQuestion` で 1 回 blocking）

文面には snapshot の実測値をそのまま載せ、**帯域を決めたウィンドウ（5h / 7d のうち圧力の高い方）を明示する**（例: 「7d ウィンドウ 63% 消費（↻07/30 07:00 リセット）。直近 5 件は Sonnet で足りる軽作業でした。このペースだと重作業の前に週次上限に当たる見込みです」）。選択肢はセッション種別で分岐する:

- **cld 系（通常セッション）**:
  1. `/model sonnet` に下げて続行（推奨）
  2. continue anyway（カウンタをリセットし、次の閾値まで沈黙）
  3. abort
- **cldf 系（Fable orchestrator）**:
  1. exit → profile に応じた `cld` / `cld-r06` で `--continue` 再開（推奨。orchestrator prompt は argv 注入のため再起動で契約ごと降りられ、会話文脈は保持される）。**アカウントを取り違えない**: `cldf-r06`（`CLAUDE_CONFIG_DIR` が `*.claude-r06`）なら `cld-r06 --continue`、それ以外は `cld --continue`。両アカウントはセッション状態が分離しており、誤ると無関係な default セッションを再開してしまう
  2. `/model opus` 等でセッション内切替（**注記必須**: system-prompt の自己申告 model identity が古い値を残すため、以後の本 skill の主経路検出を信用せず、切替済みであることをセッション内に記録する）
  3. continue anyway（カウンタをリセット）

このゲートは **Fable / cldf セッションにも適用される**（floor 免除は上方向の switch 提案に限る）。

## 呼び出し規約

**行種別は引数で受け取る**（`/model-fitness-check <tier>`）。判定は行種別ごとに分岐するため、呼び出し側の散文ではなく引数で確定させる。

- `pr-workflow`: Phase 0 冒頭 —— `/model-fitness-check <tier>`（Phase 0 の分類結果をそのまま渡す）
- `sdd`: Phase 0 冒頭 —— `/model-fitness-check orchestration`（large 相当なら `large`）
- `multi-review`: Phase 1 の前 —— `/model-fitness-check orchestration`（`multi-review` に Phase 0 は無い）

各 skill は本 skill を呼ぶ 1 行を持つのみで、**§4 テーブルも行種別の説明も再掲しない**。

**idempotency（多重起動の抑制）**: `pr-workflow` → `sdd` → `multi-review` と連鎖すると 1 実行で最大 3 回同じ判定が走る。**同一セッションで一度 pass した行、および明示的に continue-anyway を選んだ行については再提示しない**（前回の判断を再利用する）。model / effort が変更された形跡があるときのみ再評価する。
