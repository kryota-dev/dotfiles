# multi-review: other-model leg

実行中のハーネスとは別のモデルで同じ観点のレビューをさせ、見落としの偏りを減らす。すべての起動を新規セッションにし、親の会話・過去のレビュー・他 leg の結果を渡さない。leg ごとに結果ファイルを親が決め（`<scratch>/multi-review/<owner>__<repo>__<PR>/<leg>-<round>.md`）、そのファイルだけを読む。並列は 3 本までにする（standard / large で database と IaC が両方立つと 4 本になるので、残りの 1 本は最初に終わった leg の後に起動する）。

## Claude Code から: Codex

起動形と注意点は `codex` skill に従う（stdin で prompt を渡す、結果は `-o`、レビューは read-only）。

```bash
codex exec --sandbox read-only --cd "$WT" --color never --json \
  --model "$MODEL" -c model_reasoning_effort="$EFFORT" -o "$RESULT" < "$PROMPT_FILE" > "$STREAM" 2>&1
```

- `PROMPT_FILE` に execution.md の Phase 3 に従う入力を保存し、stdin で渡す。`perspectives.md` の共通の約束とその leg の観点、PR のタイトルと本文を入れる。`review` サブコマンドは使わない（プロンプトは受け取れるが `--base` と併用できず、共通の約束と差分の範囲を同時に指定できない）。
- Codex の sandbox からは `gh` の認証が届かないので、差分は `CHECKOUT_OK` なら `git diff <base SHA>...<HEAD SHA>` で取らせ（fetch は起動前に親が済ませる）、そうでなければ `${DIFF}` を埋め込む。PR のタイトルと本文の渡し方は execution.md の Phase 1 に従う。
- `MODEL` は利用する設定から選んだモデル、`EFFORT` は general を `xhigh`、それ以外を `high` にして明示する。実行値・起動設定の記録は execution.md に従う。
- 再レビュー・再試行も毎回 `codex exec` を新規起動する。`resume` / `fork` は使わない。`$STREAM` の `thread.started` の ID は実行記録の識別用に保存し、次の起動には使わない。

## Codex から: Claude Code

```bash
claude -p --model "$MODEL" --effort "$EFFORT" --output-format json \
  --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
  --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" \
  < "$PROMPT_FILE" > "$RESULT" 2>"$RESULT.err"
```

`dontAsk` は許可リストに無い道具を確認なしで拒否する。`--setting-sources ""` で user / project の settings（広い allow を持つ）を読ませず、`--strict-mcp-config` で MCP も使わせないので、leg に許されるのは上の読み取りだけになる。

プロンプトには `perspectives.md` の共通の約束と観点、対象、PR のタイトルと本文、差分（埋め込みか `git diff <base SHA>...<HEAD SHA>`）を入れる。`MODEL` と `EFFORT` は上の Codex leg と同じ方針で明示する。`--resume` / `--continue` / `--fork-session` は使わず、再レビュー・再試行も新規起動する。JSON の `result` をレビュー結果として読み、`session_id` と利用モデルなど取得できたメタデータも保存する。JSON 自体と stderr は実行記録として保持する。
