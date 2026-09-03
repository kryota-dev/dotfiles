---
name: fresh-note
description: fixture の陰性対照。どのチェックでも finding になってはならない
metadata:
  type: project
modified: 2026-08-31T09:00:00+09:00
---

この fixture では lint ツールのバージョンを `home/dot_config/lint-pins.toml` に固定している。
CI はそのピンを読み取って同じビルドを入れる。

**Why:** ランナーイメージ同梱のビルドに暗黙依存すると、手元と CI で lint 結果が食い違い、
push して初めて失敗が分かる。宣言してから読む方が安い。

**How to apply:** ツールを増やすときは、まずバージョンをこのファイルへ宣言し、CI 側は
そのピンを読み取るステップを足す。イメージに入っているからという理由で宣言を省かない。
