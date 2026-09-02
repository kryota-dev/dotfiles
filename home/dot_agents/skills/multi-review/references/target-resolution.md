# multi-review: 引数とレビュー対象の解決

`multi-review` の registry（`SKILL.md`）が受け取る引数を、**owner/repo と PR 番号の 2 つ組**へ
決定的に解決する手順。**Phase 1 手順 1 の前にこのファイルを Read する。**

## 引数の解釈

**手順 0（フラグ抽出を最優先）**: `$ARGUMENTS` からまず `--arch` を取り除き `ARCH=true`（未指定なら `ARCH=false`）にする。次に `--spec-context <dir>` があれば取り除き `SPEC_CONTEXT=<dir>`（未指定なら空）にする（spec ドキュメントのディレクトリパス。「spec-context 入力」節参照）。さらに `--tier=<t>` があれば取り除き、**`<t>` が `trivial|small|standard|large` のいずれかのときのみ** `TIER=<t>` にする。**それ以外の未定義値（例 `--tier=foo`）は空扱い**とし `TIER` に載せず、未指定と同様に「tier → roster 予算」節の diff 自動推定へ回す（**未知値で roster gating を無効化しない = fail-open 禁止**。fail-safe 切り上げ）。残った 0/1 個のトークンを **target** として下記の優先順で判定する。フラグを先に剥がしておくことで `owner/repo#N --arch` のような複合引数のパース順序事故を避ける。

target を以下の優先順で判定し、**owner/repo と PR 番号の 2 つ組**を確定する。以降の全 `gh` 呼び出しには `--repo <owner/repo>` を明示すること（cross-repo バッチで cwd の repo に暗黙解決される事故を防ぐ）。**cross-repo バッチ（review-fleet 等）から委譲されるときは PR 番号のみを渡さない**（case 3 の cwd 暗黙解決を踏むため）:

1. **PR URL**（**path 完全一致 + トレイル部分は任意**）:
   ```
   ^https?://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})/pull/(\d+)(?:[/?#].*)?$
   ```
   グループ 1: `owner`、グループ 2: `repo`、グループ 3: PR 番号を抽出する。
   **拒否例**（target が **URL 形態を持ち**（`https?://github.com/` を含む）URL regex に非マッチなら**即座にエラー**（case 2/3 へ fallthrough しない））:
   - `leading dash owner`: オーナー名が `-` で始まる（regex が `[A-Za-z0-9]` 先頭文字で弾く）
   - `>39 char owner`: オーナー名が 39 文字超（regex が弾く）
   - `>100 char repo`: リポジトリ名が 100 文字超（regex が弾く）
   - `..` / `.` alone / leading `.` or `-` in repo、trailing `-` or `--` in owner: **post-regex `case` チェックで弾く**（下記参照）
2. **`owner/repo#PR番号`**（完全一致）:
   ```
   ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}#\d+$
   ```
   **拒否例**（target が **`/` を含む** owner/repo 形態で `#` を含みつつ regex に非マッチなら**即座にエラー**（case 3 へ fallthrough しない））:
   - `leading dash owner`: `-myorg/repo#1`（regex が `[A-Za-z0-9]` 先頭文字で弾く）
   - `>39 char owner`: 40 文字以上のオーナー名（regex が弾く）
   - `>100 char repo`: 101 文字以上のリポジトリ名（regex が弾く）
   - `..` / `.` alone / leading `.` or `-` in repo（`org/my..repo#1`、`org/.#1`）、trailing `-` or `--` in owner: **post-regex `case` チェックで弾く**（下記参照）
3. **PR番号のみ** (`^\d+$` または `^#\d+$`): 現在の作業ディレクトリの owner/repo を `gh repo view --json nameWithOwner --jq '.nameWithOwner'` で解決し、それを補う。**cross-repo 用途では使わない**
4. **target なし**: 現在のブランチに関連する PR を `gh pr view --json number --jq '.number'` で自動検出。owner/repo は同じく cwd から `gh repo view` で補う
5. **`--arch`**（手順 0 で抽出済み）: 指定時のみ **aggregate-view reviewer**（`architecture-reviewer`）を別レイヤで追加 spawn する（「aggregate-view reviewer」節参照）。未指定時は spawn しない（毎 PR は走らせないコスト方針）。pr-workflow の large tier からは自動でこのフラグ相当が要請される。

**case 3/4 は fallback**: case 3 (bare number) と case 4 (auto-detect) は URL/owner-repo-like でない target のみ到達する fallback（`https?://github.com/` を含む場合は case 1 で停止、`/` と `#` を両方含む場合は case 2 で停止）。

**post-regex `case` チェック**（ERE の限界を補う）: case 1/2 の regex マッチ後、以下の `case` チェックで危険な形状パターンを追加で弾く。ERE は lookahead を持たないため、`..` や先頭 `.`/`-`・末尾 `-` のような形状制約を単一の固定アンカーパターンで表現できない:

```bash
# After the regex matches, reject repos with dangerous shapes that ERE cannot
# express as a single anchored pattern:
case "$REPO" in *..*|.|.*|-*) echo "invalid repo shape: $REPO" >&2; exit 2 ;; esac
case "$OWNER" in *--*|*-|-*) echo "invalid owner shape: $OWNER" >&2; exit 2 ;; esac
```

**cross-repo 呼び出しの例**（`review-fleet` からの委譲想定）: 引数 `octo-org/awesome#123` が渡された場合、以降 `gh pr diff --repo octo-org/awesome 123`、`gh api "repos/octo-org/awesome/pulls/123/reviews" …` のように owner/repo を明示して呼ぶ。cwd がどこにあっても他 repo の PR を正しく解決できる。
