# model-fitness-check: effort floor の根拠

これは**根拠**である。守るべきこと（規範）は [`../SKILL.md`](../SKILL.md) が持つ。ここにあるのは
その規範がなぜその形なのか —— 一次ソースの原文と、確認できたことと**確認できなかったこと**の境界 ——
で、**contract を疑う / 書き換える / 契約が想定していない状況に出たときに読む**。

対応する規範: `SKILL.md`「§4 contract（Model/effort テーブル）」「各行の根拠」。

調査日: **2026-09-03**（#629）。以降の日付表記はすべてこの日の確認を指す。

## 結論から

**行を分ける軸は「user と対話するか」である。**

| 行 | 対話 | 主根拠 |
|---|---|---|
| large tier / adversarial verification | しない（子セッション） | 公式 docs の xhigh 適用条件（long-horizon） |
| 横断設計 / PRD 審議 | する | user の実地観察 |

論点だった旧 xhigh 行はこの 4 項目を 1 行に束ねていた。**束ねたままでは、実地で観察された事実
（対話は medium が良い）と、docs が示す条件（30 分超の自律実行には xhigh）を同時に満たせない。**
束を解いたのが今回の変更である。

**FrontierCode 1.1 の数値は、どの行の根拠にも使っていない。** 参考資料として下記に記録する。

## 一次ソース: 公式 effort ガイダンス

https://platform.claude.com/docs/en/build-with-claude/effort

**effort の 5 段階と xhigh の定義**（`Effort levels` 表より）:

> `xhigh` — Extended capability for long-horizon work. …
> Typical use case: **Long-running agentic and coding tasks (over 30 minutes) with token budgets in the millions**

**モデル別の推奨開始点**:

| モデル | 原文 |
|---|---|
| Claude Opus 5 | "**Start with `high`, the default**, and adjust based on your evals: step up to `xhigh` for demanding coding and agentic work, or to `max` when a task justifies unconstrained token spending, and use `low` and `medium` liberally as your primary control for token cost and response time **wherever your evals show quality holds**." |
| Claude Fable 5.1 | "**Start with `high`, the default.** Step up to `xhigh` or `max` for the most capability-sensitive agentic and coding work, and step down to `medium` or `low` for routine or latency-sensitive work **once your evals show quality holds**." |
| Claude Sonnet 5 | "Claude Sonnet 5 **defaults to `high` effort** on the Claude API and Claude Code." / "**Xhigh effort:** For the hardest coding and agentic tasks." |
| Claude Opus 4.8 | "**Start with `xhigh` for coding and agentic use cases**, use `high` for most other intelligence-sensitive workloads…" |
| Claude Opus 4.7 | "**Start with `xhigh` for coding and agentic use cases**, and use `high` as the minimum for most intelligence-sensitive workloads." |

**確認できたこと**: **xhigh 開始を勧めているのは Opus 4.7 / 4.8 だけ**である。Opus 5・Fable 5.1・
Sonnet 5 はいずれも `high` が開始点で、xhigh は step-up として位置づけられている。

**持ち越しの禁止**（Opus 5 の節）:

> "**If you carried effort settings over from an earlier model, run a fresh effort sweep on your evals rather than reusing them.**"

旧 contract の xhigh floor は PRD 330（`.claude/prds/330-model-tier-codex-permissions.prd.md`、
user 承認 2026-07-25）で Opus 4.7 / 4.8 世代の運用から引かれたもので、**この記述が名指しする
「持ち越し」に該当する**。ただし公式が指定する調整手段は **eval sweep の実走**であり、それは
コスト理由で見送ると user が判断した。**したがって「公式に従って調整する」経路は塞がっている。**

この塞がりが、行を分ける方針を選ばせている。**数値による調整はできないが、docs 自身の定性的基準
（30 分超の long-horizon か）で行を分けることは sweep 無しでも成立する。**

**読みやすさについて**（Opus 5 の節）:

> "Effort controls thinking volume, not visible response length: on Claude Opus 5, **changing effort does not reliably shorten responses**, so prompt for length instead."

→ effort を下げても回答は短くならない。**回答の長さは prompt 側の担保**であり、floor の仕事ではない。

## 一次ソース: Opus 5 のプロンプトガイド

https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5

- 長時間作業について: "Claude Opus 5 is built for complex agentic coding and enterprise work, with
  **particular strengths in long-horizon agentic tasks**."
- スコープについて: "**Claude Opus 5 can also expand the scope of a task, adding steps that weren't
  requested** or applying its own judgment about what the task should be. For narrow tasks,
  **constrain scope explicitly**" —— 対処手段として prompt の実例が提示されている。
