---
name: zenn-draft
description: |
  開発ログ（merged PR / session-summary / 調査メモ）から Zenn 記事ドラフトを生成する skill。
  zenn-qiita-content リポジトリの既存記事から文体を参照し、published: false 固定で articles/ に
  ドラフトを作成、redact パターン検査（クライアント固有名）まで済ませて人間へハンドオフする。
  トリガー: "zenn-draft", "Zenn 記事", "記事ドラフト", "記事にして", "ブログに書きたい"
  使用場面: 実装・調査で得た知見の発信、登壇ネタの下書き。公開判断・公開操作は常に人間。
argument-hint: "[<テーマ>] [--from=pr:<owner/repo#N>|session:<path>|topic:<text>] [--slug=<slug>]"
user-invocable: true
---

# zenn-draft

記事化の初動コスト（素材集め・構成・文体合わせ）を 2〜4 時間から 30 分に圧縮する。
**生成するのは published: false のドラフトまで**であり、公開に関わる操作は一切行わない。

対象リポジトリ: `~/ghq/github.com/ryota-k0827/zenn-qiita-content`（`articles/` のみ。`qiita/` は ztoq 同期の管轄のため触らない）

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `<テーマ>` | なし | 記事テーマの自由記述（未指定なら Phase 1 で候補を提案） |
| `--from` | なし | 素材の明示指定: `pr:<owner/repo#N>` / `session:<path>` / `topic:<text>` |
| `--slug` | 自動 | 記事 slug（Zenn 制約: 12〜50 字の `a-z0-9_-`）。未指定は内容から生成 |

## 安全原則（絶対遵守）

- **公開系操作の禁止**: `git add` / `commit` / `push`、`published: true` への変更、デプロイ、Zenn / Qiita への直接投稿を行わない。
- **既存記事を上書きしない**: slug 重複時は別 slug を提案する。
- **クライアント案件由来の素材は汎用化**: 固有名・内部 URL・非公開の数値は `<owner>/<repo>` や一般名詞へ置換してから記事に載せる（public リポジトリへの固有名記載禁止ルールに従う）。
- 生成後の redact 検査（Phase 4）を必ず通してからハンドオフする。

## Phase 1: 素材選定

- テーマ・`--from` とも未指定の場合: 直近 14 日の merged PR（`gh search prs --author=@me --merged-at ...`）と session-summary から、**記事候補 3 本**（仮タイトル / 素材 / 想定読者と得られる価値）を提案し、選択してもらう。
- `--from=pr:` は `gh pr view <N> --repo <owner/repo> --json title,body,files,url` で素材化する。`--from=session:` は該当ファイルを Read する。
- クライアント repo 由来の素材は、選定段階で「固有名は汎用化する前提」と明示する。

## Phase 2: 文体参照

- 直近に追加・更新された記事 2〜3 本を Read し、次を合わせる: 口調（です・ます調）、見出しの粒度、コード例の密度、冒頭リード（対象読者とゴールの提示）の型。

```bash
git -C ~/ghq/github.com/ryota-k0827/zenn-qiita-content log --pretty=format: --name-only -- articles/ \
  | grep -v '^$' | awk '!seen[$0]++' | head -3
```

## Phase 3: ドラフト生成

- slug を決定する: `--slug` 指定値、なければ内容ベースの kebab-case（12〜50 字、`a-z0-9_-` のみ。例: `gha-nodejs-cache` のような既存の意味付き slug の慣習に合わせる）。`articles/<slug>.md` の存在を確認し、重複していれば別案を提示する。
- `articles/<slug>.md` に生成する。frontmatter は既存記事と同形式:

```yaml
---
title: "（記事タイトル）"
emoji: "⚡️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["topic1", "topic2"] # 最大 5 個
published: false # 固定。true への変更は人間のみが行う
---
```

- 構成: リード（誰向け・何が得られる）→ 背景 / 課題 → 本編（コード例は実際に動くもの）→ まとめ → 参考リンク。
- 画像が必要な箇所は `images/` への配置指示をプレースホルダで示す（画像の生成・コピーはしない）。

## Phase 4: redact 検査（必須）

```bash
# own-namespace 用 strict config の client-identifiers ルールで機械検査（gitleaks は Go RE2）
gitleaks detect --no-git \
  --source ~/ghq/github.com/ryota-k0827/zenn-qiita-content/articles/<slug>.md \
  --config ~/.config/git/gitleaks-own.toml
```

- 検出時: 該当箇所を汎用化して再検査する（通過するまでループ）。
- パターン網羅の不足に気づいた場合（検出されるべき固有名が素通りした場合）は、`redact-patterns` skill でのパターン追加を**ユーザーに提案**する（本 skill からは追加しない）。
- 機械検査に加えて意味的な検査も行う: 内部事情・非公開の数値・スクリーンショット指示内の写り込みがないか。
- 補足: zenn repo は own-namespace のため commit 時にも gitleaks pre-commit hook が同じルールで再検査する（多層防御）。ただし本 skill は commit しないため、**ハンドオフ前検査が唯一の必須ゲート**である。

## Phase 5: ハンドオフ

以下を提示して終了する:

1. 生成ファイルのパスと全文
2. プレビュー手順: `cd ~/ghq/github.com/ryota-k0827/zenn-qiita-content && npx zenn preview`（http://localhost:8000）
3. 公開までの人間の手順: 内容確認 → `published: true` → `npm run check:spell` → commit / push
4. 残タスク（画像差し込み・リンク確認・タイトル推敲など）

## 運用メモ

- 素材 → ドラフト 30 分を目標にした設計。推敲と公開判断は人間の領分として残す。
- worklog / session-summary が素材の供給源になる（週次の worklog から記事候補を拾う運用が有効）。
