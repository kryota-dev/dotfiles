---
name: monitor-ci
description: PR作成後やCI実行中にStatus Checksの状態を監視する。チェック完了まで定期的にステータスを確認し、結果を報告する。
---

# Monitor CI Checks

Pull Request の CI チェックが解決する（成功または失敗）まで監視する。

## 使い方

CI チェックの監視を求められたら、Claude は以下を行う:

1. `gh pr checks --watch` を実行し、継続的にステータスを監視する
2. すべてのチェックが完了するまで待つ
3. 全チェックの最終ステータスを報告する
4. チェックが失敗した場合、失敗ログを分析し修正案を提示する

## コマンド

```bash
# watch モードで PR チェックを監視
gh pr checks --watch

# 代替: 一度だけステータスを確認
gh pr checks

# 失敗したチェックとその実行 URL を特定する
gh pr checks --json name,state,link --jq '.[] | select(.state != "SUCCESS")'

# 上で得た link の run ID から、失敗したステップのログだけを取得する
gh run view <run-id> --log-failed
```

## ワークフロー

1. **監視開始**: PR 作成直後、または依頼を受けたら即座に `gh pr checks --watch` を実行する
2. **進捗の追跡**: このコマンドは全 CI チェックの状態をリアルタイムで表示する
3. **完了**: すべてのチェックが ✓（成功）または X（失敗）になるまで待つ
4. **失敗時の対応**:
   - チェックが失敗したら `gh pr checks --json name,state,link` で失敗したチェックと実行 URL を特定し、その run ID を `gh run view <run-id> --log-failed` に渡して失敗ステップのログを取得する
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