- レビューについて: "**Accuracy holds at lower effort settings**, which supports a fast pass at review
  time and a more thorough pass later."
- 委譲について: "Claude Opus 5 **delegates to subagents more readily than prior models**. Delegation
  pays off on genuinely independent, sizeable tracks of work, but it multiplies cost and time when
  applied to small tasks."

スコープ逸脱が**モデルの実在の特性として公式に認められている**点に注意する。後述の FrontierCode の
順位を読むとき、これは「ベンチマーク側の都合」だけでは片付かないことを意味する。

## FrontierCode 1.1 を参考資料に留めた理由

出典: https://cognition.com/frontiercode 、https://cognition.com/blog/frontier-code-1.1

### 到達できなかった経路（記録）

**このセッションからは effort 別の数値に到達できなかった。** 経路と結果を残す —— 同じ調査を繰り返す
コストを避けるためと、「到達したうえで棄却した」のではないことを明示するため。

| 経路 | 結果 |
|---|---|
| `cognition.com/frontiercode` | 本文は取得できるが leaderboard 部分は `Loading leaderboard…` のみ。モデル名・effort・スコアのいずれも DOM に無い（JS で後から取得） |
| `cognition.com/blog/frontier-code-1.1` | 1.1 の変更点は取得できるが **effort 別スコア表が本文に無い** |
| X（該当スレッド） | HTTP 402 |
| 解説記事（sitepoint） | HTTP 403 |
| llm-stats の同 leaderboard | 16 行取得できるが **effort 列が存在しない** |

**数値は orchestrator が Chrome の対話ビュー（All reasoning levels）で取得した観測である。**
本セッションの WebFetch 経路では再現できない。

### 数値（orchestrator 観測、2026-09-03）

| モデル | 順位 |
|---|---|
| Opus 5 | medium 53.4% > high 48.0% = max 48.0% > **xhigh 43.6%** > low 41.9%（flag rate: medium 0.6% → xhigh 1.4%） |
| Fable 5.1 | medium 50.9% > high 50.3% = max 50.3% > low 49.8% > **xhigh 48.7%** |
| Sonnet 5 | xhigh 42.7% > max 42.4% > high 39.4% > medium 35.2% > low 28.7% |

### 非単調性が説明できない（降格の理由）

Opus 5 と Fable 5.1 は **`max` が `high` と同点で、`xhigh` だけが凹む**。

「effort が高いほどスコープ外の変更をして減点される」という説を採ると、**`max` は最下位付近に来る
はずである**。実際には来ない。flag rate は medium 0.6% → xhigh 1.4% とスコープ減点自体は effort と
ともに増えているのに、max の凹みが無い。**この形を説明できる仮説を、一次ソースからは立てられなかった。**

**説明のつかない順位を blocking gate の根拠にはできない。** よって参考資料に留める。

ただし **Sonnet 5 は単調に xhigh が最良**で、これは公式が Sonnet 5 の xhigh を "For the hardest
coding and agentic tasks" とすることと整合する。`home/dot_claude/agents/` のレビュー系 agent
（`cc-code-review` / `cc-security-review` / `adversarial-verifier`）の `model: sonnet` +
`effort: xhigh` pin は、**この 1 点で裏づけられる**ため維持する。

### 指標特性の解釈分岐（検討の記録）

FrontierCode は mergeability 評価で、スコープ外の変更を減点する。したがって順位は 2 通りに読める:

- **解釈 A「medium のほうが賢い」** —— 能力の順位。floor を下げる根拠になりうる。
- **解釈 B「medium のほうが余計なことをしない」** —— スコープ規律の順位。**floor の根拠にならない**
  （下げるべきは effort ではなく、スコープを縛る prompt になる）。

解釈 B を支持する材料:

- Cognition の Cheng-Yuan (Sam) Lee は、Opus 5 のスコアが effort とともに下がることについて
  "the behavior is **expected under the benchmark design**"、"One such verifier is a **scope
  criterion**, which penalizes modifications to the codebase beyond what the task requires"、
  "We observe this effect **across all frontier models we evaluate**" と述べている
  （全 frontier model に効く = 指標側の性質）。
- edison は "the FrontierCode 'scope' score was **penalizing Opus 5 for making changes unrelated to
  the task**" と、減点対象がスコープであって能力ではないことを特定している。
- Anthropic 公式も Opus 5 のスコープ拡大を認め、対処を **prompt** に置いている（前節）。
- 同ベンチの議論で "despite **increasing performance with effort on other evals**" と言及されており、
  逆転が FrontierCode に固有であることが示唆される。

