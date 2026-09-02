#!/usr/bin/env bats

# pr-workflow の実行モデル契約 (kryota-dev/dotfiles#585)。
#
# `pr-workflow` は「バックグラウンドへ投げて、結果を次の turn で受け取る」前提で書かれていた。
# `fh session launch` が起こす `claude -p` は 1 turn 実行なのでその次の turn が無く、子は
# 「完了通知が来次第 Phase 6 へ進めます」と述べて終わり、Phase 5〜7 が丸ごと実行されない。
# ターンはエラー無く終わるため `fh runs` には `succeeded` / `exitCode: 0` と記録され、
# **完走した実行と外形が一致する**（#573 が扱う検出の側）。
#
# ここで固定するのは、その規範が退行しないことである。**失敗様式は「節が消える」ことではなく
# 「静かに緩む」ことなので、語句の存在ではなく意味論の対応を見る** —— 語句検査だけだと、
# CI 行を `gh pr checks --watch &` に変えても、Failure mode 表の対処を「次の Phase へ進む」に
# 緩めても、`.reviews | length` を `reviews: 1` の固定値へ退行させても通ってしまう。
#
#   1. 不変条件そのもの（turn を終えてよいのは AskUserQuestion のときだけ）
#   2. join の形 —— **待つ対象と join の形の対応**を表の行ごとに検査する
#   3. 到達点検査 —— **同一コードフェンス内**で投稿者フィルタと CI 結論抽出まで検査する
#   4. Failure mode —— 失敗条件だけでなく**対処**まで検査する
#   5. 未文書の内部識別子に規範を載せていないこと（名前が変わると静かに失効するため）
#   6. 規範が callee 側（multi-review）にも届いていること（caller の override だけでは
#      pr-workflow を経由しない起動で #585 が再現する）

load helpers/setup

SKILL_MD="${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
SINGLE_TURN_REF="${HOME_DIR}/dot_agents/skills/pr-workflow/references/single-turn.md"
MULTI_REVIEW_PROTOCOL="${HOME_DIR}/dot_agents/skills/multi-review/references/execution-protocol.md"

# 見出し 1 つぶんを切り出す。ファイル全体への grep では「見出しを空にして規範を他所へ散らす」
# 退行が通ってしまい、それは節を SSOT にしていることそのものの退行である。
#
# `^#{1,2} ` を使わないのは、interval expression が macOS と Ubuntu の awk の間で移植性を
# 欠くため（tests/files.bats の同型スライスに合わせる）。`###` の小見出しはどちらのパターンにも
# 一致しないので、節を途中で終わらせない。
#
# **コードフェンスの中は見出し判定から外す。** この節が持つ待機コマンドは `# <RESULT_FILE> が
# 出るまで…` というシェルコメントで始まり、それは `^# ` に一致する。フェンスを追わないと節は
# そこで打ち切られ、以降の規範（前景待機の上限・到達点検査）を検査したつもりで検査しなくなる。
#
# TODO(#620 レビュー指摘): この fence-aware スライスは tests/files.bats:1047-1051 の同型実装の
# スーパーセットである。本来は tests/helpers/setup.bash へ `_skill_section` として昇格し、
# files.bats 側も置き換えるべきだが、files.bats は並列 wave の共有ファイルなので分離した PR で行う。
_md_section() {
  awk -v a="$2" '
    $0 == a { inside = 1; next }
    !inside { next }
    /^```/ { fence = !fence }
    !fence && (/^# / || /^## /) { exit }
    { print }
  ' "$1"
}

_contract_section() {
  _md_section "$SKILL_MD" '## turn を跨いで待たない（実行モデル契約）'
}

# 契約節の表から、第 1 セル（待つ対象）が $1 に一致する行を 1 本返す。
# 表全体への grep だと「どの対象にどの join を対応させるか」が検査から抜ける。
_join_row() {
  _contract_section | awk -v k="$1" -F'|' 'NF > 2 && $2 ~ k { print; exit }'
}

# 契約節のコードフェンスのうち、本文に $1 を含むものを 1 つ返す。
# 節全体への grep だと、別の場所に同じ語があるだけで通ってしまう。
_contract_fence() {
  _contract_section | awk -v k="$1" '
    /^```/ {
      if (inside) { if (buf ~ k) { printf "%s", buf; exit } ; inside = 0; buf = "" }
      else { inside = 1; buf = "" }
      next
    }
    inside { buf = buf $0 "\n" }
  '
}

