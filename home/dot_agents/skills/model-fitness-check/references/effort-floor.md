# model-fitness-check: effort floor の根拠

これは**根拠**である。守るべきこと（規範）は [`../SKILL.md`](../SKILL.md) が持つ。ここにあるのは
その規範がなぜその形なのか —— 一次ソースの原文と、確認できたことと**確認できなかったこと**の境界 ——
で、**contract を疑う / 書き換える / 契約が想定していない状況に出たときに読む**。

対応する規範: `SKILL.md`「§4 contract（Model/effort テーブル）」「各行の根拠」。

調査日: **2026-09-03**（#629）。以降の日付表記はすべてこの日の確認を指す。

## 結論から

**行を分ける軸は「その作業がどれだけ自律的に走るか」である。** floor は作業の重要度ではなく、
**判断を誤ったときの受け皿が実行中に存在するか**で決める。

| 行 | 実行中の受け皿 | 主根拠 |
|---|---|---|
| large tier / adversarial verification | **無い**（誰も見ていない場所で 30 分以上走る） | 公式 docs の xhigh 適用条件（long-horizon） |
| 横断設計 / PRD 審議 | **有る**（人がループ内にいて、その場で差し戻せる） | 構造的な非対称 + 本リポジトリの運用実績（下記） |

論点だった旧 xhigh 行はこの 4 項目を 1 行に束ねていた。**束ねたままでは、受け皿の有無という構造的な
差を契約に表現できない。** 束を解いたのが今回の変更である。

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
（30 分超の long-horizon か）と、受け皿の有無という構造的な差で行を分けることは sweep 無しでも成立する。**

**medium は docs だけでは正当化できない**（重要）。Opus 5 / Fable 5.1 の medium はいずれも
**eval 条件付き**（"wherever your evals show quality holds" / "once your evals show quality holds"）で、
その条件である sweep を見送っている以上、**公式 docs 単独で medium を floor にする根拠は作れない**。
medium 行の水準の出どころは次節に書く。

**出力の長さについて**（Opus 5 の節）:

> "Effort controls thinking volume, not visible response length: on Claude Opus 5, **changing effort does not reliably shorten responses**, so prompt for length instead."

→ effort を下げても回答は短くならない。**出力の長さは prompt 側の担保**であり、floor の仕事ではない。

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

## medium 行の水準はどこから来ているか

**公開できる根拠は 2 つある。順に書く。**

### (a) 構造的な非対称（公開してよい設計判断）

floor は**作業の重要度**ではなく、**その作業がどれだけ自律的に走るか**で決める。

- **横断設計 / PRD 審議**は人がループ内にいる。判断が浅ければ user がその場で気づいて差し戻せるので、
  **実行中に受け皿が存在する**。
- **large tier / adversarial verification** は誰も見ていない場所で 30 分以上走る。**実行中の受け皿が
  無い**ので、事後に PR や CI で拾うしかない。

**この非対称が行を分ける根拠である。** floor は「失敗したときに誰も気づけない作業」ほど高くする、
という向きに揃えた。重要度で揃えると、人が見ている作業にまで高い floor を課すことになる。

### (b) 水準そのものは暫定値で、根拠の一部は公開していない

**medium という具体的な水準は、本リポジトリの運用実績に基づく暫定値である。その詳細は公開していない。**

これは「根拠が無い」という意味ではなく、「**公開していない根拠がある**」という意味である。混同しない
こと。ここに書けるのは次の 3 点までである:

1. **公式 docs だけでは medium を正当化できない。** 推奨開始点は `high` で、medium はその 2 段下。
   docs 上の medium は eval 条件付きで、その条件（sweep）は満たしていない。
2. **FrontierCode の数値も根拠にしていない**（次節の理由による）。
3. したがって **medium は暫定値**であり、**自前の計測が貯まった時点で再検討する**。それが再検討の
   条件であって、それまでは動かさない。

**この節で書けないことを、書けるように見せかけないこと。** 存在しない公開根拠を後から補うのは、
契約の検証可能性を壊す方向の変更にあたる。

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

### 数値（2026-09-03 時点）

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

### 指標特性の解釈分岐（未決着のまま残す）

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
  出典: https://x.com/cl571128/status/2080783750456311836
- edison（@edis0n_zhang）は "We found that Opus 5 actually scores lower on FrontierCode 1.1 in xhigh
  and max reasoning efforts. Our investigation revealed that the FrontierCode 'scope' score was
  **penalizing Opus 5 for making changes unrelated to the task**" と、減点対象がスコープであって
  能力ではないことを特定している。
  出典: https://x.com/edis0n_zhang/status/2080701743097344427
