# 深掘りモード subagent 指示テンプレート

`session-summary` の `--archive` モードから呼び出す general-purpose subagent への
指示本体。SKILL.md 本体を軽く保つため、深掘り時のみ本ファイルを Read する。

## 目的

`capture.sh` でアーカイブした JSONL を、選択的に jq 抽出しながら詳細な
Markdown サマリーへ変換する。JSONL は行数が数万に達する場合があるため、
**全行を一度に読み込まない**。

## 指示テンプレート（そのまま subagent へ渡す）

以下をそのまま subagent の prompt として渡す（`<RAW_FILE>` は capture.sh の
戻り値で置換）:

````
あなたはセッションログのアナリストです。以下の JSONL を分析し、
セッション全体の詳細サマリーを作成してください。

## 入力
- JSONL ファイル: <RAW_FILE>

## 分析手順

JSONL は大きい場合があるため、全行を一度に読み込まないこと。
bash の jq / grep / head / tail を駆使して選択的に抽出する。

### Step 1: 構造の把握

```bash
head -3 "$RAW_FILE" | jq 'keys'
jq -r '.type' "$RAW_FILE" | sort | uniq -c | sort -rn
```

典型的な構造:
- type: "user" — ユーザー入力。message.content が string または array
- type: "assistant" — アシスタント応答。message.content 配列に text / tool_use / thinking
- type: "progress" / "file-history-snapshot" / "system" 等 — スキップ対象

構造はバージョンにより変わりうるため、実際の内容を確認した上で
適切な jq クエリを組み立てること。

### Step 2: 基本統計の収集

```bash
# タイムスタンプ範囲
head -5 "$RAW_FILE" | jq -r 'select(.timestamp != null) | .timestamp' | head -1
tail -1 "$RAW_FILE" | jq -r '.timestamp // empty'

# ツール使用統計
jq -r 'select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use") | .name' "$RAW_FILE" \
  | sort | uniq -c | sort -rn
```

### Step 3: ユーザー入力の全件抽出

ユーザーが実際に入力したメッセージを全件抽出する。
**tool_result（ツール結果の自動フィードバック）は除外する**。

```bash
# ユーザー直接入力（string 型）
jq -r 'select(.type == "user")
       | select((.message.content | type) == "string")
       | "\(.timestamp) | \(.message.content | .[0:500])"' "$RAW_FILE"

# ユーザー直接入力（array 型で text を含むもの）
jq -r 'select(.type == "user")
       | select((.message.content | type) == "array")
       | select([.message.content[] | select(.type == "text")] | length > 0)
       | {ts: .timestamp,
          text: [.message.content[] | select(.type == "text") | .text]
                | join("\n") | .[0:500]}
       | "\(.ts) | \(.text)"' "$RAW_FILE"
```

抽出時の注意:
- スキル展開テキスト（非常に長い、スキルの説明文が展開されたもの）や
  システムメッセージは、内容をそのまま転記せず「[スキル展開: /sdd]」等に要約する
- チームメイトからのレビュー結果は、結論（APPROVE / REQUEST_CHANGES 等）と
  主要指摘事項のみ記載する
- 何がノイズで何が重要かの判断は subagent に委ねる。セッションの文脈を
  読み取って適切に判断すること

### Step 4: アシスタント主要応答の抽出

```bash
jq -r 'select(.type == "assistant")
       | {ts: .timestamp,
          texts: [.message.content[]? | select(.type == "text") | .text]}
       | select(.texts | length > 0)
       | "\(.ts) | \(.texts | join(" ") | .[0:300])"' "$RAW_FILE"
```

注意:
- **thinking ブロックは省略する**
- スキルの展開テキストやシステムプロンプトの引用など、長大なテキストは
  ノイズなので要約または省略する

### Step 5: ツール呼出しの把握

```bash
# Bash コマンドの一覧
jq -r 'select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and .name == "Bash")
       | "\(.input.command | gsub("\n"; " ") | .[0:150])"' "$RAW_FILE" \
  | head -100

# Write / Edit されたファイル
jq -r 'select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
       | "\(.name): \(.input.file_path)"' "$RAW_FILE" | sort -u

# Git 操作
jq -r 'select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and .name == "Bash")
       | select(.input.command | test("git (commit|push|checkout|merge)"))
       | .input.command | gsub("\n"; " ") | .[0:250]' "$RAW_FILE"
```

### Step 6: サマリー Markdown 生成

上記で収集した情報を元に、下記の構造の Markdown を生成し、
`<RAW_FILE から .jsonl を除いた部分>_formatted.md` に保存する。

## 出力フォーマット

```markdown
# セッション詳細サマリー

## セッション情報
- セッション ID、期間（開始〜終了）、ブランチ、対象 Issue / PR
- 規模（メッセージ数、ツール呼出し数、ファイルサイズ）

## ユーザー指示の全一覧
- 時系列で全てのユーザー入力を列挙する
- タイムスタンプ付き
- フェーズごとにグルーピングする（例: 「フェーズ1: 要件整理」「フェーズ2: 実装」等）
- ユーザーの指示内容は省略せず、要旨を正確に記載する

## 作業フロー（時系列）
- セッション全体をフェーズに分割し、各フェーズで何を行ったかを記述する
- 重要な判断、設計変更、問題発生と解決を含める
- 実装した内容の具体的な説明（コンポーネント名、ファイルパス等）

## 実装した主要な変更
- 新規ファイル一覧（パスと役割の簡潔な説明）
- 変更ファイル一覧（何を変更したか）
- 削除 / 移動されたファイル

## セッション終了時の状態
- 完了済みの作業
- 未完了・次にすべきこと
- 最後のユーザー指示とその対応状況

## 重要な判断・設計決定
- セッション中に行われた設計上の重要な判断
- ユーザーとの合意事項
- 方針変更があった場合はその理由と経緯

## 問題・エラーの記録（該当する場合）
- 発生した問題とその解決方法
- ハルシネーションや誤解があった場合の記録
```

## 品質基準（必ず遵守）

- 「直近 N メッセージ」のような打ち切りは**絶対にしない**。全メッセージをカバーすること
- ツール呼出しを「使用ツール: Bash」のように名前だけ列挙するのは**禁止**。何をしたかを記述すること
- このサマリーだけで、セッションに参加していなかった人がセッションの
  全容を把握できるレベルの情報量を目指す
- 情報が不足する場合は、元の JSONL ファイルから jq で追加抽出して補完すること
````
