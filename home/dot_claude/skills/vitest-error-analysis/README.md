# Vitest Error Analysis Skill

Vitest のテスト結果からエラー情報を効率的に抽出・分析するためのエージェントスキル。

## 概要

Vitest の出力は非常に長くなることがあり、エラー情報を見つけるのが困難な場合があります。このスキルは、テスト出力を一時ファイルに保存し、grep/awk を使用してエラー情報のみを効率的に抽出する手法を提供します。

## 主な機能

1. **テスト結果の保存**: 出力を一時ファイルに保存して後から分析
2. **エラーサマリーの抽出**: 失敗テストの概要を素早く把握
3. **詳細差分の抽出**: Expected/Received の差分を確認
4. **エラー解釈ガイド**: よくあるエラーパターンの説明

## 使用例

### 基本的な使い方

```bash
# テスト実行と結果保存
pnpm test 2>&1 | tee /tmp/test-output.txt

# エラー情報の抽出
grep -E "(FAIL|Failed Tests|AssertionError)" /tmp/test-output.txt
```

### 詳細なエラー差分の確認

```bash
awk '/Failed Tests/,/Test Files/' /tmp/test-output.txt
```

## トリガーキーワード

以下のキーワードでスキルが自動的に有効化されます：

- 「テストエラーを分析」
- 「テスト失敗の原因」
- 「test failed」
- 「vitest error」

## 互換性

- **テストフレームワーク**: Vitest
- **パッケージマネージャー**: pnpm, npm, yarn（コマンドを適宜読み替え）
- **プロジェクト構成**: 単一パッケージ、monorepo 両対応
