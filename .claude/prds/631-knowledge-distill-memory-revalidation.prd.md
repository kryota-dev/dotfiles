---
slug: 631-knowledge-distill-memory-revalidation
feature: knowledge-distill への既存 auto-memory 再検証フェーズ追加
created_at: 2026-09-03T11:30:16+09:00
grill_session: dfd25e4f-c71b-4e5c-aa9e-53e8c5efd8e6
status: draft
---

# knowledge-distill への既存 auto-memory 再検証フェーズ追加

## Background

auto-memory を読み取り専用で監査したところ、4 件の腐敗が見つかった。

**乖離 2 件**（内容が実態とずれていた。監査後に user 承認のうえ MEMORY.md 側は修正済み）:

1. `make dump-brewfile` を前提にした記述。この Make target は PR #373 で廃止され、現在は `brew` の
   PATH シム（`home/dot_local/launchers/executable_brew`）が install/uninstall 後に
   `brew bundle dump --force` で自動同期する。**存在しない Make target を案内していた。**
2. macOS CI のキャッシュ対象が `~/Library/Caches/Homebrew` だけだという記述。PR #38 で
   `/opt/homebrew/{Cellar,opt,Library/Taps}` を含む 4 パスに拡張済み。

**重複 2 件**（`~/AGENTS.md` の恒久ルールと同じことを書いていた。監査後に user 承認のうえ削除済み）:

3. レビュー指摘を一次ソースで検証するルール（`~/AGENTS.md`「レビュー指摘の検証」と重複）
4. public リポジトリに固有名を書かないルール（`~/AGENTS.md`「commit / PR / 公開物への記載禁止」と重複）

つまり検出したい腐敗は 2 種類ある。**(a) 参照先の実体が消えている / 変わっている**（1・2）と
**(b) 上位の恒久ルールに吸収されて存在意義が消えている**（3・4）。

現行の `knowledge-distill` は Phase 2 で「直近 7 日に更新された instinct」を拾うだけで、**既に保存済みの
memory が古くなっていないかを一切見ていない**。古いメモリは無いより悪く、存在しないコマンドを案内する
などの誤判断を生む。新規検出だけでは腐敗を止められない。

一次ソース（auto-memory 公式仕様 <https://code.claude.com/docs/en/memory#auto-memory>）から、本 PRD が
根拠に使う事実は次の 3 点である。

- `MEMORY.md` の読み込み上限:「The first 200 lines of `MEMORY.md`, or the first 25KB, whichever comes
  first, are loaded at the start of every conversation.」超過分は次回ロードで捨てられる。
- 書き込み時刻の記録:「When Claude writes a memory file that begins with YAML frontmatter, Claude Code
  records the write time in a `modified` frontmatter field as an ISO 8601 timestamp.」（v2.1.214 以降。
  **frontmatter を持たないファイルには付与されない**）。
- 重複の禁止:「It also skips anything your CLAUDE.md files already say.」——(b) の腐敗は、この公式ルールが
  事後に破れた状態そのものである。

関連: #473（ECC hook 側。本 PRD のスコープ外）。

## User Story

週次の `knowledge-distill` を回したとき、**その週に新しく溜まった学びの棚卸しだけでなく、既に保存されている
auto-memory が今も正しいか**が同じレポートに載る。腐敗の疑いは「memory ファイル名 : 行番号 : 検出した参照 :
判定理由」の形で提示され、**その場で書き換えられることはない**。user はレポートを読んで、直すか消すか
残すかを自分で決める。

instinct の蓄積が閾値未満で蒸留フェーズが縮退終了する週でも、この再検証だけは走る。今回の 4 件は
instinct 蓄積量とは無関係に腐っていたからである。

## Acceptance Criteria

### フェーズの配置と契約

- **AC-001**: `knowledge-distill` SKILL.md に **Phase 0.5「既存 auto-memory の再検証」** を追加する。
  実行順は Phase 0（健全性診断）の直後、**Phase 1（縮退判定）の縮退終了より前**。縮退レポートにも
  再検証結果を含める。
- **AC-002**: 本フェーズは **報告のみ**。memory ディレクトリ配下のファイルを一切変更しない。memory の
  修正・削除は従来どおり user が明示承認したあとに別途行う（グローバル memory ポリシー準拠）。
