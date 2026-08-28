# #370 合格基準 (b): 既存レイヤーが提供している部分の明示

status: draft / 実装なし（設計スパイクの成果物）
対象: issue #370 合格基準 2「既存のレイヤーによって提供される部分を明示的にリストします（再発明なし）」
関連: #473（ECC hook の縮小と継続的改善ループの導入）、#368（closed）、#369（closed）

本書は #370 の合格基準 (a)（インベントリ・ギャップ分析・フォローアップ）を実質カバーしている #473 PRD に対して、
**(b) だけを埋める差分ドキュメント**である。PRD の内容は再掲しない。

すべての主張は実コードの実測に基づく。skill の説明文・issue 本文は根拠に採用していない。

> **追記（2026-08-29）: 本書は執筆時点のスナップショットである。**
> 本文が実在するものとして参照する `hooks-fork/ecc-state-reader.js`（および `ecc-status` /
> `ecc-sessions` / `ecc-work-items`）は、その後 **PR #520（#496）で削除**され、
> `home/.chezmoiremove:126` に削除対象として登録された。「read-only な会話面の
> パターン」という論旨は有効だが、参照先の実体はもう存在しない。
> 本文は当時の判断根拠を保全するため書き換えていない。

---

## 0. 要約

#370 が名指しする「既存 3 レイヤー」は、**個々には健在だが、週次の昇華経路が計測ミスで縮退したまま動いている**。
#473 の週次 evaluator が新規に足すものの相当部分は、既存の `knowledge-distill` + その launchd radar が
**すでに持っている実行基盤の再パラメータ化**であり、真に新規なのは *candidate queue（採否・追跡・効果測定）* と
*匿名化シグナル収集* の 2 つに絞られる。

---

## 1. レイヤー別の担当範囲（実コード実測）

### Layer 1: CLV2 instinct（hook observe パターン）

| 項目 | 実測 | 根拠 |
|---|---|---|
| 観測 | PreToolUse/PostToolUse `*` で全 tool call を記録 | `home/dot_claude/settings.json` の `continuous-learning-v2/hooks/observe.sh pre|post` |
| 記録内容 | `timestamp / event / tool / session / project_id / project_name / input` | `observations.jsonl` 1 行を実測。`.input` は **生の tool 入力**（Bash コマンド全文・ファイルパスを含む） |
| 蓄積 | project-scoped instinct（v2.1）。**計 3506 件**が `projects/<hash>/instincts/**` に実在 | `find $H/projects -path '*instincts*' -type f`（内訳は §3.1） |
| 昇華候補 | review-ready cluster **3 件** | `$H/.review-ready-clusters` |
| 消費 | SessionStart で agent context へ注入 | ECC `scripts/hooks/session-start.js:459`（`Active instincts:`） |

**担当している範囲**: 日常作業からの signal 抽出、confidence 付き atomic 化、cluster 化。
**担当していない範囲**: 採否の記録、Issue 化、効果測定。instinct は「観測の要約」であって「改善の意思決定」ではない。

### Layer 2: knowledge-distill（週次診断・昇華）

| 項目 | 実測 | 根拠 |
|---|---|---|
| 週次スケジュール実行 | **金曜 18:00（Weekday 5 / Hour 18）** | `home/Library/LaunchAgents/dev.kryota.knowledge-distill.plist.tmpl` |
| headless 実行基盤 | model pin（sonnet）、`--max-turns 50`、watchdog（TERM→10s→KILL）、timeout 600s | `executable_knowledge-distill-radar.sh` |
| 最小権限 | read-mostly allowlist、書き込みは自分の report dir のみ | 同 `ALLOWED_TOOLS` |
| 重複実行防止 | ISO 週スタンプによる same-week guard（成功時のみ記録＝失敗週は再試行可能） | 同 `$STATE_DIR/last-run` |
| 出力契約の検証 | report file が空なら失敗扱いにして通知＋週スタンプを残さない | 同 |
| 失敗通知 | ntfy `claude-attention` へ priority 5 | 同 `notify_error` |
| 正常通知 | ntfy `claude-attention` へ priority 3 の 1 行 | 同 `ntfy_publish 3` |
| 独立 precheck | claude の自己申告を信用せず、蓄積数を自前で数えて「縮退」を明示 | 同 `INSTINCT_COUNT` |
| 昇華の routing | evolved skill 化 / curated skill 改修 / memory 追加 / ルール化 の 4 区分（**提案のみ、適用しない**） | `knowledge-distill/SKILL.md` Phase 3 |

**担当している範囲**: 週次スケジュール実行、コスト上限つき headless 実行、健全性診断、昇華先の routing、通知配達。
**#473 の evaluator が必要とする実行基盤は、ここにほぼ全部ある。**

### Layer 3: retrospective-codify（会話レベルの規約捕捉）

