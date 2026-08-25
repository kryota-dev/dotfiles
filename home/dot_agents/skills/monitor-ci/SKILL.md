---
name: monitor-ci
description: PR作成後やCI実行中にStatus Checksの状態を監視する。チェック完了まで定期的にステータスを確認し、結果を報告する。
---

# Monitor CI Checks

## Harness contract

`~/.agents/workflow/README.md` を優先する。Claude 固有のツールは使わず、両 harness とも host 側で
CI status を取得する。Codex の非対話実行では `agent-workflow checks <run-id> --watch` を使い、必要な
PR 番号や GitHub capability が不足すると `blocked` として停止する。監視結果・ログ・token は transient
state にのみ置き、tracked handoff へ保存しない。

Pull Request の CI チェックが解決する（成功または失敗）まで監視する。

## 使い方

CI チェックの監視を求められたら、harness は以下を行う（Codex 非対話は下記の host runner command を使い、
直接の `gh` command は Claude adapter / 対話型 main session に限る）:

1. `gh pr checks --watch` を実行し、継続的にステータスを監視する
2. すべてのチェックが完了するまで待つ
3. 全チェックの最終ステータスを報告する
4. チェックが失敗した場合、失敗ログを分析し修正案を提示する

## コマンド

```bash
# watch モードで PR チェックを監視
gh pr checks --watch

# Codex の非対話 run（host runner 経由）
agent-workflow checks <run-id> --watch

# 代替: 一度だけステータスを確認
gh pr checks

# 必要に応じて特定チェックの詳細を表示
gh pr checks --verbose
```

## ワークフロー

1. **監視開始**: PR 作成直後、または依頼を受けたら即座に `agent-workflow checks <run-id> --watch`（Codex 非対話）または `gh pr checks --watch`（Claude adapter / 対話型 main）を実行する
2. **進捗の追跡**: このコマンドは全 CI チェックの状態をリアルタイムで表示する
3. **完了**: すべてのチェックが ✓（成功）または X（失敗）になるまで待つ
4. **失敗時の対応**:
   - チェックが失敗したら `gh pr checks --verbose` で詳細ログを取得する
   - 失敗内容を分析し、修正を提案または実装する
   - 修正後、変更を push して再度監視する

## 出力例

```
Refreshing checks status every 10 seconds. Press Ctrl+C to quit.

NAME                    STATUS      CONCLUSION
Build                   completed   success     ✓
Lint                    completed   success     ✓
Test                    completed   failure     X
Type Check              in_progress -           ◐

Some checks were not successful
```

## 重要な注意事項

- `--watch` フラグは10秒ごとに更新する
- 監視を止めるには Ctrl+C を押す
- 次のステップに進む前に、必ずすべてのチェックの完了を待つこと
- チェックが失敗した場合、マージ前に問題を調査・修正すること
