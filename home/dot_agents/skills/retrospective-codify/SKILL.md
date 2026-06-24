---
name: retrospective-codify
description: |
  セッションで確立した学び（preference / convention / 設計判断）を topic 単位の markdown convention file に「永続化」する skill。
  会話の議論ベースの規約を、chezmoi source や project tracked file に書き出して次セッション以降も効くようにする。
  ECC 継続学習 v2（tool 実行 pattern → instinct YAML）の Layer 4 補完。
  トリガー: "retrospective-codify", "学びを convention 化", "規約に落とす", "convention file に永続化", "学びを固定化して規約に"
  使用場面: セッションで合意した設計方針・命名規約・運用ルールを convention file として残したいとき（単なるセッション要約は session-summary を使う）。
argument-hint: "[task description] [--range=session|recent-N|date-range] [--target=project|user|private] [--mode=interactive|auto|unattended]"
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
| `--range` | `session` | 学びの**抽出範囲**: `session` / `recent-N`（直近 N） / `date-range` |
| `--target` | `project` | 書き出し先の**スコープ**: `project` / `user` / `private`（下記「書き出し先」） |
| `--mode` | `interactive` | 承認の**粒度**（下記「モード」） |

> 注: 旧 `--scope` は「抽出範囲」と「書き出し先」を二重に意味して曖昧だったため、`--range`（抽出）と `--target`（書き出し先）に分離した。

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

- **user 手動**: `/retrospective-codify`
- **将来連携（未実装）**: Theme A SessionEnd hook からの auto trigger（interactive 既定で user 介入前提。Phase 6 PR11 系で評価）。

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
