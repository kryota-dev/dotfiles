---
slug: pr-workflow-implementer-choice
feature: pr-workflow の実装者を Claude と Codex から PR ごとに選ぶ
created_at: 2026-10-22T18:41:31+09:00
grill_session: session_016SahyGsSRsZ8kjLogeEtV7
status: finalized
---

# pr-workflow の実装者を Claude と Codex から PR ごとに選ぶ

## Background

pr-workflow・sdd・review-resolve-loop は「設計と判断は Claude、実装は GPT」を前提にしていて、実装の委譲先は GPT の役割（`implementer`・`implementer-light`・`implementer-astra`）に固定されている。実装を Claude に任せたい場面でも選べない。

Claude の役割は `claude -p` の別プロセスで起動し、Bash を持たない（`tests/agent_roles.bats` が検査する）。そのため Claude に実装させても、実装者が自分でテストを回せない。Claude Code の sandbox は `--settings` で有効にでき、`--profile agent` の Codex と同等の境界（書き込みは作業ディレクトリと一時ディレクトリだけ、ネットワークなし）を作れる（[公式](https://code.claude.com/docs/en/sandboxing)）。

単価は Sonnet 5.5 と GPT-6.1 Sol がどちらも $2/$10 per MTok、Opus 5.5 と GPT-6 Astra が最上位の階層にあたる。役割の段を揃えれば、どちらを選んでも費用と品質の前提が同じになる。

## User Story

- 開発者として、PR ごとに実装者を Claude と Codex から選びたい。選ぶときには推奨と理由を示してほしい。
- 開発者として、Claude を実装者にしても、実装者が sandbox の中で自分でテストを回してほしい。
- 開発者として、どちらが実装しても、general のレビューは実装と別の系統のモデルに見てほしい。
- 開発者として、非対話の実行や、呼び出し元が実装者を決めているときは、質問で止まらずに進んでほしい。

## Acceptance Criteria

- **AC-001**: pr-workflow は Phase 0 の分類の直後に、PR ごとに 1 回だけ実装者（Claude / Codex）を尋ねる。trivial では尋ねない。決めた実装者を、その PR の初回の実装・CI の修正・指摘の修正（review-resolve-loop）・sdd の Phase 4 のすべてに使う。
- **AC-002**: 推奨は規則で決める。既定は Codex。codex が使えない（未導入・未認証）とき、または入力が 272K トークンを超えるタスクでは Claude を推奨する。各選択肢に、使う役割と推奨の理由を 1 行添える。
- **AC-003**: `--implementer=claude|codex` が渡されたら尋ねない。渡されず非対話で尋ねられないときは推奨を採り、その旨と理由を PR の本文に 1 行残す。
- **AC-004**: Claude の役割を 3 つ足す。`implementer-claude`（claude-sonnet-5-5 / high、standard・large の 1 タスク）、`implementer-claude-light`（claude-sonnet-5-5 / medium、small・CI の修正・指摘の修正）、`implementer-claude-opus`（claude-opus-5-5 / high、格上げ先）。定義は `~/.agents/roles/` に置く。
- **AC-005**: GPT の実装の役割は `implementer`（gpt-6.1-sol / high）・`implementer-light`（gpt-6.1-sol / medium）・`implementer-astra`（gpt-6-astra / high）のまま変えない。model-roles.md の根拠に、段の対称性と、GPT-6 Luna を採らない理由を書く。
- **AC-006**: 格上げは 1 段ずつにする。light が同じタスクで 2 回失敗したら、同じ系統の通常の役割で 1 回試す。通常の役割が 2 回（light から上がった場合は 1 回）失敗したら、同じ系統の最上位で 1 回試す。それでもだめなら user に上げる。系統はまたがない。
- **AC-007**: Claude の実装者は `claude -p` で起動し、Bash を持つ。`--settings` で `sandbox.enabled: true`・`allowUnsandboxedCommands: false`・`failIfUnavailable: true`・`network.strictAllowlist: true`（許すドメインは空）を指定し、`filesystem.denyRead` で認証情報のパス（`~/.ssh`・`~/.aws`・`~/.config/gh`・`~/.codex` など、`claude_leg` の拒否と同じもの）を拒否する。linked worktree の中でだけ起動する。起動形は model-roles.md に関数として置く。
- **AC-008**: 親の手順は Codex のときと同じにする。diff の全体を読んでから、ホストでテスト・lint を実行する。commit は親が行う。Claude の実装者には commit・stash・reset・checkout をさせない。
- **AC-009**: ネットワークが要るときは、必要性を説明できる場合に限り、許すドメインを列挙して足す（codex skill の `network_access` と同じ扱い）。
- **AC-010**: pr-workflow は multi-review に `--implementer=claude|gpt` を渡す。claude のときは general を GPT に入れ替える。trivial・small は新設の `reviewer-gpt-light`（gpt-6.1-sol / medium）、standard は `reviewer-gpt`、large は `reviewer-gpt` と `review-general` にする。security・intent・simplicity は変えない。gpt のときと、`--implementer` が渡らないときは今の roster のままにする。
- **AC-011**: Claude の実装者の結果の `modelUsage` に要求していないモデルがあれば、fallback として実行記録と PR の本文に残す。diff は親が検証するので、走らせ直しはしない。
- **AC-012**: secret や認証情報に触れうるタスクは、どちらを選んでも親が書く（今の規則を保つ）。
- **AC-013**: `tests/agent_roles.bats` は、新しい役割の定義と役割表の一致を検査する。Bash を持ってよいのは `implementer-claude*` だけ、書き込みの道具を持ってよいのは `spec-designer` と `implementer-claude*` だけにする。Claude の実装者の起動の関数について、sandbox の設定と道具を組み立てていることを検査する。`make test` が通る。
- **AC-014**: ARCHITECTURE.md・pr-workflow・sdd の implementation.md・review-resolve-loop・multi-review・codex skill から、「実装は GPT」に固定した記述をなくし、実装者は PR ごとに選ぶことと、その参照先（model-roles.md）を書く。
- **AC-015**: 新しい役割の本文は、Sonnet 5.5 と Opus 5.5 の公式のプロンプトのガイドに沿って書く。非対話で完了まで進めること、頼まれていない追加をしないこと、変更を実際の検査で確かめること、ネットワークが無いときに確かめられなかった検査を報告すること、を含める。

## Considered Alternatives / Rejection Rationale

- **実装の局面ごと・タスクごとに尋ねる**: 1 PR で質問が 3 回から十数回に増え、自動で進む Phase 5〜7 が止まる。系統が混ざって、レビューの系統の判断も一意にならない。PR ごとに 1 回にした。
- **Claude Code の subagent で実装させる**: 親の広い permission を継承し、Codex が親のときに使えず、ARCHITECTURE.md の方針に反する。`claude -p` にした。
- **Bash を持たせない `claude -p`**: 実装者が自分でテストを回せず、往復が増える。user の要求（実装者は自律的にテストを実行する）に合わない。sandbox の中の Bash にした。
- **Claude の実装を Opus 5.5 だけ（2 段）にする**: Sonnet 5.5 は Sol と単価の階層が同じで、仕様が明確な agentic coding は medium から始めるよう公式が勧めている。Sonnet を主に使い、Opus は格上げ先にした。
- **GPT の light を GPT-6 Luna にする**: 単価は Sol の 1/20 だが、Codex の harness での Coding Agent Index が 41（Sol は 57）で、失敗と格上げの往復が増えうる。user が却下した。
- **格上げで最上位に直行する**: エフォートが足りないだけで失敗した修正まで Astra / Opus に回る。1 段ずつにした。
- **格上げで系統をまたぐ**: user が選んだ系統と違うモデルが書くことになり、レビューの系統の判断がずれる。系統はまたがない。
- **推奨を常に固定する**: codex が使えない環境でも Codex を推奨してしまう。規則で決めることにした。
- **Claude が実装しても general を変えない／GPT を足すだけ**: 前者は「general は実装と別の系統で見る」が崩れる。後者は small でも high の leg が 2 本になり、重複の指摘が増える。入れ替えにした。
- **非対話では止める**: 自動化した実行が進まなくなる。推奨を採って PR に残すことにした。

## Out of Scope

- multi-review の security・intent・simplicity・database / IaC の leg の割り当ての変更。
- security-review の役割の変更。
- 役割のモデルとエフォートを、自分の評価で測って調整すること（`xhigh`・`max` を使わない方針も保つ）。
- Codex が親のときに、Codex 自身の sandbox が `claude -p` の起動を妨げるかの検証（既存の `claude_leg` と同じ前提に置く）。

## Open Questions

- macOS の sandbox で、対象のリポジトリのテストが動くか（`jest` のハングなど、公式の Troubleshooting にある既知の問題）。動かない場合、実装者は確かめられなかった検査を報告し、親がホストで実行する。
- 272K トークンの閾値をどう見積もるか（入力の文字数からの概算でよいか）。
