# 役割ごとのモデルとエフォート

pr-workflow・sdd・multi-review・security-review・review-resolve-loop・codex が、どの作業をどのモデルにどのエフォートで任せるかを、この文書で決める。設計と判断は Claude。実装者は PR ごとに Claude と GPT から選ぶ（下の「実装者の選択」）。モデルとエフォートの値は定義ファイルにだけ書き、skill の本文には役割の名前だけを書く。モデル固有の性質も、この文書にだけ書く。

## 役割表

値の正本は定義ファイルで、この表との一致は `tests/agent_roles.bats` が検査する。Claude の役割は `~/.agents/roles/<役割>.md`、GPT の役割は `~/.codex/agents/<役割>.toml` にある。Claude の役割は Claude Code の subagent として使わないので、Claude Code が読む `~/.claude/agents` には置かない（置くと、自動委譲で親のセッションの中で走りうる）。

| 役割 | 系統 | model | effort | 用途 |
|---|---|---|---|---|
| `spec-designer` | Claude | claude-opus-5-5 | high | Codex から起動したときの sdd の spec と small の計画 |
| `review-general` | Claude | claude-opus-5-5 | high | multi-review の general（standard 以上） |
| `review-general-light` | Claude | claude-opus-5-5 | medium | multi-review の general（trivial・small） |
| `review-security` | Claude | claude-opus-5-5 | high | multi-review の security、security-review の Phase 2 |
| `review-security-deep` | Claude | claude-fable-5-1 | high | security-review の `--deep` |
| `review-intent` | Claude | claude-opus-5-5 | high | multi-review の intent |
| `review-simplicity` | Claude | claude-sonnet-5-5 | medium | multi-review の simplicity |
| `fact-checker` | Claude | claude-sonnet-5-5 | medium | multi-review の裏取りの委譲（web の一次ソースだけ） |
| `implementer-claude` | Claude | claude-sonnet-5-5 | high | 実装者に Claude を選んだ PR の standard・large の実装（tasks.md の 1 タスク） |
| `implementer-claude-light` | Claude | claude-sonnet-5-5 | medium | 実装者に Claude を選んだ PR の small の実装、CI の失敗の修正、レビュー指摘の修正 |
| `implementer-claude-opus` | Claude | claude-opus-5-5 | high | 実装者に Claude を選んだ PR で、`implementer-claude` か `implementer-claude-light` が失敗したときの格上げ |
| `implementer` | GPT | gpt-6.1-sol | high | 実装者に GPT を選んだ PR の standard・large の実装（tasks.md の 1 タスク） |
| `implementer-light` | GPT | gpt-6.1-sol | medium | 実装者に GPT を選んだ PR の small の実装、CI の失敗の修正、レビュー指摘の修正 |
| `implementer-astra` | GPT | gpt-6-astra | high | 実装者に GPT を選んだ PR で、`implementer` か `implementer-light` が失敗したときの格上げ |
| `reviewer-gpt-light` | GPT | gpt-6.1-sol | medium | multi-review の general の GPT 側（実装者に Claude を選んだ PR の trivial・small） |
| `reviewer-gpt` | GPT | gpt-6.1-sol | high | multi-review の general の GPT 側（large、実装者に Claude を選んだ PR の standard）・database・IaC、security-review の Phase 2・3 |
| `checker-gpt` | GPT | gpt-6.1-sol | medium | security-review の Phase 4 |

表に無い作業は親が行う。Claude Code の親は Opus 5.5（medium、`settings.json` の既定）で、分類・GATE・統合の判断・spec と計画の執筆・trivial の編集・数行で済む修正を受け持つ。Codex の親は GPT-6.1 Sol（medium、`config.toml` の既定）である。

`xhigh` と `max` は使わない。Anthropic と OpenAI はどちらも、品質の向上を自分の評価で測ってから使うよう勧めている（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#calibrate-effort)、[GPT-6.1 Sol](https://developers.openai.com/api/docs/guides/latest-model)）。測って差が出たら、ここと定義を一緒に上げる。