- **AC-003**: 意味的な判定（「解除条件が満たされたか」「この学びはまだ有効か」等）は機械化しない。
  機械チェックは参照実体・日付・重複・サイズに限り、判断は人に残す。

### 検査スクリプト

- **AC-010**: 検査は単一スクリプト `home/dot_agents/skills/knowledge-distill/scripts/memory-revalidate.py`
  （Python 3 標準ライブラリのみ）で行う。SKILL.md はこれを 1 コマンドとして呼ぶ。
- **AC-011**: 次の 6 チェックを実装する。

  | id | 何を見るか | 対象 | 捕まえる腐敗 |
  |---|---|---|---|
  | `path-exists` | コードスパン中のリポジトリ相対パスが実在するか | memory 全ファイル | (a) |
  | `make-target` | コードスパン中の `make <target>` が Makefile に存在するか | memory 全ファイル | (a) — 監査 1 |
  | `pr-reference` | `#N` / `<owner>/<repo>#N` が GitHub 上に実在するか | memory 全ファイル | (a) |
  | `staleness` | 参照先の最終変更日 > memory の日付か | memory 全ファイル | (a) — 監査 2 |
  | `rule-duplication` | CLAUDE.md / AGENTS.md が既に同じことを書いていないか | topic file のみ | (b) — 監査 3・4 |
  | `memory-index-size` | `MEMORY.md` が 200 行 / 25KB を超えていないか | `MEMORY.md` | 読み込み欠落 |

- **AC-012**: 閾値はすべて名前付き定数にする。少なくとも `MEMORY_INDEX_MAX_LINES` (200)、
  `MEMORY_INDEX_MAX_BYTES` (25000)、`MEMORY_INDEX_WARN_RATIO`、`DUPLICATE_SHINGLE_SIZE`、
  `DUPLICATE_CONTAINMENT_THRESHOLD`、`DUPLICATE_MIN_SHINGLES`、`PR_NUMBER_MAX` を定数として持つ。
  リテラルを検査ロジックへ直書きしない。

### 「検査できなかった」と「問題なし」の分離

- **AC-020**: 各チェックは `ok` / `finding` / `inconclusive` の 3 状態を持つ。`inconclusive` は
  **チェックそのものが実行できなかった**ことを表し、`ok` には決して丸めない。
- **AC-021**: 各チェックは `checked`（実際に判定した候補数）と `unchecked`（設計上判定対象外にした候補と
  その理由）を**必ず出力する**。「0 件中 finding 0」と「12 件中 finding 0」がレポート上で区別できる
  ことを、本フェーズの中核的性質とする。`unchecked` の候補は理由付きで列挙し、黙って落とさない。
- **AC-022**: 終了コードは `0`=finding なし・inconclusive なし、`1`=finding あり、`2`=inconclusive あり、
  `3`=両方、`64`=usage error、`70`=internal error。ビットの独立性を保ち、finding の有無と検査可否を
  1 つの値へ潰さない。
- **AC-023**: `2>/dev/null` と `|| true` の併用でパース失敗が「0 件」に写像される事故を構造的に防ぐため、
  スクリプト内部で例外を握り潰さない。想定外の例外は当該チェックを `inconclusive` にし、理由を出す。

### 検索が無言でスキップする 2 経路への対処（house rule）

- **AC-030**: 重複検出・参照抽出は ripgrep 再帰（Grep / Glob ツール、`rg` 再帰、`grep -rI`）を使わない。
  memory ディレクトリは `os.scandir` で列挙し、ルールファイルは明示パスで直読みする。gitignore 対象で
  無言スキップされる経路を作らない。
- **AC-031**: 入力ファイル（memory / ルールファイル）に**生 NUL バイト**が含まれる場合、そのファイルに
  関わるチェックを `inconclusive`（理由 `nul-bytes`）にする。無言で 0 件にしない。
- **AC-032**: リポジトリ側の検索・照会（`staleness` の最終変更日）は `git log` を用いる。追跡外の
  パスは `unchecked`（理由 `untracked`）として明示し、`ok` にしない。

### 外部依存の扱い

