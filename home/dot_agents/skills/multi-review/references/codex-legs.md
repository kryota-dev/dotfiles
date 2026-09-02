# multi-review: Codex leg の実行・並列・観測・resume

## Codex leg 実行・並列・観測・resume

Codex leg（generalist + specialists）の起動形・並列制御・ライブ観測・再レビュー resume の SSOT。**Codex コマンドの構文的 SSOT は `codex/SKILL.md`**（`--json` / `-o` / `review --base` / heredoc / `resume` / session-id 捕捉節）。ここではそれを multi-review の roster に組み込む運用を定義する。

### 実行形（generalist / specialist 共通）

```bash
codex exec --profile shared --sandbox <SANDBOX_MODE> --cd "$WT" --color never --json \
  -c model_reasoning_effort=<high|xhigh> \
  -o "$RESULT_leg" <REVIEW_OR_HEREDOC> \
  > "$STREAM_leg" 2>&1   # run_in_background
```

#### `<SANDBOX_MODE>` は「外側に sandbox があるか」で決まる

| 実行環境 | 指定 | 理由 |
|---|---|---|
| 通常のセッション（外側に sandbox 無し） | **`read-only`** | codex 自身の sandbox が唯一の封じ込め。外せない |
| `fh session` の子の中（外側に sandbox 有り） | **`danger-full-access`** | codex に自分の sandbox を張らせない。封じ込めは外側が担う |

**`fh session` の中で `read-only` を指定すると Codex leg はシェルを一切実行できない。** macOS の Seatbelt は
入れ子にできないため、codex の `sandbox_apply` が `Operation not permitted` で落ちる。その状態でも codex は
起動して応答するので、**差分を渡さない限り「レビュー不能」としか返らない**（実測）。

**フラグ名に反して封じ込めは弱まらない。** 外側の sandbox が残ることを実測で確認済み:

| 検査 | `fh session` の子の中で `-s danger-full-access` |
|---|---|
| `git log` | 成功（シェルが使える） |
| 許可外ホストへの `curl` | `CONNECT tunnel failed, 403`（外側の allowlist が有効） |
| ワークツリー外への `touch` | `Operation not permitted`（外側の書き込み隔離が有効） |

codex 自身の flag 説明も同じ前提に立つ —— `--dangerously-bypass-approvals-and-sandbox` は
*"Intended solely for running in environments that are **externally sandboxed**"*。

**外側に sandbox が無い環境でこれを指定しない。** そこでは封じ込めがゼロになる。判定は
「今このプロセスは `fh session` の子か」であって、「codex を速く動かしたいか」ではない。

- **generalist**: `review --base origin/<base>`（primary）。base 取得不可なら `${DIFF}` 埋め込み heredoc（fallback）。effort=xhigh（standard/large）/ high（trivial/small）。
- **specialist**: heredoc = 「agent `.md` 本文（frontmatter 除去）+ 対象説明 + 差分取得コマンド（`--repo` 明示）+ 作業ディレクトリ絶対パス + 棄却台帳（+ spec-context）」。effort=high。
- 親は **`$RESULT_leg` のみ Read**。`$STREAM_leg`（JSONL）は観測用で親コンテキストに載せない。

### session-id 捕捉と状態ファイル

- 各 leg 起動後、`$STREAM_leg` 先頭の `thread.started` イベントから `thread_id` を捕捉（codex/SKILL.md の grep 例）。
- `<scratch>/codex-review/<owner>__<repo>__<PR>/sessions.json`（**非コミット**）に `{leg → thread_id}` を記録する（`multi-review` が所有。round 2+ の resume がこれを読む）。**区切りは `__`（owner/repo にも PR にも出現しない）**にして、`foo/bar-baz#1` と `foo-bar/baz#1` のようなハイフン曖昧による cross-repo 衝突を避ける。

#### TTL / クリーンアップ契機（OQ-005: 解決済み）

`sessions.json` と scratch の `codex-review/` 配下は次の方針で寿命管理する（PR #406 の未解決事項 OQ-005 の確定）:

- **所有と idempotency**: `multi-review` が round 1 開始時に自 `(owner,repo,PR)` の `codex-review/<owner>__<repo>__<PR>/` を idempotent に作り直す（前 run の stale な `sessions.json` を置換）。これにより同一 PR の再レビューで古い `thread_id` が混ざらない。
- **TTL 掃除（mtime ベース）**: round 1 開始時に、`codex-review/` 直下のサブディレクトリのうち **mtime が 7 日以上前**のものを best-effort で削除する（`find "<scratch>/codex-review" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +` 相当）。scratch はセッション隔離だが、standalone 多用や cross-repo バッチで dir が溜まるのを防ぐ。掃除の失敗（権限・不在）は無視する（レビュー本体を止めない）。
- **契機は round 1 のみ**: 掃除は round 1 開始時の 1 回に限定し、round 2+ の resume 中には行わない（resume 対象の状態ファイルを消さないため）。