- 同じ現象を扱ったスレッドが "Opus 5 has a better FrontierCode score at medium effort than higher
  effort - **despite increasing performance with effort on other evals**" と述べており、逆転が
  FrontierCode に固有であることが示唆される。
  出典: https://x.com/jerhadf/status/2080806399794163798
- Anthropic 公式も Opus 5 のスコープ拡大を認め、対処を **prompt** に置いている（前節）。

**それでも解釈 B に確定できない。** 解釈 B は「effort が高いほどスコープを外れる」を含意するが、それ
なら `max` が `high` と同点である説明がつかない。**解釈 A と B のどちらでも `max` の位置を説明できず、
この分岐は未決着のまま残る。** 決着していない解釈を floor の根拠に使わない、というのが今回の判断である。

### Claude Opus 5 System Card §8.4 に到達できなかった記録

**この分岐に決着材料がある可能性のある一次ソースとして、Claude Opus 5 System Card の §8.4
（FrontierCode を扱う節）がある。原文には到達できなかった。**

| 経路 | 結果 |
|---|---|
| WebFetch で PDF を直接取得（2 種の URL） | `maxContentLength size of 10485760 exceeded`（取得サイズ上限超過） |
| `curl` で PDF をダウンロード | **sandbox が拒否**（`www-cdn.anthropic.com` が許可ホストに無い） |
| alphaXiv のミラー | §8.4 が存在しない |
| System Card の解説記事（thezvi） | FrontierCode に言及していない |

**したがって §8.4 の原文を引いた判断はしていない。** 検索エンジンの要約は §8.4 の内容に触れていたが、
**要約を一次ソースとして扱わない**（#629 の調査中に一度その誤りを犯して撤回している）。

**この分岐は §8.4 を読めば決着する可能性がある。** 上記いずれかの経路が開いたときに読み、この節を
更新すること。ただし **§4 テーブルの medium / xhigh の割り当ては、§8.4 の内容によっては変えない** ——
FrontierCode はどの行の根拠にも使わないと既に決めており、§8.4 は解釈の記録として扱う。

### タスク形状が contract と一致しない

FrontierCode は「1 タスク = 1 PR を書く」評価で、スコープ規律が採点軸になる。一方 §4 の floor 行が
縛るのは orchestration の主導セッション（分類・GATE・統合・裁定・設計判断・PRD 審議）で、
**「コードベースを余計に触る」機序が適用される作業ではない**。順位をそのまま contract に持ち込むこと
自体が、指標の一般化にあたる。

## floor は下限であって推奨値ではない

**medium 行でも、xhigh のセッションは monotonic に pass する（止まらない）。**

この行を下げた効果は「**medium のセッションが止められなくなる**」ことであって、「xhigh のセッションを
下げさせる」ことではない。下方向の是正は over-provision パスの担当で、そちらは trivial/small 行にしか
掛からない。

出力の長さや密度を変えたいなら effort ではなく prompt で扱う（公式: "prompt for length instead"）。
**gate に prompt の仕事を期待しないこと。**

## floor が実運用より高いときに何が起きるか

「floor を割る誤りだけが gate を静かに弱める」という fail-safe 原則（PRD 537 判断 #6）は正しい。
**しかしその原則は、floor が実運用より高い位置にあるときには逆向きに働く。**

floor が高すぎると、gate は**実際には十分な水準で走っているセッションを止めにかかる**。止められた側は
`continue anyway` を選ぶしかなく、それが習慣になると **blocking の希少性が失われる**。gate の信頼性は
blocking の希少性が支えているので、これは gate 自身を蝕む。

**floor を「安全側だから高めに」と置くのは、この意味で安全側ではない。** 受け皿の有無で決める（前述の
構造的な非対称）ほうが、gate の信頼性を保てる。

## 変更しなかったもの

- **`~/.config/frontier-harness/config.json`（chezmoi source: `home/dot_config/frontier-harness/config.json`）は変更していない。** `session.child` = Opus @ xhigh は
  large tier の子に、`session.child.standard` = Opus @ high はそれ以外に割り当てられており
  （`wave-orchestrator/SKILL.md`「capability を tier で選ぶ」）、**新 contract はこの割り当てと矛盾
  しない**。横断設計 / PRD 審議は人がループ内にいる作業で、`fh session launch` で起こす子セッションの
  仕事ではないため、medium 行は capability registry に対応物を必要としない。
- **`home/dot_claude/settings.json` の `effortLevel: "xhigh"` も変更していない。** これは user の
  standing preference（PRD 330 AC-014、user 承認 2026-07-25）であって contract の floor ではない。
  floor が下がっても session 既定が下がるわけではなく、**両者は独立**である。
- **レビュー系 agent の `effort: xhigh` frontmatter も変更していない**（前述のとおり Sonnet 5 の
  単調性で裏づけられる）。
