# multi-review: エラーハンドリングと実行上の注意

**コスト管理（tier gating・Codex offload・並列上限）は `SKILL.md` の「コスト管理」節が SSOT**。
ここは leg の失敗時の縮退と、Bash ツール固有の注意を持つ。

## エラーハンドリング

| シナリオ | 対応 |
|---------|------|
| cc-code-review / cc-security サブエージェントの失敗・スキップ | 1回リトライ。再失敗なら該当ツールをスキップして残りで続行 |
| 動的 specialist の失敗・未定義（`<lang>-reviewer` 未配備） | 1回リトライ。再失敗なら該当 specialist のみスキップし、その回の tier roster（generalist + フロア anchor + 他 specialist）で続行（specialist は補強レイヤのため必須ではない） |
| `cc-code-review` / `cc-security-review` サブエージェント未定義 | `~/.claude/agents/` に定義があるか確認を案内（chezmoi apply 済みか）。該当ツールをスキップ |
| `codex` コマンド未発見 | 警告を出力し、その回に spawn 済みの Claude leg（tier により cc-code-review **or** cc-security-review）と Claude specialist は無いため、**generalist 観点が失われる旨を明示**して続行。standard/large では generalist を Codex が独占するため、緊急フォールバックとして cc-code-review（Claude 汎用）の spawn を検討する |
| codex が `No prompt provided via stdin.` で終了 | 差分を事前変数確保するパターンで1回リトライ（codex skill 参照） |
| codex 結果ファイルにログ混入 | `-o <FILE>` 形式になっているか確認（`> file 2>&1` 併合をやめる） |
| 個別ツールのタイムアウト | 1回リトライ。2回目も失敗なら該当ツールをスキップ |
| 空の差分 | 「レビュー対象の差分がありません」と報告して終了 |
| PR番号が無効 | エラーメッセージを表示して終了 |
| Pending Review 作成失敗 | エラー内容を表示してユーザーに報告 |
| 全ツール失敗 | エラーサマリーを出力して終了 |

### jq の否定演算子

Claude Code の Bash ツールでは `!` が履歴展開として解釈されるため、jq の否定比較演算子は使用できない。代わりに `select(.user.login | startswith("coderabbitai") | not)` パターンを使用する。