### 並列上限とバッチ（CODEX_MAX_CONCURRENCY）

- `CODEX_MAX_CONCURRENCY = 3`（named constant。read-only の codex exec 3 本同時に競合/レートエラーが出ないことを実機確認済みの床）。
- マッチした Codex leg 総数が上限を超える場合、**先発（generalist を先頭に）→ 後続バッチ**で順次消化する（全 specialist を落とさず消化）。**観測ビューの pane を作る前に、待機中も含む全 leg の `$STREAM_leg` を空ファイルで `touch` しておく**（存在しないファイルへの `tail -f` は即終了し、後から STREAM が作られても表示されないため）。待機中の leg は STREAM が空のまま = `queued` と分かる。

### ライブ観測（`$TMUX` 出し分け）

コア（`--json` の STREAM・`-o` の RESULT・session-id 捕捉）は **tmux 非依存**。整形ライブビューのみ tmux best-effort:

| 判定 | 挙動 | ユーザーへの提示 |
|------|------|-----------------|
| `$TMUX` セット（親が tmux 内） | 同セッションに専用ウィンドウ `codex-review-<PR>` を作成し、各 leg ペインで `tail -f "$STREAM_leg" \| codex-stream-fmt <leg>` を回す | 「レビュー窓を作成。`Ctrl-b w` で選択」 |
| `$TMUX` 未セット + tmux 在 | detached セッション `codex-review-<PR>` を作成（`tmux new-session -d`）し同様に tail | **「別ターミナルで `tmux attach -t codex-review-<PR>`」**（現端末は Claude TUI と衝突し attach 不可の旨も添える） |
| tmux 非在 | ライブ整形はスキップ（コアは無傷） | `tail -f "$STREAM_leg"` の各パスを提示 |

- 整形は `codex-stream-fmt`（`~/.agents/skills/multi-review/codex-stream-fmt`。JSONL→簡潔行、jq 不在時は生素通し）。セッション名は `#` を避け **`codex-review-<owner>__<repo>__<PR>`**（例 `codex-review-kryota-dev__dotfiles__412`）。**owner/repo を必ず含める**（PR 番号だけだと別 repo の同番号 PR が cross-repo バッチで衝突し、別リポジトリのレビュー実況が同じペインに混線するため）。上表の `codex-review-<PR>` はこの正式名の略記。
- **セッションの lifecycle は multi-review（作成者）が所有し自己完結する（standalone でも溜めない）**:
  - **create（round 開始）**: `tmux kill-session -t <name> 2>/dev/null` してから `tmux new-session -d`（idempotent。同名の orphan / 前回分を置換し、accumulation を (owner,repo,PR) ごと最大 1 に bound）。
  - **teardown（round 終了 = Phase 5 投稿後）**: multi-review が自分のセッションを `tmux kill-session -t <name> 2>/dev/null` で破棄する。**ただし client が attach 中（`tmux list-clients -t <name>` が非空）なら破棄せず残置**し、「見終わったら手動 kill、または次 run が置換する」と注記する（観測中の画面を消さない）。
  - **caller（pr-workflow）側の teardown は不要**: round ごとに multi-review が自己完結するため、pr-workflow の GATE 3 等での破棄には依存しない（standalone 多用でも PR ごとに溜まらない）。
- **観測（tmux）と resume（`sessions.json`）は独立**: tmux セッションはライブ観測専用で、round 2+ の resume は `sessions.json` の `thread_id` を使う（tmux セッションに依存しない）。よって teardown で resume は壊れず、round 2 は fresh にセッションを作り直して新 STREAM を tail する。STREAM の JSONL はディスクに残置（post-hoc 検分用。掃除は上記「TTL / クリーンアップ契機（OQ-005: 解決済み）」の scratch TTL に委ねる）。

### round 判定と resume 再レビュー

- **round 1（`sessions.json` に当該 PR の記録なし）**: 通常起動 + session-id 記録（上記）。
- **round 2+（記録あり）**: **前ラウンドで open 指摘を持つ Codex leg を resume** する:

  ```bash
  codex exec resume "$thread_id" --json -o "$RESULT2_leg" - <<'PROMPT' > "$STREAM2_leg" 2>&1
  前ラウンドの自分の指摘の対応状況を再確認し、未解決のみを再提起してください。
  加えて、修正で新たに混入した問題がないか差分を走査してください。
  PROMPT
  ```

  - resume は文脈を継承するため **棄却台帳の注入は不要**（session 継続が再提起を構造的に防ぐ）。
  - **clean だった leg は原則スキップ**。ただし修正 diff がその leg のドメイン（拡張子/特性）に触れたら **fresh で追加 spawn**（修正が新たに持ち込む問題を拾う）。
  - **fresh フォールバック**: `thread_id` 欠落・resume 失敗・別セッション/別アカウントで解決不能なら、その leg は fresh 起動に切り替える（AC 準拠）。
- **Claude leg は resume しない**（round ごと fresh spawn + 棄却台帳。Codex 専用の非対称対応）。
