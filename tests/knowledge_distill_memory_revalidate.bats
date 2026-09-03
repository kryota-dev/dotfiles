#!/usr/bin/env bats

# knowledge-distill Phase 0.5: auto-memory 再検証スクリプト
# (home/dot_agents/skills/knowledge-distill/scripts/memory-revalidate.py, #631).
#
# 監査で見つかった 4 件（参照先の実体が消えた 2 件・恒久ルールに吸収されて存在意義が消えた
# 2 件）を fixture 上で再現できることが、この suite の一次目的である。あわせて、腐敗検出器が
# 静かに壊れる 2 経路 ——「検査できなかった」が「問題なし」へ写像されること、および生 NUL
# バイトで無言スキップすること —— を機械で塞ぐ。
#
# ネットワークには触れない: PR 番号の実在確認は `--github off` か、PATH 先頭に置いた gh
# スタブでのみ行う。

load helpers/setup

FIXTURE="${REPO_ROOT}/tests/fixtures/knowledge-distill/memory-revalidate"
SCRIPT="${HOME_DIR}/dot_agents/skills/knowledge-distill/scripts/memory-revalidate.py"

# fixture repo のコミット日時。memory 側の `modified` を挟むように前後へ振り分けて、
# staleness の再現が実行時刻や mtime に依存しないようにする（fixture の memory は
# 2026-06-21 / 2026-06-25 / 2026-08-31）。
BASE_COMMIT_DATE='2026-01-05T00:00:00+09:00'
CI_TOUCH_COMMIT_DATE='2026-08-30T00:00:00+09:00'

_git() {
  git -c user.name=bats -c user.email=bats@example.invalid -c commit.gpgsign=false "$@"
}

# fixture を $BATS_TEST_TMPDIR へ複製し、日時を固定した 2 コミットの git リポジトリにする。
# 2 コミット目は CI ワークフローだけを触るので、「memory が書かれたあとに参照先が変わった」
# 状態がその 1 ファイルにだけ生じる。
setup() {
  WS="${BATS_TEST_TMPDIR}/ws"
  mkdir -p "$WS"
  cp -R "${FIXTURE}/memory" "${FIXTURE}/rules" "${FIXTURE}/repo" "${WS}/"
  # コミット上は `dot_github`（chezmoi の綴り）で持ち、ここで本来のパスへ展開する。
  # `.github/workflows/*.yml` の形でコミットすると、リポジトリ自身のワークフロー
  # linter が fixture を本物のワークフローとして走査してしまう（下の
  # 「fixture はリポジトリ全体を走査するツールに拾われるパスを作らない」参照）。
  mv "${WS}/repo/dot_github" "${WS}/repo/.github"
  (
    cd "${WS}/repo" || exit 1
    git init -q -b main
    # この使い捨てリポジトリにはフックを持たせない。開発者の global core.hooksPath
    # （gitleaks 等）を継ぐと、テストの成否と所要時間が手元の設定に依存してしまう。
    # `--no-verify` ではなくリポジトリ設定で表現するのは、フックの迂回ではなく
    # 「このリポジトリにはフックが無い」という状態そのものを作るため。
    mkdir -p "${BATS_TEST_TMPDIR}/no-hooks"
    git config core.hooksPath "${BATS_TEST_TMPDIR}/no-hooks"
    _git add -A
    GIT_AUTHOR_DATE="$BASE_COMMIT_DATE" GIT_COMMITTER_DATE="$BASE_COMMIT_DATE" \
      _git commit -q -m base
    printf '\n# memory が書かれたあとに触られた\n' >>.github/workflows/setup-validation.yml
    _git add -A
    GIT_AUTHOR_DATE="$CI_TOUCH_COMMIT_DATE" GIT_COMMITTER_DATE="$CI_TOUCH_COMMIT_DATE" \
      _git commit -q -m touch-ci
  ) >/dev/null
}

# 既定の引数でスクリプトを走らせる（JSON）。追加引数は末尾に足せる。
revalidate() {
  run python3 "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --rules "${WS}/rules/CLAUDE.fixture.md" \
    --format json "$@"
}

# チェック 1 件を JSON から取り出す。
check_json() {
  jq -c --arg id "$1" '.checks[] | select(.id == $id)' <<<"$output"
}

# gh スタブを作り、そのディレクトリのパスを返す。#373 だけ 404、それ以外は成功。
make_gh_stub() {
  local dir="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$dir"
  cat >"${dir}/gh" <<'EOF'
#!/bin/bash
case "$*" in
*"issues/373"*)
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
  ;;
*) exit 0 ;;
esac
EOF
  chmod +x "${dir}/gh"
  printf '%s\n' "$dir"
}

@test "script exists and compiles (python3 is required, never skipped)" {
  [ -f "$SCRIPT" ]
  # ツールが無いと自分を飛ばすガードは、このリポジトリが明示的に禁じている失敗形
  # （Makefile の lint-console 参照）。python3 が無ければ skip ではなく fail させる。
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 not found; this guard does not skip itself"
    false
  }
  # cfile を明示して、ソースの隣に __pycache__ を作らせない。
  run python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$SCRIPT" "${BATS_TEST_TMPDIR}/memory-revalidate.pyc"
  [ "$status" -eq 0 ]
}

# --- 監査で見つかった 4 件の再現 -------------------------------------------

