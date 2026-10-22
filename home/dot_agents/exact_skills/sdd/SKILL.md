---
name: sdd
description: pr-workflow の standard/large tier から呼ばれる内部コンポーネント。Spec-Driven Development（要件定義・設計・タスク分解・実装・コミット・PR作成）を完全自律で実行し、PR 作成で完了する。レビューは pr-workflow の PR 作成後パイプライン（CI 監視 → multi-review → review-resolve-loop）に一本化されているため sdd 自身はレビューを行わない。単体起動はせず pr-workflow 経由でのみ実行する。
argument-hint: "[--prd <path>] <issue-url-or-feature-description>"
user-invocable: false
# spec を書く間の親（Claude Code）のエフォート。役割の割り当ては pr-workflow/references/model-roles.md。
effort: high
---

# sdd

spec（要件・設計・タスク）を書いてから実装し、コミットと Draft PR の作成まで自律で行う。レビューはしない（pr-workflow の PR 作成後の工程が担う）。

承認のために止まらない。止まるのは、呼び出し元がワークツリーを用意しなかったとき（下記）と、Git 操作が認証エラー（1Password など）で通らないとき（`notify` してから user に判断を仰ぐ）だけ。spec-workflow MCP の承認ツールも、止まる原因になるので使わない。

## 入力

- 引数: Issue URL か `#番号` なら `gh issue view <…> --json title,body,number,labels` で読む。テキストならそのまま使う。
- PRD の受け取り（任意 / opt-in）: `--prd <path>` で `/grill-me --output-prd` の PRD を受け取り、要件の起点にする。file が無ければ error にして `/grill-me --output-prd` での作成を案内する（PRD を捏造しない）。
- 実装者（`claude|codex`）: 呼び出し元から受け取る。受け取らなかったら、[`pr-workflow/references/model-roles.md`](../pr-workflow/references/model-roles.md)「実装者の選択」の推奨を採る（sdd は承認で止まらないので尋ねない）。その旨と理由を PR の本文に 1 行残す。
- spec 名: PRD の frontmatter の `slug`、無ければ内容から kebab-case で決める。

## ブランチとワークツリー

- **base はリポジトリの既定ブランチ**（`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`）。呼び出し元が base を指定したらそれに従う。現在のブランチを base にしない（pr-workflow 経由では既にフィーチャーブランチにいるので、head と同じブランチを base にしてしまう）。
- pr-workflow 経由ではワークツリーは作成済みで、委譲プロンプトが新規作成を止めている。現在のワークツリーで作業する。ワークツリー操作の SSOT は `wtp` skill。
- 呼び出し元がワークツリーを用意しなかったときだけ、user に「ワークツリーを作る / 現在の場所で作業する」を確認する。作るなら `wtp add -b <branch> "$BASE" --quiet` の出力先へ移る（branch は Issue があれば `claude/{issue}/{spec-name}`、無ければ `claude/{spec-name}`）。

## spec の契約

Phase 1〜3 で下の 3 ファイルを順に書く（1: requirements、2: design、3: tasks）。出力先は `.spec-workflow/specs/{spec-name}/`。`.spec-workflow/` は gitignore されていることがあり、Glob / Grep では見えないので、`ls` と Read で直接読む。テンプレートは `.spec-workflow/user-templates/<kind>-template.md`、無ければ `.spec-workflow/templates/<kind>-template.md` を探し、あればその構造に従う。steering docs（`.spec-workflow/steering/`）があれば整合させる。

| ファイル | 載せること |
|---|---|
| `requirements.md` | 概要と目的、ユーザーストーリー、受け入れ基準（WHEN / THEN / IF。PRD があればその `AC-NNN` を起点に番号を保つ）、非機能要件、スコープ外 |
| `design.md` | 概要、再利用する既存コード（既存実装を先に探す）、アーキテクチャ（Mermaid 推奨）、コンポーネントとインターフェース、データモデル、エラー処理、テスト戦略 |
| `tasks.md` | 各タスクに `- [ ]`、File、Purpose、_Leverage、_Requirements。1 タスクの変更は 1〜3 ファイル、依存の順に並べ、それぞれ単独でテストできる粒度にする |

spec は Claude が書く（役割は [`pr-workflow/references/model-roles.md`](../pr-workflow/references/model-roles.md)）。

| 親 | requirements.md・tasks.md | design.md |
|---|---|---|
| Claude Code | 親が書く（この skill の `effort: high`） | 親が書く |
| Codex | `spec-designer` を `claude_leg` で起動して書かせる | 同じ |

`spec-designer` に書かせるときは、委譲プロンプトに書くファイルの絶対パス・要件の出所（Issue・PRD・user の確認）・既存の spec・完了の条件（上の表の項目がそろっている）を書く。Issue や PRD の本文は `<pasted_content id="<乱数>">` で囲む。書き込みは追加の許可の `Edit(./.spec-workflow/specs/<spec 名>/**)` に限る（`claude_leg spec-designer "$RESULT" "Edit(./.spec-workflow/specs/<spec 名>/**)" < "$PROMPT_FILE"`）。書かれた spec は親が読み、要件の取りこぼしと、範囲の外への拡大が無いことを確かめてから次に進む。

この 3 ファイルは、multi-review が `--spec-context` で「実装が spec どおりか」の照合に使う。調査の進め方（何を読むか、subagent を使うか）は自分で決める。ただしシェルなど書き込みうる道具を持つ subagent に渡すときは、調査でも `pr-workflow`「共有作業ツリーでの subagent 委譲契約」節に従う。

## 実装と納品

- Phase 4（実装）に入る前に [`references/implementation.md`](references/implementation.md) を Read する。
- Phase 5（コミット & PR）に入る前に [`references/delivery.md`](references/delivery.md) を Read する。
