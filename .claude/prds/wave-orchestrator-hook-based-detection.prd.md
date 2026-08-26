---
slug: wave-orchestrator-hook-based-detection
feature: wave-orchestrator の停止検知を hook ベースに移す
created_at: 2026-08-26T17:07:17+09:00
grill_session: 3282b3f6-f1d6-48a6-9a2d-f7fd3566d90f
status: finalized
---

# wave-orchestrator の停止検知を hook ベースに移す

## Background

`wave-orchestrator` の停止検知 (`scripts/pane-state.sh`) と送信 (`scripts/send-to-pane.sh`) は、tmux `capture-pane` が返す画面テキストの文字列照合に依存している。この方式は実運用で性質の違う 3 つの故障を起こした。

| Issue | 壊れている箇所 | 症状 | 気づけるか |
| --- | --- | --- | --- |
| #435 | `MARK_SELECTOR` | 確認画面を検知できず `--select` が拒否される | 騒がしい失敗 |
| #436 | `MARK_BGWAIT` | 過去のトランスクリプトに誤マッチし永久に `BUSY` と誤判定、停止を見落とす | **沈黙する失敗** |
| #438 | `input_state()` | キュー状態を未送信と誤判定し、成功した送信を失敗と報告したうえ確定キーを再送する | 偽陰性 |

TUI の文言・レイアウト・スクロールバックの内容・プレースホルダの有無は、いずれも検知や送信の正しさを保証する材料ではない。定数を 1 つ直しても次の TUI 変更で同じ形が再発する。

とくに #436 の型は沈黙するため、監視が「停止への遷移だけを報告する」運用である以上、イベントが出ないことと正常であることが区別できない。実際に子セッションが blocking gate を開いたまま放置され、利用者の指摘で初めて発覚した。

## User Story

orchestrator として、子セッションが停止したことと何を問われているかを、TUI の描画結果に依存しない形で受け取りたい。そうすれば見落とし（沈黙する失敗）と偽の承認（意図と別の選択肢の確定）の両方を、定数の保守ではなく構造で防げる。

## Acceptance Criteria

- `AC-001` 停止検知が TUI の文言・スクロールバックの内容に依存しない
- `AC-002` 提示された選択肢を構造化データとして取得し、ハイライト位置に依存せず応答できる
- `AC-003` 自由記述の送信成否を画面照合なしで確認できる
- `AC-004` hook が配線されていない環境では、capture へ黙ってフォールバックせず「検知不能」として報告し停止する
- `AC-005` hook payload の処理に回帰テスト (bats) がある
- `AC-006` payload の保存先が 700/600 で作られ、wave 完了後に削除される

## 設計

### 実測で確定した hook の挙動

AskUserQuestion で停止した瞬間に 2 つの hook が同時発火する。

- `Notification`: `notification_type` (`permission_prompt` / `idle_prompt` / `agent_needs_input` / `agent_completed`)、`message`、`session_id`、`cwd`、`transcript_path`
- `PreToolUse` (matcher `AskUserQuestion`): `tool_name`、`tool_use_id`、`session_id`、`permission_mode`、`effort`、`transcript_path`、`tool_input.questions[].{question,header,multiSelect,options[].{label,description}}`

応答後に `Stop` が `session_id` 付きで発火する。プロンプト送信時には `UserPromptSubmit` が発火する。

画面を一切見ずに全工程が成立することを実測で確認した: payload の `options[1].label` から index+1 = 数字キーを決めて送信し、意図した選択肢が選ばれた。数字キーはハイライト位置に依存せず直接選択する。

### 決定事項

| 枝 | 決定 | 根拠 |
| --- | --- | --- |
| hook の実体 | スクリプトファイル (chezmoi 管理)。inline command にしない | 大きな minified コマンドを settings.json に埋めると読めなくなる (既存 launcher のコメントに教訓が残っている) |
| 配線 | user settings へ恒久追加 (既存配列に 1 要素足す) | `--settings` は override で、足したいイベントの枠を既存 hook が使っているため壊す |
| 書き込み先 | `${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events/<session_id>.jsonl` | 並行追記で行が混ざるのを原理的に回避。transcript と同等の機微度なので 700/600 |
| セッション対応づけ | 起動時に `--session-id <uuid>` を発行し、`ps` の argv から読む | state file にキャッシュしない (キャッシュした状態は実態とずれたときに嘘をつく) |
| 応答 | payload の options index + 1 を数字キーとして送る | ハイライト照合が不要になり、意図と別の選択肢を確定する事故が構造的に消える |
| フォールバック | しない。報告して停止する | 沈黙する失敗を新たに作らない |
| ENDED 判定 | `ps` の PID 生存確認 | hook では検知できない |

## Considered Alternatives / Rejection Rationale

### 却下 1: セッション jsonl を読む (当初の提案)

**実測で否定された。** assistant のメッセージは応答が返るまで jsonl に書かれない。

- 停止中に jsonl を全行読んでも `assistant` エントリが存在しない
- 先行する tool 実行を挟んだ実運用に近い条件でも末尾は直前の `tool_result` で終わり、「モデルが考え中」と「人の応答待ち」が同じ見え方になる
- 5.5 分放置しても 1 行も増えない (flush は時間ベースではない)
- 応答した瞬間に、それまで存在しなかった `tool_use` が過去のタイムスタンプを持って書かれる。終了後のファイルだけを見ると「応答待ちの間ずっと末尾にあった」と誤読できる

当初この誤読を根拠に jsonl 方式を提案していた。実測で覆したため hook 方式へ切り替えた。

### 却下 2: SDK へ移行する

Claude Code のラッパー実装 (`slopus/happy`) を調査したところ、同種の問題を SDK の `canUseTool` コールバックで解いていた。AskUserQuestion の検出も SDK ストリームから行っており、jsonl を読む local path は会話記録の転送のみで停止検知はしていない。

SDK 化は正解の一つだが、本 skill の中核 (独立した対話型セッションを立て、人が覗いて介入できる) と衝突するため採らない。hook なら設計を変えずに同じ「構造化イベントで受け取る」解に到達できる。

同調査から転用した知見: セッション ID の取得に `SessionStart` hook を使うのは実プロダクトでも採られている手法。jsonl を読む場合にスキップすべき内部イベントは `file-history-snapshot` / `change` / `queue-operation`。

### 却下 3: `--settings` で一時的に hook を仕込む

公式ドキュメントの優先順位で `--settings` は user settings を override する。粒度が `hooks` 全体かイベント単位かは確定できなかったが、どちらであっても足したいイベントの枠を既存 hook が使っているため壊すリスクがある。

### 却下 4: 保存先を transcript と同じ場所 / `$TMPDIR` にする

前者は既存 transcript と混ざり分離性が落ちる。後者は macOS の TMPDIR が他プロセスから読める場合がある。専用の state ディレクトリを 700 で作る案を採った。

## Out of Scope

- SDK ベースへの移行 (却下 2)
- `wave-orchestrator` 以外の skill の hook 利用
- 既存 Notification hook (通知系) の挙動変更

## Open Questions

- `--settings` の override 粒度 (`hooks` 全体かイベント単位か) は確定できていない。恒久設定を採ることで論点を回避しているため、実装には影響しない。
- `Notification` の `idle_prompt` / `agent_needs_input` が、AskUserQuestion 以外のどの停止で発火するかは網羅していない (実測できたのは `permission_prompt`)。実装時に他の停止パターンを確認する。
