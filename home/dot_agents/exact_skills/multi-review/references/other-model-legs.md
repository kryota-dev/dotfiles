# multi-review: other-model leg

実行中のハーネスとは別のモデルで同じ観点のレビューをさせ、見落としの偏りを減らす。leg ごとに結果ファイルを親が決め（`<scratch>/multi-review/<owner>__<repo>__<PR>/<leg>-<round>.md`）、そのファイルだけを読む。並列は 3 本までにする（standard / large で database と IaC が両方立つと 4 本になるので、残りの 1 本は最初に終わった leg の後に起動する）。

## Claude Code から: Codex

起動形と注意点は `codex` skill に従う（stdin で prompt を渡す、結果は `-o`、レビューは read-only）。

```bash
codex exec --sandbox read-only --cd "$WT" --color never --json \
  -c model_reasoning_effort=<high|xhigh> -o "$RESULT" <HEREDOC> > "$STREAM" 2>&1
```

- どの leg も heredoc で起動し、`perspectives.md` の共通の約束とその leg の観点、PR のタイトルと本文を入れる。`review` サブコマンドはプロンプトを受け取れず、共通の約束（PR 本文を読む・根拠の 3 条件）を渡せないので使わない。
- Codex の sandbox からは `gh` の認証が届かないので、差分は `CHECKOUT_OK` なら `git fetch origin <base>` してから `git diff origin/<base>...HEAD` で取らせ、そうでなければ `${DIFF}` を埋め込む。
- effort は general を `xhigh`、それ以外を `high` にする。
- 2 ラウンド目以降は、前のラウンドで指摘のあった leg を `codex exec resume <thread_id>` で続ける（`thread_id` は `$STREAM` の最初の `thread.started` にある）。resume には棄却台帳を入れない。resume できなければ fresh で起動する。

## Codex から: Claude Code

```bash
claude -p --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
  --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" \
  < "$PROMPT_FILE" > "$RESULT" 2>"$RESULT.err"
```

`dontAsk` は許可リストに無い道具を確認なしで拒否する。`--setting-sources ""` で user / project の settings（広い allow を持つ）を読ませず、`--strict-mcp-config` で MCP も使わせないので、leg に許されるのは上の読み取りだけになる。

プロンプトには `perspectives.md` の共通の約束と観点、対象、PR のタイトルと本文、差分（埋め込みか `git diff origin/<base>...HEAD`）を入れる。Claude Code の resume は使わず、毎ラウンド fresh で起動して棄却台帳を入れる。
