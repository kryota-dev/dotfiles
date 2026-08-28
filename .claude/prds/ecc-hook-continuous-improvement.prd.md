---
slug: ecc-hook-continuous-improvement
feature: ECC hook の縮小と継続的改善ループ
created_at: 2026-08-27T21:01:51+09:00
grill_session: codex-interactive
status: draft
---

# Background

現行の Claude Code 向け ECC hook は、安全防御、品質自動化、観測、監査、通知、CLV2 学習を同じ event surface に重ねている。多数の hook が agent context へ advisory を注入し、通知は完了・idle・情報イベントまで送るため、ユーザーが通知を無視する状態になっている。観測・監査も、意思決定や改善へ結び付く定例 loop を持たない。

この変更は、安全境界を維持しながら、常時の agent 介入・token 消費・hook I/O・通知を削減する。同時に、個人/r06 の利用から秘匿化済み signal を集約し、週次に複数候補を評価して継続的な改善へ結び付ける。

# User Story

ユーザーとして、通常は画面を見ていなくても、通知が届いた時だけ「いま自分の判断または承認が必要」と理解したい。agent は安全に自律判断できる限り作業を続け、実質的な判断が必要な時だけ Claude Code の `AskUserQuestion` で待機してほしい。

また、継続改善の候補は通知で押し付けられるのではなく、通常作業の完了後に最大一件だけ採否を尋ねられたい。一方で、優先されなかった候補も必要時に会話から一覧でき、採用・延期・見送り・Issue 化・効果測定まで追跡できてほしい。

# Acceptance Criteria

## Notification and user-decision contract

- `AC-001`: Claude Code の ntfy hook 通知は `permission_prompt` と `agent_needs_input` だけを送る。`idle_prompt`、`agent_completed`、`Stop` は Claude hook 通知から外す。
- `AC-002`: morning brief の `claude-brief` 通知は維持する。
- `AC-003`: evaluator の初回失敗は即時に一度だけ incident alert を送る。成功回復まで重複通知しない。
- `AC-004`: background evaluator incident が未確認なら、次の interactive 作業の自然な完了点で agent は `AskUserQuestion` により「修復する・次週まで延期・休止」を尋ねる。
- `AC-005`: 共通 instructions は、安全で可逆的な既定判断がなく、外部公開・実データ・security・費用・互換性・プロダクト仕様などに実質的な影響がある時だけ native な質問面でユーザー判断を求めるよう定義する。通常の実装手順は重ねて確認しない。
- `AC-006`: Claude Code では判断待ちに必ず `AskUserQuestion` を使う。通常 message や commentary で待機してはならない。
- `AC-007`: Codex には共通の判断原則を適用するが、v1 では Claude Code と同等の質問待ち通知・入力基盤を追加しない。

## Retained and removed hook behavior

- `AC-008`: `block-no-verify`、Bash destructive fact-forcing、`auto-tmux-dev`、Git の gitleaks pre-commit は維持する。Bash destructive fact-forcing は実承認 prompt へ変更せず、現行の fact-forcing 挙動を維持する。
- `AC-009`: `GATEGUARD_BASH_ROUTINE_DISABLED=1` により、session 最初の通常 Bash を止める routine Bash gate だけを無効化する。
- `AC-010`: Bash dispatcher から tmux reminder、git-push reminder、commit-quality を外す。Post-Bash dispatcher、PR 作成助言、raw Bash audit log も外す。
- `AC-011`: 無効状態の Edit/Write fact-forcing wiring を削除する。
- `AC-012`: linter/formatter config の変更は hard block ではなく、理由・影響・代替案を伴う `AskUserQuestion` により判断する。
- `AC-013`: `pre:edit-write:suggest-compact`、`pre:write:doc-file-warning`、per-edit quality gate、edit accumulator、Stop typecheck、design-quality warning、console warning を外す。品質検証は変更完了時の明示フローと CI へ移す。
- `AC-014`: MCP の proactive PreToolUse health probe を外し、PostToolUseFailure の recovery だけを維持する。
- `AC-015`: raw Bash audit、governance-capture SQLite、`ecc-status`/`ecc-sessions`/`ecc-work-items` reader を外す。raw command、path、governance payload を evaluator へ渡さない。
- `AC-016`: wave-orchestrator の設定、matcher、hook、テストは本変更で一切変更しない。