**それでも解釈 B に確定できない。** 解釈 B は「effort が高いほどスコープを外れる」を含意するが、それ
なら `max` が `high` と同点である説明がつかない。**解釈 A と B のどちらでも `max` の位置を説明できず、
この分岐は未決着のまま残る。** 決着していない解釈を floor の根拠に使わない、というのが今回の判断である。

**加えて、タスク形状が contract と一致しない。** FrontierCode は「1 タスク = 1 PR を書く」評価で、
スコープ規律が採点軸になる。一方 §4 の floor 行が縛るのは orchestration の主導セッション（分類・
GATE・統合・裁定・設計判断・PRD 審議）で、**「コードベースを余計に触る」機序が適用される作業ではない**。
順位をそのまま contract に持ち込むこと自体が、指標の一般化にあたる。

## 主根拠: user の実地観察（横断設計 / PRD 審議 の行）

**user 本人の発言**（伝聞ではない）:

- Opus 5 @ effort **medium** のセッションは**会話しやすい**。
- effort **xhigh** に設定したセッションで `wave-orchestrator` 等を回すと、**回答内容が複雑化し、
  議論したくても理解しがたい回答が返ってくると感じる場面が多い**。**その度に噛み砕かせている。**

**観察の射程を正確に扱う。** 観察の対象は **user と対話するセッション**である。contract で言えば
**横断設計 / PRD 審議**の行そのもの。一方 **large tier の子セッションは user と会話しない**ので
射程外であり、adversarial verification も同様。**論点の 4 項目のうち、切り分けが問題になっている側
だけを user が実地で評価した形になっている。**

だから対話行は medium、子セッション行は docs の定性基準で xhigh、という非対称な決着になった。

### 交絡（断定しない）

**xhigh のセッションには難しい仕事を割り当てがちなので、複雑さが effort ではなく課題由来である
可能性は残る。** 観察は無作為割付ではない。

ただし **「その度に噛み砕かせている」という反復パターンは、課題ごとのばらつきより設定由来の傾向を
示唆する**（課題由来なら、難しい課題のときだけ起きるはずで、毎回にはなりにくい）。

**この交絡は解消されていない。** 観察を主根拠に据えたうえで、交絡が残ることを contract の判断材料
として明示する。将来 sweep を実走するなら、ここが最初に潰すべき点である。

### 読みやすさは floor では買えない

公式が "changing effort does not reliably shorten responses, so prompt for length instead" と述べる
とおり、**effort を下げても回答は短くならない**。user が感じている差が「長さ」ではなく「密度・
込み入り方」なら観察と矛盾しないが、**長さの面は prompt 側の担保が要る**。

したがって **floor を medium に下げたことで読みにくさが解決するとは考えない**。floor は下限なので
xhigh のセッションは依然として monotonic に pass する（止まらない）。**この行を下げた効果は
「medium のセッションが止められなくなる」ことであって、「xhigh のセッションを止める」ことではない。**

## contract が運用と合っていなかった実例

**#629 を起票し、この作業を差配した orchestrator セッションは Opus 5 @ medium で走っており、
変更前の §4 contract の floor 行 2 本のどちらも下回っていた。**

contract に忠実であれば、**そのセッションは `wave-orchestrator` を回す前に blocking され、停止させ
られていたはずである。** 実際には停止せず、しかも **user にとって最も議論しやすいセッションだった。**

**この 1 件が、契約の切り方が実際の運用と合っていないことを直接示している。** 「floor を割る誤りだけが
gate を静かに弱める」という fail-safe 原則（PRD 537 判断 #6）は正しいが、**floor が実運用より高い
位置にあると、原則が守るべき対象そのもの（実際に良い仕事をしているセッション）を止めにかかる**。
gate の信頼性は blocking の希少性が支えているので、これは gate 自身を蝕む。

## 変更しなかったもの

- **`~/.config/frontier-harness/config.json`（chezmoi source: `home/dot_config/frontier-harness/config.json`）は変更していない。** `session.child` = Opus @ xhigh は
  large tier の子に、`session.child.standard` = Opus @ high はそれ以外に割り当てられており
  （`wave-orchestrator/SKILL.md`「capability を tier で選ぶ」）、**新 contract はこの割り当てと矛盾
  しない**。横断設計 / PRD 審議は user と対話する作業で、`fh session launch` で起こす子セッションの
  仕事ではないため、medium 行は capability registry に対応物を必要としない。
- **`home/dot_claude/settings.json` の `effortLevel: "xhigh"` も変更していない。** これは user の
  standing preference（PRD 330 AC-014、user 承認 2026-07-25）であって contract の floor ではない。
  floor が下がっても session 既定が下がるわけではなく、**両者は独立**である。
- **レビュー系 agent の `effort: xhigh` frontmatter も変更していない**（前述のとおり Sonnet 5 の
  単調性で裏づけられる）。