- **AC-040**: `pr-reference` は `--github=auto|on|off` を持つ。**照会対象の参照が 1 件以上あるとき**、
  `gh` が無い / 認証が無い / `off` 指定のいずれでも、チェック状態は `inconclusive`（理由付き）になり
  `ok` にならない。**参照が 0 件のときは `ok`（`checked=0`）** —— 見送ったものが無いので
  「実行できなかった」を立てる対象が存在しない。ここで理由を立てると、検査対象がゼロなだけの
  実行まで inconclusive になり、実行不能の警告が意味を失う（同じ判断を `make-target` の
  Makefile 不在にも適用する）。
- **AC-041**: memory 由来の文字列をシェルへ渡さない。外部コマンドは引数リストで起動し（`shell=True` 禁止）、
  PR 番号は `1..PR_NUMBER_MAX` の整数のみ、パス候補は NUL・改行・シェルメタ文字を含まないものだけを
  外部コマンドへ渡す。

### 報告

- **AC-050**: `--format text`（既定）は週次レポートへ貼り付けられる日本語 Markdown 断片を出力する。
  チェック別の状態表（`状態` / `検査` / `finding` / `未検査`）、finding 一覧、未検査一覧、
  実行不能一覧、「報告のみ・変更は user 承認後」の但し書きを含む。
- **AC-051**: `--format json` は同じ内容を機械可読な JSON で出力する（bats からの assert 用）。
- **AC-052**: **memory 本文を引用しない**。finding 行は「memory ファイル名 : 行番号 — 検出した参照
  （パス / make target / PR 番号）と判定理由」まで。重複検出は「一致したルールファイルとセクション見出し、
  含有率スコア」まで。memory にはクライアント情報が入りうるため、転記面を最小化する。

### fixture と再現

- **AC-060**: `tests/fixtures/knowledge-distill/memory-revalidate/` に fixture を置き、**監査で見つかった
  4 件をすべて再現**する。fixture は実 auto-memory のコピーではなく、同じ腐敗の形だけを写した合成物とする。
  - 乖離 1 → `make-target` finding（`make dump-brewfile` が fixture の Makefile に存在しない）
  - 乖離 2 → `staleness` finding（参照先 CI ワークフローの最終コミット日 > memory の日付）
  - 重複 3 → `rule-duplication` finding（fixture の AGENTS.md「レビュー指摘の検証」節に対する含有率超過）
  - 重複 4 → `rule-duplication` finding（同「commit / PR / 公開物への記載禁止」節）
- **AC-061**: fixture の memory ファイルは `modified` frontmatter を持ち、`staleness` の再現が mtime に
  依存しないようにする。mtime フォールバックは別テストで独立に検証する。
- **AC-062**: 実行後に fixture の memory ディレクトリが**バイト単位で不変**であることをテストで固定する
  （AC-002 の機械的担保）。

### テスト

- **AC-070**: `tests/knowledge_distill_memory_revalidate.bats` を追加し、`make test-bats` で走る。
  4 件の再現、3 状態の分離（AC-020〜AC-022）、NUL バイト（AC-031）、`--github=off` の `inconclusive`
  （AC-040）、スタブ `gh` での 404 finding、200 行 / 25KB 超過、read-only 性（AC-062）を assert する。
- **AC-071**: スクリプトの構文チェック（`python3 -m py_compile`）を bats から実行する。python3 が
  無い環境では **skip せず fail** する（「ツールが無いと自分を飛ばすガード」を作らない）。
- **AC-072**: CI の bats ジョブに `python3` を明示的にインストール宣言する（イメージ同梱への暗黙依存を
  作らない、という本リポジトリの既存規律に合わせる）。

### 週次 headless radar への配線

- **AC-080**: `home/dot_claude/executable_knowledge-distill-radar.sh` の `ALLOWED_TOOLS` に
  `Bash(python3 ~/.agents/skills/knowledge-distill/scripts/memory-revalidate.py:*)` を追加する。
  許可リストに載せない限り、SKILL.md にフェーズを書いても production の headless 実行では**無言で
  拒否され、フェーズが存在しないのと同じになる**（#491 と同型の故障）。
- **AC-081**: `tests/knowledge_distill_radar.bats` に、この許可エントリの存在を assert するテストを
  追加する（将来の削除を機械で止める）。