@test "#585: 実行モデル契約の節が SKILL.md にあり、根拠が references から辿れる" {
  [ -f "$SKILL_MD" ]
  [ -f "$SINGLE_TURN_REF" ]
  # 前置きが無いと、reference を単体で開いた読み手が規範と根拠を取り違える
  # （wave-orchestrator / multi-review / sdd の references と同じ約束）。
  grep -qF 'これは根拠である' "$SINGLE_TURN_REF"

  local section
  section="$(_contract_section)"
  [ -n "$section" ] || { echo "契約の節が空か、見出しが動いた"; return 1; }
  # 導線は**契約節の中**にあること。SKILL.md 全体への grep だと、リンクを無関係な節へ
  # 移しても通り、規範とその根拠の接続が切れたことを検出できない。
  printf '%s' "$section" | grep -qF 'references/single-turn.md' || {
    echo "根拠への導線が契約節の外へ出た"; return 1
  }
}

@test "#585: 不変条件は AskUserQuestion を唯一の例外として書かれている" {
  local section
  section="$(_contract_section)"
  # 「バックグラウンドの結果待ちで終えない」だけだと、別の理由での中断が抜ける。
  # 「AskUserQuestion のときだけ」という閉じた形であることを見る。
  printf '%s' "$section" | grep -qF 'turn を終えてよいのは、`AskUserQuestion` で user の判断を待つときだけである'
  printf '%s' "$section" | grep -qF 'バックグラウンドの結果待ちで終えない'
  # 対話セッションの挙動を壊していないこと（GATE 1 / GATE 3 が例外側に入ると明記されている）。
  printf '%s' "$section" | grep -qF 'GATE 1・GATE 3 は `AskUserQuestion` なので例外側に入る'
}

@test "#585: 実行形態で分岐しない（未文書の識別子に規範を載せない）" {
  local section
  section="$(_contract_section)"
  printf '%s' "$section" | grep -qF '実行形態で分岐しない'

  # 契約として裏取りできていない内部識別子は、名前が変わった時点で何も言わずに効かなくなる。
  # 規範（SKILL.md）に載せてよいものではない。references/ 側は「なぜ採らないか」を述べる
  # ために名前を挙げるので、検査対象は SKILL.md に限る。
  #
  # `CLAUDECODE` は references が実行形態判定の識別子として名指ししているので必ず含める
  # （`CLAUDE_CODE_*` は別名なので、この 1 語を落とすと分岐の退行を検出できない）。
  local internal
  for internal in \
    CLAUDECODE \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS \
    CLAUDE_CODE_ENTRYPOINT \
    CLAUDE_CODE_CHILD_SESSION; do
    if grep -qF -- "$internal" "$SKILL_MD"; then
      echo "裏取りされていない内部識別子が規範に載っている: $internal"
      return 1
    fi
  done

  # references/ 側は名前を挙げるだけで終わらせず、採らない理由まで持つこと。
  # 理由が消えると、次の改訂で「実測で効いたのだから」と規範へ昇格しうる。
  grep -qF 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS' "$SINGLE_TURN_REF"
  grep -qF 'なぜ環境変数（1）を規範に書かないか' "$SINGLE_TURN_REF"
  grep -qF 'skill には設定する手段が無い' "$SINGLE_TURN_REF"
  # 「未文書だから」は #620 のレビューで撤回された誤った根拠。撤回の記録ごと消して
  # 元の主張へ戻す退行を防ぐ（理由 A は文書化の有無と無関係に成立する、が要点）。
  grep -qF '撤回した理由' "$SINGLE_TURN_REF"
  grep -qF '526-noninteractive-mode-research.prd.md' "$SINGLE_TURN_REF"
}