@test "乖離 1: 廃止された make target (\`make dump-brewfile\`) を finding として報告する" {
  revalidate --github off
  local c
  c="$(check_json make-target)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '.checked' <<<"$c")" -ge 1 ]
  [ "$(jq -r '[.findings[] | select(.subject == "make dump-brewfile")] | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '.findings[0].memory_file' <<<"$c")" = "MEMORY.md" ]
  [ "$(jq -r '.findings[0].line' <<<"$c")" -gt 0 ]
}

@test "乖離 2: memory より後に変更された参照先を staleness の finding として報告する" {
  revalidate --github off
  local c f
  c="$(check_json staleness)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '[.findings[] | select(.subject == ".github/workflows/setup-validation.yml")] | length' <<<"$c")" -eq 1 ]
  # 同じ 1 件の finding に対して、由来（どの memory の何行目か）と両方の日付を固定する。
  # 「どこかで staleness が出た」だけだと、別の memory / 別の参照が偶然 stale になっても通る。
  f="$(jq -c '[.findings[] | select(.subject == ".github/workflows/setup-validation.yml")][0]' <<<"$c")"
  [ "$(jq -r '.memory_file' <<<"$f")" = "MEMORY.md" ]
  [ "$(jq -r '.line' <<<"$f")" -gt 0 ]
  [[ "$(jq -r '.reason' <<<"$f")" == *"2026-08-30"* ]]   # 参照先の最終コミット日（setup で固定）
  [[ "$(jq -r '.reason' <<<"$f")" == *"2026-06-21"* ]]   # memory 側の modified
  # 日付の出所を必ず併記する（mtime 由来か frontmatter 由来かで証拠の強さが違う）。
  [[ "$(jq -r '.reason' <<<"$f")" == *"frontmatter-modified"* ]]
  # memory より前のコミットしか無いファイルは finding にしない。
  [ "$(jq -r '[.findings[] | select(.subject | contains("lint-pins"))] | length' <<<"$c")" -eq 0 ]
}

@test "staleness: memory の日付が mtime 由来のときもその出所を明示して判定する" {
  # 実在する memory は `modified` frontmatter を持たない世代のものがあり、その場合の経路は
  # mtime フォールバックになる。fixture は再現を mtime に依存させないため全件 `modified` を
  # 持たせてあるので、フォールバック自体はここで独立に固定する。
  local note="${WS}/memory/mtime-only.md"
  cat >"$note" <<'EOF'
# frontmatter を持たない memory

CI の定義は `.github/workflows/setup-validation.yml` にある。
EOF
  # 参照先の最終コミット（2026-08-30）より前に memory が書かれた状態を作る。
  python3 -c 'import os,sys; t=1767000000; os.utime(sys.argv[1], (t, t))' "$note"
  revalidate --github off
  local f
  f="$(jq -c '[.checks[] | select(.id == "staleness")][0].findings[]
        | select(.memory_file == "mtime-only.md")' <<<"$output")"
  [ -n "$f" ]
  [ "$(jq -r '.subject' <<<"$f")" = ".github/workflows/setup-validation.yml" ]
  [[ "$(jq -r '.reason' <<<"$f")" == *"mtime"* ]]
  [ "$(jq -r '[.memory_files[] | select(.name == "mtime-only.md")][0].modified_source' <<<"$output")" = "mtime" ]

  # 逆向き: 参照先の最終コミットより後の mtime なら finding にしない。
  python3 -c 'import os,sys; t=1798000000; os.utime(sys.argv[1], (t, t))' "$note"
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "staleness")][0].findings
        | map(select(.memory_file == "mtime-only.md")) | length' <<<"$output")" -eq 0 ]
}

@test "staleness: 日付の解釈をホストの timezone に依存させない" {
  # offset を持たない `modified:` をローカル時刻として解釈すると、同じ memory と同じ git 履歴でも
  # 実行マシンの TZ で判定が変わる。UTC 固定であることを、TZ を振って同じ結果になることで固定する。
  local note="${WS}/memory/naive-date.md"
  cat >"$note" <<'EOF'
---
name: naive-date
modified: 2026-08-30T00:00:01
---

CI の定義は `.github/workflows/setup-validation.yml` にある。
EOF
  local a b
  a="$(TZ=UTC python3 "$SCRIPT" --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github off |
    jq -c '[.checks[] | select(.id == "staleness")][0].findings | map(select(.memory_file == "naive-date.md"))')"
  b="$(TZ=Pacific/Kiritimati python3 "$SCRIPT" --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github off |
    jq -c '[.checks[] | select(.id == "staleness")][0].findings | map(select(.memory_file == "naive-date.md"))')"
  [ "$a" = "$b" ]
  # UTC と決めた解釈であることを出所に残す（証拠の強さが読み手に伝わるように）。
  revalidate --github off
  [ "$(jq -r '[.memory_files[] | select(.name == "naive-date.md")][0].modified_source' <<<"$output")" = "frontmatter-modified(naive-utc)" ]
}

@test "staleness: modified が壊れているときは mtime へ無言で落とさない" {
  local note="${WS}/memory/bad-modified.md"
  cat >"$note" <<'EOF'
---
name: bad-modified
modified: いつだったか忘れた
---

CI の定義は `.github/workflows/setup-validation.yml` にある。
EOF
  revalidate --github off
  # 「modified が無い」と「modified があるのに読めない」は別の事実。後者を隠すと、
  # 壊れた監査対象データが弱い根拠（mtime）にすり替わったまま気づけない。
  [[ "$(jq -r '[.memory_files[] | select(.name == "bad-modified.md")][0].modified_source' <<<"$output")" == "frontmatter-modified(unparsable)"* ]]
}

