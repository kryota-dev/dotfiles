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
- **auto-memory ディレクトリは読み取り専用**。Phase 0.5 の再検証も報告だけを行い、腐敗を見つけても自分では直さない。
- CLV2 engine（external — chezmoi external・SHA pin 管理）は読み取り専用で扱い、改変しない。

## Phase 0: 健全性診断（必ず実施）

```bash
H="${CLV2_HOMUNCULUS_DIR:-$HOME/.local/share/ecc-homunculus-default}"    # 未設定なら既定へ fallback（診断表に明記）
jq '.observer' "$H/config.json"                              # enabled / run_interval / min_observations
# instinct 蓄積数。CLV2 v2.1 で保存先がグローバル階層（$H/instincts/personal/）から
# project 単位（下記）へ移行済み（#491）。グローバル階層は promote の書き込み先
# （instinct-cli.py の cmd_promote が project から COPY するだけで project 側は残る）
# であって蓄積量の指標ではないため、両方を数えると昇格済み instinct を二重計上する。
# knowledge-distill-instinct-count:begin
find "$H/projects" -mindepth 4 -maxdepth 4 -type f \
  \( -path '*/instincts/personal/*' -o -path '*/instincts/inherited/*' \) \
  \( -iname '*.md' -o -iname '*.yaml' -o -iname '*.yml' \) \
  ! -iname 'MEMORY.md' 2>/dev/null | wc -l
# knowledge-distill-instinct-count:end
ls -lt "$H"/projects/*/observations.jsonl 2>/dev/null | head -3   # 観測の鮮度（記録が進んでいるか）
ls "$H"/projects/*/observations.archive/ 2>/dev/null | tail -3    # 分析の処理痕跡（processed-<時刻> 名はソート=時系列のため tail が直近）
grep -h 'timed out' "$H"/projects/*/*.log 2>/dev/null | tail -3   # timeout 痕跡（#256 の再発監視）
grep -h 'Reached max turns' "$H"/projects/*/*.log 2>/dev/null | tail -3   # turn 枯渇痕跡（#336 の再発監視）
grep -h 'sensitive file' "$H"/projects/*/*.log 2>/dev/null | tail -3      # 保存先が config dir 配下へ戻った兆候（#336）
printf '%s\n' "${ECC_OBSERVER_TIMEOUT_SECONDS:-unset (この場合 observer は既定 120s)}"
```

- `config.json` や `jq` が無い場合はエラーで止めず、「config 不在」「jq 不在」を**実測値として診断表に記載**して続行する（診断 skill 自身が診断前に死なない）。

結果を診断表で報告する（空のセクションも「なし」と明記）:

| 項目 | 期待 | 実測 | 判定 |
|------|------|------|------|
| observer.enabled | true | | |
| observations の鮮度 | 対象週内に更新 | | |
| 分析完走の痕跡（archive） | 増加している | | |
| timeout 痕跡 | なし | | |
| turn 枯渇痕跡（Reached max turns） | なし | | |
| sensitive-file 痕跡 | なし | | |
| ECC_OBSERVER_TIMEOUT_SECONDS | 300 以上 | | |
| instinct 蓄積数 | ≥ --min-instincts | | |

- `ECC_OBSERVER_TIMEOUT_SECONDS` が unset の場合、cld / cld-r06 wrapper（claude.zsh）を経由しない起動の可能性を指摘する（#256 の修正は wrapper の env 注入で効く）。
- **timeout / turn 枯渇痕跡が残る場合**: 既に起動済みの**長寿命 observer プロセスには新しい env が届いていない**。推奨アクションに observer の再起動を含める（cld / cld-r06 セッションからの起動し直しが確実 — wrapper が保存先・timeout・active-hours・max-turns の env を一式注入するため、手動起動では取りこぼしやすい）:

```bash
~/.agents/skills/continuous-learning-v2/agents/start-observer.sh stop || true
# 手動起動は timeout のみを固定する例。他の env は wrapper 側（claude.zsh）が SSOT。
ECC_OBSERVER_TIMEOUT_SECONDS="${ECC_OBSERVER_TIMEOUT_SECONDS:-300}" \
  ~/.agents/skills/continuous-learning-v2/agents/start-observer.sh start
```

- **sensitive-file 痕跡が残る場合**: 保存先が config dir 配下（`~/.claude*`）に戻っている。Claude Code は config dir 配下を sensitive file として扱い、非対話セッションは instinct の Write を承認できない。`claude.zsh` の `CLV2_HOMUNCULUS_DIR` が `~/.local/share/ecc-homunculus-<slug>` を指しているか確認する（#336）。

- その他の判定 NG の項目には修理手段を添える（例: chezmoi apply の再実行、`run_onchange_after_14-enable-clv2-observer` の確認、issue 起票）。

## Phase 0.5: 既存 auto-memory の再検証（必ず実施・報告のみ）

