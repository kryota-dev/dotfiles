---
name: vitest-error-analysis
description: Vitestのテスト結果からエラー情報を効率的に抽出・分析するスキル。テストが失敗した際、テストエラーの調査時、または「テストエラーを分析」「テスト失敗の原因」「test failed」などと言及された際に使用。
allowed-tools: Bash, Read, Grep
---

# Vitest テストエラー分析

Vitestテストの出力から効率的にエラー情報を抽出・分析するためのガイド。

## 基本原則

Vitestの出力は非常に長くなることがあるため、**直接読まずに一時ファイルに保存**してからエラー情報のみを抽出する。

**重要**: 一時ファイルには必ずタイムスタンプを付与する（`yyyy-mm-dd_hh-mm-ss`形式）。

## 手順

### Step 0: タイムスタンプの設定

```bash
# セッション内で共通のタイムスタンプを使用
TS=$(date +%Y-%m-%d_%H-%M-%S)
```

### Step 1: テスト実行と結果の保存

```bash
# プロジェクト全体のテスト
pnpm test 2>&1 | tee /tmp/test-output_${TS}.txt

# 特定パッケージのテスト（monorepo）
pnpm -F @scope/package test 2>&1 | tee /tmp/test-output_${TS}.txt

# 特定ファイルのテスト
pnpm test src/path/to/file.spec.ts 2>&1 | tee /tmp/test-output_${TS}.txt
```

### Step 2: エラーサマリーの抽出

```bash
# 失敗テストの概要を抽出
grep -E "(FAIL|Failed Tests|AssertionError|Error:|Test Files.*failed|❯.*\.spec\.ts)" /tmp/test-output_${TS}.txt > /tmp/test-errors_${TS}.txt

# 結果を確認
cat /tmp/test-errors_${TS}.txt
```

### Step 3: 詳細なエラー差分の抽出

```bash
# Failed Tests セクションから Test Files サマリーまでを抽出
awk '/Failed Tests/,/Test Files/' /tmp/test-output_${TS}.txt
```

### Step 4: 特定のテストファイルのエラーのみ抽出

```bash
# 特定ファイル名でフィルタリング
grep -A 30 "FAIL.*specific-file.spec.ts" /tmp/test-output_${TS}.txt
```

## エラー出力の解釈ガイド

### 出力構造

```
⎯⎯⎯⎯⎯⎯⎯ Failed Tests N ⎯⎯⎯⎯⎯⎯⎯    # 失敗テスト数
FAIL  @scope/pkg  <ファイルパス> > <テスト名>  # 失敗したテストの特定
AssertionError: ...                           # エラー種類
- Expected                                    # 期待値（緑色）
+ Received                                    # 実際の値（赤色）
❯ <ファイル>:<行番号>                          # エラー発生箇所
Test Files  N failed | M passed               # サマリー
```

### よくあるエラーパターン

| パターン | 説明 | 対処法 |
|---------|------|--------|
| `expected X to equal Y` | 値の不一致 | Expected/Received の差分を確認 |
| `expected X to have length Y` | 配列長の不一致 | 配列の中身を確認 |
| `expected X to deeply equal Y` | オブジェクト構造の不一致 | プロパティ名・順序を確認 |
| `TypeError: Cannot read property` | undefined アクセス | nullチェック漏れを確認 |
| `Test timed out` | タイムアウト | 非同期処理の完了待ちを確認 |

### 差分の読み方

```diff
- Expected   # この行は期待値（テストコードで指定した値）
+ Received   # この行は実際の値（テスト対象が返した値）

@@ -9,11 +9,12 @@   # 差分の位置情報
   "type": "action",   # 変更なし（コンテキスト）
-  "categories": [     # 期待していたが存在しない
+  "itemGroups": [     # 代わりに存在する
```

## 反復的なエラー修正フロー

大量のテストエラーがある場合の効率的な修正フロー：

```bash
# 0. タイムスタンプ設定（セッション開始時に1回）
TS=$(date +%Y-%m-%d_%H-%M-%S)

# 1. テスト実行
pnpm test 2>&1 | tee /tmp/test-output_${TS}.txt

# 2. エラー抽出
grep -E "(FAIL|Failed Tests|Test Files.*failed)" /tmp/test-output_${TS}.txt > /tmp/test-errors_${TS}.txt

# 3. エラー確認
cat /tmp/test-errors_${TS}.txt

# 4. 詳細確認（必要に応じて）
awk '/Failed Tests/,/Test Files/' /tmp/test-output_${TS}.txt

# 5. 修正後、タイムスタンプを更新して1に戻る
TS=$(date +%Y-%m-%d_%H-%M-%S)
```

## 継続判定

```bash
# 失敗テストがあるか確認
if grep -q "Test Files.*failed" /tmp/test-output_${TS}.txt; then
  echo "エラーあり - 修正を継続"
else
  echo "全テスト成功"
fi
```

## Tips

- **出力が長すぎる場合**: `head -100` や `tail -100` で絞り込む
- **色コードが邪魔な場合**: `| sed 's/\x1b\[[0-9;]*m//g'` で除去
- **特定のテストのみ実行**: `pnpm test -- --testNamePattern="テスト名"`
- **並列実行を無効化**: `pnpm test -- --no-threads` でデバッグしやすくする
- **過去のログを確認**: `ls -la /tmp/test-output_*.txt` で一覧表示