@test "重複 2 件: 恒久ルールが同じことを書いている topic file を報告する" {
  revalidate --github off
  local c
  c="$(check_json rule-duplication)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '.findings | length' <<<"$c")" -eq 2 ]
  [ "$(jq -r '[.findings[] | select(.memory_file == "verify-reviewer-findings.md")] | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '[.findings[] | select(.memory_file == "public-repo-no-client-names.md")] | length' <<<"$c")" -eq 1 ]
  # 証拠は「どのルールファイルのどの節か」まで。memory 本文は載せない。
  [[ "$(jq -r '[.findings[] | select(.memory_file == "verify-reviewer-findings.md")][0].subject' <<<"$c")" == *"レビュー指摘の検証"* ]]
  [[ "$(jq -r '[.findings[] | select(.memory_file == "public-repo-no-client-names.md")][0].subject' <<<"$c")" == *"公開物への記載禁止"* ]]
}

@test "陰性対照: 重複していない topic file は finding にならず、スコアは記録される" {
  revalidate --github off
  local c
  c="$(check_json rule-duplication)"
  [ "$(jq -r '[.findings[] | select(.memory_file == "fresh-note.md")] | length' <<<"$c")" -eq 0 ]
  # 「判定した」ことが見えるように、閾値未満でも最高スコアを notes に残す。
  [ "$(jq -r '[.notes[] | select(startswith("fresh-note.md"))] | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '.checked' <<<"$c")" -eq 3 ]
}

@test "path-exists: 消えたパスを finding にし、陰性対照のパスは finding にしない" {
  revalidate --github off
  local c
  c="$(check_json path-exists)"
  [ "$(jq -r '[.findings[] | select(.subject == "home/dot_local/bin/executable_removed-tool")] | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '[.findings[] | select(.subject | contains("lint-pins"))] | length' <<<"$c")" -eq 0 ]
  [ "$(jq -r '.checked' <<<"$c")" -ge 4 ]
}

# --- 「検査できなかった」と「問題なし」の分離 -------------------------------

@test "各チェックが checked / findings / unchecked / reasons を独立に持つ" {
  revalidate --github off
  # 6 チェックすべてが揃っていること（チェックが静かに消えるのを防ぐ）。
  [ "$(jq -r '.checks | length' <<<"$output")" -eq 6 ]
  local id
  for id in path-exists make-target pr-reference staleness rule-duplication memory-index-size; do
    local c
    c="$(check_json "$id")"
    [ -n "$c" ]
    jq -e 'has("checked") and has("findings") and has("unchecked") and has("reasons")' <<<"$c" >/dev/null
  done
}

@test "断定できない候補は finding ではなく unchecked として必ず列挙される" {
  revalidate --github off
  local c
  c="$(check_json path-exists)"
  # 絶対パス / ホーム相対は「存在しない」と断定できないので finding にしない。
  [ "$(jq -r '[.unchecked[] | select(.subject == "~/Library/Caches/Homebrew")] | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '[.findings[] | select(.subject == "~/Library/Caches/Homebrew")] | length' <<<"$c")" -eq 0 ]
  # 先頭セグメントがリポジトリに無いものも同様。
  [ "$(jq -r '[.unchecked[] | select(.reason | contains("先頭セグメント"))] | length' <<<"$c")" -ge 1 ]
  # 理由が空の unchecked を作らない（「なぜ見なかったか」が必ず残る）。
  [ "$(jq -r '[.unchecked[] | select(.reason == "")] | length' <<<"$c")" -eq 0 ]
}

@test "--github=off は ok ではなく inconclusive になる" {
  revalidate --github off
  local c
  c="$(check_json pr-reference)"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [ "$(jq -r '.checked' <<<"$c")" -eq 0 ]
  [ "$(jq -r '.reasons | length' <<<"$c")" -ge 1 ]
  [[ "$(jq -r '.reasons[0]' <<<"$c")" == *"--github=off"* ]]
}

@test "gh が PATH に無ければ inconclusive（--github=on ならその旨も残す）" {
  # gh だけが引けない PATH を、必要な実行ファイルの symlink だけを置いた
  # ディレクトリとして組み立てる。`/usr/bin:/bin` を足す形は使えない ——
  # GitHub Actions の Ubuntu ランナーは gh を /usr/bin/gh に同梱しているため、
  # gh が見つかってしまい、別の理由（remote 未解決）で inconclusive になる。
  # 手元の macOS では gh が /usr/bin に無いので、この差は CI でしか露見しなかった。
  local fakebin real_python
  fakebin="${BATS_TEST_TMPDIR}/fakebin"
  mkdir -p "$fakebin"
  # git は残す（外すと staleness の理由が増え、何を検証しているのかが曖昧になる）。
  ln -sf "$(command -v git)" "${fakebin}/git"
  # python3 は shim ではなく実体を絶対パスで起動する。PATH に依存させない。
  real_python="$(python3 -c 'import sys; print(sys.executable)')"
  run env PATH="$fakebin" "$real_python" "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github on
  [ "$status" -eq 3 ]
  local c
  c="$(jq -c '.checks[] | select(.id == "pr-reference")' <<<"$output")"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [[ "$(jq -r '.reasons[0]' <<<"$c")" == *"--github=on"* ]]
}

