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
| `--output-prd <path>` | （なし） | 合意内容を PRD file として書き出す（既定の配置: `.claude/prds/<slug>.prd.md`、git tracked） |
| `--mode=interactive\|auto` | `interactive` | `interactive`=各判断を user 対話（現状動作）/ `auto`=council（4 視点）+ santa-method（PRD draft を 2 reviewer で adversarial verify）で自動審議し、**最終 PRD draft を user が 1 回承認** |

- **auto でも security / data migration / contract change 等は強制的に user エスカレート**する。
- PRD 書き出しは memory 記録に相当するため、`~/AGENTS.md` の memory ポリシー（**承認前に保存しない**）に従い、**file 出力前に必ず user 承認**を得る。

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

sections: **Background** / **User Story** / **Acceptance Criteria**（`AC-NNN`） / **Out of Scope** / **Open Questions**。

slug 衝突時は `-v2` suffix で生成（user override 可）。下流の `/planning --input-prd <path>` がこの file を入力にする。
