# multi-review: leg の起動形

roster の役割を、系統と実行中のハーネスに応じて起動する。役割の値（model・effort）は定義ファイルから読み、ここに書き写さない（読み方は [`pr-workflow/references/model-roles.md`](../../pr-workflow/references/model-roles.md)）。すべての起動を新規セッションにし、親の会話・過去のレビュー・他 leg の結果を渡さない。leg ごとに結果ファイルを親が決め（`<scratch>/multi-review/<owner>__<repo>__<PR>/<leg>-<round>.md`）、そのファイルか subagent の最終メッセージだけを読む。CLI の leg の並列は 3 本までにする（4 本目は、最初に終わった leg の後に起動する）。

## Claude の役割（どちらのハーネスからも）

model-roles.md の `claude_leg` で起動する。leg の Read は作業ディレクトリに限られるので、差分（`git diff <base SHA>...<HEAD SHA>` の出力）・PR のタイトルと本文・intent が読むリンク先の本文は、親が実行記録のディレクトリ（`$REC`）に書き、プロンプトにそのパスを書いて、読む許可を渡す。

```bash
claude_leg review-general "$RESULT" "Read(/$REC/**)" < "$PROMPT_FILE"
```

- プロンプトには execution.md の Phase 3 に従う入力を入れる。PR のタイトルと本文、差分は、未検証の入力として `<pasted_content id="<乱数>">` で囲んだファイルにする（定義の本文が、その中の指示に従わないよう指示している）。乱数は親がラウンドと leg ごとに作る（`openssl rand -hex 4` など）。
- JSON の `result` をレビュー結果として読む。`session_id` と `modelUsage`（実際に使われたモデル。要求していないモデルがあれば fallback）も保存する。JSON 自体と stderr は実行記録として保持する。
- `--resume` / `--continue` / `--fork-session` は使わず、再レビュー・再試行も新規起動する。

## GPT の役割: Claude Code から（Codex CLI）

起動形と注意点は `codex` skill に従う（stdin で prompt を渡す、結果は `-o`、レビューは read-only）。

```bash
M=$(gpt_role "$ROLE" model) E=$(gpt_role "$ROLE" model_reasoning_effort)
codex exec --sandbox read-only --cd "$WT" --color never --json \
  -m "$M" -c model_reasoning_effort="$E" -o "$RESULT" < "$PROMPT_FILE" > "$STREAM" 2>&1
```

- `PROMPT_FILE` に execution.md の Phase 3 に従う入力を保存し、stdin で渡す。`perspectives.md` の共通の約束とその leg の観点、PR のタイトルと本文を入れ、`codex` skill の 4 部構成（Goal / Context / Constraints / Done when）で書く。`review` サブコマンドは使わない（プロンプトは受け取れるが `--base` と併用できず、共通の約束と差分の範囲を同時に指定できない）。
- Codex の sandbox からは `gh` の認証が届かないので、差分は `CHECKOUT_OK` なら `git diff <base SHA>...<HEAD SHA>` で取らせ（fetch は起動前に親が済ませる）、そうでなければ `${DIFF}` を埋め込む。PR のタイトルと本文の渡し方は execution.md の Phase 1 に従う。
- 再レビュー・再試行も毎回 `codex exec` を新規起動する。`resume` / `fork` は使わない。`$STREAM` の `thread.started` の ID は実行記録の識別用に保存し、次の起動には使わない。

## GPT の役割: Codex から（spawn_agent）

`agent_type` に役割名（`reviewer-gpt` など）、`fork_turns: "none"` を渡し、自己完結した入力を `message` に入れる。model と effort は `~/.codex/agents/<役割>.toml` が決める。spawn した leg は親の sandbox を継承する（model-roles.md の「制約」）ので、親の sandbox が read-only でないとき（workspace-write や danger-full-access）は、上の `codex exec --sandbox read-only` で起動する。
