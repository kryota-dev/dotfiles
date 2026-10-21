# multi-review: leg の起動形

roster の役割を、実行中のハーネスに応じて起動する。役割の値（model・effort）は定義ファイルから読み、ここに書き写さない（読み方は [`pr-workflow/references/model-roles.md`](../../pr-workflow/references/model-roles.md)）。すべての起動を新規セッションにし、親の会話・過去のレビュー・他 leg の結果を渡さない。leg ごとに結果ファイルを親が決め（`<scratch>/multi-review/<owner>__<repo>__<PR>/<leg>-<round>.md`）、そのファイルか subagent の最終メッセージだけを読む。CLI の leg の並列は 3 本までにする（4 本目は、最初に終わった leg の後に起動する）。

## Claude Code から

### Claude の役割: Agent ツール

`subagent_type` に役割名（`review-general` など）を渡す。model・effort・道具は定義が決める。プロンプトには execution.md の Phase 3 に従う入力を入れる。報告が `⚠ This agent switched to` で始まれば fallback しているので、model-roles.md の「fallback の検出」に従う。

### GPT の役割: Codex

起動形と注意点は `codex` skill に従う（stdin で prompt を渡す、結果は `-o`、レビューは read-only）。

```bash
M=$(gpt_role "$ROLE" model) E=$(gpt_role "$ROLE" model_reasoning_effort)
codex exec --sandbox read-only --cd "$WT" --color never --json \
  -m "$M" -c model_reasoning_effort="$E" -o "$RESULT" < "$PROMPT_FILE" > "$STREAM" 2>&1
```

- `PROMPT_FILE` に execution.md の Phase 3 に従う入力を保存し、stdin で渡す。`perspectives.md` の共通の約束とその leg の観点、PR のタイトルと本文を入れ、`codex` skill の 4 部構成（Goal / Context / Constraints / Done when）で書く。`review` サブコマンドは使わない（プロンプトは受け取れるが `--base` と併用できず、共通の約束と差分の範囲を同時に指定できない）。
- Codex の sandbox からは `gh` の認証が届かないので、差分は `CHECKOUT_OK` なら `git diff <base SHA>...<HEAD SHA>` で取らせ（fetch は起動前に親が済ませる）、そうでなければ `${DIFF}` を埋め込む。PR のタイトルと本文の渡し方は execution.md の Phase 1 に従う。
- 再レビュー・再試行も毎回 `codex exec` を新規起動する。`resume` / `fork` は使わない。`$STREAM` の `thread.started` の ID は実行記録の識別用に保存し、次の起動には使わない。

## Codex から

### GPT の役割: spawn_agent

`agent_type` に役割名（`reviewer-gpt` など）、`fork_turns: "none"` を渡し、自己完結した入力を `message` に入れる。model と effort は `~/.codex/agents/<役割>.toml` が決める。

### Claude の役割: Claude Code

```bash
M=$(claude_role "$ROLE" model) E=$(claude_role "$ROLE" effort)
claude -p --model "$M" --effort "$E" --output-format json \
  --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
  --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" \
  < "$PROMPT_FILE" > "$RESULT" 2>"$RESULT.err"
```

`dontAsk` は許可リストに無い道具を確認なしで拒否する。`--setting-sources ""` で user / project の settings（広い allow を持つ）を読ませず、`--strict-mcp-config` で MCP も使わせないので、leg に許されるのは上の読み取りだけになる。`--setting-sources ""` では `~/.claude/agents` も読まれないので `--agent` は使わず、役割の値を `--model` と `--effort` で渡す。

プロンプトには `perspectives.md` の共通の約束と観点、対象、PR のタイトルと本文、差分（埋め込みか `git diff <base SHA>...<HEAD SHA>`）、完了の条件を入れる。intent には、親が取得したリンク先の issue / PR の本文のファイルのパスも渡し、`--allowedTools` にその `Read` を足す。`--resume` / `--continue` / `--fork-session` は使わず、再レビュー・再試行も新規起動する。JSON の `result` をレビュー結果として読み、`session_id` と `modelUsage`（実際に使われたモデル。要求していないモデルがあれば fallback）も保存する。JSON 自体と stderr は実行記録として保持する。
