---
name: knowledge-distill
description: |
  週次のナレッジ蒸留 routine。ECC 継続学習ループ（observe → instinct → evolve/codify）の
  健全性を診断し、instinct と session-summary を横断して「evolved skill 化 / curated skill 改修 /
  memory 追加 / ルール化」の 4 区分で昇華提案レポートを生成する。蓄積不足なら診断レポートで縮退終了。
  トリガー: "knowledge-distill", "ナレッジ蒸留", "週次蒸留", "今週の学びをまとめて", "instinct 棚卸し"
  使用場面: 週次の振り返り、ナレッジループが機能しているかの定点観測。
argument-hint: "[--week=this|last] [--min-instincts=10] [--dry-run]"
user-invocable: true
---

# knowledge-distill

セッションで得た学びが「揮発」せず資産化されているかを週次で点検し、溜まった素材を適切な昇華先へ routing する。**書き込みは自分のレポートのみで、昇華の実行はすべて提案止まり**（実行はユーザー承認後に各 skill へハンドオフ）。

## 棲み分け

| skill | 対象 | タイミング |
|-------|------|-----------|
| session-summary | 単一セッションの要約 | セッション終了時 |
| retrospective-codify | 学びの convention file 固定化（人手レビュー前提） | 学びが確立したとき |
| `/evolve`（CLV2） | instinct → cluster 検出エンジン | 蓄積が閾値を超えたとき |
| **knowledge-distill（本 skill）** | **週次横断の健全性診断 + 昇華先 routing（提案のみ）** | **週 1 回** |

## 引数

| 引数 | 既定 | 意味 |
|------|------|------|
| `--week` | `this` | 対象週（`this`=今週月曜〜実行時点、`last`=先週月〜日。JST） |
| `--min-instincts` | 10 | 蒸留フェーズへ進む instinct 蓄積数の下限（未満なら縮退レポート） |
| `--dry-run` | off | レポートのファイル書き込みをせず、標準出力のみ |

## 安全原則

- ファイル書き込みは gitignore 領域のレポート（`~/dotfiles/.kryota-dev/knowledge-distill/`）のみ。
- **memory / skill / AGENTS.md への変更は提案の提示に留める**。実書き込みはユーザーが明示承認した後に別途行う（グローバル memory ポリシー準拠）。
- CLV2 engine（chezmoi external、vendored）は読み取り専用で扱い、改変しない。

## Phase 0: 健全性診断（必ず実施）

```bash
H="${CLV2_HOMUNCULUS_DIR:-$HOME/.claude/ecc-homunculus}"    # 未設定なら既定へ fallback（診断表に明記）
jq '.observer' "$H/config.json"                              # enabled / run_interval / min_observations
ls "$H/instincts/personal/" 2>/dev/null | wc -l              # instinct 蓄積数
ls -lt "$H"/projects/*/observations.jsonl 2>/dev/null | head -3   # 観測の鮮度（記録が進んでいるか）
ls "$H"/projects/*/observations.archive/ 2>/dev/null | tail -3    # 分析が完走した痕跡（archive 移動）
grep -h 'timed out' "$H"/projects/*/*.log 2>/dev/null | tail -3   # timeout 痕跡（#256 の再発監視）
printf '%s\n' "${ECC_OBSERVER_TIMEOUT_SECONDS:-unset (この場合 observer は既定 120s)}"
```

結果を診断表で報告する（空のセクションも「なし」と明記）:

| 項目 | 期待 | 実測 | 判定 |
|------|------|------|------|
| observer.enabled | true | | |
| observations の鮮度 | 対象週内に更新 | | |
| 分析完走の痕跡（archive） | 増加している | | |
| timeout 痕跡 | なし | | |
| ECC_OBSERVER_TIMEOUT_SECONDS | 300 以上 | | |
| instinct 蓄積数 | ≥ --min-instincts | | |

- `ECC_OBSERVER_TIMEOUT_SECONDS` が unset の場合、cld / cld-r06 wrapper（claude.zsh）を経由しない起動の可能性を指摘する（#256 の修正は wrapper の env 注入で効く）。
- 判定 NG の項目には修理手段を添える（例: chezmoi apply の再実行、`run_onchange_after_14-enable-clv2-observer` の確認、issue 起票）。

## Phase 1: 縮退判定

instinct 蓄積数 < `--min-instincts` の場合、**縮退レポート**を出力して正常終了する:

- 診断表 + NG 項目ごとの推奨アクション
- 蓄積の見込み: config の `min_observations_to_analyze` / `run_interval_minutes` と直近の observations 量から「次に分析が走る条件」を説明する（日数の断定はしない）
- 再実行の目安（例: observer が健全なら 1〜2 週間後）

空振りはエラーではなく「**ループが動いていない**という観測結果」であり、backlog #15 の再開条件（instinct 10 件以上）の定点監視を兼ねる。

## Phase 2: 収集とクラスタ（蓄積が十分な場合）

- `ls "$H/instincts/personal/"` の全 instinct を Read する
- cluster 候補を取得する（instinct 3 件未満は exit 1 になるため、その場合はこの経路を skip）:

```bash
python3 ~/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py evolve
# 出力の「## SKILL CANDIDATES」節（trigger / 構成 instinct ID / avg confidence）を候補として読む
```

- 対象週の session-summary（`ghq list -p` 横断で `<repo>/.kryota-dev/claude/session-summary/*.md`、timestamp で期間フィルタ）から会話ベースの学びを抽出する
- 類似の学びを束ね、**2 回以上繰り返し出現したもの**を優先候補にする

## Phase 3: 昇華提案レポート

`~/dotfiles/.kryota-dev/knowledge-distill/<YYYY-Www>.md` に出力する（`--dry-run` 時は標準出力のみ）:

| 区分 | 昇華先 | 提案の形 |
|------|--------|---------|
| (a) evolved skill 化 | `/retrospective-codify --input=instinct-clusters`（adopt-ideas 方針。`/evolve` の auto-files は使わない） | cluster と convention 草案 |
| (b) curated skill 改修 | pr-workflow | 対象 skill と改修案 |
| (c) memory 追加 | ユーザー承認 → Write | 記録対象・内容案・保存価値の根拠（**承認前に書き込まない**） |
| (d) ルール化 | pr-workflow | AGENTS.md / CLAUDE.md への追記 diff 案 |

- 各提案に根拠（instinct ID / session-summary の該当箇所）を必ず添える。
- レポート末尾に「今週の routing 決定」チェックリスト（ユーザーが GO / NO-GO を記入する欄）を含める。

## 運用メモ

- 推奨リズム: 週 1 回（金曜夕方 or 月曜朝）。morning-brief / worklog と同じ朝ルーチンに組み込める。
- 定期自動実行（cron）は本 skill の範囲外。載せる場合は課金を伴うため、ユーザーの明示承認で別途設定する。
