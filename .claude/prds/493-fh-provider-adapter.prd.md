---
slug: 493-fh-provider-adapter
feature: frontier-harness の provider adapter と capability registry 接続
created_at: 2026-08-29T03:46:07+09:00
grill_session: 01UhjRsjRsVDGVa7DLh4nkSz
status: finalized
---

# frontier-harness に provider adapter を実装し capability registry と接続する

本書は issue #493 の intent gate（`pr-workflow` large tier）の成果物である。設計入力は
`.claude/prds/526-noninteractive-mode-research.prd.md` §7.2 が挙げた adapter の最小要件 4 件のうち、
**要件 1（provider ごとの起動形・再開形・成功判定を別々に持つ）と要件 2（サンドボックス指定が
起動時と再開時で形が違う）** である。要件 3 は #534、要件 4 は #535 が扱う。

## Background

`fh run` は route を記録するだけで、どの provider も起動しない。`providers.mjs` は 12 行で
「provider 名 → 実行ファイル名」の対応だけを持ち、`rollout.mjs` の
`runWithRolloutGuard(config, context, executor)` に渡す `executor` は未実装のままである。

#526 の実測が示したのは、3 provider の非対話能力が**非対称**であり、実行ファイル名の対応では
表現できないという事実である。

| provider | 起動方式 | 再開 | サンドボックス | 成功判定 |
| --- | --- | --- | --- | --- |
| Claude | `-p` ＋ `--output-format stream-json` ＋ 設定の事前遮断 | `--resume <session-id>` | 設定 JSON（`--settings`）。**CLI フラグは存在しない**［実測］ | envelope の `result` / `permission_denials[]` |
| Codex | `codex exec -s <mode> --json` | `codex exec resume <id>`。**`-s` も `-C` も受け付けない**［実測］ | 起動は `-s`、再開は `-c sandbox_mode="..."` | 終了コードと JSONL イベント |
| Antigravity | `-p --output-format json` | `--conversation <id>` | `--sandbox` は **ファイル書き込みを止めない**［実測］ | **exit 0 / `status: SUCCESS` でも何もしていない場合がある**［実測］ |

とくに Codex の「起動は `-s`、再開は `-c sandbox_mode`」という非対称は、知らずに書くと
**再開時にサンドボックスが設定既定へ戻る（＝弱まる）静かな退行**を作る。Antigravity の
ソフト拒否は、呼び出し側が exit code と `status` だけを見ると「成功した」と読む。
どちらも本リポジトリが最も嫌う沈黙する故障にあたる。

## User Story

`frontier-harness` の運用者として、provider ごとの起動形・再開形・成功判定の差を
**router ではなく adapter が引き受けている**状態にしたい。そうすれば、provider を足すときも
起動方式が変わったときも、router と capability registry を触らずに済み、
「再開でサンドボックスが弱まる」「何もしていない実行を成功として記録する」を
コードレビューの注意力ではなくテストで防げる。

## Acceptance Criteria