@test "gh が 404 を返した参照は finding、引けた参照は checked に数える" {
  local stub
  stub="$(make_gh_stub)"
  (cd "${WS}/repo" && _git remote add origin git@github.com:kryota-dev/fixture-repo.git)
  run env PATH="${stub}:${PATH}" python3 "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --rules "${WS}/rules/CLAUDE.fixture.md" \
    --format json --github auto
  local c
  c="$(jq -c '.checks[] | select(.id == "pr-reference")' <<<"$output")"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '.checked' <<<"$c")" -eq 3 ]
  [ "$(jq -r '.findings | length' <<<"$c")" -eq 1 ]
  [ "$(jq -r '.findings[0].subject' <<<"$c")" = "#373" ]
  [ "$(jq -r '.reasons | length' <<<"$c")" -eq 0 ]
}

@test "gh の 404 以外の失敗は finding ではなく unchecked + reason になる" {
  local stub="${BATS_TEST_TMPDIR}/stub-fail"
  mkdir -p "$stub"
  printf '%s\n' '#!/bin/bash' 'echo "gh: HTTP 403 rate limit exceeded" >&2' 'exit 1' >"${stub}/gh"
  chmod +x "${stub}/gh"
  (cd "${WS}/repo" && _git remote add origin git@github.com:kryota-dev/fixture-repo.git)
  run env PATH="${stub}:${PATH}" python3 "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github auto
  local c
  c="$(jq -c '.checks[] | select(.id == "pr-reference")' <<<"$output")"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [ "$(jq -r '.findings | length' <<<"$c")" -eq 0 ]
  [ "$(jq -r '.unchecked | length' <<<"$c")" -ge 1 ]
  [ "$(jq -r '.reasons | length' <<<"$c")" -ge 1 ]
}

@test "生 NUL バイトを含む memory は inconclusive にし、その中の参照を finding にしない" {
  # ripgrep 再帰と Claude Code の Grep/Glob はこの手のファイルを無言でスキップする。
  # ここで沈黙すると、腐敗検出器が「0 件」を返して壊れていることに誰も気づけない。
  printf -- '---\nname: nul-note\n---\n\nNUL\000 bytes `home/definitely-gone.md`\n' \
    >"${WS}/memory/nul-note.md"
  revalidate --github off
  local c
  c="$(check_json path-exists)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '[.reasons[] | select(contains("nul-bytes"))] | length' <<<"$c")" -ge 1 ]
  # 読めなかったファイルの中身は走査していないので、そこにある参照を finding にしてはならない。
  [ "$(jq -r '[.findings[] | select(.subject | contains("definitely-gone"))] | length' <<<"$c")" -eq 0 ]
  # 読めなかったこと自体は memory_files にも残る。
  [ "$(jq -r '[.memory_files[] | select(.name == "nul-note.md")][0].error' <<<"$output")" = "nul-bytes" ]
}

@test "ルールファイル側の NUL / デコード失敗も inconclusive にする（memory 側と対称）" {
  # 無言スキップ経路は memory 側だけの話ではない。読めないルールファイルを黙って
  # 対象から外すと、重複検出は「照合したが 0 件」と見分けが付かなくなる。
  printf -- '# rule\n\nNUL\000 bytes in a rule file\n' >"${WS}/rules/AGENTS.fixture.md"
  revalidate --github off
  local c
  c="$(check_json rule-duplication)"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [ "$(jq -r '[.reasons[] | select(contains("nul-bytes"))] | length' <<<"$c")" -ge 1 ]
  [ "$(jq -r '[.reasons[] | select(contains("AGENTS.fixture.md"))] | length' <<<"$c")" -ge 1 ]
  # 読めなかったルールファイルに由来する finding を出してはならない。
  [ "$(jq -r '[.findings[] | select(.subject | contains("レビュー指摘の検証"))] | length' <<<"$c")" -eq 0 ]

  printf -- '# rule\n\n\xff\xfe not utf-8\n' >"${WS}/rules/AGENTS.fixture.md"
  revalidate --github off
  c="$(check_json rule-duplication)"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [ "$(jq -r '[.reasons[] | select(contains("decode-error"))] | length' <<<"$c")" -ge 1 ]
}