@test "#585: join の形が、待つ対象ごとに対応付けて書かれている" {
  # 語句の存在だけを見ると、CI 行を `gh pr checks --watch &` に変えても、
  # `run_in_background: false` を無関係な行へ移しても通ってしまう。行ごとに対応を見る。
  local row

  row="$(_join_row 'CI')"
  [ -n "$row" ] || { echo "CI の行が表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'gh pr checks --watch' || { echo "CI 行が --watch を指していない"; return 1; }
  printf '%s' "$row" | grep -qF '前景' || { echo "CI 行が前景実行を要求していない"; return 1; }
  # 「背景へ回さない」が消えると、`--watch &` への退行を止めるものが無くなる。
  printf '%s' "$row" | grep -qF 'へ回さない' || { echo "CI 行が背景化の禁止を失った"; return 1; }

  row="$(_join_row 'サブエージェント（Phase 1-4')"
  [ -n "$row" ] || { echo "サブエージェントの行が表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'run_in_background: false' || {
    echo "サブエージェント行が run_in_background: false を要求していない"; return 1
  }

  row="$(_join_row 'teammate')"
  [ -n "$row" ] || { echo "teammate の行が表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'ポーリング' || { echo "teammate 行が in-turn ポーリングを要求していない"; return 1; }
  printf '%s' "$row" | grep -qF '同じ turn' || { echo "teammate 行が同一 turn を要求していない"; return 1; }

  row="$(_join_row 'バックグラウンドの Bash')"
  [ -n "$row" ] || { echo "背景 Bash の行が表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'ポーリング' || { echo "背景 Bash 行が in-turn ポーリングを要求していない"; return 1; }
  printf '%s' "$row" | grep -qF '前景' || { echo "背景 Bash 行が前景待機を要求していない"; return 1; }
}

@test "#585: 前景待機の上限と、時間切れ後の続行が規範として書かれている" {
  local section fence
  section="$(_contract_section)"
  # 1 回分の上限（tool 側）と、「時間切れ = 待機の終わりではない」の両方。
  # 後者が抜けると、10 分で切れた時点で turn を跨ぐ待機へ戻る。
  printf '%s' "$section" | grep -qF '600000 ms'
  printf '%s' "$section" | grep -qF '同じ turn の中で待機コマンドをもう一度呼ぶ'
  # 総上限が数値であること。空欄だと「もう一度呼ぶ」が無制限に解釈され、1 turn の
  # 実行時間・コストが青天井になる。
  printf '%s' "$section" | grep -qE '1 Phase あたり最大 [0-9]+ 回'
  # 待機コマンドの形が有限であること（無限ループを書き写せないようにする）。
  fence="$(_contract_fence 'RESULT_FILE')"
  [ -n "$fence" ] || { echo "待機コマンドのコードフェンスが消えた"; return 1; }
  printf '%s' "$fence" | grep -qF 'deadline'
  printf '%s' "$fence" | grep -qF 'WAIT-INCOMPLETE'
}

@test "#585: 到達点検査が投稿者で絞り、CI 結論まで取っている" {
  local fence section
  # **同一コードフェンス内**で見る。節全体への grep だと、`gh pr view` と `reviews` が
  # 別々の場所にあるだけで通り、`reviews: 1` のような固定値への退行を素通りさせる。
  fence="$(_contract_fence 'gh pr view')"
  [ -n "$fence" ] || { echo "到達点検査のコードフェンスが消えた"; return 1; }
  printf '%s' "$fence" | grep -qF -- '--json reviews,statusCheckRollup' || {
    echo "到達点検査が reviews と statusCheckRollup を取っていない"; return 1
  }
  # 投稿者フィルタ。`.reviews | length` だけだと、CI ボットや第三者の review 1 件で
  # 「Phase 6 実行済み」と誤判定し、#585 が塞ごうとしている経路がそのまま残る。
  printf '%s' "$fence" | grep -qF 'select(.author.login ==' || {
    echo "到達点検査が投稿者で絞っていない（誰の review でも通ってしまう）"; return 1
  }
  printf '%s' "$fence" | grep -qF '| length' || { echo "件数の算出が消えた"; return 1; }
  printf '%s' "$fence" | grep -qF '.statusCheckRollup' || { echo "CI 結論の抽出が消えた"; return 1; }

  section="$(_contract_section)"
  printf '%s' "$section" | grep -qF 'GATE 3 へ進まず Phase 6 からやり直す'
  # 正常な no-op（指摘ゼロで返信の痕跡が残らない）を失敗にしないこと。
  printf '%s' "$section" | grep -qF '正常な no-op' || {
    echo "Phase 7 の no-op を失敗扱いしない規定が消えた"; return 1
  }
  # 自己検査の限界を隠さないこと。隠すと、起動側の独立検査（#615）が不要に見える。
  printf '%s' "$section" | grep -qF '規範ごと飛ばされたら一緒に飛ぶ'
  printf '%s' "$section" | grep -qF '#615'
}

@test "#585: Failure mode 表が、失敗条件だけでなく対処まで定めている" {
  # 左列だけを見ると、対処が「次の Phase へ進む」等に緩和されても通る。
  # それは規範の「静かな緩み」そのもので、このテストが防ぐべき退行の本体である。
  local row

  row="$(grep -E '^\| Phase 5〜7 の待機が総上限' "$SKILL_MD")"
  [ -n "$row" ] || { echo "待機上限の行が Failure mode 表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'turn を終えて通知を待たない' || {
    echo "待機上限の対処が turn 継続を許してしまっている"; return 1
  }
  printf '%s' "$row" | grep -qF 'user へエスカレート' || {
    echo "待機上限の対処が user へのエスカレーションを失った"; return 1
  }

  row="$(grep -E '^\| 到達点検査で `mine == 0` \|' "$SKILL_MD")"
  [ -n "$row" ] || { echo "到達点検査の行が Failure mode 表から消えた"; return 1; }
  printf '%s' "$row" | grep -qF 'GATE 3 へ進まず Phase 6 からやり直す' || {
    echo "到達点検査の対処が GATE 3 への進行を許してしまっている"; return 1
  }
  printf '%s' "$row" | grep -qF 'failure として user へ' || {
    echo "再実行しても 0 のときに failure にする規定が消えた"; return 1
  }
}

@test "#585: 待機が発生する Phase から契約へ導線がある" {
  # 契約の節だけにあっても、Phase 5 / 6 を読んでいる最中には届かない。#585 の 3 本が
  # 止まったのはまさにその 2 箇所である。
  local phase5 phase6
  phase5="$(_md_section "$SKILL_MD" '## Phase 5: CI 監視')"
  phase6="$(_md_section "$SKILL_MD" '## Phase 6: AI レビュー（multi-review）')"
  [ -n "$phase5" ] || { echo "Phase 5 の節が空か、見出しが動いた"; return 1; }
  [ -n "$phase6" ] || { echo "Phase 6 の節が空か、見出しが動いた"; return 1; }
  printf '%s' "$phase5" | grep -qF 'turn を跨いで待たない'
  printf '%s' "$phase6" | grep -qF '同じ turn の中で join'
}

@test "#585: join の規範が callee 側（multi-review）にも置かれている" {
  # 規範を caller（pr-workflow の委譲プロンプト）にだけ置くと、`/multi-review` を
  # standalone で、あるいは pr-workflow 以外の orchestrator から非対話で起動したときに
  # 一切効かず、#585 と同種の障害が再現する。実際に leg を起こして待つのは multi-review 側
  # なので、規範はそこに無ければならない。
  [ -f "$MULTI_REVIEW_PROTOCOL" ]
  local phase3
  phase3="$(_md_section "$MULTI_REVIEW_PROTOCOL" '## Phase 3: 結果収集と統合')"
  [ -n "$phase3" ] || { echo "multi-review の Phase 3 が空か、見出しが動いた"; return 1; }
  printf '%s' "$phase3" | grep -qF '同じ turn の中で完結' || {
    echo "multi-review Phase 3 が in-turn join を要求していない"; return 1
  }
  printf '%s' "$phase3" | grep -qF '完了通知を待って turn を終えない' || {
    echo "multi-review Phase 3 が turn を跨ぐ待ちの禁止を失った"; return 1
  }
  # 呼び出し元に依存しないこと（override として書き直されると standalone で効かなくなる）。
  printf '%s' "$phase3" | grep -qF '呼び出し元に依存しない' || {
    echo "multi-review Phase 3 の規範が呼び出し元依存へ退行した"; return 1
  }
  # SSOT は 1 か所。規範本体を multi-review へ複製せず pr-workflow を指すこと。
  printf '%s' "$phase3" | grep -qF 'pr-workflow' || {
    echo "multi-review Phase 3 が規範の SSOT を指していない"; return 1
  }
}

@test "#585: 規範は SKILL.md、実測は references/（肥大の再演を防ぐ）" {
  # #585 の実測（4 本中 3 本 / コミット 0 本）は根拠であって規範ではない。SKILL.md へ
  # 書き戻すと、skill 本文は毎セッション context に載るのでバイト数がそのままコストになる。
  local measurement
  for measurement in 'コミット 0 本' '4 本とも完走'; do
    if grep -qF -- "$measurement" "$SKILL_MD"; then
      echo "実測が SKILL.md に書き戻されている: $measurement"
      return 1
    fi
    grep -qF -- "$measurement" "$SINGLE_TURN_REF" || {
      echo "実測が references から失われている: $measurement"
      return 1
    }
  done
}