| ID | 条件 | 対応する issue の項目 |
| --- | --- | --- |
| AC-001 | 各 provider の adapter が、起動形・再開形・結果解釈を**別々の実装として**持ち、正規化された結果へ変換する | やること 1 / §7.2 要件 1 |
| AC-002 | adapter は `node:child_process` を import せず、invocation の組み立てと結果の解釈だけを行う純関数として実装される。実プロセス起動の runner は呼び出し側が注入する | 完了条件 1 |
| AC-003 | sandbox policy は 1 つの値オブジェクトから起動形と再開形の**両方**へ描画され、`readEffectiveSandbox()` で argv から読み戻せる。全 adapter を回す conformance テストが「起動時と再開時の実効サンドボックスが一致する」ことを不変条件として検査する | §7.2 要件 2 |
| AC-004 | Codex adapter の再開形に `-s` / `--sandbox` / `-C` / `--cd` が現れず、`-c sandbox_mode="<mode>"` でサンドボックスが維持されることがテストで固定される | §7.2 要件 2（§2.3 実測） |
| AC-005 | Antigravity adapter は exit code と `status` だけで `succeeded` を返さない。判定不能を `indeterminate` として返し、adapter run の状態へは fail-closed に写像する | §7.2 要件 1（§3.2 実測） |
| AC-006 | Antigravity adapter は書き込みを伴う invocation の組み立てを拒否する（read-only 用途に限定） | scope: 書き込み経路に出さない |
| AC-007 | adapter は実行前に capability registry の **exact model ID** が discovery 結果に含まれることと、**effort** が安全に描画できるトークンであることを検査する | やること 2 |
| AC-008 | 実 credential・クォータを使わない fake adapter が同じ契約で提供され、既定 registry には登録されない | やること 3 |
| AC-009 | 可用性・構造化出力の解釈・利用不可時のフォールバックが、provider プロセスを起動せずにテストされる | 完了条件 1 |
| AC-010 | `router.mjs` に vendor 固有のコマンド名・provider 名リテラルが現れないことがテストで固定される | 完了条件 2 |
| AC-011 | `config.json`（capability registry）のスキーマを変更しない。承認チャネル（#534）と read-only 制限の registry 表現（#536）が後から足せる形を保つ | scope |
| AC-012 | 起動形・再開形の詳細（argv / sandbox 設定 / conversation ID 等）を `adapter_runs` へ永続化しない | 既存 schema の意図（#492） |

## 設計

### モジュール構成

新規ファイルは `home/dot_local/lib/frontier-harness/` 直下に**フラットに**置く。
`make lint-node` の glob が `home/dot_local/lib/*/*.mjs` の **1 階層のみ**を対象とするため、
サブディレクトリに置くと構文検査を黙って外れる。

| ファイル | 責務 |
| --- | --- |
| `sandbox.mjs` | sandbox policy の値オブジェクトと正規化 |
| `adapter-contract.mjs` | adapter 契約の検証（conformance）、invocation の構築ヘルパー、outcome → adapter run status の写像 |
| `adapter-claude.mjs` | Claude の起動形・再開形・結果解釈 |
| `adapter-codex.mjs` | Codex の起動形・再開形・結果解釈 |
| `adapter-antigravity.mjs` | Antigravity の起動形・再開形・結果解釈（read-only 限定） |
| `adapter-fake.mjs` | 実 credential を使わない fake adapter |
| `adapters.mjs` | registry（provider → adapter）、実行前検査、`createAdapterExecutor()` |

`providers.mjs`（コマンド名の SSOT）は**再利用**し、adapter 側にコマンド名を複製しない。
`cli.mjs`（#533 が編集中）と `paths.mjs`（#541 が編集中）は変更しない。

### 挿入点

`rollout.mjs` の `runWithRolloutGuard(config, context, executor)` の `executor` が挿入点である。
`createAdapterExecutor()` がその形の関数を返し、`runCli(argv, { executor })` から入る。
`shadow` の間は `runWithRolloutGuard` が executor を呼ばないため、配線しても実行は起きない。

### 実行前検査の分担

- **router**: provider 非依存の可用性のみ（executable の有無、account scope、discovery 済み model 一覧）。
- **adapter**: vendor 固有の検査（effort の描画可否、書き込み可否、サンドボックスの実効性）に加え、
  **exact model ID を実行直前に再検査**する。route 決定と実行の間に readiness cache は TTL 失効しうるため、
  同じ規則の再検査は重複ではなく多層防御である。

## Considered Alternatives / Rejection Rationale