@test "memory ディレクトリ内の symlink は追わず、読めない理由として記録する" {
  # memory ディレクトリへ書ける者が `*.md` という名前のリンクを置けば、ディレクトリ外の
  # 任意ファイルを「memory」として読ませ、抽出結果をレポートへ載せられる。
  printf 'secret-looking content `home/nope.md`\n' >"${BATS_TEST_TMPDIR}/outside.md"
  ln -s "${BATS_TEST_TMPDIR}/outside.md" "${WS}/memory/linked.md"
  revalidate --github off
  [ "$(jq -r '[.memory_files[] | select(.name == "linked.md")][0].error' <<<"$output")" = "symlink" ]
  # リンク先の中身を走査していない = そこにある参照を finding にしていない。
  [ "$(jq -r '[.checks[] | select(.id == "path-exists")][0].findings
        | map(select(.subject | contains("nope"))) | length' <<<"$output")" -eq 0 ]
  # 黙って飛ばしてもいない（読めなかった理由として実行不能に上がる）。
  [ "$(jq -r '[.checks[] | select(.id == "path-exists")][0].reasons
        | map(select(contains("symlink"))) | length' <<<"$output")" -ge 1 ]
}

@test "UTF-8 としてデコードできない memory も inconclusive になる" {
  printf -- '---\nname: bad\n---\n\n\xff\xfe not utf-8\n' >"${WS}/memory/bad-encoding.md"
  revalidate --github off
  [ "$(jq -r '[.memory_files[] | select(.name == "bad-encoding.md")][0].error' <<<"$output")" = "decode-error" ]
  [ "$(jq -r '[.checks[] | select(.id == "path-exists")][0].reasons | map(select(contains("decode-error"))) | length' <<<"$output")" -ge 1 ]
}

# --- MEMORY.md の読み込み上限 ----------------------------------------------

@test "MEMORY.md が 200 行を超えたら finding" {
  {
    printf -- '---\nname: MEMORY\nmodified: 2026-08-31T09:00:00+09:00\n---\n\n'
    for i in $(seq 1 250); do printf -- '- entry %s\n' "$i"; done
  } >"${WS}/memory/MEMORY.md"
  revalidate --github off
  local c
  c="$(check_json memory-index-size)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [ "$(jq -r '.checked' <<<"$c")" -eq 1 ]
  [[ "$(jq -r '.findings[0].reason' <<<"$c")" == *"超過"* ]]
}

@test "MEMORY.md が 25KB を超えたら finding（行数が上限内でも）" {
  {
    printf -- '---\nname: MEMORY\nmodified: 2026-08-31T09:00:00+09:00\n---\n\n'
    for i in $(seq 1 50); do
      printf -- '- '
      head -c 700 /dev/zero | tr '\0' 'x'
      printf -- '\n'
    done
  } >"${WS}/memory/MEMORY.md"
  local lines bytes
  lines=$(wc -l <"${WS}/memory/MEMORY.md")
  bytes=$(wc -c <"${WS}/memory/MEMORY.md")
  [ "$lines" -le 200 ]
  [ "$bytes" -gt 25000 ]
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "memory-index-size")][0].status' <<<"$output")" = "finding" ]
}

@test "MEMORY.md の閾値はちょうどの値では finding にせず、1 超えたら finding にする" {
  # 「超過」だけを見ていると、境界がどちら側にあるのかが契約として固定されない。
  # 公式仕様は「先頭 200 行 / 25KB までが読み込まれる」なので、ちょうどは収まっている。
  write_index_lines() {
    # 警告帯にも入らない小さな本文で、指定の行数ちょうどのファイルを作る。
    python3 - "$1" "${WS}/memory/MEMORY.md" <<'PY'
import sys
n = int(sys.argv[1])
head = "---\nname: MEMORY\nmodified: 2026-08-31T09:00:00+09:00\n---\n"
body = "".join("- e\n" for _ in range(n - head.count("\n")))
open(sys.argv[2], "w", encoding="utf-8").write(head + body)
PY
  }
  write_index_lines 200
  [ "$(wc -l <"${WS}/memory/MEMORY.md")" -eq 200 ]
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "memory-index-size")][0].findings
        | map(select(.reason | contains("超過"))) | length' <<<"$output")" -eq 0 ]

  write_index_lines 201
  [ "$(wc -l <"${WS}/memory/MEMORY.md")" -eq 201 ]
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "memory-index-size")][0].findings
        | map(select(.reason | contains("超過"))) | length' <<<"$output")" -eq 1 ]
}

@test "MEMORY.md のバイト境界も 25000 ちょうどは通し、25001 で finding にする" {
  write_index_bytes() {
    python3 - "$1" "${WS}/memory/MEMORY.md" <<'PY'
import sys
target = int(sys.argv[1])
head = "---\nname: MEMORY\nmodified: 2026-08-31T09:00:00+09:00\n---\n"
# 行数は上限内に収めたまま、バイト数だけを狙った値にする。
line = "- " + "x" * 497 + "\n"
body = line * ((target - len(head)) // len(line))
body += "y" * (target - len(head) - len(body))
open(sys.argv[2], "w", encoding="utf-8").write(head + body)
PY
  }
  write_index_bytes 25000
  [ "$(wc -c <"${WS}/memory/MEMORY.md" | tr -d ' ')" -eq 25000 ]
  [ "$(wc -l <"${WS}/memory/MEMORY.md")" -le 200 ]
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "memory-index-size")][0].findings
        | map(select(.reason | contains("超過"))) | length' <<<"$output")" -eq 0 ]

  write_index_bytes 25001
  [ "$(wc -c <"${WS}/memory/MEMORY.md" | tr -d ' ')" -eq 25001 ]
  revalidate --github off
  [ "$(jq -r '[.checks[] | select(.id == "memory-index-size")][0].findings
        | map(select(.reason | contains("超過"))) | length' <<<"$output")" -eq 1 ]
}

@test "MEMORY.md が上限の 90% に達したら接近を finding として知らせる" {
  {
    printf -- '---\nname: MEMORY\nmodified: 2026-08-31T09:00:00+09:00\n---\n\n'
    for i in $(seq 1 190); do printf -- '- entry %s\n' "$i"; done
  } >"${WS}/memory/MEMORY.md"
  revalidate --github off
  local c
  c="$(check_json memory-index-size)"
  [ "$(jq -r .status <<<"$c")" = "finding" ]
  [[ "$(jq -r '.findings[0].reason' <<<"$c")" == *"到達"* ]]
}

# --- 終了コード -------------------------------------------------------------

