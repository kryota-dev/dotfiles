@~/AGENTS.md

# Claude Code 固有のルール

## ユーザーに判断を求めるとき

判断を仰ぐときは必ず `AskUserQuestion` を使う。確認だけの短い問いも例外にしない。「進めてよろしいですか」と書きかけたら、それは `AskUserQuestion` の呼び出しである。

## memory への記録

memory に書く前にユーザーの承認を得る。保存する価値があると判断したら、記録の種類（user / feedback / project / reference）、内容の案（ファイル全文）、保存する理由を示し、明示的に承認されたときだけ書く。

## ツール

- 画面に影響する変更をしたとき、またはブラウザでの確認を頼まれたときは、`agent-browser` で実際の表示を確かめる。
- 「DeepWiki を使って」と言われたら DeepWiki の MCP を使う。MCP が使えなければ、有効にするようユーザーに伝える。