- **AC-082**: 許可リストは read-mostly 設計を維持する。追加するのは当該スクリプトのフルパス 1 件のみで、
  `python3` のワイルドカードには広げない。

### docs

- **AC-090**: `docs/agents/claude-code.md` と `docs/agents/claude-code.ja.md` に auto-memory 再検証の節を
  追加し、目次にも載せる。6 チェック、3 状態、終了コード、報告のみである旨、公式仕様の URL を記載する。
- **AC-091**: `docs/architecture/notifications.md` / `.ja.md` の週次 knowledge-distill 配信節にある
  許可リスト記述を、AC-080 の追加に合わせて更新する。
- **AC-092**: `tests/docs_facts.bats` の既存検証（EN/JA ミラー、相対リンク解決）を通す。

### 総合

- **AC-100**: `make lint` と `make test` が緑。

## Considered Alternatives / Rejection Rationale

| # | 代替案 | 却下理由 |
|---|--------|---------|
| 1 | 検査を bash + awk で書く | 重複検出の中核は日本語を含む文字 n-gram 類似度。macOS の BSD awk と CI Ubuntu の gawk でマルチバイト `substr` の挙動が割れ、**同じ入力で結果が変わる**。検出器そのものが環境依存で沈黙する経路を作ることになる。Python 3 標準ライブラリなら Unicode 正しく、`prune-session-transcript` / `ios-device-web` に既存の前例がある |
| 2 | 検査を Phase 2 以降（蒸留フェーズ内）に置く | instinct 蓄積が `--min-instincts` 未満の週は Phase 1 で縮退終了するため走らない。今回の 4 件は instinct 蓄積量と無関係に腐っていたので、**縮退週こそ検出したい**。よって Phase 0.5 に置き、縮退レポートにも載せる |
| 3 | SKILL.md に散文で手順を書くだけ（スクリプトなし） | 受け入れ条件「fixture 上で 4 件を再現して報告できる」を機械で固定できない。散文の手順は実行のたびに揺れ、bats から検証できない |
| 4 | 検出した腐敗をその場で自動修正する | グローバル memory ポリシー（記録・変更は user 承認後）に反する。かつ (a) の是正には「今の正しい記述」の判断が要り、それは意味的判定＝スコープ外 |
| 5 | 重複検出に `difflib.SequenceMatcher` の ratio を使う | ratio は長さ差を罰するため「短い memory が長いルール節に吸収されている」形（今回の 3・4 がまさにこれ）で低く出る。含有率（memory 側 n-gram のうちルール側に現れる割合）の方が (b) の定義に直接対応する |
| 6 | `unchecked` 候補も終了コードを `2` に倒す | 絶対パス・`~` 始まり・ブレース展開などの「設計上の対象外」が常に存在するため、終了コードが常時 `2` になり、**実行不能の警告が意味を失う**（alert fatigue）。`unchecked` はレポートに必ず列挙して沈黙を防ぎ、終了コードは「チェック自体が走れたか」に限定する |
| 7 | 許可リストを `Bash(python3:*)` に広げる | read-mostly 設計（#368 / #388 レビュー）を壊す。`python3` 全般を許すと任意スクリプト実行になる。フルパス 1 件に限定する |
| 8 | 週次 radar には配線せず手動実行のみにする | 許可リストに無いコマンドは headless 実行で無言拒否される。SKILL.md にフェーズを書いても production では走らず、「フェーズが存在しない」のと区別が付かない（#491 と同型）。**user 承認済み: 週次 radar でも走らせる** |
| 9 | finding に memory 本文を引用して人が判断しやすくする | memory にはクライアント情報が入りうる（既存レポートの `<!-- INTERNAL -->` 転記警告と同じ懸念）。レポートは gitignore 領域とはいえ転記面は最小化する。**user 承認済み: 引用しない** |
| 10 | memory ディレクトリを `git ls-files` 系で走査する | memory ディレクトリはリポジトリ外の runtime 状態であり git 管理下にない。追跡ファイル限定の走査では 0 件になる。ディレクトリ列挙は `os.scandir`、リポジトリ側の日付照会だけ `git log` という役割分担にする |
| 11 | スクリプトを薄いエントリポイント + ローカルパッケージへ分割する | レビューで [MUST] として提起され、cross-model の反証 2 本がいずれも一次ソース根拠つきで `REFUTED` を返した。(a) house rule の当該条項は `home/.chezmoitemplates/coding-standards.md` の「800 行で**分割検討**」であって分割義務ではない。(b) リポジトリには 800 行超の追跡ファイルが既に複数ある（`tests/frontier_harness.test.mjs` 4396 行、`tests/files.bats` 3097 行、`home/dot_claude/executable_statusline.sh` 949 行）。(c) 決定的なのは、**単一ファイルがそのまま静的検査の境界になっている**こと —— bats は `$SCRIPT` 1 本に対して `py_compile`・閾値定数の存在検査・「起動する外部コマンドは git と gh だけ」の AST 検査を掛けており、ロジックを隣接モジュールへ移すと guard を同時に作り直さない限り検査対象外のコードが生まれる。**「許可リストのエントリを 1 件に保つため」という当初の理由は誤り**（Python はスクリプトのディレクトリを `sys.path` へ自動追加するので分割しても許可パスは変わらない）で、docstring の記述を上記 (c) に訂正した。分割自体は将来の非ブロッキングな改善として残す |
| 12 | finding を `agent-improvement` 型のキュー（状態遷移・失効・終端状態）へ乗せる | 対象が auto-memory という小さな集合で、フェーズは report-only（AC-002）。状態を持つとレポートと queue の二重管理になり、`agent-improvement` が解いている「候補が多く通知疲れが起きる」問題の規模に達していない。毎週フルスキャンして同じ finding を再掲する設計を受け入れる。運用して同一 finding の再掲が実際に無視されるようなら、前回レポートとの差分抑制という軽量策を後続で検討する |

