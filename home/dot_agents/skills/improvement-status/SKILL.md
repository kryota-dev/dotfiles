---
name: improvement-status
description: |
  ECC 継続的改善ループの候補キューを会話内に表示する read-only skill。evaluator の健全性と
  active な改善候補の全件を出し、`--history` で延期・見送り・失効・Issue 化済みも表示する。
  トリガー: "improvement-status", "改善候補", "候補キュー", "改善候補を見せて", "improvement queue"
  使用場面: 週次の改善候補を確認したいとき、採否を判断する前に一覧を見たいとき。
---

# improvement-status

改善候補キュー（`${XDG_STATE_HOME:-~/.local/state}/agent-improvement/queue.json`、owner-only）を
**読むだけ**で会話内に提示する。

## 不変条件

- **evaluator を再実行しない。** 週次評価そのものは別の scheduled job が担う。本 skill が起動するのは
  読み取り専用のサブコマンドだけで、候補の再計算・再取得は一切しない。
- **state を書き換えない。** `status` は queue ファイルにも state ディレクトリにも書き込まない
  （未作成なら作成もしない）。書き込むのは `agent-improvement resolve` / `upsert` だけで、本 skill は呼ばない。
- **外部へ公開しない。** 取得した候補を Git・GitHub・外部サービスへ自動送信しない。

## 手順

1. 次を実行する（既定は active 候補のみ）:

   ```bash
   agent-improvement status
   ```

   延期中・見送り・失効・Issue 化済みも求められたら `--history` を付ける:

   ```bash
   agent-improvement status --history
   ```

2. 出力をそのまま貼らず、会話向けに整形して提示する:
   - **evaluator の健全性**を 1 行目に置く。`未実行` は異常ではない（週次評価がまだ動いていないだけ）。
   - **改善候補**は CLI が返した順（順位の高い順）を保ち、`id` / タイトル / 要約 / 根拠アカウント / 順位スコアを示す。
   - **採用済み（効果測定中）**は再評価日を明示する。期日を過ぎているものは目立たせる。
   - `--history` を付けた場合のみ履歴セクションを出す。

3. 候補が 0 件なら「保持中の候補はありません」と伝えて終わる。憶測で候補を作らない。

## やってはいけないこと

- 採否を勝手に決めない。採用・延期・見送りの判断はユーザーが行う。
  記録が必要になったら `agent-improvement resolve <id> --decision=adopt|defer|reject` を**ユーザーの明示的な回答を得てから**実行する。
- 候補を Issue 化しない。Issue 作成は通常の Issue 作成フロー（`$create-issue`）を経る。
- queue ファイルを直接編集しない。schema 検証と原子的更新を迂回することになる。

## 機械可読な出力が要るとき

`--json` を付けると `{ health, active, adopted, history? }` の JSON を返す（`history` は `--history` 指定時のみ）。
最優先の 1 件だけが欲しい場合は `agent-improvement next --json` を使う（これも読み取り専用）。

## 関連

- CLI 実体: `~/.local/bin/agent-improvement`（実装は `~/.local/lib/agent-improvement/`）
- シェル関数: `improvement-status` / `improvement-next` / `improvement-resolve`
- 設計の出典: #473（ECC hook の縮小と継続的改善ループ）の AC-030 / 034-037 / 039-041
