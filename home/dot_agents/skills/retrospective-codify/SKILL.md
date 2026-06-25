---
name: retrospective-codify
description: |
  セッションで確立した学び（preference / convention / 設計判断）を topic 単位の markdown convention file に「永続化」する skill。
  会話の議論ベースの規約を、chezmoi source や project tracked file に書き出して次セッション以降も効くようにする。
  ECC 継続学習 v2（tool 実行 pattern → instinct YAML）の Layer 4 補完。
  トリガー: "retrospective-codify", "学びを convention 化", "規約に落とす", "convention file に永続化", "学びを固定化して規約に"
  使用場面: セッションで合意した設計方針・命名規約・運用ルールを convention file として残したいとき（単なるセッション要約は session-summary を使う）。
argument-hint: "[task description] [--input=session|instinct-clusters] [--range=session|recent-N|date-range] [--target=project|user|private] [--mode=interactive|auto|unattended]"
---

# retrospective-codify

セッションで確立した **学び（preference / convention / 設計判断）** を、topic 単位の markdown convention file に永続化する。
ECC 継続学習 v2 が捕捉する「tool 実行 pattern → instinct」とは別レイヤ（**Layer 4**）として、**会話の議論ベース**の規約を人手レビューで curated 化する。

`session-summary` がセッションの**要約**を作るのに対し、本 skill はその要約から **再利用可能な規約**を抽出して convention file に固定する（役割が異なる）。

## 位置づけ（ECC との Layer 分担）

| Layer | 捕捉対象 | 仕組み |
|-------|---------|--------|
| Layer 1-3（ECC） | tool 実行 pattern → instinct YAML → skill | observe hook / confidence scoring / `/evolve` |
| **Layer 4（本 skill）** | conversation 議論 → topic-based convention file | retrospective-codify（人手レビュー前提） |

自動生成（auto-files）ではなく **adopt ideas**（人が吟味して採用）方針（task #34）。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `[task description]` | （任意） | 今回固定化したい学びの概要（自由記述。省略時はセッション全体から抽出） |
| `--input` | `session` | 学びの**入力ソース**: `session`（会話から抽出） / `instinct-clusters`（CLV2 の review-ready cluster を入力にする。下記「instinct-cluster 入力モード」） |
| `--range` | `session` | 学びの**抽出範囲**（`--input=session` 時のみ）: `session` / `recent-N`（直近 N） / `date-range` |
| `--target` | `project` | 書き出し先の**スコープ**: `project` / `user` / `private`（下記「書き出し先」） |
| `--mode` | `interactive` | 承認の**粒度**（下記「モード」） |

> 注: 旧 `--scope` は「抽出範囲」と「書き出し先」を二重に意味して曖昧だったため、`--range`（抽出）と `--target`（書き出し先）に分離した。

## instinct-cluster 入力モード（`--input=instinct-clusters`）

ECC 継続学習 v2（Layer 1-3）が観測から蓄積した instinct を、`/evolve` が **同 trigger 2+ の cluster**（review-ready）に束ねる。本モードはその cluster を学びの入力ソースとして取り込み、**会話要約の代わりに**人手レビューで convention file に固定化する。Layer 1-3（自動観測）と Layer 4（人手 curated 化）を橋渡しする経路であり、`/evolve --generate` の **auto-files（skill 自動生成）は使わない**——「adopt ideas not auto-files」方針（task #34）を維持し、cluster は**候補の素材**として扱う。

**呼び出し契機**:

- **user 手動**: `/retrospective-codify --input=instinct-clusters`
- **system push**: CLV2 の SessionStart 通知 hook（`clv2-session-notify.sh`）が cluster≥1 を検出してデスクトップ通知（最大 7 日 1 回）。statusline の 🧬N も同じ cluster 数を表示する。通知を見た user が本モードを起動する **pull→push** の経路。

**cluster の取得**（engine は改変せず、読み取り専用で利用する）:

```bash
python3 ~/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py evolve
```

`evolve` 出力の `## SKILL CANDIDATES` 節（各 cluster の trigger / 構成 instinct ID / avg confidence / domain / scope）を学びの候補として読む。`Potential skill clusters found: N` 行が cluster 総数（statusline 🧬N と同値）。instinct が 3 件未満のときは `evolve` が exit 1 で「Need at least 3 instincts」を返すため、その場合は **no-op で終了**し session 入力モードを案内する。

**この入力モードでの実行フロー差分**（下記「実行フロー」の 1-2 を置換）:

1. `session-summary` は **invoke しない**。代わりに上記 `evolve` を実行し、`## SKILL CANDIDATES` の各 cluster を 1 件 = 1 学び候補として列挙する。
2. 各 cluster を、その trigger・構成 instinct の意味から **convention の草案**に翻訳する（例: 「同 trigger に 2+ の instinct が蓄積 = 暗黙の運用規約が形成されている」と解釈し、Rationale に cluster の instinct ID と avg confidence を **Evidence** として残す）。

3 以降（topic 割り当て → 機微判定 → mode 審議承認 → convention file merge → hub @-import）は session モードと**完全に共通**。承認ゲート（実ファイル書き込み前に必ず user 承認）も同一。

## モード（承認の粒度）

**大原則**: convention の永続化は実質的に memory 記録であり、`~/AGENTS.md` の memory ポリシー（**ユーザー承認前に保存しない**）が常に優先する。したがって**どのモードでも実ファイルへの書き込み前に承認が要る**。モードは「候補の審議方法と承認のまとめ方」を変えるだけ。