@test "終了コードは finding(bit0) と inconclusive(bit1) を別ビットで表す" {
  # fixture そのままなら finding も inconclusive（--github off）もある → 3
  revalidate --github off
  [ "$status" -eq 3 ]
  [ "$(jq -r '.summary.exit_code' <<<"$output")" -eq 3 ]

  # gh スタブをすべて成功させれば inconclusive が消え、finding だけが残る → 1
  local stub="${BATS_TEST_TMPDIR}/stub-ok"
  mkdir -p "$stub"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"${stub}/gh"
  chmod +x "${stub}/gh"
  (cd "${WS}/repo" && _git remote add origin git@github.com:kryota-dev/fixture-repo.git)
  run env PATH="${stub}:${PATH}" python3 "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --rules "${WS}/rules/CLAUDE.fixture.md" \
    --format json --github auto
  [ "$status" -eq 1 ]
}

@test "腐敗が無く実行不能も無ければ 0 で終わる" {
  local clean="${BATS_TEST_TMPDIR}/clean-memory"
  mkdir -p "$clean"
  cp "${WS}/memory/fresh-note.md" "${clean}/"
  cat >"${clean}/MEMORY.md" <<'EOF'
---
name: MEMORY
modified: 2026-08-31T09:00:00+09:00
---

# Project Memory

- lint ツールのピンは `home/dot_config/lint-pins.toml`
EOF
  run python3 "$SCRIPT" --memory-dir "$clean" --repo "${WS}/repo" \
    --rules "${WS}/rules/CLAUDE.fixture.md" --format json --github off
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.checks[] | select(.status != "ok")] | length' <<<"$output")" -eq 0 ]
  # 「0 件中 finding 0」と「N 件中 finding 0」が区別できること。
  [ "$(jq -r '[.checks[] | select(.id == "path-exists")][0].checked' <<<"$output")" -ge 1 ]
}

@test "memory ディレクトリが無ければ全チェックが inconclusive（exit 2）" {
  run python3 "$SCRIPT" --memory-dir "${BATS_TEST_TMPDIR}/nope" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github off
  [ "$status" -eq 2 ]
  [ "$(jq -r '[.checks[] | select(.status == "inconclusive")] | length' <<<"$output")" -eq 6 ]
  [ "$(jq -r '.summary.findings' <<<"$output")" -eq 0 ]
}

@test "引数エラーは 64（inconclusive の 2 と衝突させない）" {
  run python3 "$SCRIPT" --format yaml
  [ "$status" -eq 64 ]
}

@test "ルールファイルが 1 つも無ければ rule-duplication は ok ではなく inconclusive" {
  run python3 "$SCRIPT" --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${BATS_TEST_TMPDIR}/no-such-rules.md" --format json --github off
  local c
  c="$(jq -c '.checks[] | select(.id == "rule-duplication")' <<<"$output")"
  [ "$(jq -r .status <<<"$c")" = "inconclusive" ]
  [ "$(jq -r '.checked' <<<"$c")" -eq 0 ]
  [ "$(jq -r '[.reasons[] | select(contains("存在しない"))] | length' <<<"$c")" -ge 1 ]
}

# --- 読み取り専用 -----------------------------------------------------------

@test "memory ディレクトリへ書き込まない" {
  # ハッシュは python3（CI で明示インストール済み）で取る。`shasum` は Ubuntu では
  # ランナーイメージ同梱の perl に依存しており、宣言していない依存になる。
  digest_tree() {
    python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*")):
    if path.is_file():
        print(path.relative_to(root), hashlib.sha256(path.read_bytes()).hexdigest())
PY
  }
  local before after
  before="$(digest_tree "${WS}/memory")"
  revalidate --github off
  after="$(digest_tree "${WS}/memory")"
  [ "$before" = "$after" ]
  # 新規ファイル（一時ファイル・キャッシュ等）も作らせない。
  [ "$(find "${WS}/memory" -mindepth 1 | wc -l | tr -d ' ')" -eq 4 ]
}

@test "--memory-dir 省略時はリポジトリから既定の memory ディレクトリを導出する" {
  # 既定導出が壊れても、常に --memory-dir を渡す suite では気づけない。
  local slug config
  # スクリプトは --repo を resolve() してから slug 化する（macOS では /tmp が
  # /private/tmp へ解決される）。テスト側も同じ解決を経てから綴りを組み立てる。
  slug="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]).replace("/", "-").replace(".", "-"))' "${WS}/repo")"
  config="${BATS_TEST_TMPDIR}/config"
  mkdir -p "${config}/projects/${slug}"
  cp -R "${WS}/memory" "${config}/projects/${slug}/memory"
  run python3 "$SCRIPT" --repo "${WS}/repo" --config-dir "$config" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github off
  [ "$(jq -r '.memory_dir' <<<"$output")" = "${config}/projects/${slug}/memory" ]
  [ "$(jq -r '.memory_file_count' <<<"$output")" -eq 4 ]
  # 導出先が存在しなければ「問題なし」ではなく inconclusive に倒れる。
  run python3 "$SCRIPT" --repo "${WS}/repo" --config-dir "${BATS_TEST_TMPDIR}/no-config" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github off
  [ "$status" -eq 2 ]
}

