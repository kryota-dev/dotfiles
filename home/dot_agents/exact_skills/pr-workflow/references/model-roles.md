# 役割ごとのモデルとエフォート

pr-workflow・sdd・multi-review・security-review・review-resolve-loop・codex が、どの作業をどのモデルにどのエフォートで任せるかを、この文書で決める。基本は「設計と判断は Claude、実装は GPT」とする。モデルとエフォートの値は定義ファイルにだけ書き、skill の本文には役割の名前だけを書く。

## 役割表

値の正本は定義ファイルで、この表との一致は `tests/agent_roles.bats` が検査する。Claude の役割は `~/.claude/agents/<役割>.md`、GPT の役割は `~/.codex/agents/<役割>.toml` にある。

| 役割 | 系統 | model | effort | 用途 |
|---|---|---|---|---|
| `spec-designer` | Claude | claude-opus-5-5 | high | sdd の spec、Codex から起動したときの small の計画 |
| `spec-designer-deep` | Claude | claude-opus-5-5 | xhigh | large の design.md |
| `review-general` | Claude | claude-opus-5-5 | high | multi-review の general（standard 以上） |
| `review-general-light` | Claude | claude-opus-5-5 | medium | multi-review の general（trivial・small） |
| `review-security` | Claude | claude-opus-5-5 | high | multi-review の security、security-review の Phase 2 |
| `review-security-deep` | Claude | claude-fable-5-1 | high | security-review の `--deep` |
| `review-intent` | Claude | claude-opus-5-5 | high | multi-review の intent |
| `review-simplicity` | Claude | claude-sonnet-5-5 | medium | multi-review の simplicity |
| `fact-checker` | Claude | claude-sonnet-5-5 | medium | multi-review の裏取りの委譲 |
| `implementer` | GPT | gpt-6.1-sol | high | standard・large の実装（tasks.md の 1 タスク） |
| `implementer-light` | GPT | gpt-6.1-sol | medium | small の実装、CI の失敗の修正、レビュー指摘の修正 |
| `implementer-astra` | GPT | gpt-6-astra | high | 同じタスクで `implementer` か `implementer-light` が 2 回失敗したときの格上げ |
| `reviewer-gpt` | GPT | gpt-6.1-sol | xhigh | multi-review の general の GPT 側（large） |
| `reviewer-gpt-focused` | GPT | gpt-6.1-sol | high | multi-review の database・IaC、security-review の Phase 2・3 |
| `checker-gpt` | GPT | gpt-6.1-sol | medium | security-review の Phase 4 |

表に無い作業は親が行う。Claude Code の親は Opus 5.5（medium、`settings.json` の既定）で、分類・GATE・統合の判断・trivial の編集・数行で済む修正を受け持つ。Codex の親は GPT-6.1 Sol（medium、`config.toml` の既定）である。

## 割り当ての根拠

2026-10 時点の一次資料と第三者の評価による。モデルが替わったら、ここと定義ファイルを一緒に見直す。