**Phase 0 の直後、Phase 1 の縮退終了より前に実行する。** 検出したい腐敗は instinct の蓄積量とは
無関係に進むので、蒸留フェーズが縮退する週こそ走らせる（縮退レポートにも結果を含める）。

`knowledge-distill` は長らく「その週に新しく溜まった学び」しか見ておらず、既に保存済みの
auto-memory が古くなっていないかは誰も点検していなかった。実監査（kryota-dev/dotfiles#631）で
4 件が見つかっている。腐敗は 2 種類ある: **(a) 参照先の実体が消えている / 変わっている**、
**(b) 上位の恒久ルールに吸収されて存在意義が消えている**。公式仕様も
「Claude skips ... anything your CLAUDE.md files already say」と述べており、(b) はそのルールが
事後に破れた状態にあたる。

```bash
python3 ~/.agents/skills/knowledge-distill/scripts/memory-revalidate.py --format text
```

- 週次 headless 実行では **env prefix を付けず単独のコマンド**として呼ぶ。許可リストはこの
  フルパスに対する prefix マッチなので、`VAR=x python3 ...` の形は一致せず無言で拒否される。
- 既定の対象は cwd のリポジトリから導出した `<config dir>/projects/<project>/memory/`。
  別の場所を見るなら `--memory-dir`、照合先を変えるなら `--repo` / `--rules` を渡す。
- `--github off` を付けると PR / Issue 番号の実在確認を行わない（その分は「実行不能」に出る）。

### 何を見るか（6 チェック）

| id | 見るもの | 拾う腐敗 |
|---|---|---|
| `path-exists` | コードスパン中のリポジトリ相対パスが実在するか | (a) |
| `make-target` | コードスパン中の `make <target>` が Makefile にあるか | (a) |
| `pr-reference` | `#N` / `<owner>/<repo>#N` が GitHub 上に実在するか | (a) |
| `staleness` | 参照先の最終変更日が memory の日付より後か | (a) |
| `rule-duplication` | CLAUDE.md / AGENTS.md が既に同じことを書いていないか | (b) |
| `memory-index-size` | `MEMORY.md` が 200 行 / 25KB の読み込み上限に収まっているか | 索引の読み込み欠落 |

**意味的な判定は機械化しない。** 「解除条件が満たされたか」「この学びはまだ有効か」は人が決める。

### 出力の読み方

出力には各チェックの **状態 / 検査 / finding / 未検査 / 実行不能** が並ぶ。読み方は 1 つだけ:

- **「未検査」は「問題なし」ではない。** 絶対パスや glob のように、存在しないと断定できない
  候補を意図的に判定対象から外したもので、必ず件数と理由が列挙される。
- **「実行不能」も「問題なし」ではない。** `gh` が無い、git リポジトリでない、ルールファイルが
  無い等でチェック自体が走れなかったことを表す。
- したがって **「0 件中 finding 0」と「12 件中 finding 0」は別物**として読む。

| 終了コード | 意味 |
|---|---|
| 0 | finding なし・実行不能なし |
| 1 | finding あり |
| 2 | 実行できなかったチェックがある |
| 3 | 両方 |
| 64 | 引数エラー |
| 70 | 内部エラー |

### 報告と昇華

- `--format text` の出力を Phase 3 のレポートへ **1 節としてそのまま転記する**（機械可読な
  `--format json` はテスト・自動処理用）。
- 出力に memory 本文は含まれない（ファイル名・行番号・検出した参照・判定理由まで）。この節を
  レポートへ写すときも、memory の散文を補って引用しない。
- **finding は提案止まり**。memory の修正・削除はユーザーが明示承認したあとに別途行う
  （Phase 3 の区分 (c) と同じ扱い）。

## Phase 1: 縮退判定

instinct 蓄積数 < `--min-instincts` の場合、**縮退レポート**を出力して正常終了する:

- 診断表 + NG 項目ごとの推奨アクション
- **Phase 0.5 の再検証結果**（縮退週でも省略しない。既存メモリの腐敗は instinct 蓄積量と無関係に進む）
- 蓄積の見込み: config の `min_observations_to_analyze` / `run_interval_minutes` と直近の observations 量から「次に分析が走る条件」を説明する（日数の断定はしない）
- 再実行の目安（例: observer が健全なら 1〜2 週間後）

空振りはエラーではなく「**ループが動いていない**という観測結果」であり、backlog #15 の再開条件（instinct ≥ 10）の定点監視を兼ねる。

## Phase 2: 収集とクラスタ（蓄積が十分な場合）

- 対象週内に更新された instinct を Read する（project 単位の蓄積は全 project 合計で数百〜数千件に
  なり得るため、Phase 0 の総数を全件 Read するのは非現実的。更新日時で絞り、直近更新順で上限を切る）:

