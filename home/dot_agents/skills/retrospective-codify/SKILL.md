---
name: retrospective-codify
description: |
  セッション末の学び（会話で確立した preference / convention）を topic 単位の markdown convention file に固定化する skill。
  ECC 継続学習 v2（tool 実行 pattern → instinct YAML）の Layer 4 補完として、conversation 議論ベースの規約を捕捉する。
  トリガー: "retrospective-codify", "学びを固定化", "convention 化", "規約に落とす", "retrospective", "ふりかえりを記録"
  使用場面: セッションで合意した設計方針・命名規約・運用ルール等を、次セッション以降も効く convention file として残したいとき。
argument-hint: "<task description> [--mode=interactive|auto|unattended] [--scope=session|recent-N|date-range]"
---

# retrospective-codify

セッションで確立した **学び（preference / convention / 設計判断）** を、topic 単位の markdown convention file に固定化する。
ECC 継続学習 v2 が捕捉する「tool 実行 pattern → instinct」とは別レイヤ（**Layer 4**）として、**会話の議論ベース**の規約を人手レビューで curated 化する。

## 位置づけ（ECC との Layer 分担）

| Layer | 捕捉対象 | 仕組み |
|-------|---------|--------|
| Layer 1-3（ECC） | tool 実行 pattern → instinct YAML → skill | observe hook / confidence scoring / `/evolve` |
| **Layer 4（本 skill）** | conversation 議論 → topic-based convention file | retrospective-codify（人手レビュー前提） |

補完関係であり scope 重複は限定的。自動生成（auto-files）ではなく **adopt ideas**（人が吟味して採用）方針（task #34）。

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<task description>` | - | 今回固定化したい学びの概要（自由記述） |
| `--mode` | `interactive` | 下記「モード」参照 |
| `--scope` | `session` | 学びの抽出範囲（`session` / `recent-N` / `date-range`） |

## モード（3 種）

| モード | 動作 | user 介入 |
|--------|------|----------|
| `interactive`（既定） | 各 merge 候補ごとに user 承認を取る | 候補ごと |
| `auto` | council（4 視点）+ santa-method（PRD 全体検証）で審議し、最終 list を 1 回承認 | list 承認 1 回 |
| `unattended` | 完全自走。事後に `git diff` で user 確認 | 事後のみ |

**機微判定の強制エスカレーション**: `auto` / `unattended` でも、以下は必ず user にエスカレートする（mode を無視）:
- 個人情報 / secret（regex + pattern matching で検出）
- security 関連の convention 変更

## topic-based file 戦略（file 1 = topic 1）

学びは **topic 単位**で 1 ファイルに集約する（巨大な単一ファイルにしない）。scope で配置先を決める:

| scope | 配置 | 管理 |
|-------|------|------|
| project 固有 | `<project>/.claude/conventions/<topic>.md` | project が tracked |
| user global | `~/.claude/conventions/<topic>.md` | chezmoi 管理（dotfiles で cross-machine 共有） |
| 機微 private | `~/.claude/private/<topic>.md` | `.gitignore` or 別 private repo |

### file frontmatter + sections

```yaml
---
topic: typescript-style
scope: project | user | private
created_at: <session 開始時刻 ISO8601>
last_updated: <最終 update 時刻 ISO8601>
sources:
  - session: <session-id>
    date: <date>
---
```

本文の section: **Convention**（規約本体） / **Rationale**（なぜ） / **Evidence**（session 参照） / **Exceptions**（例外）。

### hub file への @-import 自動追加

新規 topic file を作成したら、hub file（project の `CLAUDE.md` or `~/AGENTS.md`）に次の 1 行を追記して薄く保つ:

```
See @.claude/conventions/<topic>.md for <description>.
```

hub が肥大化したら警告し、categorize（分類整理）を提案する。

## 実行フロー

1. **scope に従いセッションの学びを抽出**する（`--scope` で範囲決定）。
2. **session-summary skill を前段として invoke** する（役割分担: summary 生成は session-summary、学びの merge は本 skill）。
3. 各学びを **topic に割り当て**、既存 convention file との突き合わせを行う。
4. **機微判定**（個人情報 / secret / security）を実施し、該当は強制エスカレート。
5. mode に従い **merge 候補を提示・承認**する（interactive=候補ごと / auto=list 1 回 / unattended=自走）。
6. 承認された学びを convention file に **merge**（新規作成 or 既存更新、`last_updated` 更新、`sources` 追記）。
7. 新規 topic file は **hub file に @-import を追記**する。
8. （unattended 時）最後に `git diff` を提示して user 確認を促す。

## トリガー

- **user 手動**: `/retrospective-codify`
- **Theme A SessionEnd hook 連携**: セッション終了時に auto trigger できる（ただし interactive 既定で user 介入前提。完全自走させたいときのみ `--mode=unattended`）。

## failure mode と対処

| 失敗 | 対処 |
|------|------|
| 既存 topic file との衝突（同 topic で異なる convention） | merge conflict として提示し user judgment を仰ぐ（独断 merge しない） |
| 機微判定の false negative | regex/pattern matching + user confirmation の二段で担保 |
| hub file の @-import 肥大化 | 警告 + categorize（分類）提案 |

## 注意

- convention file・hub への追記は **学びの固定化**であり、独断で機微情報を書き込まない（機微は強制エスカレート）。
- 自動生成に寄せすぎず、**人が吟味して採用**する原則を保つ（task #34 の signal-only 方針と整合）。