- **設計と判断に Opus 5.5**: 大半の作業で Fable 5.1 と同等か上回り、単価は 6 割安い。medium でも Opus 5 の high に並ぶ（[Anthropic](https://www.anthropic.com/claude-opus-5-5)）。コードレビューの actionable precision は 66.7% で、Sonnet 5.5 は 41.2%（[CodeRabbit](https://www.coderabbit.ai/blog/sonnet-5-5-model-review)）。
- **Fable 5.1 は格上げ先だけに使う**: 最難の長時間作業では強いが、15 回の試行の 1 回で、テストを通すための近道をした（[The New Stack](https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/)。本文は取得できず、見出しと要約で確認）。既定の割り当てには使わない。
- **範囲の狭い作業に Sonnet 5.5**: Opus 5.5 の半額で速いが、持続的な判断では Opus に劣る（[Anthropic](https://www.anthropic.com/claude-sonnet-5-5)）。
- **実装に GPT-6.1 Sol**: high で DeepSWE が Astra の high と同点で、費用は約 5 分の 1、3 割速い。security の判定（SecPass）も Astra とほぼ同じで、テストの改ざんなどの不正は 0 件だった（[Endor Labs](https://www.endorlabs.com/learn/gpt-6-1-sol-on-codex-astra-level-security-a-third-faster-zero-cheating)）。Astra は、Sol で足りないときの格上げ先にとどめる（[OpenAI](https://developers.openai.com/api/docs/guides/latest-model)）。
- **general は実装と別の系統で見る**: 同じ系統のモデルは見落としが重なりやすい。実装は GPT なので、general の主担当を Claude にする。

## 弱点への対策（委譲プロンプトに書く）

| 対象 | 弱点 | 委譲プロンプトに書くこと |
|---|---|---|
| Opus 5.5 | 止める条件を指示しないと、長く走りトークンを使い続ける | 完了の条件と、調べる範囲の上限（対象のファイル・経路） |
| Fable 5.1 | テストを通すための近道をすることがある | テストを弱めて通さないこと。結果を親が diff で確かめる |
| GPT-6.1 Sol | 範囲の外まで作業を続ける（ロールアウトの 23.5%）。出力が長くなりがち | 目的・文脈・制約・完了の条件の 4 部構成。書いてよいファイルの列挙、止めどころ、出力の形と長さ |

定義ファイルの本文（Claude）と `developer_instructions`（GPT）にも同じ約束を書いてあるが、委譲プロンプトでも具体的に指定する。

## 呼び出し方

もう一方のハーネスの役割を呼ぶときは、定義ファイルから値を読む。値を skill に書き写さない。

```bash
# Claude の役割の値（frontmatter の行）
claude_role() { sed -n "s/^$2: *//p" "$HOME/.claude/agents/$1.md" | head -1; }
# GPT の役割の値
gpt_role() { sed -nE "s/^$2 *= *\"([^\"]*)\"\$/\1/p" "$HOME/.codex/agents/$1.toml" | head -1; }
```

値が空なら（`chezmoi apply` の前など）起動せずに止め、`chezmoi apply` を案内する。既定のモデルで黙って代えない。

| 親 | Claude の役割 | GPT の役割 |
|---|---|---|
| Claude Code | Agent ツールの `subagent_type` に役割名を渡す。model と effort は定義が決める（2.1.291 は呼び出しごとの effort を受け付けない） | `codex exec -m "$(gpt_role R model)" -c model_reasoning_effort="$(gpt_role R model_reasoning_effort)"`。実装は `--profile agent`、レビューと検証は `--sandbox read-only`。起動形の詳細は `codex` skill |
| Codex | `claude -p --model "$(claude_role R model)" --effort "$(claude_role R effort)"`。`--setting-sources ""` では `~/.claude/agents` が読まれないので、`--agent` は使えない。道具は `--allowedTools` で役割の定義の `tools` に合わせる | `spawn_agent` に `agent_type: <役割>` と `fork_turns: "none"` を渡す |

Codex から `claude -p` に書き込みをさせるとき（spec など）は、`--allowedTools` に書いてよいパスだけを `Edit(./<パス>/**)` で足す。`Edit` の規則は Write にも効く。

**例外**: security-review の Phase 2 の Claude の leg は、Claude Code が親のときも `claude -p` の別プロセスで走らせる。cyber safeguard が fallback すると、Claude Code 2.1.229 以降はセッションの残りが fallback 先のモデルに固定される。subagent の fallback が親に波及するかどうかは、ドキュメントに記述が無い。

## fallback の検出

Opus 5.5・Sonnet 5.5・Fable 5.1 は、cyber safeguard の classifier に当たると Opus 4.8 などに fallback する。ソースコードの脆弱性の走査は許可されているが、exploit の生成や攻撃手順の詳述は当たりうる（[Claude のサポート](https://support.claude.com/en/articles/16049681-why-claude-switched-models-in-your-conversation-with-opus-5-or-opus-5-5)）。

- Claude Code の subagent: 報告が `⚠ This agent switched to` で始まれば fallback している。
- `claude -p`: `--output-format json` の `modelUsage` に、要求していないモデルがあれば fallback している。

fallback したら、実行記録に「要求したモデル・実際のモデル」を残し、その leg を GPT の対応する役割で 1 回だけ走らせ直す（security → `reviewer-gpt-focused`、それ以外 → `reviewer-gpt`）。fallback した結果は捨てずに、GPT の結果と並べて統合する。

## 実装の格上げ

同じタスクで `implementer`（または `implementer-light`）が 2 回失敗したら（検証が通らない、範囲の外を変えた、完了の条件を満たさない）、`implementer-astra` で 1 回だけ試す。それでもだめなら user に上げる。2 回目を試す前に、失敗の原因を親が読み、委譲プロンプトを直す（同じプロンプトで回し直さない）。