| 項目 | 実測 |
|---|---|
| 入力 | `--input=session`（会話）/ `--input=instinct-clusters`（CLV2 cluster） |
| 審議 | `--mode=auto` で council(4 視点) + santa-method |
| 承認 | **どの mode でも実ファイル書き込み前に user 承認**（memory ポリシー準拠） |
| 出力 | topic 単位の convention file + hub への @-import |

**担当している範囲**: 「採用が決まった学び」を永続資産へ落とす経路と、その承認ゲート。
**担当していない範囲**: 何を採用するかの**優先順位付け**と、採用後の**効果測定**。

### 記録資産

| 資産 | 出力先（実測） | evaluator から見た位置づけ |
|---|---|---|
| `daily-planning` | GitHub Discussions | 人間向け。集計 API はあるが匿名化されていない |
| `session-summary`（skill） | project 相対 `.kryota-dev/claude/session-summary/` | `knowledge-distill` Phase 2 の入力。**手動実行**（hook 配線なし） |
| `session-end`（ECC hook） | `~/.claude*/session-data/` | 上とは**別ストア**。Stop ごとに transcript から自動生成 |
| `worklog` | `.kryota-dev/worklog/` | 活動事実の集約。read-only |

> 検証済みの注意点: `session-summary` skill と ECC の `session-end.js` は**出力先が別**である。
> したがって #473 AC-025 が ECC の自動 session summary 保存を外しても、`knowledge-distill` Phase 2 の
> 入力（project 相対の session-summary）は失われない。

---

## 2. #473 の週次 evaluator / candidate queue の分解

| #473 が要求するもの | 既存レイヤーの担当 | 判定 |
|---|---|---|
| 週次スケジュール実行（AC-029） | `dev.kryota.knowledge-distill` LaunchAgent が金曜 18:00 に既に存在 | **再発明。既存を repoint すべき** |
| headless 実行・model pin・turn/time guard（AC-033） | radar wrapper が実装済み（watchdog + max-turns + timeout） | **再発明** |
| 失敗の incident 通知（AC-003） | radar の `notify_error` が失敗時に通知。ただし**重複抑止と復旧検知は無い** | **部分的に再発明 + 差分は新規** |
| 集計済み evidence の受け渡し（AC-032） | radar の独立 precheck + `instinct-cli.py evolve` の cluster サマリ | **再発明。cluster サマリが既に「集計済み evidence」** |
| 複数候補の生成・重複排除・順位付け（AC-030/034） | `knowledge-distill` Phase 3 は 4 区分に routing するが**順位付けも重複排除もしない** | **新規** |
| candidate queue の永続化・採否・失効（AC-035/036/039） | prior art なし（リポジトリ全体を grep して不在を確認） | **新規** |
| Issue 化と効果測定（AC-040/041） | `create-issue` skill は起票のみ。効果測定の仕組みは不在 | **新規** |
| 会話内での候補一覧（AC-037） | `ecc-status` / `ecc-sessions` / `ecc-work-items`（`ecc-state-reader.js` + zsh 関数）が**同型のパターン**を持つ | **パターンは再利用可能、実体は新規** |
| 匿名化シグナル収集（AC-022/023/024） | prior art なし | **新規** |
| resource / loop / scope 警告（AC-018/020/021） | `ecc-context-monitor.js`（286 行）が context / cost / scope / loop を**すべて実装済み**（`detectLoop`、warning 文言が変化したときだけ再提示する dedup 付き） | **再発明。ただし意味論は変わる**（下記） |
| 昇華先の routing（4 区分） | `knowledge-distill` Phase 3 | **再発明しない（AC-044 で手動維持）** |
| 承認ゲート | `retrospective-codify` の mode 別承認 + memory ポリシー | **再発明しない** |

### 「再発明」判定の注釈

- **AC-018/020/021 は完全な再発明ではない**。既存 `ecc-context-monitor` は
  ①常時 PostToolUse で走り ②cost 閾値ベースで ③生のファイル数を見る。
  #473 は ①UserPromptSubmit のみ ②quota 閾値ベース ③salt 付き hash に変える。
  **意味論が変わるので置換自体は正当**だが、PRD の Considered Alternatives に
  「ecc-context-monitor を残して閾値と発火面だけ再設定する」案が挙がっていない。
- **AC-021 は既存の依存を切ると新規状態が必要になる**。`detectLoop` は
  `bridge.recent_tools` を読むが、その bridge は AC-017 で削除される。
  よって「最小の PostToolUse sentinel」は自前の ring buffer を持つことになる。

---

## 3. 実測で判明した既存レイヤーの不具合（#473 の前提に影響する）

### 3.1 週次昇華経路が計測ミスで恒久縮退している

| 計測箇所 | 見ているパス | 実測値 |
|---|---|---|
| `executable_knowledge-distill-radar.sh:154` | `$HOMUNCULUS_DIR/instincts/personal`（maxdepth 1） | **0 件** |
| `knowledge-distill/SKILL.md:45,95` | 同上 | **0 件** |
| `executable_clv2-session-notify.sh` | `instinct-cli.py evolve` へ委譲 | cluster **3 件**（正しく検出） |

