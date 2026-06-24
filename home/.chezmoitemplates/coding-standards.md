## Coding standards (house)

harness 非依存のコーディング規約。言語固有の規約・tool は各 project の CLAUDE.md に従う。

### 設計原則
- **小さく凝集したファイルを多数** > 巨大ファイル少数。~200-400 行を目安、800 行で分割検討。feature/domain 単位で整理。
- **immutability 既定**: 既存オブジェクトを破壊的変更せず新しい値を返す。副作用は局所化。
- **KISS / YAGNI**: 動く最小で始め投機的抽象化をしない。重複が実在してから DRY 化。
- **深いネストより early return**: ガード節で先に抜ける。

### 堅牢性
- **error を握り潰さない**: 各層で明示的に扱う（空 catch 禁止）。server 側は文脈付きで log、UI 側は利用者向けメッセージ。
- **境界で検証**: 外部入力（API 応答・ユーザー入力・ファイル）を信頼せず schema 検証を優先、fail fast。
- **magic number/string を避ける**: 意味ある閾値・上限は名前付き定数に。

### security by default
- 執筆時に secret（API key/password/token）をソースへ直書きしない。env / secret manager 経由。（commit 時の機械検査は gitleaks が別途担保）
- SQL は parameterized query、外部出力は文脈に応じて escape。

### テスト姿勢
- 非自明なロジックにはテストを書く。**project の既存テスト framework・カバレッジ規範に合わせる**（global な固定カバレッジ率は課さない）。
- bug fix は再現テストを先に書く。

### 実装前 / 後始末
- **reuse-first**: 車輪の再発明を避け、battle-tested な既存実装を先に探す。要件の 80% を満たすものは採用/port を優先。
- debug 出力（console.log 等）・コメントアウトの死にコードを残さない。