## Out of Scope

- 意味的判定（解除条件の充足、学びがまだ有効か）。人の判断に残す。
- 実際の auto-memory の内容修正。本 PR は fixture 上でのみ検証し、実ディレクトリは読み取りのみ。
- `MEMORY.md` の自動圧縮・自動整理。
- ECC hook 側の変更（#473）。
- topic file 同士の重複検出（memory 内部の重複）。今回の監査は memory と恒久ルールの重複だったため、
  まずそこに絞る。

## Open Questions

- `rule-duplication` の含有率閾値は fixture 上で経験的に決める。実 memory に対する偽陽性率は運用して
  みないと分からないため、**初回は偽陽性寄り**（拾いすぎて人が捨てる）に倒し、数週の運用後に再調整する。
- `modified` frontmatter を持たない既存 memory（本リポジトリの 3 ファイルはすべてこれ）では日付の出所が
  mtime になる。mtime は chezmoi apply / バックアップ復元で書き換わりうるため、`staleness` の finding は
  日付の出所を必ず併記し、mtime 由来の finding は弱い証拠として扱う。
- 既定の memory ディレクトリ導出（`git rev-parse --git-common-dir` からリポジトリルート → スラグ化）は
  公式仕様の「git リポジトリから導出、worktree 間で共有」に沿った推測。`--memory-dir` で常に上書きでき、
  導出先が存在しなければ `inconclusive` になるため、外しても静かに誤らない。

## Assumptions（自律解決した前提）

1. **「25KB」は 25000 バイトと解釈する。** 公式表記は SI / 2 進のいずれか曖昧。小さい方を採れば
   過小警告にならない（fail-safe）。根拠: 一次ソースで文言は確認済み、解釈は推測。
2. **memory の日付は `modified` frontmatter を第一とし、無ければ mtime にフォールバックする。**
   根拠: `modified` フィールドの存在と意味は一次ソースで確認済み。フォールバックの妥当性は推測で、
   Open Questions に残した。fixture は `modified` を持たせて再現が mtime に依存しないようにする。
3. **既定の memory ディレクトリはリポジトリルートのスラグから導出する。** `--memory-dir` で上書き可能。
4. **`make <target>` の抽出はコードスパン内に限定する。** 地の文の `make sure` 等を target と誤認しない。
   範囲外の言及は `unchecked` として明示列挙する。
5. **CI の bats ジョブに `python3` を明示宣言する。** 「declare it, never inherit it from the image」という
   既存 CI の規律に合わせる。テストは python3 不在時に skip せず fail させる。
