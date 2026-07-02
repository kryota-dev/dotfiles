---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Plan-PRD pipeline（任意 / opt-in, task #22）

以下の flag は **任意**。**未指定時は上記の通常動作（対話のみ、ファイル出力なし）を完全に維持する**。flag を渡したときだけ session 横断 handoff 用の PRD file を出力する。

| flag | 既定 | 意味 |
|------|------|------|
| `--output-prd [<path>]` | （なし） | 合意内容を PRD file として書き出す。`<path>` を渡せばそのパスに出力し **slug = basename（拡張子・`.prd` を除く）**。省略時は対話で確定した feature 名を **kebab-case 化した slug** で `.claude/prds/<slug>.prd.md`（git tracked）に出力 |
| `--mode=interactive\|auto` | `interactive` | `interactive`=各判断を user 対話（現状動作）/ `auto`=council（4 視点）+ santa-method（PRD draft を 2 reviewer で adversarial verify）で自動審議し、**最終 PRD draft を user が 1 回承認** |

- **auto でも security / data migration / contract change 等は強制的に user エスカレート**する。
- PRD 書き出しは memory 記録に相当するため、`~/AGENTS.md` の memory ポリシー（**承認前に保存しない**）に従い、**file 出力前に必ず user 承認**を得る。
- **PRD 生成の default 化（#222）**: `pr-workflow` の non-trivial path（standard/large）から呼ばれるときは **PRD 生成を default handoff** とする（intent gate の成果物）。ただし **file 永続化は上記 memory ポリシーどおり user 承認必須**（生成は default、保存は承認）。grill-me を **単体起動**したときの `--output-prd` は従来どおり opt-in（未指定なら対話のみ・ファイル出力なし）を維持する。

### PRD frontmatter + sections

```yaml
---
slug: <slug>
feature: <feature 名>
created_at: <ISO8601>
grill_session: <session-id>
status: draft | finalized | implemented
---
```

sections: **Background** / **User Story** / **Acceptance Criteria**（`AC-NNN`、ゼロ埋め 3 桁: `AC-001`） / **Considered Alternatives / Rejection Rationale**（決定ログ: 検討した代替案とその却下理由。**必須**） / **Out of Scope** / **Open Questions**。`created_at` は `date -Iseconds`（ローカル TZ）で生成する。

- **Considered Alternatives / Rejection Rationale（決定ログ, #222）は必須セクション**。intent を将来へ残すため、検討した設計代替案と「なぜ採らなかったか」を最低 1 件記録する（可能なら `AC` と対応づける）。intent 確認の成果を decision log として保全し、後から「なぜこの設計か」を辿れるようにする狙い。

**衝突処理（上書き禁止）**: 出力先 file が既存なら `-v2`、それも在れば `-v3`…と空きが見つかるまで `-vN` を増やす（既存 file は決して上書きしない。user が override path を明示した場合のみ従う）。下流の `/planning --input-prd <path>` がこの file を入力にする。
