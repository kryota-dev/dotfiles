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
| approval | 質問、選択肢、影響を表示し、明示承認まで外向き操作をしない | `AskUserQuestion` | interactive `main` session の native command approval。`codex exec` は承認待ちで停止 |
| worker | 独立 context、最小権限、親が採番した結果 file、失敗時 1 回 retry | custom Agent | `codex exec` child process |
| review rubric | 共通 reviewer 本文を唯一の SSOT とする | frontmatter 付き Claude adapter | rubric を stdin prompt に注入 |
| notification | 進捗ではなく必要な承認・block・完了のみ通知する | `notify` があれば使用 | 会話出力。CLI は state を表示 |
| external operation | allowlist 済み operation manifest だけを host が実行する | 親 process | `agent-workflow` runner |

## Approval and resume

承認 gate は intent、commit、push、PR 作成、ready-for-review、人間 reviewer への返信、
merge-ready である。merge は常に user が行う。

対話型 harness は会話で承認を得る。interactive Codex は、対象・影響・固定 host action を先に会話で提示し、
その action を sandbox 外で実行するための **Codex native command approval** を要求する。user は Codex の
approval UI だけで許可または拒否し、terminal command を実行しない。approval は action ごとに一回限りであり、
任意 command や persistent allowlist を承認対象にしてはならない。

`codex exec` のような非対話実行は `waiting-for-user` state を返す。user は同じ run を interactive `main`
session で開き、そこで action の native approval を選ぶ。`--resume <run-id>` は state を復元するだけで、
approval を与えない。

## Persistent data

- Git 追跡する handoff: `.agent-workflow/prds/` と `.agent-workflow/plans/`
- 短期の運用 state: account home 配下の `~/.local/state/agent-workflow/`。runner は `HOME` / `XDG_STATE_HOME`
  の上書きを採用しないため、workspace-write agent が state の場所を agent-writable な path へ差し替えることはできない。
  named profile は同じ OS user を共有するため、ここは profile 間の秘密情報隔離ではない。外向き action は state の
  run id だけで対象を選ばず、実行時の canonical linked worktree が state の repository binding と一致することも要求する。
- legacy `.claude/{prds,plans,pull-requests}` は read-only migration input としてのみ読む。
  新規ファイルの作成、移動、削除はしない。
- `state.tsv` には task 本文、review 本文、token、秘密情報を保存しない。run id、phase、PR 番号、
  branch、作成時刻だけを保存し、30 日後に削除対象とする。PR title/body の下書きは同じ
  run directory の transient file に限り、`create-pr` action が path containment を検証して読む。
  legacy v1/v2 state は repository binding がないため、外向き action で拒否する。interactive Codex の native
  approval を伴う `init <run-id>` を記録済み linked worktree から実行した場合だけ、current worktree を照合して
  v3 binding を再確立する。

## Codex-only execution

Codex-only では Claude worker を省略しない。各 Claude reviewer は同じ shared rubric を
使う独立した Codex leg に置き換える。異なる model family による review が利用できない
ことは統合結果に明記する。必須 leg の結果、GitHub 認証、host runner、承認回収のいずれかが
利用不能なら `blocked` として停止する。optional specialist だけは欠落を明記して継続できる。

Codex child は `codex/SKILL.md` の `shared` (read-only) または `agent`
(workspace-write) profile を使用する。workspace-write child は linked worktree だけで実行し、
親が diff 全体を review してから test、commit、push の順に進める。

## Host runner manifest

`agent-workflow` は任意 command を受け取らない。`worktree-init`、`init`、`commit`、`push`、`prepare-pr`、
`create-pr`、`checks`、`ready-for-review` の固定 action だけを実行し、worktree、branch、引数形式を検証する。
`worktree-init` は clean な main worktree の `main` branch から、固定導出した sibling path へ hook を無効化した
`git worktree add` を実行する。`wtp`、repository の Git hook / post-create hook、`direnv allow` は host action から実行しない。新規 state は
canonical worktree path と common Git directory を束縛し、以後の action で照合する。`init` は実行時の linked worktree
だけを対象にし、任意 path を受け取らない。
runner は最初に POSIX shell から固定した `env -i` 環境の Bash へ再実行する。これにより `BASH_ENV`、`GIT_*`、
`GH_*`、agent が差し替えた `PATH` を host action に継承しない。Git は固定 system path、GitHub CLI は既知の
absolute path だけから解決する。`commit` は stage 後に account 側の pinned mise binary と固定 global config による
gitleaks pre-commit を scan-only で直接実行し、scanner / config がなければ fail-closed とする。worktree 内の
`.gitleaks.toml` は host scan に影響しない。worktree 作成、stage、commit、push は `core.hooksPath=/dev/null`（commit は
さらに `--no-verify`）で repository / local hook を実行しない。`commit`、`push`、`prepare-pr`、`create-pr`、`checks`、`ready-for-review` は、
canonical current worktree が state の記録値と一致するときだけ実行する。
`prepare-pr` は linked worktree 内の title/body source を private run state へ 0600 でコピーする。書き込みを
伴う action（run state を初期化する `init` を含む）は interactive Codex の native command approval または Claude の
approval capability の直後だけに実行する。runner 自身は二重の TTY prompt や承認済み gate を持たない。sandbox を
`--yolo` 等で迂回してはならない。
