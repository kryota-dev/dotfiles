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
| `review-security-deep` | Claude | claude-fable-5-2 | high | security-review の `--deep` |
| `review-intent` | Claude | claude-opus-5-5 | high | multi-review の intent |
| `review-simplicity` | Claude | claude-opus-5-5 | high | multi-review の simplicity（standard 以上） |
| `review-simplicity-light` | Claude | claude-sonnet-5-5 | medium | multi-review の simplicity（small） |
| `fact-checker` | Claude | claude-sonnet-5-5 | medium | multi-review の裏取りの委譲（web の一次ソースだけ） |
| `implementer-claude` | Claude | claude-sonnet-5-5 | high | 実装者に Claude を選んだ PR の standard・large の実装（tasks.md の 1 タスク） |
| `implementer-claude-light` | Claude | claude-sonnet-5-5 | medium | 実装者に Claude を選んだ PR の small の実装、CI の失敗の修正、レビュー指摘の修正 |
| `implementer-claude-opus` | Claude | claude-opus-5-5 | high | 実装者に Claude を選んだ PR で、`implementer-claude` か `implementer-claude-light` が失敗したときの格上げ |
| `implementer` | GPT | gpt-6.1-sol | high | 実装者に GPT を選んだ PR の standard・large の実装（tasks.md の 1 タスク） |
| `implementer-light` | GPT | gpt-6.1-sol | medium | 実装者に GPT を選んだ PR の small の実装、CI の失敗の修正、レビュー指摘の修正 |
| `implementer-astra` | GPT | gpt-6.2-astra | high | 実装者に GPT を選んだ PR で、`implementer` か `implementer-light` が失敗したときの格上げ |
| `reviewer-gpt-light` | GPT | gpt-6.1-sol | medium | multi-review の general の GPT 側（実装者に Claude を選んだ PR の trivial・small） |
| `reviewer-gpt` | GPT | gpt-6.1-sol | high | multi-review の general の GPT 側（large、実装者に Claude を選んだ PR の standard）・database・IaC、security-review の Phase 2・3、sdd の spec レビュー |
| `checker-gpt` | GPT | gpt-6.1-sol | medium | security-review の Phase 4 |
| `grill-counterpart` | Claude | claude-opus-5-5 | high | grill-me の auto mode の議論の相手（親が Codex のとき） |
| `grill-counterpart-gpt` | GPT | gpt-6.1-sol | high | grill-me の auto mode の議論の相手（親が Claude Code のとき） |

表に無い作業は親が行う。Claude Code の親は Opus 5.5（medium、`settings.json` の既定）で、分類・GATE・統合の判断・spec と計画の執筆・trivial の編集・数行で済む修正を受け持つ。Codex の親は GPT-6.1 Sol（medium、`config.toml` の既定）である。

`xhigh` と `max` は使わない。Anthropic と OpenAI はどちらも、品質の向上を自分の評価で測ってから使うよう勧めている（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#calibrate-effort)、[GPT-6.1 Sol](https://developers.openai.com/api/docs/guides/latest-model)（2026-10 に読んだ内容。ページは GPT-6.2 向けに替わった））。測って差が出たら、ここと定義を一緒に上げる。

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

2026-11 時点の公式資料と第三者の評価による。モデルが替わったら、ここと定義ファイルを一緒に見直す。