@test "PR 照会は 1 実行あたりの上限で打ち切り、超過分を unchecked として列挙する" {
  local stub="${BATS_TEST_TMPDIR}/stub-many"
  mkdir -p "$stub"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"${stub}/gh"
  chmod +x "${stub}/gh"
  (cd "${WS}/repo" && _git remote add origin git@github.com:kryota-dev/fixture-repo.git)
  # 上限（50）を超える一意な参照を 1 ファイルに並べる。
  {
    printf -- '---\nname: many-refs\nmodified: 2026-08-31T09:00:00+09:00\n---\n\n'
    for i in $(seq 1000 1069); do printf -- '- ref #%s\n' "$i"; done
  } >"${WS}/memory/many-refs.md"
  run env PATH="${stub}:${PATH}" python3 "$SCRIPT" \
    --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --format json --github auto
  local c
  c="$(jq -c '.checks[] | select(.id == "pr-reference")' <<<"$output")"
  [ "$(jq -r '.checked' <<<"$c")" -le 50 ]
  [ "$(jq -r '[.unchecked[] | select(.reason | contains("照会上限"))] | length' <<<"$c")" -ge 1 ]
}

# --- 報告 -------------------------------------------------------------------

@test "text 出力は状態表と 4 セクション、および報告のみである旨を含む" {
  run python3 "$SCRIPT" --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --rules "${WS}/rules/CLAUDE.fixture.md" \
    --format text --github off
  [ "$status" -eq 3 ]
  [[ "$output" == *"| チェック | 状態 | 検査 | finding | 未検査 | 実行不能 |"* ]]
  [[ "$output" == *"### finding"* ]]
  [[ "$output" == *"### 未検査"* ]]
  [[ "$output" == *"### 実行不能"* ]]
  [[ "$output" == *"報告のみ"* ]]
  [[ "$output" == *"意味的な判定"* ]]
}

@test "報告に memory 本文を転記しない" {
  run python3 "$SCRIPT" --memory-dir "${WS}/memory" --repo "${WS}/repo" \
    --rules "${WS}/rules/AGENTS.fixture.md" --rules "${WS}/rules/CLAUDE.fixture.md" \
    --format text --github off
  [ "$status" -eq 3 ]
  # 重複が検出された memory の本文にしか無い言い回しが、レポートへ流れ出ていないこと。
  ! grep -qF '確認用サブエージェントの要約' <<<"$output"
  ! grep -qF '検索インデックスに残り' <<<"$output"
}

# --- 定数と不変条件の固定 ---------------------------------------------------

@test "閾値はすべて名前付き定数として定義されている" {
  local name
  for name in MEMORY_INDEX_MAX_LINES MEMORY_INDEX_MAX_BYTES MEMORY_INDEX_WARN_RATIO \
    DUPLICATE_SHINGLE_SIZE DUPLICATE_CONTAINMENT_THRESHOLD DUPLICATE_MIN_SHINGLES \
    PR_NUMBER_MAX PR_REFERENCE_MAX_QUERIES GIT_LOG_MAX_QUERIES SUBPROCESS_TIMEOUT_SECONDS; do
    grep -qE "^${name} = " "$SCRIPT" || {
      echo "named constant missing: ${name}"
      false
    }
  done
  # 公式仕様の値そのもの（200 行 / 25KB）。片方だけ書き換わる drift を止める。
  grep -qxF 'MEMORY_INDEX_MAX_LINES = 200' "$SCRIPT"
  grep -qxF 'MEMORY_INDEX_MAX_BYTES = 25_000' "$SCRIPT"
}

@test "fixture はリポジトリ全体を走査するツールに拾われるパスを作らない" {
  # 実際に踏んだ失敗: fixture が `.github/workflows/setup-validation.yml` を持っていた
  # ため、リポジトリ自身のワークフロー linter（zizmor）がそれを本物のワークフローとして
  # 走査し、excessive-permissions で CI が落ちた。
  #
  # 同じ形の地雷は他にもある。いずれも「リポジトリを模す」という fixture の目的と、
  # 「パス glob で対象を決める」というツールの都合が正面衝突するために起きる:
  #   - `.github/workflows/*.y?ml` -> actionlint / ghalint / zizmor / ls-lint
  #   - `mise/config.toml`         -> .github/renovate.json5 の mise manager。パターンが
  #                                   アンカー無しの正規表現なので部分一致で拾われる
  #   - `CLAUDE.md` / `CLAUDE.local.md`
  #                                -> Claude Code は cwd 配下のネストしたものを、その
  #                                   ディレクトリを読んだ時点で「指示」として読み込む
  #
  # 追跡ファイルの列挙に git ls-files を使うのは house rule どおり（Grep / Glob は
  # gitignore 対象と生 NUL バイトを含むファイルを無言で飛ばすため、網羅性の主張には
  # 使わない）。ここでは検索対象がパス文字列そのものなので、その 2 経路は生じない。
  local tracked offenders
  tracked="$(git -C "$REPO_ROOT" ls-files tests/fixtures)"
  [ -n "$tracked" ] || {
    echo "git ls-files tests/fixtures が空: fixture が追跡されていないか、抽出が壊れている"
    false
  }
  offenders="$(grep -E '(^|/)(\.github/workflows/[^/]*\.ya?ml|mise/config\.toml|CLAUDE\.md|CLAUDE\.local\.md)$' <<<"$tracked" || true)"
  [ -z "$offenders" ] || {
    echo "リポジトリ全体を走査するツールに拾われる fixture パス:"
    printf '%s\n' "$offenders"
    false
  }
}