## 実装者の選択

実装者の系統（Claude / GPT）は PR ごとに選び、その PR の初回の実装・CI の修正・指摘の修正・sdd の Phase 4・格上げのすべてに同じ系統を使う。段ごとの役割は次のとおり。

| 段 | Claude | GPT |
|---|---|---|
| light（small・CI の修正・指摘の修正） | `implementer-claude-light` | `implementer-light` |
| 通常（standard・large の 1 タスク） | `implementer-claude` | `implementer` |
| 最上位（格上げ） | `implementer-claude-opus` | `implementer-astra` |

推奨の規則（選ぶときは推奨を先頭に置き、各選択肢に役割と理由を 1 行で添える）:

- 既定は Codex（GPT）。
- `command -v codex` が失敗するか、`codex login status` が 0 以外なら Claude。Codex を起動できない。
- Phase 0 の時点で分かる入力（Issue・Phase 0 で読んだファイル・spec や PRD）の合計のバイト数を 4 で割った見込みが `LONG_CONTEXT_TOKENS=272000` を超えるなら Claude。Sonnet 5.5 は 272K トークンを超えるプロンプトで大幅に安い（[BenchLM](https://benchlm.ai/compare/claude-sonnet-5-5-vs-gpt-6-1-sol)）。

secret や認証情報に触れうるタスクは、どちらを選んでも親が書く。

## 割り当ての根拠

2026-10 時点の公式資料と第三者の評価による。モデルが替わったら、ここと定義ファイルを一緒に見直す。

- **設計と判断に Opus 5.5**: 大半の作業で Fable 5.1 と同等か上回り、単価は 6 割安い。既定の medium でも Opus 5 の high に並び、コードレビューでは Opus 5 より多くのバグを、少ない誤検知で見つける（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#capabilities-relevant-to-prompting)）。actionable precision は 66.7% で、Sonnet 5.5 は 41.2%（[CodeRabbit](https://www.coderabbit.ai/blog/sonnet-5-5-model-review)）。
- **Fable 5.1 は格上げ先だけに使う**: 最難の長時間作業では強いが、単価が高い。頼まれた以上の変更やテストを足しがちで（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1#keep-changes-and-tests-to-what-the-task-asks-for)）、15 回の試行の 1 回でテストを通すための近道をした報告もある（[The New Stack](https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/)。本文は取得できず、見出しと要約で確認）。
- **範囲の狭い作業に Sonnet 5.5**: Opus 5.5 の半額で速いが、持続的な判断では Opus に劣る（[Anthropic](https://www.anthropic.com/claude-sonnet-5-5)）。
- **実装に GPT-6.1 Sol**: high で DeepSWE が Astra の high と同点で、費用は約 5 分の 1、3 割速い。security の判定（SecPass）も Astra とほぼ同じで、テストの改ざんなどの不正は 0 件だった（[Endor Labs](https://www.endorlabs.com/learn/gpt-6-1-sol-on-codex-astra-level-security-a-third-faster-zero-cheating)）。Astra は、Sol で足りないときの格上げ先にとどめる（[OpenAI](https://developers.openai.com/api/docs/guides/latest-model)）。
- **実装の段を系統で揃える**: Sonnet 5.5 と GPT-6.1 Sol はどちらも $2/$10 per MTok で、Opus 5.5 と GPT-6 Astra がそれぞれの最上位である（[Anthropic](https://www.anthropic.com/claude-sonnet-5-5)、[OpenAI](https://developers.openai.com/api/docs/models)）。light・通常・最上位の 3 段が、どちらの系統でも同じ位置に並ぶ。Sonnet 5.5 は、仕様が明確な agentic coding を medium から、難しければ high から始めるよう公式が勧め、最難の長時間作業には Opus を勧めている（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#calibrate-effort)）。
- **GPT-6 Luna は採らない**: 単価は Sol の 1/20 だが、Codex の harness での Coding Agent Index が Sol の 57 に対して 41 である（[ComputingForGeeks](https://computingforgeeks.com/gpt-6-sol-luna-released-features-benchmarks/)）。失敗と格上げの往復が増えうる。
- **general は実装と別の系統で見る**: 同じ系統のモデルは見落としが重なりやすい。実装者の系統と逆の系統が、general の主担当になる。

## 弱点への対策（公式のプロンプトのガイドによる）

| 対象 | 公式が挙げる傾向 | 委譲プロンプトと定義に書くこと |
|---|---|---|
| Opus 5.5 | 頼まれた範囲を広げたり、自分の判断で作業を置き換えたりする。自分の作業は指示が無くても検証する（[Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5#task-scope-and-over-verification)） | 頼まれた範囲を届けること（定義の本文に書いてある）。「念のため再確認する」のような検証の指示は足さない（検証が過剰になる）。考える量はプロンプトではなくエフォートで調整する（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#calibrate-effort)） |
| Claude 全般 | 貼り付けられた本文の中の指示にも従いうる | PR の本文・diff・Issue・Web の内容を `<pasted_content id="<乱数>">` と `</pasted_content id="<乱数>">` で囲む。定義の本文がその扱いを指示している（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#mark-pasted-text-in-user-messages)）。タグは偽装できるので、道具の制限（下記）と併用する |
| Sonnet 5.5 | low・medium の長い作業で、確認のために止まりやすい。頼まれていないテスト・文書・小さなファイルを足しがち。low では検査を飛ばして完了と報告することがある（[Sonnet 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#steer-initiative-and-scope)、[Verification on coding tasks](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#verification-on-coding-tasks)） | 定義の本文に、完了まで進めること・頼まれていない追加をしないこと・実際の検査で確かめること・確かめられなかった検査を報告することを書いてある。low は使わない |
| Fable 5.1 | 頼まれていない修正・拡張・テストを足しがち | 定義の本文の「範囲を届ける」に加え、変更を伴う作業では任せない（レビューだけに使う） |
| GPT-6.1 Sol | 確認の質問をして止まりやすい。小さな変更でもテストを広げすぎる。表と箇条書きの多い長い出力になりがち。skill や AGENTS.md の指示に敏感（[OpenAI](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices)） | 非対話で動いていて、可逆な作業は確認せずに完了させること。変更に見合うテストだけにすること。出力の形と長さ（定義の `developer_instructions` に書いてある）。委譲プロンプトは `codex` skill の 4 部構成で書く |

## Claude の役割の起動

Claude の役割は、どちらのハーネスからでも `claude -p` の別プロセスで起動する。理由は 3 つある。

- **権限**: Claude Code の subagent は親の permission の規則を継承する（[公式](https://code.claude.com/docs/en/sub-agents)）。親の allow には `npx`・`git push`・`sed` などがあるので、diff を読む leg に Bash を持たせると、埋め込まれた指示で実行されうる。
- **fallback の隔離**: cyber safeguard が fallback すると、Claude Code 2.1.229 以降はセッションの残りがそのモデルに固定される。subagent の fallback が親に波及するかは、ドキュメントに記述が無い。
- **検出**: `claude -p` の JSON の `modelUsage` で、実際に使われたモデルを確かめられる。手元の 2.1.291 の subagent の報告には、公式ドキュメントにある `⚠ This agent switched to` が出ない（cyber の fallback は `safeguards flagged this message` と `[answered by …]` の形で届く）。

```bash
claude_role() { sed -n "s/^$2: *//p" "$HOME/.agents/roles/$1.md" | head -1; }
# 定義の本文（2 つ目の --- より後）
claude_body() { awk 'n>=2; /^---$/{n++}' "$HOME/.agents/roles/$1.md"; }
# 秘密のファイルの拒否（claude_leg と claude_impl で共通）
CLAUDE_SECRET_DENY=(
  "Read(//**/.env)" "Read(//**/.env.*)" "Read(//**/.envrc)" "Read(//**/id_rsa)"
  "Read(//**/id_ed25519)" "Read(//**/*.pem)" "Read(//**/*.key)" "Read(//**/*credentials*.json)"
  "Read(//**/*credentials*.yaml)" "Read(//**/*credentials*.yml)" "Read(//**/*secret*.json)" "Read(//**/*secret*.yaml)"
  "Read(//**/*secret*.yml)" "Read(//**/secrets/**)" "Read(~/.ssh/**)" "Read(~/.aws/**)"
  "Read(~/.config/gcloud/**)" "Read(~/.config/gh/**)" "Read(~/.docker/**)" "Read(~/.codex/**)"
  "Read(~/.netrc)" "Read(~/.npmrc)"
)
# claude_leg <役割> <結果 JSON> [追加の許可 …] < プロンプト
claude_leg() {
  local role=$1 out=$2 m e tools t
  shift 2
  m=$(claude_role "$role" model) e=$(claude_role "$role" effort) tools=$(claude_role "$role" tools | tr -d ,)
  [ -n "$m" ] && [ -n "$e" ] && [ -n "$tools" ] || {
    echo "abort: ~/.agents/roles/$role.md が無い。chezmoi apply を実行する" >&2
    return 1
  }
  # ファイルを読む道具は Read の規則で作業ディレクトリに限り、それ以外の道具（WebFetch など）は名前で許す。
  local allow=("Read(./**)")
  for t in $tools; do
    case $t in Read | Grep | Glob | Edit | Write) ;; *) allow+=("$t") ;; esac
  done
  # shellcheck disable=SC2086 # tools は定義の道具名を空白で区切ったもの
  claude -p --model "$m" --effort "$e" --output-format json \
    --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
    --append-system-prompt "$(claude_body "$role")" \
    --tools $tools --allowedTools "${allow[@]}" "$@" \
    --disallowedTools "${CLAUDE_SECRET_DENY[@]}" \
    > "$out" 2> "$out.err"
}
```

- `--tools` で、使える道具そのものを定義の道具に絞る。`--allowedTools` は確認を省く指定で、道具を絞らない（`dontAsk` でも作業ディレクトリの中の読み取りは通る）。この違いは実機で確かめた。
- Read は `Read(./**)` で作業ディレクトリに限る。Read の規則は Grep と Glob にも効く。親が作業ディレクトリの外に置いた入力（差分・本文など）は、追加の許可に `Read(//<入力のディレクトリ>/**)` を渡して読ませる。
- `dontAsk` は許可リストに無い操作を確認なしで拒否する。`--setting-sources ""` で user / project の settings（広い allow を持つ）を読ませず、`--strict-mcp-config` で MCP も使わせない。settings.json の deny も効かなくなるので、同等以上の秘密のファイルを `--disallowedTools` で拒否する。パターンは拡張子と名前で絞り、`secretManager.ts` のような認証まわりのソースは拒否しない。
- `--setting-sources ""` では Claude Code の agent の定義も読まれないので `--agent` は使わず、値と本文は `~/.agents/roles` の定義から読んで渡す。
- 実装の役割を除く定義の道具は Read・Grep・Glob（`fact-checker` は WebFetch・WebSearch、`spec-designer` は Edit・Write も）で、Bash は持たない。diff・コミットの履歴・リンク先の Issue の本文は、親が取得してファイルに書き、そのディレクトリを追加の許可で渡す。`spec-designer` の書き込みは、追加の許可の `Edit(./<パス>/**)` で許したパスに限られる（`Edit` の規則は Write にも効く。許したパスの外は拒否されることを実機で確かめた）。
- 結果は JSON の `result` を読む。`session_id` と `modelUsage` も実行記録に残す。

## Claude の実装の役割の起動

実装の役割（`implementer-claude*`）は Bash を持ち、sandbox の中でテストを回す。起動は `claude_leg` と同じく `claude -p` で、sandbox の設定を `--settings` で渡す。`claude_leg` と同じ秘密のファイルの一覧は、共通の配列 `CLAUDE_SECRET_DENY` に置く。

```bash
# claude_impl <役割> <結果 JSON> [許すドメイン …] < プロンプト
claude_impl() {
  local role=$1 out=$2 m e tools gd gcd root secret_env settings
  shift 2
  gd=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) &&
    gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    root=$(git rev-parse --show-toplevel 2>/dev/null) &&
    [ "$gd" != "$gcd" ] || {
    echo "abort: linked worktree の中で実行する" >&2
    return 1
  }
  m=$(claude_role "$role" model) e=$(claude_role "$role" effort) tools=$(claude_role "$role" tools | tr -d ,)
  [ -n "$m" ] && [ -n "$e" ] && [ -n "$tools" ] || {
    echo "abort: ~/.agents/roles/$role.md が無い。chezmoi apply を実行する" >&2
    return 1
  }
  # 起動時の環境から、名前が認証情報らしい変数を拾って拒否に足す（固定の一覧だけでは漏れる）。
  secret_env=$(compgen -e | grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL' | jq -Rsc 'split("\n") | map(select(length > 0))')
  settings=$(jq -nc --arg gcd "$gcd" --argjson env "$secret_env" '{sandbox: {
    enabled: true, allowUnsandboxedCommands: false, failIfUnavailable: true, autoAllowBashIfSandboxed: true,
    network: {strictAllowlist: true, allowedDomains: $ARGS.positional},
    filesystem: {denyWrite: [$gcd]},
    credentials: {
      files: (["~/.ssh", "~/.aws", "~/.config/gcloud", "~/.config/gh", "~/.docker", "~/.codex", "~/.netrc", "~/.npmrc", "~/.git-credentials", "~/.gmail-mcp", "~/.config/op", "~/.gnupg", "~/.kube"] | map({path: ., mode: "deny"})),
      envVars: ((["GH_TOKEN", "GITHUB_TOKEN", "NPM_TOKEN", "OP_SERVICE_ACCOUNT_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] + $env) | unique | map({name: ., mode: "deny"}))}}}' --args "$@")
  # shellcheck disable=SC2086 # tools は定義の道具名を空白で区切ったもの
  claude -p --model "$m" --effort "$e" --output-format json \
    --permission-mode dontAsk --setting-sources "" --strict-mcp-config --settings "$settings" \
    --append-system-prompt "$(claude_body "$role")" \
    --tools $tools --allowedTools "Read(/$root/**)" "Edit(/$root/**)" \
    --disallowedTools "${CLAUDE_SECRET_DENY[@]}" \
    > "$out" 2> "$out.err"
}
```

- Read と Edit の許可は、worktree のルートの絶対パス（`//<root>/**`）で固定する。`./**` は現在のディレクトリを基準にするので、実装者が Bash で `cd` すると基準が移り、ルートのファイルへの Edit が `dontAsk` で拒否される（実機で確かめた）。
- プロンプトは stdin で渡す。`--allowedTools` などの可変長の引数が、末尾の位置引数を飲み込むため。
- Bash の allow は渡さない。sandbox の中のコマンドは auto-allow で確認なしに通り、`FOO=bar cmd` のように通常の判定に回るものは `dontAsk` で拒否される。
- `denyWrite` に git の共通ディレクトリを入れる。sandbox は linked worktree の共有 `.git` への書き込みを既定で許すので、commit・reset を物理的に止めるために必要である。linked worktree の外では起動しない。
- 環境変数は、固定の一覧に加えて、起動時の環境から名前が認証情報らしいものを拾い、`credentials.envVars` で sandbox の中から消す。`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` は使わない。付けると `bash t.sh` のようなスクリプトの実行が自動許可から外れ、`dontAsk` で拒否されて、実装者がテストを回せなくなる（実機で確かめた）。
- 実機の確認（2026-10-22、Claude Code 2.1.291、macOS）: この関数で、Bash は確認なしで通った。外部への `curl` は proxy に 403 で拒否された。worktree のルートの `.git` ファイルと `$HOME` への書き込みは `operation not permitted` で拒否され、Edit も拒否された。`~/.ssh` の読み取りは拒否され、`credentials.envVars` の環境変数（`GH_TOKEN`）は消えていた。一覧に無かった `~/.gmail-mcp` は読め、一覧に無い環境変数は見えたので、上の一覧と環境変数の拾い上げを足した。
- `failIfUnavailable` により、sandbox を起動できないと claude は起動時に終わる。sandbox なしで走らせ直さず、user に上げる。
- ネットワークは既定で無い。要るときは、必要性を説明できる場合に限り、許すドメインを第 3 引数以降に渡す。書き込みのできる API を持つドメイン（汎用のコードホスティングなど）は、秘密の持ち出しの経路になるので避ける。
- 親は `git status --porcelain` と `git diff` で、新規ファイルも含めて変更の全体を読んでから、ホストでテストと lint を実行する（`git diff` は未追跡のファイルを出さない）。commit は親が行う。順序は `codex` skill の親の手順と同じ。
- 結果の `modelUsage` に要求していないモデルがあれば、fallback として実行記録と PR の本文に残す。走らせ直さない。

## GPT の役割の起動

```bash
gpt_role() { sed -nE "s/^$2 *= *\"([^\"]*)\"\$/\1/p" "$HOME/.codex/agents/$1.toml" | head -1; }
```

| 親 | 起動 |
|---|---|
| Claude Code | `codex exec -m "$(gpt_role R model)" -c model_reasoning_effort="$(gpt_role R model_reasoning_effort)"`。実装は `--profile agent`、レビューと検証は `--sandbox read-only`。起動形の詳細は `codex` skill |
| Codex | `spawn_agent` に `agent_type: <役割>` と `fork_turns: "none"` を渡す |

値が空なら（`chezmoi apply` の前など）起動せずに止め、`chezmoi apply` を案内する。既定のモデルで黙って代えない。

**制約**: Codex の custom agent の定義では `sandbox_mode` を上書きできない（[公式](https://learn.chatgpt.com/docs/agent-configuration/subagents)）。Codex が親のとき、`spawn_agent` で起動したレビューの役割は親の sandbox を継承し、読み取り専用であることは `developer_instructions` の文言だけで担保される。書き込みを許さない sandbox で走らせたいレビューは、Codex からも `codex exec --sandbox read-only` で起動する。

## fallback の検出

Opus 5.5・Sonnet 5.5・Fable 5.1 は、cyber safeguard の classifier に当たると Opus 4.8 などに fallback する。ソースコードの脆弱性の走査は許可されているが、exploit の生成や攻撃手順の詳述は当たりうる（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#safeguard-refusals)）。

`claude_leg` の結果の `modelUsage` に、要求していないモデルがあれば fallback している。実行記録に「要求したモデル・実際のモデル」を残し、その leg を `reviewer-gpt` で 1 回だけ走らせ直す。fallback した結果は捨てずに、GPT の結果と並べて統合する。

## 実装の格上げ

格上げは 1 段ずつ行い、系統はまたがない。失敗は、検証が通らない、範囲の外を変えた、完了の条件を満たさない、のいずれか。

- light（`implementer-light` / `implementer-claude-light`）が同じタスクで 2 回失敗したら、同じ系統の通常の役割で 1 回試す。
- 通常の役割（`implementer` / `implementer-claude`）が 2 回（light から上がった場合は 1 回）失敗したら、同じ系統の最上位（`implementer-astra` / `implementer-claude-opus`）で 1 回だけ試す。
- それでもだめなら user に上げる。

2 回目を試す前に、失敗の原因を親が読み、委譲プロンプトを直す（同じプロンプトで回し直さない）。系統をまたがないのは、user が選んだ系統と違うモデルが書くと、レビューの系統の判断がずれるため。