- **設計と判断に Opus 5.5**: 大半の作業で Fable 5.1 と同等か上回り、単価は 6 割安い。既定の medium でも Opus 5 の high に並び、コードレビューでは Opus 5 より多くのバグを、少ない誤検知で見つける（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#capabilities-relevant-to-prompting)）。actionable precision は 66.7% で、Sonnet 5.5 は 41.2%（[CodeRabbit](https://www.coderabbit.ai/blog/sonnet-5-5-model-review)）。
- **Fable 5.2 は `--deep` のレビューに限る**: 難しい推論と長い agentic な作業に向き、Opus 5.5 の高いエフォートで足りないときの格上げ先とされるが、単価は $8/$40 per MTok と高い（[Anthropic](https://platform.claude.com/docs/en/about-claude/models/overview)）。所有者として扱う指示で、頼まれていない変更・テスト・文書が増える。範囲を絞る規則でも打ち消せないため、変更を伴わないレビューに限る（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2#say-who-owns-the-code)）。
- **範囲の狭い作業に Sonnet 5.5**: Opus 5.5 の半額で速いが、持続的な判断では Opus に劣る（[Anthropic](https://www.anthropic.com/claude-sonnet-5-5)）。
- **実装に GPT-6.1 Sol**: high で DeepSWE が GPT-6 Astra の high と同点で、費用は約 5 分の 1、3 割速い。security の判定（SecPass）も GPT-6 Astra とほぼ同じで、テストの改ざんなどの不正は 0 件だった（[Endor Labs](https://www.endorlabs.com/learn/gpt-6-1-sol-on-codex-astra-level-security-a-third-faster-zero-cheating)）。
- **格上げ先は GPT-6.2 Astra**: 単価は入力 $8・出力 $40 per MTok で、GPT-6 Astra（$10/$50）より 20% 安い（[OpenAI の料金表](https://developers.openai.com/api/docs/pricing)）。OpenAI は最も難しい作業に Astra、複雑な作業を低い費用でこなすのに Sol を勧めているため、Sol で足りないときの格上げ先にする（[公式ガイド](https://developers.openai.com/api/docs/guides/latest-model)）。
- **Sol は GPT-6.2 に上げない**: 単価は同じ $2/$10 per MTok だが（[OpenAI の料金表](https://developers.openai.com/api/docs/pricing)）、2026-11-18 に各 1 回の A/B を行うと、同じ実装タスクで 6.2 は頼んでいない書き直しをし、テストは通るものの、末尾が書きかけの入力で振る舞いが後退した。同じ diff のレビューは 6.2 が 6 件、6.1 が 1 件で、6.2 だけの 5 件は通常の使い方では起きにくく、時間とトークンは 6.2 が 1.4〜2.2 倍だった。Artificial Analysis の Coding Agent Index でも Sol は下がり（[VentureBeat](https://venturebeat.com/technology/essentially-unusable-openai-launches-gpt-6-2-astra-and-sol-to-negative-reception-from-ai-power-users)）、`gpt-6.1-sol` に廃止の予定は無いため（[OpenAI の廃止予定](https://developers.openai.com/api/docs/deprecations)）、6.1 を維持する。各 1 回の測定なので、Codex の更新か評判が落ち着いたら測り直す。
- **実装の段を系統で揃える**: Sonnet 5.5 と GPT-6.1 Sol はどちらも $2/$10 per MTok で、Opus 5.5 と GPT-6.2 Astra がそれぞれの最上位である（[Anthropic](https://www.anthropic.com/claude-sonnet-5-5)、[OpenAI](https://developers.openai.com/api/docs/models)）。light・通常・最上位の 3 段が、どちらの系統でも同じ位置に並ぶ。Sonnet 5.5 は、仕様が明確な agentic coding を medium から、難しければ high から始めるよう公式が勧め、最難の長時間作業には Opus を勧めている（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#calibrate-effort)）。
- **GPT-6 Luna は採らない**: 単価は Sol の 1/20 だが、Codex の harness での Coding Agent Index が Sol の 57 に対して 41 である（[ComputingForGeeks](https://computingforgeeks.com/gpt-6-sol-luna-released-features-benchmarks/)）。失敗と格上げの往復が増えうる。
- **general は実装と別の系統で見る**: 同じ系統のモデルは見落としが重なりやすい。実装者の系統と逆の系統が、general の主担当になる。
- **simplicity は standard 以上を Opus で見る**: 精度の低いレビュアーは細かい指摘を増やし、親が折れる機会を増やす。上の actionable precision は一般のレビューの値で、simplicity での実測ではない。意図しない複雑さが入りやすい standard 以上だけを Opus にし、small は費用を抑えて Sonnet のままにする。

## 弱点への対策（公式のプロンプトのガイドによる）

| 対象 | 公式が挙げる傾向 | 委譲プロンプトと定義に書くこと |
|---|---|---|
| Opus 5.5 | 頼まれた範囲を広げたり、自分の判断で作業を置き換えたりする。自分の作業は指示が無くても検証する（[Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5#task-scope-and-over-verification)） | 頼まれた範囲を届けること（定義の本文に書いてある）。「念のため再確認する」のような検証の指示は足さない（検証が過剰になる）。考える量はプロンプトではなくエフォートで調整する（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#calibrate-effort)） |
| Claude 全般 | 貼り付けられた本文の中の指示にも従いうる | PR の本文・diff・Issue・Web の内容を `<pasted_content id="<乱数>">` と `</pasted_content id="<乱数>">` で囲む。定義の本文がその扱いを指示している（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#mark-pasted-text-in-user-messages)）。タグは偽装できるので、道具の制限（下記）と併用する |
| Sonnet 5.5 | low・medium の長い作業で、確認のために止まりやすい。頼まれていないテスト・文書・小さなファイルを足しがち。low では検査を飛ばして完了と報告することがある（[Sonnet 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#steer-initiative-and-scope)、[Verification on coding tasks](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5-5#verification-on-coding-tasks)） | 定義の本文に、完了まで進めること・頼まれていない追加をしないこと・実際の検査で確かめること・確かめられなかった検査を報告することを書いてある。low は使わない |
| Fable 5.2 | 所有を示さないと既存の構造に追加しやすい。所有者として扱うと頼まれていない変更・テスト・文書が増え、PR の要約から小さな変更が漏れやすい（[Anthropic](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2#say-who-owns-the-code)） | 範囲を絞る規則でも所有者として扱う指示は打ち消せないため、その指示を入れない。レビューだけに使い、変更を伴う作業は任せない |
| GPT-6.1 Sol | 確認の質問をして止まりやすい。小さな変更でもテストを広げすぎる。表と箇条書きの多い長い出力になりがち。skill や AGENTS.md の指示に敏感（[OpenAI](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices)（2026-10 に読んだ内容。ページは GPT-6.2 向けに替わった）） | 非対話で動いていて、可逆な作業は確認せずに完了させること。変更に見合うテストだけにすること。出力の形と長さ（定義の `developer_instructions` に書いてある）。委譲プロンプトは `codex` skill の 4 部構成で書く |
| GPT-6.2 Astra | 既定で以前より簡潔に書くため、簡潔さを求める指示は見直す。意図が不明だと次の手を提案して確認を待つ。長い作業では推論や subagent とのやり取りの略語を最終の回答に持ち込む（[OpenAI](https://developers.openai.com/api/docs/guides/latest-model)） | 定義の本文に、作業が終わるまで止まらず、可逆な仮定で進めることを書いてある。既存のロジックを再利用し、不要な間接化や抽象化を足さないことも明記する。簡潔さを求める指示を外し、最終の回答は途中の経過を読んでいない人がそれだけで読めるように書く |

## Claude の役割の起動

Claude の役割は、どちらのハーネスからでも `claude -p` の別プロセスで起動する。理由は 3 つある。

- **権限**: Claude Code の subagent は親の permission の規則を継承する（[公式](https://code.claude.com/docs/en/sub-agents)）。親の allow には `npx`・`git push`・`sed` などがあるので、diff を読む leg に Bash を持たせると、埋め込まれた指示で実行されうる。
- **fallback の隔離**: cyber safeguard が fallback すると、Claude Code 2.1.229 以降はセッションの残りがそのモデルに固定される。subagent の fallback が親に波及するかは、ドキュメントに記述が無い。
- **検出**: `claude -p` の JSON の `modelUsage`・`safety_stops`・終了の欄を `claude_check` で判定する（「結果の判定」）。手元の 2.1.291 の subagent の報告には、公式ドキュメントにある `⚠ This agent switched to` が出ない（cyber の fallback は `safeguards flagged this message` と `[answered by …]` の形で届く）。

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
  # settings.json を読まない起動でも、切り替えて続ける設定を明示する。
  # shellcheck disable=SC2086 # tools は定義の道具名を空白で区切ったもの
  claude -p --model "$m" --effort "$e" --output-format json \
    --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
    --settings '{"switchModelsOnFlag":true}' \
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
- 結果は先に `claude_check` で判定し、「結果の判定」の扱いに従って JSON の `result` を読む。`session_id` と判定に使った欄も、同節に従って実行記録に残す。

## Claude の実装の役割の起動

実装の役割（`implementer-claude*`）は Bash を持ち、sandbox の中でテストを回す。起動は `claude_leg` と同じく `claude -p` で、sandbox の設定を `--settings` で渡す。`claude_leg` と同じ秘密のファイルの一覧は、共通の配列 `CLAUDE_SECRET_DENY` に置く。

```bash
# claude_impl <役割> [許すドメイン …] < プロンプト: 結果 JSON のパスを標準出力に 1 行出す
claude_impl() {
  local role=$1 base dir out rc m e tools gd gcd root secret_env settings
  shift
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
  # 結果の置き場所は、子の sandbox が書けない固定の基底の下に起動のたびに作り、基底ごと sandbox と道具の両方で
  # 拒否する（実装者に、自分の回にも並列の回にも偽の結果を書かせないため。TMPDIR は回ごとに違いうるので使わない）。
  base=${XDG_STATE_HOME:-$HOME/.local/state}/claude-impl
  # 並列の初回でも失敗しないよう、作成の成否は見ずに、できた基底を検査する。
  mkdir -p "${base%/*}" 2>/dev/null
  mkdir -m 700 "$base" 2>/dev/null
  # symlink の基底と他の利用者の基底は、中の置き場所を付け替えられうるので使わない。
  if [ -L "$base" ] || [ ! -d "$base" ] || [ ! -O "$base" ] || ! chmod 700 "$base" || ! base=$(cd "$base" && pwd -P); then
    echo "abort: 結果の置き場所の基底を使えない: $base" >&2
    return 1
  fi
  case "$base/" in "$(cd "$root" && pwd -P)"/*)
    echo "abort: 結果の置き場所の基底が worktree の中にある" >&2
    return 1
    ;;
  esac
  dir=$(mktemp -d "$base/XXXXXX") || {
    echo "abort: 結果の置き場所を作れない" >&2
    return 1
  }
  out=$dir/result.json
  # 起動時の環境から、名前が認証情報らしい変数を拾って拒否に足す（固定の一覧だけでは漏れる）。
  secret_env=$(compgen -e | grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL' | jq -Rsc 'split("\n") | map(select(length > 0))')
  # settings.json を読まないので、切り替えて続ける設定も sandbox と同じ JSON に入れる。
  settings=$(jq -nc --arg gcd "$gcd" --arg base "$base" --argjson env "$secret_env" '{switchModelsOnFlag: true, sandbox: {
    enabled: true, allowUnsandboxedCommands: false, failIfUnavailable: true, autoAllowBashIfSandboxed: true,
    network: {strictAllowlist: true, allowedDomains: $ARGS.positional},
    filesystem: {denyWrite: [$gcd, $base]},
    credentials: {
      files: (["~/.ssh", "~/.aws", "~/.config/gcloud", "~/.config/gh", "~/.docker", "~/.codex", "~/.netrc", "~/.npmrc", "~/.git-credentials", "~/.gmail-mcp", "~/.config/op", "~/.gnupg", "~/.kube"] | map({path: ., mode: "deny"})),
      envVars: ((["GH_TOKEN", "GITHUB_TOKEN", "NPM_TOKEN", "OP_SERVICE_ACCOUNT_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] + $env) | unique | map({name: ., mode: "deny"}))}}}' --args "$@")
  # shellcheck disable=SC2086 # tools は定義の道具名を空白で区切ったもの
  claude -p --model "$m" --effort "$e" --output-format json \
    --permission-mode dontAsk --setting-sources "" --strict-mcp-config --settings "$settings" \
    --append-system-prompt "$(claude_body "$role")" \
    --tools $tools --allowedTools "Read(/$root/**)" "Edit(/$root/**)" \
    --disallowedTools "${CLAUDE_SECRET_DENY[@]}" "Read(/$base/**)" "Edit(/$base/**)" \
    > "$out" 2> "$out.err"
  rc=$?
  echo "$out"
  return "$rc"
}
```

- Read と Edit の許可は、worktree のルートの絶対パス（`//<root>/**`）で固定する。`./**` は現在のディレクトリを基準にするので、実装者が Bash で `cd` すると基準が移り、ルートのファイルへの Edit が `dontAsk` で拒否される（実機で確かめた）。
- プロンプトは stdin で渡す。`--allowedTools` などの可変長の引数が、末尾の位置引数を飲み込むため。
- 結果の JSON は、関数が起動のたびに `mktemp -d` で基底の下に作るディレクトリに書き、そのパスを標準出力に 1 行だけ出す。`out=$(claude_impl <役割> < "$PROMPT")` で受け取り、`claude_check "$out" "$(claude_role <役割> model)"` で判定する。終了コードは `claude` のもので、失敗してもパスは出す（stderr は `"$out.err"`）。worktree の外にいる・定義が無い・置き場所を作れないときは何も出さずに止まる。
- 置き場所は、実装者に `ok` になる偽の結果を書かせないため、`${XDG_STATE_HOME:-$HOME/.local/state}/claude-impl/` の下に作る。拒否は基底ごとにかける。`denyWrite` は Bash を止め、`--disallowedTools` の `Read`・`Edit` は Bash の sandbox を通らない Edit・Write・Read の道具を止める。基底ごとにするのは、並列の回や判定前の前の回の結果も守るため。`TMPDIR` を基底にしないのは、回ごとに値が違いうるうえ、子の sandbox から書ける場所（`/tmp/claude-<uid>` の下など）を指しうるからで、違う基底の回どうしは互いを拒否できない。基底が symlink・他の利用者のもの・worktree の中なら止まる。基底は実体のパスに直してから拒否に入れる。結果を書くのは sandbox の外の親のシェルなので、書き出しは止まらない。
- Bash の allow は渡さない。sandbox の中のコマンドは auto-allow で確認なしに通り、`FOO=bar cmd` のように通常の判定に回るものは `dontAsk` で拒否される。
- `denyWrite` に git の共通ディレクトリを入れる。sandbox は linked worktree の共有 `.git` への書き込みを既定で許すので、commit・reset を物理的に止めるために必要である。linked worktree の外では起動しない。
- 環境変数は、固定の一覧に加えて、起動時の環境から名前が認証情報らしいものを拾い、`credentials.envVars` で sandbox の中から消す。`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` は使わない。付けると `bash t.sh` のようなスクリプトの実行が自動許可から外れ、`dontAsk` で拒否されて、実装者がテストを回せなくなる（実機で確かめた）。
- 実機の確認（2026-10-22、Claude Code 2.1.291、macOS）: この関数で、Bash は確認なしで通った。外部への `curl` は proxy に 403 で拒否された。worktree のルートの `.git` ファイルと `$HOME` への書き込みは `operation not permitted` で拒否され、Edit も拒否された。`~/.ssh` の読み取りは拒否され、`credentials.envVars` の環境変数（`GH_TOKEN`）は消えていた。一覧に無かった `~/.gmail-mcp` は読め、一覧に無い環境変数は見えたので、上の一覧と環境変数の拾い上げを足した。
- 実機の確認（2026-11-21、Claude Code 2.1.325、macOS）: この関数をそのまま使い、`TMPDIR` を子の sandbox から書ける `/tmp/claude-<uid>` の下に向けた。sandbox の中の `bash` のスクリプトから試した結果は次のとおり。基底（`~/.local/state/claude-impl`）の下の自分の回と別の回の `result.json` への上書き・削除、回のディレクトリの `mv`、基底そのものの `mv` は、すべて `operation not permitted` で拒否された。別の回の中身は変わらず、自分の回は `claude_check` で `ok` になった。`TMPDIR` の下の対照のディレクトリでは、同じ操作が通った。2026-11-20 には、worktree の中の symlink を経由して置き場所を読む・書く道具の呼び出しが、`--disallowedTools` の deny で止まることも確かめた（この deny が無いときに Write を止めたのは、先に Read を求める道具の検査だった）。パスを直接書いた Bash の呼び出しは、sandbox に届く前に `dontAsk` で拒否された。
- `failIfUnavailable` により、sandbox を起動できないと claude は起動時に終わる。sandbox なしで走らせ直さず、user に上げる。
- ネットワークは既定で無い。要るときは、必要性を説明できる場合に限り、許すドメインを第 2 引数以降に渡す。書き込みのできる API を持つドメイン（汎用のコードホスティングなど）は、秘密の持ち出しの経路になるので避ける。
- 親は `git status --porcelain` と `git diff` で、新規ファイルも含めて変更の全体を読んでから、ホストでテストと lint を実行する（`git diff` は未追跡のファイルを出さない）。commit は親が行う。順序は `codex` skill の親の手順と同じ。
- 結果は `claude_check` で判定し、「結果の判定」の実装の扱いに従う。`fallback`・`stopped` は走らせ直さず、実行記録と PR の本文に残す。`abnormal` は格上げに数えず user に上げる。

## GPT の役割の起動

```bash
gpt_role() { sed -nE "s/^$2 *= *\"([^\"]*)\"\$/\1/p" "$HOME/.codex/agents/$1.toml" | head -1; }
gpt_body() { awk '/^"""$/{f=0} f; /^developer_instructions = """$/{f=1}' "$HOME/.codex/agents/$1.toml"; }
```

| 親 | 起動 |
|---|---|
| Claude Code | `codex exec -m "$(gpt_role R model)" -c model_reasoning_effort="$(gpt_role R model_reasoning_effort)" -c developer_instructions="$(gpt_body R)"`。実装は `--profile agent`、レビューと検証は `--sandbox read-only`。起動形の詳細は `codex` skill |
| Codex | `spawn_agent` に `agent_type: <役割>` と `fork_turns: "none"` を渡す |

model・effort・本文のどれかが空なら（`chezmoi apply` の前など）起動せずに止め、`chezmoi apply` を案内する。既定のモデルで黙って代えない。

**制約**: Codex の custom agent の定義では `sandbox_mode` を上書きできない（[公式](https://learn.chatgpt.com/docs/agent-configuration/subagents)）。Codex が親のとき、`spawn_agent` で起動したレビューの役割は親の sandbox を継承し、読み取り専用であることは `developer_instructions` の文言だけで担保される。書き込みを許さない sandbox で走らせたいレビューは、Codex からも `codex exec --sandbox read-only` で起動する。

## 結果の判定

Opus 5.5・Sonnet 5.5・Fable 5.2 は、Claude Code の上では、cyber safeguard の classifier に当たると Opus 4.8 などに fallback する（[Claude Code](https://code.claude.com/docs/en/model-config#automatic-model-fallback)）。ソースコードの脆弱性の走査は許可されているが、exploit の生成や攻撃手順の詳述は当たりうる（[Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5#safeguard-refusals)）。API を単体で使ったときは fallback せず、`stop_reason: "refusal"` が返る（[Fable 5.2](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2#safeguard-refusals)）。

`claude_leg` と `claude_impl` は `switchModelsOnFlag: true` を `--settings` で明示する。`--setting-sources ""` では settings.json の設定を読まないためである。公式では、未設定でも自動で切り替えるが、対話のセッションでは先に聞くことがある。`false` を指定した `-p` では、分類器に当たったリクエストは error で終わる（[設定のリファレンス](https://code.claude.com/docs/en/settings-reference#switchmodelsonflag)）。`--settings` の指定が分類器に当たったときに効くかは未確認である。Sonnet 5.5 の bio のように fallback 先が無ければ、`true` でも拒否で終わる。

`modelUsage` には、補助の処理に使う haiku も載る。2026-11-18 に手元の結果 600 件余りを調べると、2 件を除くすべてに `claude-haiku-5-5` が載り、WebFetch を使う役割では出力トークンが 20409 の例もあった。出力の大きさでは補助を見分けず、haiku の ID を判定から除く。別名の指す先を `ANTHROPIC_DEFAULT_HAIKU_MODEL` で変えているときは、その値を使う。

モデルの切り替えが無くても、`safety_stops: 1` で途中の応答が止められた実行があった。`safety_stops: 2` で Opus 4.8 に切り替えて最後まで続いた実行もあり、どちらも終了の欄は正常と同じ値だった。このため、使われたモデルと終了の欄に加えて `safety_stops` も見る。

```bash
# haiku の別名が指す既定の ID。Claude Code は補助の処理（WebFetch の取得したページの処理など）にこのモデルを使う。
CLAUDE_HAIKU_MODEL=claude-haiku-5-5
# claude_check <結果 JSON> <要求したモデル>: ok・fallback・stopped・abnormal のどれかを出す
claude_check() {
  jq -rn --arg m "$2" --arg h "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$CLAUDE_HAIKU_MODEL}" '
    input | if type != "object" then error("結果が JSON のオブジェクトでない") else . end |
    if .is_error != false or .stop_reason != "end_turn" or .terminal_reason != "completed" then "abnormal"
    elif (.modelUsage[$m].outputTokens // 0) == 0 or (((.modelUsage // {}) | keys) - [$m, $h] | length) > 0 then "fallback"
    elif (.safety_stops // 1) > 0 then "stopped"
    else "ok" end' "$1"
}
```

`claude_check <結果 JSON> "$(claude_role <役割> model)"` で判定する。条件は次の順に調べ、最初に当たった判定を返す。

| 判定 | 条件 |
|---|---|
| `abnormal` | `is_error` が false でない、`stop_reason` が `end_turn` でない、`terminal_reason` が `completed` でない、のいずれか |
| `fallback` | 要求したモデルが無いか出力トークンが 0、または要求したモデルと補助の haiku 以外のモデルが載る |
| `stopped` | `safety_stops` が正、または欄が無い |
| `ok` | 上のどれにも当たらない |

拒否と他の異常終了を見分ける値は未観測なので、どちらも `abnormal` とする。`fallback` と `stopped` が重なれば `fallback` を返す。扱いは同じで、GPT での走らせ直しは 1 回だけである。

| 判定 | レビューの leg（multi-review・security-review の `claude_leg`） | 実装（`claude_impl`） |
|---|---|---|
| `ok` | そのまま使う | そのまま使う |
| `fallback` | 結果は捨てず、`reviewer-gpt` で 1 回走らせ直して並べる | 走らせ直さず、実行記録と PR の本文に残す |
| `stopped` | fallback と同じ | fallback と同じ（親の diff の検証で欠けを見る） |
| `abnormal` | 結果があれば残し、`reviewer-gpt` で 1 回走らせ直す | 格上げに数えず user に上げる |

レビュー以外の `claude_leg`（`spec-designer`・`fact-checker`・`grill-counterpart` など）は、呼び出し元の skill の扱いに従う。書かれていなければ、`fallback`・`stopped` は結果を使って判定を記録する。`abnormal` は同じ役割を新規セッションで 1 回走らせ直し、だめなら user に上げる。

結果 JSON が空・空白だけ・壊れている・オブジェクトでないときは、判定が 0 以外で終わる。呼び出し側は終了コードを確認し、「結果が空・失敗」として扱う。

実行記録には、`session_id`・要求したモデル・`modelUsage`（モデルごとの出力トークン）・`safety_stops`・`stop_reason`・`terminal_reason`・`is_error`・判定を残す。判定が失敗したときは、その終了コードとエラーも残す。

## 実装の格上げ

格上げは 1 段ずつ行い、系統はまたがない。失敗は、検証が通らない、範囲の外を変えた、完了の条件を満たさない、のいずれか。

- light（`implementer-light` / `implementer-claude-light`）が同じタスクで 2 回失敗したら、同じ系統の通常の役割で 1 回試す。
- 通常の役割（`implementer` / `implementer-claude`）が 2 回（light から上がった場合は 1 回）失敗したら、同じ系統の最上位（`implementer-astra` / `implementer-claude-opus`）で 1 回だけ試す。
- それでもだめなら user に上げる。

2 回目を試す前に、失敗の原因を親が読み、委譲プロンプトを直す（同じプロンプトで回し直さない）。系統をまたがないのは、user が選んだ系統と違うモデルが書くと、レビューの系統の判断がずれるため。