| # | 検討した代替案 | 却下理由 |
| --- | --- | --- |
| 1 | adapter を `adapters/` サブディレクトリに置く | `make lint-node` の glob が 1 階層しか見ないため、新規モジュールが構文検査を黙って外れる（実測）。Makefile を触ると `$code-change-verification` の対象が広がり、#511（brew launcher）と競合面が増える |
| 2 | `providers.mjs` を拡張して adapter もそこに持たせる | コマンド名の SSOT と起動方式が同一ファイルに同居し、#526 の結論で起動方式が変わるたびに SSOT が揺れる。`cli.mjs` / `doctor.mjs` が import しているため変更の影響半径も広い |
| 3 | 実プロセスを起動する既定 runner を本 PR に含める | 完了条件が「provider プロセスを起動せずにテストされる」であり、既定 runner は rollout 昇格（#502）の作業。adapter 層から `node:child_process` を排除しておくほうが「起動しない」を構造で担保できる |
| 4 | sandbox の起動時／再開時の非対称をコメントで注意喚起する | #526 が名指しした退行（初回だけ pin して再開で弱まる）は、レビューの注意力では防げないから issue になった。argv から実効値を読み戻す関数を契約に含め、全 adapter を回す conformance テストで不変条件にする |
| 5 | Antigravity adapter の結果解釈を exit code ベースで暫定実装し、#536 で直す | 「exit 0 = 成功」は #526 が実測で誤りと確認した振る舞いであり、TODO 付きでも一度入れると沈黙する故障を作る。判定しないこと（`indeterminate`）は #536 の実装（`response` 非空 ＋ stderr 走査）を先取りせずに fail-closed を保てる |
| 6 | Antigravity adapter をそもそも登録しない | 起動形・再開形は #526 で実測済みで、要件 1 の「provider ごとに別々に持つ」を 3 provider で満たすことが本 issue の範囲。登録せずに残すと #536 が adapter 実装ごと引き受けることになり分担が崩れる |
| 7 | capability registry（`config.json`）に承認チャネル軸と read-only 制限を今足す | #534 と #536 の範囲。今足すと両 issue が既存フィールドの再設計から始めることになる。adapter descriptor に記述的フィールドとして持つだけなら、#534 がそれを参照して registry 軸を足せる |
| 8 | provider ごとの effort 受理値を網羅的に宣言する | #526 が実測したのは pin の**方式**（`--effort` / `-c model_reasoning_effort`）であって受理値の集合ではない。部分的な観測から集合を捏造すると、正当な値で fail-closed になるか不正な値で fail-open になる |
| 9 | テストを既存の `tests/frontier_harness.test.mjs` に追記する | 既存ファイルは 2763 行で house 標準の分割閾値（800 行）を大きく超える。同じ wave の #533 / #541 も同ファイルを編集するため衝突面にもなる |

### assumption（文脈収集とコードベースから自律解決した前提）

1. `fh run` の既存経路（`runWithRolloutGuard` の `executor`）で足りるため `cli.mjs` は変更しない。
2. `paths.mjs` は symlink ガードと atomic write の SSOT として**呼ぶだけ**にする（修正は #541）。
3. 承認チャネル本体の実装は #533、承認できない provider への route 封鎖は #534。
4. Antigravity の成功判定の修正と read-only route 封鎖は #536。
5. rollout の pilot / default 昇格と実プロセス起動は #502。

## Out of Scope

- 承認チャネル本体（stdio MCP server）の実装 → #533
- capability registry の承認チャネル軸と route 封鎖 → #534
- サンドボックス実効性の回帰テスト → #535
- Antigravity の成功判定の修正と read-only route 封鎖 → #536
- rollout の pilot / default 昇格、`--legacy` rollback → #502
- `paths.mjs` の中間ディレクトリ symlink ガード → #541

## Open Questions

1. provider ごとの effort 受理値の集合は未実測である（#526 は pin の方式のみ実測した）。
   実測して adapter に宣言するか、shape 検査のままにするかは別途判断する。
2. Codex の 1 プロセス多ターン（`codex queue --thread` / `exec-server`）は #526 でも未検証である。
   常駐プロセス方式の adapter を作るなら、その検証が前提になる。
3. Claude の `--permission-prompt-tool` を起動形へ含めるかは #533 の受け口の形が決まってから確定する。
   本 issue の adapter は caller が渡したときだけ描画し、配線の要否を判断しない。
