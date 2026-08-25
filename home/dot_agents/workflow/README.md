# Agent Workflow Harness Contract

`pr-workflow` とその依存 skill は、この文書を実行時の共通契約として参照する。skill
本文に残る harness 固有の記述より、この契約を優先する。

共通の判断・state・review rubric はここに置き、実行方法だけを
[`claude.md`](claude.md) と [`codex.md`](codex.md) の adapter に分離する。skill 本文は
adapter 固有の手順を新しい SSOT として増やしてはならない。

## Harness selection

- 既定は現在の実行環境から `codex` または `claude` を自動検出する。
- `--harness=codex|claude` は自動検出を上書きする。検出不能・値不正・必要 capability
  の欠落は silent fallback せず `blocked` として停止する。
- 既存の引数と Claude Code の起動方法は維持する。harness と resume は追加引数である。

## Common capabilities

| Capability | 共通契約 | Claude adapter | Codex adapter |
| --- | --- | --- | --- |
| approval | 質問、選択肢、影響を表示し、明示承認まで外向き操作をしない | `AskUserQuestion` | 会話で承認を回収。非対話では `agent-workflow approve` を TTY で実行 |
| worker | 独立 context、最小権限、親が採番した結果 file、失敗時 1 回 retry | custom Agent | `codex exec` child process |
| review rubric | 共通 reviewer 本文を唯一の SSOT とする | frontmatter 付き Claude adapter | rubric を stdin prompt に注入 |
| notification | 進捗ではなく必要な承認・block・完了のみ通知する | `notify` があれば使用 | 会話出力。CLI は state を表示 |
| external operation | allowlist 済み operation manifest だけを host が実行する | 親 process | `agent-workflow` runner |

## Approval and resume

承認 gate は intent、commit、push、PR 作成、ready-for-review、人間 reviewer への返信、
merge-ready である。merge は常に user が行う。

対話型 harness は会話で承認を得る。`codex exec` のような非対話実行は
`waiting-for-user` state を返し、user が TTY で次を実行した後だけ再開できる。

```bash
agent-workflow approve <run-id> <gate>
agent-workflow status <run-id>
```

`--resume <run-id>` は state を復元するだけで、承認を与えない。

## Persistent data

- Git 追跡する handoff: `.agent-workflow/prds/` と `.agent-workflow/plans/`
- 短期の運用 state: `${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow/`
- legacy `.claude/{prds,plans,pull-requests}` は read-only migration input としてのみ読む。
  新規ファイルの作成、移動、削除はしない。
- `state.tsv` には task 本文、review 本文、token、秘密情報を保存しない。run id、phase、PR 番号、
  branch、承認済み gate、作成時刻だけを保存し、30 日後に削除対象とする。PR title/body の下書きは同じ
  run directory の transient file に限り、`create-pr` action が path containment を検証して読む。

## Codex-only execution

Codex-only では Claude worker を省略しない。各 Claude reviewer は同じ shared rubric を
使う独立した Codex leg に置き換える。異なる model family による review が利用できない
ことは統合結果に明記する。必須 leg の結果、GitHub 認証、host runner、承認回収のいずれかが
利用不能なら `blocked` として停止する。optional specialist だけは欠落を明記して継続できる。

Codex child は `codex/SKILL.md` の `shared` (read-only) または `agent`
(workspace-write) profile を使用する。workspace-write child は linked worktree だけで実行し、
親が diff 全体を review してから test、commit、push の順に進める。

## Host runner manifest

`agent-workflow` は任意 command を受け取らない。`worktree-init`、`commit`、`push`、`create-pr`、
`checks`、`ready-for-review` の固定 action だけを実行し、worktree、branch、gate、引数形式を検証する。
`worktree-init` は main worktree の TTY からだけ新しい linked worktree と run state を作成する。approval が
必要な action は先に TTY 承認された state を要求する。sandbox を `--yolo` 等で迂回してはならない。
