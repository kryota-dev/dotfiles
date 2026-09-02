#!/usr/bin/env bats

# pr-workflow の実行モデル契約 (kryota-dev/dotfiles#585)。
#
# `pr-workflow` は「バックグラウンドへ投げて、結果を次の turn で受け取る」前提で書かれていた。
# `fh session launch` が起こす `claude -p` は 1 turn 実行なのでその次の turn が無く、子は
# 「完了通知が来次第 Phase 6 へ進めます」と述べて終わり、Phase 5〜7 が丸ごと実行されない。
# ターンはエラー無く終わるため `fh runs` には `succeeded` / `exitCode: 0` と記録され、
# **完走した実行と外形が一致する**（#573 が扱う検出の側）。
#
# ここで固定するのは、その規範が退行しないことである。失敗様式は「節が消える」ことよりも
# 「静かに緩む」ことなので、次の 4 つを別々に見る:
#
#   1. 不変条件そのもの（turn を終えてよいのは AskUserQuestion のときだけ）
#   2. join の形（規範の実体。これが消えると不変条件は守りようがなくなる）
#   3. 到達点検査（守られなかったことを検出する側。#573 の検出との接続点）
#   4. 未文書の内部識別子に規範を載せていないこと（名前が変わると静かに失効するため）

load helpers/setup

SKILL_MD="${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
SINGLE_TURN_REF="${HOME_DIR}/dot_agents/skills/pr-workflow/references/single-turn.md"

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
_skill_section() {
  awk -v a="$1" '
    $0 == a { inside = 1; next }
    !inside { next }
    /^```/ { fence = !fence }
    !fence && (/^# / || /^## /) { exit }
    { print }
  ' "$SKILL_MD"
}

_contract_section() {
  _skill_section '## turn を跨いで待たない（実行モデル契約）'
}

@test "#585: 実行モデル契約の節が SKILL.md にあり、根拠が references から辿れる" {
  [ -f "$SKILL_MD" ]
  [ -f "$SINGLE_TURN_REF" ]
  grep -qF 'references/single-turn.md' "$SKILL_MD"
  # 前置きが無いと、reference を単体で開いた読み手が規範と根拠を取り違える
  # （wave-orchestrator / multi-review / sdd の references と同じ約束）。
  grep -qF 'これは根拠である' "$SINGLE_TURN_REF"

  local section
  section="$(_contract_section)"
  [ -n "$section" ] || { echo "契約の節が空か、見出しが動いた"; return 1; }
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

  # 未文書の内部変数・内部識別子は、名前が変わった時点で何も言わずに効かなくなる。
  # 規範（SKILL.md）に載せてよいものではない。references/ 側は「なぜ採らないか」を
  # 述べるために名前を挙げるので、検査対象は SKILL.md に限る。
  local internal
  for internal in \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS \
    CLAUDE_CODE_ENTRYPOINT \
    CLAUDE_CODE_CHILD_SESSION; do
    if grep -qF -- "$internal" "$SKILL_MD"; then
      echo "未文書の内部識別子が規範に載っている: $internal"
      return 1
    fi
  done

  # references/ 側は名前を挙げるだけで終わらせず、採らない理由まで持つこと。
  # 理由が消えると、次の改訂で「実測で効いたのだから」と規範へ昇格しうる。
  grep -qF 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS' "$SINGLE_TURN_REF"
  grep -qF 'なぜ環境変数（1）を規範に書かないか' "$SINGLE_TURN_REF"
  grep -qF 'skill には設定する手段が無い' "$SINGLE_TURN_REF"
}

@test "#585: turn 内で join する形が、待つ対象ごとに書かれている" {
  local section
  section="$(_contract_section)"
  # CI: --watch を背景へ回さない
  printf '%s' "$section" | grep -qF 'gh pr checks --watch'
  # サブエージェント: Agent の既定は background なので、明示的に降ろす
  printf '%s' "$section" | grep -qF 'run_in_background: false'
  # バックグラウンド Bash（Codex leg 等）: 結果ファイルの出現を前景でポーリング
  printf '%s' "$section" | grep -qF '<RESULT_FILE>'
  printf '%s' "$section" | grep -qF 'ポーリング'
  # 1 回の前景待機の上限と、「時間切れ = 待機の終わり」ではないこと。ここが抜けると
  # 10 分で切れた時点で「待てなかった」と解釈され、turn を跨ぐ待機へ戻る。
  printf '%s' "$section" | grep -qF '600000 ms'
  printf '%s' "$section" | grep -qF '同じ turn の中で待機コマンドをもう一度呼ぶ'
}

@test "#585: 到達点を PR の外形から検査し、通らなければ GATE 3 へ進まない" {
  local section
  section="$(_contract_section)"
  # 自己申告ではなく外部状態を見る。件数の出どころ（gh pr view の reviews）まで固定する。
  printf '%s' "$section" | grep -qF 'gh pr view'
  printf '%s' "$section" | grep -qF 'reviews'
  printf '%s' "$section" | grep -qF 'GATE 3 へ進まず Phase 6 からやり直す'
  # 自己検査の限界を隠さないこと。隠すと、起動側の独立検査（#615）が不要に見える。
  printf '%s' "$section" | grep -qF '規範ごと飛ばされたら一緒に飛ぶ'
  printf '%s' "$section" | grep -qF '#615'
}

@test "#585: 待機の打ち切りと reviews == 0 が failure として扱われる" {
  # 待機上限に達したときに「次の Phase へ進む」で済ませられると、gate は静かに無効化される。
  # Failure mode 表に行があることを、表の外の散文ではなく行の形で見る。
  grep -qE '^\| Phase 5〜7 の待機が総上限に達した \|' "$SKILL_MD"
  grep -qE '^\| 到達点検査で `reviews == 0` \|' "$SKILL_MD"
}

@test "#585: 待機が発生する Phase から契約へ導線がある" {
  # 契約の節だけにあっても、Phase 5 / 6 を読んでいる最中には届かない。#585 の 3 本が
  # 止まったのはまさにその 2 箇所である。
  local phase5 phase6
  phase5="$(_skill_section '## Phase 5: CI 監視')"
  phase6="$(_skill_section '## Phase 6: AI レビュー（multi-review）')"
  [ -n "$phase5" ] || { echo "Phase 5 の節が空か、見出しが動いた"; return 1; }
  [ -n "$phase6" ] || { echo "Phase 6 の節が空か、見出しが動いた"; return 1; }
  printf '%s' "$phase5" | grep -qF 'turn を跨いで待たない'
  printf '%s' "$phase6" | grep -qF 'turn を跨いで待たない'
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