## Resource, loop, and scope signals

- `AC-017`: `ecc-metrics-bridge` と `ecc-context-monitor` を外す。
- `AC-018`: resource warning は UserPromptSubmit 時だけに評価する。statusline が owner-only snapshot に保存した context、session cost、5h/7d quota を読む。
- `AC-019`: resource warning の初期閾値は、context 残量 20%/10%、5h usage 80%/95%、7d usage 80%/95% とする。各 quota window では warning と critical を各一回だけ出し、`resets_at` の変更で状態をリセットする。
- `AC-020`: resource warning の warning 帯は短い agent 向け注意だけを返す。critical 帯では agent は `AskUserQuestion` で進め方を選ばせる。
- `AC-021`: tool loop は、最小の PostToolUse sentinel で維持する。同一 tool/input の反復を検出した時だけ一回の warning を返す。cost log 全走査、scope 判定、agent への通常時注入は行わない。
- `AC-022`: scope signal は Edit/Write/MultiEdit の時だけ収集する。session 内で変更された一意なファイル数を、salt 付き hash で重複排除し、raw path を保存・評価しない。agent context、stderr、通知には出さない。
- `AC-023`: session scope state は weekly rollup 後に削除する。数値だけの週次 aggregate は直近 12 週間保持する。
- `AC-024`: retained safety/warning/recovery が実際に発火した時だけ、account・event type・severity・時刻だけの匿名化済み event counter を記録する。通常の tool call と raw payload は記録しない。

## Session and CLV2 behavior

- `AC-025`: automatic session summary 保存、SessionStart の過去 summary/instinct/learned skill/project 情報注入、PreCompact の LLM summary を外す。native `--continue`/`--resume` と必要時の `$session-summary` を使う。
- `AC-026`: SessionStart は `ECC_SESSION_START_CONTEXT=off` で context 注入を停止しつつ、CLV2 observer の session lease 登録に必要な最小 lifecycle を維持する。
- `AC-027`: `clv2-session-notify` を外す。SessionStart ごとの Python cluster 計算、statusline の cluster 数、desktop 通知を止める。
- `AC-028`: CLV2 の PreToolUse/PostToolUse observer は維持し、週次 evaluator の signal にのみ使う。

## Weekly continuous-improvement loop

- `AC-029`: 金曜 18:00 に scheduled evaluator を一度実行する。個人/r06 の raw data はローカルで分離し、evaluator には account ラベル付きの秘匿化済み aggregate だけを渡す。
- `AC-030`: evaluator は複数の active candidate を生成・重複排除・順位付けし、schema 検証済みの candidate queue state を更新する。候補数を一件に制限しない。
- `AC-031`: 候補は `evidence_accounts` だけを provenance として持つ。変更影響 account は固定 field にせず、採用後の planning で判断する。
- `AC-032`: evaluator は raw transcript、raw command、raw governance payload、大量の過去 session summary を読まない。ローカルで集計済みの evidence を一度の構造化評価へ渡す。
- `AC-033`: turn/time 上限はコスト削減の手段として恣意的に下げない。正常 run の実測後に reliability guard として調整する。
- `AC-034`: 候補順位は頻度、影響、根拠の強さ、実装コスト/リスク、期待効果を記録して決める。
- `AC-035`: candidate queue は `${XDG_STATE_HOME:-~/.local/state}/agent-improvement/queue.json` に owner-only（directory 0700、file 0600）で保存する。Git や外部サービスへ自動公開しない。
- `AC-036`: active candidate は新しい根拠がなければ 4 週間で失効する。Issue 化済み候補は再提示せず、GitHub Issue を唯一の正本とする。
- `AC-037`: `$improvement-status` は read-only で evaluator health と active candidate 全件を会話内に表示する。延期・見送り・失効済みは `--history` で表示する。表示操作は evaluator を再実行しない。
- `AC-038`: 通常依頼の完了直前に common end-of-task rule が read-only `improvement-next` を確認する。open incident または review due の最優先候補がある場合だけ `AskUserQuestion` を出す。
- `AC-039`: 候補への回答は「採用・次週まで延期・見送り」の三択に固定する。回答直後に `improvement-resolve` が queue state を原子的に更新する。
- `AC-040`: 採用候補が現 session で安全かつ小さく完結できなければ、通常の Issue 作成フローで GitHub Issue 化する。Issue 化後の候補は queue で `promoted` と URL だけを保持する。
- `AC-041`: 採用候補には成功指標、変更前の基準値または観察事実、再評価日、効果不十分時の調整/revert 条件を持たせる。