| モード | 審議方法 | 承認 |
|--------|---------|------|
| `interactive`（既定） | 候補を 1 件ずつ提示 | 候補ごとに承認 |
| `auto` | council（4 視点）+ santa-method で一括審議し最終 list を提示 | 最終 list を 1 回承認 |
| `unattended` | 完全自走で審議し、**draft（staging）に書き出す**。実 convention file には書かない | 事後に `chezmoi diff` / `git diff` で draft を確認し、user が apply |

- **council（4 視点）**: 各候補を ①正確性（事実か） ②再現性（規約として運用可能か） ③将来の保守性 ④既存規約との衝突 の 4 観点で評価する。
- **santa-method**: 個々の候補だけでなく **convention set 全体**を通しで読み、矛盾・重複・抜けを検証する。
- いずれの mode でも、**機微判定**（個人情報 / secret / security convention の変更）に該当する候補は mode を無視して必ず user にエスカレートする（regex + pattern matching で検出）。

## 書き出し先（`--target` × chezmoi）

**重要（chezmoi 整合）**: dotfiles の SSOT は target path（`~/...`）ではなく **chezmoi source（`~/.local/share/chezmoi/home/...`）**。deploy 済み target を直接編集すると `chezmoi apply` で失われる。user global の永続化は **source を編集**するか、target に書いた後 `chezmoi add` で取り込む。

| `--target` | convention file | hub file（@-import 追記先） | 管理 |
|-----------|-----------------|---------------------------|------|
| `project` | `<project>/.claude/conventions/<topic>.md` | project の `CLAUDE.md`（tracked、直接編集可） | project repo が tracking |
| `user` | chezmoi source `home/dot_claude/conventions/<topic>.md`（→ `~/.claude/conventions/`）。target に書いた場合は `chezmoi add` で source に取り込む | chezmoi source `home/AGENTS.md`（→ `~/AGENTS.md`） | chezmoi（cross-machine 共有） |
| `private` | `~/.claude/private/<topic>.md`（**git 管理外**: `.gitignore` 済の場所、または別 private repo） | 追記しない（hub は tracked file のため機微を載せない） | 非共有 |

### file frontmatter + sections

```yaml
---
topic: <topic-slug>
scope: <project|user|private>
created_at: <ISO8601>
last_updated: <ISO8601>
sources:
  - session: <session-id>
    date: <YYYY-MM-DD>
---
```

本文の section: **Convention**（規約本体） / **Rationale**（なぜ） / **Evidence**（session 参照） / **Exceptions**（例外）。

### hub file への @-import 自動追加

新規 topic file 作成時、hub file に次の 1 行を追記して hub を薄く保つ（`@` 参照は意図的: Claude が hub ロード時に convention を取り込む）:

```
See @.claude/conventions/<topic>.md for <description>.
```

**肥大化対処**: hub の @-import が **8 行を超えたら** `conventions/INDEX.md` への集約を提案する。重複 import は追加しない（既存行を grep で確認）。カテゴリ順は固定（追記は末尾）。

## 実行フロー

1. **`session-summary` skill を前段として invoke** し、セッション要約を得る（要約生成は session-summary、学びの抽出・merge は本 skill）。出力先は session-summary の規約に従う（例: `.kryota-dev/claude/session-summary/`）。skill 間 invoke が不可の環境では、user に session-summary の出力を渡してもらう。
2. **要約と `--range` から学びを抽出**する。
3. 各学びを **topic に割り当て**、`--target` に対応する既存 convention file と突き合わせる。
4. **機微判定**（PII / secret / security）を実施し、該当は強制エスカレート。
5. **mode に従い審議・承認**する（実ファイル書き込み前に必ず承認。unattended は draft へ）。
6. 承認された学びを convention file に **merge**（新規 or 更新、`last_updated` 更新、`sources` に `session`/`date` 追記）。`--target=user` は chezmoi source を編集 or `chezmoi add`。
7. 新規 topic file は **hub file に @-import を追記**（`project`/`user` のみ。`private` は追記しない）。
8. 結果を提示（`project`→`git diff` / `user`→`chezmoi diff` / `private`→`ls -lt ~/.claude/private/`）。

## トリガー

- **user 手動**: `/retrospective-codify`（会話からの抽出）/ `/retrospective-codify --input=instinct-clusters`（CLV2 cluster からの抽出）
- **CLV2 push 連携**: SessionStart 通知 hook（`clv2-session-notify.sh`）が review-ready cluster≥1 を検出すると最大 7 日 1 回デスクトップ通知し、statusline 🧬N にも cluster 数が出る。user はそれを契機に `--input=instinct-clusters` を起動する（auto 実行ではなく user 介入前提）。
- **将来連携（未実装）**: Theme A SessionEnd hook からの auto trigger（interactive 既定で user 介入前提）。

## failure mode と対処

| 失敗 | 対処 |
|------|------|
| 既存 topic file との衝突（同 topic で異なる convention） | merge conflict として提示し user judgment を仰ぐ（独断 merge しない） |
| 機微判定の false negative | regex/pattern matching + user confirmation の二段で担保 |
| hub file の @-import 肥大化 | 8 行超で警告 + `INDEX.md` 集約提案、重複 import は追加しない |
| target 直接編集による chezmoi 乖離 | `--target=user` は source 編集 or `chezmoi add` を徹底 |

## 注意

- convention/hub への書き込みは memory 記録に相当する。**ユーザー承認前に保存しない**（mode に依らず）。
- 自動生成に寄せすぎず、**人が吟味して採用**する原則を保つ（task #34 の signal-only 方針と整合）。
