---
name: webp-convert
description: cwebpを使って画像をWebP形式に変換するスキル。「webp変換」「画像をwebpに」「画像最適化」「cwebp」などと言及された際や、画像ファイル（jpg, png, gif等）をWebPに変換する必要がある場合に使用する。Web用画像の配置・最適化時にも活用すること。
allowed-tools: Bash, Read, Glob
argument-hint: "<image-path-or-glob> [-q quality] [-w width] [-o output-dir]"
---

# WebP 画像変換

指定された画像を `cwebp` で WebP 形式に変換する。単一ファイルおよび複数ファイルの一括変換に対応。

## 引数

`$ARGUMENTS` を解析して以下のオプションを抽出する。未指定の場合はデフォルト値を使用。

| オプション | デフォルト | 説明 |
|-----------|-----------|------|
| `<path>` | (必須) | 変換対象の画像パスまたは glob パターン（例: `src/images/*.png`） |
| `-q` | `85` | 品質（0-100）。85 がサイズと画質のバランスが良い |
| `-w` | (なし) | リサイズ幅（px）。高さは自動計算。例: `1920` |
| `-o` | (なし) | 出力先ディレクトリ。未指定時は入力ファイルと同じディレクトリ |

## 前提条件

変換開始前に `cwebp` の存在を確認する:

```bash
which cwebp
```

未インストールの場合はユーザーに伝える:
- macOS: `brew install webp`
- Ubuntu/Debian: `sudo apt install webp`

## 対応フォーマット

`cwebp` がネイティブ対応: **JPEG, PNG, TIFF, WebP**

以下のフォーマットは事前に PNG へ変換が必要:
- **GIF, BMP** → `sips -s format png input.gif --out /tmp/input.png`（macOS）
- **SVG** → `rsvg-convert input.svg -o /tmp/input.png`（librsvg）

## 変換手順

### 単一ファイル

```bash
cwebp -q 85 "path/to/image.jpg" -o "path/to/image.webp"
```

### 一括変換

```bash
for f in path/to/*.{jpg,jpeg,png,gif,tiff,bmp}; do
  [ -f "$f" ] || continue
  out="${f%.*}.webp"
  cwebp -q 85 "$f" -o "$out"
done
```

### 出力先ディレクトリ指定

```bash
outdir="path/to/output"
mkdir -p "$outdir"
for f in path/to/source/*.{jpg,jpeg,png}; do
  [ -f "$f" ] || continue
  name=$(basename "${f%.*}")
  cwebp -q 85 "$f" -o "$outdir/$name.webp"
done
```

### リサイズ付き変換

幅 1920px にリサイズ（アスペクト比維持）:

```bash
cwebp -q 85 -resize 1920 0 "input.jpg" -o "output.webp"
```

## 出力パスの規則

- 拡張子を `.webp` に置換: `photo.jpg` → `photo.webp`
- 出力先ディレクトリが指定された場合はそちらに出力
- ファイル名のステム（拡張子を除いた部分）は保持

## 変換後の報告

変換完了後、元ファイルとの比較サマリーを表示する:

```bash
for f in path/to/*.webp; do
  orig="${f%.*}.jpg"
  [ -f "$orig" ] && printf "%-40s %8s -> %8s\n" "$(basename "$f")" "$(du -h "$orig" | cut -f1)" "$(du -h "$f" | cut -f1)"
done
```

## 用途別の推奨設定

| 用途 | 品質 | リサイズ幅 | 備考 |
|------|------|-----------|------|
| ヒーロー/バナー画像 | 85 | 1920px | フル幅表示 |
| コンテンツ画像 | 85 | 1200px | 記事・ページ本文 |
| サムネイル | 80 | 400px | グリッド・カード表示 |
| 高品質写真 | 92 | (なし) | ポートフォリオ、商品写真 |
| アイコン/ロゴ | 90 | (なし) | 元サイズ維持 |