homunculus ディレクトリ別の実測（`instincts/personal` maxdepth 1 / `projects/*/instincts/**`）:

| homunculus | radar が数える所 | 実際の蓄積先 |
|---|---|---|
| `ecc-homunculus`（suffix 無し fallback） | 0 | 1 |
| 個人アカウント | 0 | **1400** |
| 第2アカウント | 0 | **2105** |

3 ディレクトリすべてで radar の計測値は 0、実蓄積は計 3506 件。

`instincts/personal/` は v2.1 では **global tier**（2 プロジェクト以上で観測されたときに昇格する先）であり、
**蓄積量の指標ではない**。個人アカウント・第2アカウントの双方で 0 件だった。

帰結:
- radar の `DRY=1` が常に成立し、毎週の ntfy は「[縮退] instinct 0/10」を配達し続けている。
- `knowledge-distill` は Phase 1 の縮退判定で必ず抜けるため、**Phase 2/3（実際の蒸留と昇華提案）が一度も走っていない**。
- `clv2-session-notify.sh` だけが `instinct-cli.py` に委譲しているため正しく 3 cluster を検出しており、
  **同じリポジトリ内で計測方法が食い違っている**。

これは #370 が前提とした「3 つの学習層がすでに導入されている」という認識を修正する:
**Layer 2 は導入されているが、#368 の稼働開始以来ずっと縮退モードで動いている。**

### 3.2 LaunchAgent の退役経路が片道である

`run_onchange_after_30-register-launchd-agents.sh.tmpl:23` の `labels=()` は固定配列で、
`:26-30` のループが**その配列に載っているものだけを bootout→bootstrap する**。

**順序の罠**: 配列から label を先に消すと、その agent は二度と bootout されず、
ロード済みのまま走り続ける（`.chezmoiremove` が plist を消しても launchd の登録は残る）。
退役は次の 3 点すべてが要り、`bootout` を配列削除より先に済ませる必要がある:

1. 明示的な `launchctl bootout gui/$(id -u)/<label>`
2. `labels=()` 配列からの削除
3. `.chezmoiremove` へのエントリ追加（plist の destination 削除）

AC-043（macOS drift の休止）と、後述の knowledge-distill LaunchAgent 退役の両方に効く。

### 3.3 ECC hook ランタイムは改変できない（chezmoi external）

`home/.chezmoiexternal.toml:161-166` が `.agents/skills/ecc/scripts` を
`type = "archive"` / commit pin / `refreshPeriod = "168h"` / `include = ["*/scripts/hooks/**", ...]`
として宣言している。つまり `config-protection.js` を含む **ECC hook の実体はすべて外部取得物**であり、
chezmoi source tree に存在せず、refresh で上書きされる。

したがって ECC hook に対してこのリポジトリが取れる手段は 3 つに限られる:

1. `ECC_DISABLED_HOOKS` / env で**挙動を切る**
2. `settings.json` から**配線を外す**
3. `home/dot_claude/hooks-fork/` に**fork を置いて置き換える**（既存 4 例:
   `governance-capture.js` / `post-bash-command-log.js` / `prompt-conform-suggest.js` / `ecc-state-reader.js`）

**hook の内部挙動を「少し変える」という選択肢は存在しない。**

---

## 4. #370 合格基準 (b) に対する結論

**既存レイヤーが既に提供しており、#473 で再実装してはならないもの:**

1. 週次スケジュール実行の枠（LaunchAgent、金曜 18:00、same-week guard）
2. コスト上限つき headless 実行（model pin / max-turns / watchdog / 最小権限 allowlist）
3. モデルの自己申告に依存しない独立 precheck という設計原則
4. ntfy 配達（topic 設計・0600 の `curl -K` によるトークン秘匿・fail-open）
5. 観測 → instinct → cluster の signal 抽出パイプライン全体
6. 昇華先 4 区分への routing と、その提案止まり原則
7. 永続化前の user 承認ゲート（memory ポリシー）
8. `<name>-state-reader` + zsh 関数という read-only 会話面のパターン
9. pinned な外部 hook を置き換える `hooks-fork/` パターン（既存 4 例）と、
   全 ECC hook 呼び出しを仲介する `executable_ecc-hook.sh` という挿入点

**#473 が正当に新規追加するもの:**

1. candidate queue（複数候補の永続化・順位付け・採否・失効・Issue 化・効果測定）
2. 匿名化された signal 収集（event counter / hash 化 scope / quota スナップショット）
3. 通知契約の再定義（配達すべきものを「行動要求」に限定する）
4. incident の重複抑止と復旧検知

**先に直すべきもの（#473 の前提）:** 3.1 の計測パス。
これを直すまで「既存の週次ループでは足りない」という #473 の動機は**実測されていない**。