```bash
find "$H/projects" -mindepth 4 -maxdepth 4 -type f \
  \( -path '*/instincts/personal/*' -o -path '*/instincts/inherited/*' \) \
  \( -iname '*.md' -o -iname '*.yaml' -o -iname '*.yml' \) \
  ! -iname 'MEMORY.md' -mtime -7 2>/dev/null | head -30
```

  - `-mtime -7` は「対象週」の粗い近似で、`--week=last` 実行時も同じ 7 日窓を使う。ズレは日次精度では
    なく**最大で 1 週間分**になりうる（例: 週の半ばに `--week=last` を手動実行すると、7 日窓は今週前半を
    含み、先週前半を取りこぼす）。影響は Phase 2 で個別 Read する対象の選定に留まり、Phase 0 の集計値と
    `evolve` のクラスタ検出（累積プール全体を見る）には及ばない。`-newermt` は使わない（macOS/Linux
    両対応のため）。
  - `find | head` で完結させる（`xargs`・`ls -t` は使わない）。理由は 2 つ: (1) headless 実行時の
    `--allowedTools` は `find`/`head` は許可するが `xargs` は許可しない、(2) 件数が多いと `xargs` が
    引数を分割し、`ls -t` のソートがバッチ内に閉じて `head` の結果が「全体の直近 N 件」にならない。
    したがって上位 30 件は**更新順ではなく任意の 30 件**であり、`-mtime -7` の窓が実質的な絞り込みになる。
  - 30 件を超えて対象週内に更新がある場合、超過分は個別 Read せず Phase 0 の instinct 蓄積数（実測値）
    としてのみ報告する（この週のクラスタ抽出は下記 evolve の cluster 検出に委ねる）。
- cluster 候補を取得する（instinct 3 件未満は exit 1 になるため、その場合はこの経路を skip）:

```bash
# $H を明示的に渡す: CLV2_HOMUNCULUS_DIR 未設定のまま呼ぶと、CLI は upstream の fallback
# （$XDG_DATA_HOME/ecc-homunculus か ~/.local/share/ecc-homunculus）を解決し、Phase 0 で診断した
# ストアとは別の場所を見てしまう（診断と evolve が食い違う）。
CLV2_HOMUNCULUS_DIR="$H" python3 ~/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py evolve
# 出力の「## SKILL CANDIDATES」節（trigger / 構成 instinct ID / avg confidence）を候補として読む
```

- 対象週の session-summary（worklog と同じ 2 経路: `ghq list -p` 横断 + `~/worktrees/*/*/`、timestamp で期間フィルタ）から会話ベースの学びを抽出する
- 類似の学びを束ね、**2 回以上繰り返し出現したもの**を優先候補にする

## Phase 3: 昇華提案レポート

`~/dotfiles/.kryota-dev/knowledge-distill/<YYYY-Www>.md` に出力する（`--dry-run` 時は標準出力のみ）。**レポート冒頭には worklog と同じ `<!-- INTERNAL: ... -->` 転記警告コメントを必ず含める**（instinct / session-summary 由来のクライアント情報が入りうるため）:

| 区分 | 昇華先 | 提案の形 |
|------|--------|---------|
| (a) evolved skill 化 | `/retrospective-codify --input=instinct-clusters`（adopt-ideas 方針。`/evolve` の auto-files は使わない） | cluster と convention 草案 |
| (b) curated skill 改修 | pr-workflow | 対象 skill と改修案 |
| (c) memory 追加 | ユーザー承認 → Write | 記録対象・内容案・保存価値の根拠（**承認前に書き込まない**） |
| (d) ルール化 | pr-workflow | AGENTS.md / CLAUDE.md への追記 diff 案 |

- **Phase 0.5 の再検証結果を 1 節として含める**（`--format text` の出力をそのまま転記する）。
- 各提案に根拠（instinct ID / session-summary の該当箇所）を必ず添える。
- ※ (a) は要件上「`/evolve` で evolved skill 化」だが、adopt-ideas 方針（auto-files 不使用、task #34）により retrospective-codify の instinct-clusters 入力経由で実現する。
- レポート末尾に「今週の routing 決定」チェックリスト（ユーザーが GO / NO-GO を記入する欄）を含める。

## 運用メモ

- 週次自動実行: `dev.kryota.knowledge-distill` launchd エージェント（金曜 18:00 JST、
  `home/dot_claude/executable_knowledge-distill-radar.sh`）が headless で本 skill を起動し、
  CLV2 パイプラインの健全性（instinct 蓄積数）を独立に precheck した上でレポート要約を
  ntfy（`claude-attention`）へ通知する（kryota-dev/dotfiles#368、2026-07-26 承認）。
  詳細は `docs/architecture/notifications.md` の「Weekly knowledge-distill delivery」節を参照。
  手動実行（`--week=last` での過去週再確認等）も引き続き可能。