## Scheduled jobs outside the v1 evaluator

- `AC-042`: weekday morning brief は維持する。
- `AC-043`: macOS defaults drift は agent/harness evaluator に含めない。separate maintenance lane を設計するまで、日曜 10:00 の drift LaunchAgent を休止する。
- `AC-044`: 現行の重い `$knowledge-distill` は、深い横断診断が必要な時の手動実行として維持する。scheduled evaluator は長文週報や直接 ntfy 通知を作らない。

# Considered Alternatives / Rejection Rationale

- **すべての通知を停止する** — 却下。permission、agent の実質問待ち、evaluator の incident、morning brief には明確な行動価値がある。通知を情報配達ではなく行動要求へ限定する。
- **候補を毎週一件だけ生成する** — 却下。優先されなかった改善機会を失う。提示だけを一件に制限し、候補キューは複数保持する。
- **候補一覧を Markdown/dashboard に出す** — 却下。ユーザーがローカル Markdown を読まないため。必要時に `$improvement-status` で会話内へ表示する。
- **turn/time 上限を先に下げて evaluator を安くする** — 却下。上限は通常コストを下げず、正常 run の timeout を増やす。入力集約・一回の構造化評価・実測によってコストを最適化する。
- **raw command/governance/transcript を evaluator に渡す** — 却下。改善に不要な sensitive context をモデルへ広げる。ローカル集計した匿名 event と数値だけを渡す。
- **scope signal を完全に廃止する** — 却下。変更規模は週次改善の有用な signal として残す。context warning をやめ、Edit/Write 時だけの匿名 collector へ置換する。
- **destructive Bash を毎回 actual permission prompt に変える** — 却下。承認回数を増やす。現行の destructive fact-forcing は維持し、routine Bash gate だけ無効化する。
- **macOS defaults drift を v1 evaluator へ混ぜる** — 却下。v1 は agent/harness の改善に限定する。maintenance lane として別設計する。
- **wave-orchestrator を通知ポリシーに合わせて編集する** — 却下。別 session で改修中のため、本変更では対象外とする。
- **Codex に Claude Code 相当の通知/質問基盤を同時に追加する** — 却下。現行の Codex surface に同等の hook/input 契約は確認できず、スコープを拡大する。v1 は common policy のみ適用する。

# Out of Scope

- wave-orchestrator の実装、settings、matcher、テストの変更
- Codex の mobile notification、structured user-input、background wait 基盤
- macOS defaults drift の maintenance lane 設計・実装
- destructive Bash fact-forcing の actual permission prompt への変更
- raw transcript/command/governance payload の保管・外部送信
- GitHub Issue の自動採用・自動クローズ・自動マージ

# Open Questions

- scheduled evaluator の model、実測ベースの turn/time reliability guard、input/output token budget は実装後の正常 run 分布を計測して決める。
- candidate queue の JSON schema と local aggregator の詳細な field 定義は、上記 Acceptance Criteria の不変条件を満たす最小形で設計する。
- evaluator incident の immediate alert を、既存 ntfy のどの topic/tag 設計で扱うかは notification schema の更新時に具体化する。
- 既存の `~/.claude*/session-data/` artifact の削除・保持期間短縮は、今回の hook 停止とは別の明示的な cleanup 判断として扱う。