@test "閾値とチェック一覧の散文ミラーが、スクリプトの実体と一致する" {
  # 同じ事実（200 行 / 25KB / 6 チェック）が、スクリプトの定数・SKILL.md・docs(EN/JA)・PRD の
  # 複数箇所に手書きで現れている。このリポジトリは「同じものを 2 箇所に置くなら機械で比較する」
  # 流儀を既に持つ（tests/knowledge_distill_radar.bats の instinct-count marker、
  # tests/docs_facts.bats の FACT マーカー）ので、散文だけが取り残される drift をここで止める。
  local lines bytes
  lines="$(grep -oE '^MEMORY_INDEX_MAX_LINES = [0-9_]+' "$SCRIPT" | grep -oE '[0-9_]+$' | tr -d '_')"
  bytes="$(grep -oE '^MEMORY_INDEX_MAX_BYTES = [0-9_]+' "$SCRIPT" | grep -oE '[0-9_]+$' | tr -d '_')"
  [ -n "$lines" ] && [ -n "$bytes" ]
  # 散文は「200 行 / 25KB」という単位付きの表記なので、KB 側は 1000 で割った値と突き合わせる。
  local kb=$((bytes / 1000))
  [ "$((kb * 1000))" -eq "$bytes" ] || {
    echo "MEMORY_INDEX_MAX_BYTES=${bytes} は KB 表記に丸められない。散文側の書式を見直すこと"
    false
  }

  local doc
  for doc in "${HOME_DIR}/dot_agents/skills/knowledge-distill/SKILL.md" \
    "${DOCS_DIR}/agents/claude-code.md" "${DOCS_DIR}/agents/claude-code.ja.md"; do
    [ -f "$doc" ]
    # EN は `200-line`、JA は `200 行`。区切りの揺れは許し、数値と単位の対応だけを固定する。
    grep -qE "${lines}[ -]?(行|line)" "$doc" || {
      echo "${doc##*/} が MEMORY_INDEX_MAX_LINES=${lines} を散文に書いていない"
      false
    }
    grep -qE "${kb} ?KB" "$doc" || {
      echo "${doc##*/} が MEMORY_INDEX_MAX_BYTES=${bytes}（${kb}KB）を散文に書いていない"
      false
    }
  done

  # 6 チェックの id が、スクリプトの CHECK_IDS と各表で一致すること（増減の取り残しを防ぐ）。
  local ids id
  ids="$(python3 -c '
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id == "CHECK_IDS" for t in node.targets
    ):
        print(" ".join(e.value for e in node.value.elts))
        break
' "$SCRIPT")"
  [ -n "$ids" ]
  [ "$(wc -w <<<"$ids" | tr -d ' ')" -eq 6 ]
  for doc in "${HOME_DIR}/dot_agents/skills/knowledge-distill/SKILL.md" \
    "${DOCS_DIR}/agents/claude-code.md" "${DOCS_DIR}/agents/claude-code.ja.md" \
    "${REPO_ROOT}/.claude/prds/631-knowledge-distill-memory-revalidation.prd.md"; do
    [ -f "$doc" ]
    for id in $ids; do
      grep -qF "$id" "$doc" || {
        echo "${doc##*/} にチェック id '${id}' が現れていない"
        false
      }
    done
  done
}

@test "外部コマンドを shell 経由で起動しない" {
  # memory 由来の文字列がコマンド行として解釈される経路を作らない（#631 PRD AC-041）。
  ! grep -qF 'shell=True' "$SCRIPT"
  ! grep -qF 'os.system' "$SCRIPT"
  ! grep -qF 'os.popen' "$SCRIPT"
}

@test "起動する外部コマンドは git と gh だけ（ripgrep 再帰の無言スキップ経路を作らない）" {
  # `rg` の再帰と `grep -rI` は gitignore 対象と生 NUL バイトを含むファイルを、エラーも
  # 警告も出さずに飛ばす。腐敗検出器がそれを踏むと、壊れていることが「0 件」に化ける。
  #
  # 本文の grep ではなく AST を見るのは、この skill 自身の docstring が禁止対象として
  # `rg` / `grep -rI` に言及しており、文字列一致では散文と実装を区別できないから
  # （散文で禁止を説明したら guard が落ちる、では guard が育たない）。
  run python3 - "$SCRIPT" <<'PY'
import ast
import sys

CALLS = {"run_command", "run", "Popen", "check_output", "check_call", "call"}
names = set()


def head_of(node):
    """argv リテラルの先頭要素（コマンド名）を返す。"""
    if isinstance(node, (ast.List, ast.Tuple)) and node.elts:
        head = node.elts[0]
        if isinstance(head, ast.Constant) and isinstance(head.value, str):
            return head.value
    return None


tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in ast.walk(tree):
    # 直接 argv リテラルを渡している呼び出し。
    if isinstance(node, ast.Call):
        func = node.func
        label = func.id if isinstance(func, ast.Name) else getattr(func, "attr", "")
        if label in CALLS:
            for arg in node.args:
                name = head_of(arg)
                if name:
                    names.add(name)
    # `argv = [...]` に組み立ててから渡している呼び出し。
    if isinstance(node, ast.Assign):
        if any(isinstance(t, ast.Name) and t.id == "argv" for t in node.targets):
            name = head_of(node.value)
            if name:
                names.add(name)

if not names:
    sys.stderr.write("no external command literals found; the extractor likely broke\n")
    raise SystemExit(1)
print(" ".join(sorted(names)))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "gh git" ]
}
