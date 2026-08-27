#!/bin/bash
# 子セッションの状態を hook イベントから判定する (kryota-dev/dotfiles#437)。
#
# 記録側は home/dot_claude/executable_wave-session-event.sh。ここは記録された
# payload を読むだけで、tmux にもプロセス状態にも依存しない。だから単体テスト
# (tests/wave_orchestrator.bats) で固定できる。
#
# fail-safe 契約: 記録側は fail-open (セッションを止めない) だが、こちらは逆。
# イベントが読めないことを「稼働中」と解釈せず UNKNOWN を返す。停止の見落とし
# は沈黙するので、判定不能を正常と混同させない (#436 の教訓)。
#
# **到着順を時系列として扱わない**: hook はすべて async なので、書き込み順は
# 発生順と一致しない。かつて「ターン内は論理順序 (UserPromptSubmit <
# Notification < Stop) で判定する」形を採ったが、これは *Stop が 1 ターンに
# 最後の 1 回だけ来る* という誤った前提に乗っていた。サブエージェントへ委任した
# 親は一度 Stop を出し、同じ prompt_id のまま再開して AskUserQuestion を出す。
# any(Stop) を先に評価していたため、選択肢が開いて実際に止まっている子を
# IDLE と報告していた (#447 — 沈黙する故障)。
#
# そこで判定を論理順序から **集合の引き算** へ移した:
#
#   未回答 = { PreToolUse × AskUserQuestion の tool_use_id }
#          − { (PostToolUse ∪ PostToolUseFailure) × AskUserQuestion の tool_use_id }
#
# PostToolUse は成功時のみ発火する。決着イベントは PostToolUse と
# PostToolUseFailure の 2 種を対で見る (公式 hooks リファレンス)。
#
# **ただし Esc キャンセルは実測でどちらも発火しない** (#448 の実機検証で確認。
# Esc 後 30 秒待ってもイベントは 1 件も増えず、Stop すら出ない)。つまり
# 「人が Esc で閉じた」遷移だけはイベントから知る手段が無く、未回答が
# 永久に残る。この 1 点だけは send-to-pane.sh --dismiss が画面で閉鎖を
# 確認したうえで決着を書き戻して解除する (synthetic: "dismiss" の印が付く)。
#
# この述語は集合演算なので **イベントの到着順に一切依存しない**。評価順序が
# 意味を持つのは「未回答 と 停止 Notification を Stop より先に見る」ことだけで、
# これは停止を見落とさない側 (fail-safe) へ倒すための意図的な順序である。
#
# usage:
#   wave-events.sh --session <uuid> --state             # ASK_QUESTION | ASK_PERMISSION | RUNNING | IDLE | UNKNOWN
#   wave-events.sh --session <uuid> --question          # 現在ターン最後の選択肢を JSON で (回答済みでも返る)
#   wave-events.sh --session <uuid> --pending-question  # **未回答の**選択肢だけを JSON で
#   wave-events.sh --session <uuid> --pending-ids       # 未回答の "<tool_use_id>\t<prompt_id>"
#   wave-events.sh --session <uuid> --is-settled <id>   # その tool_use_id が決着済みか (0/1)
#   wave-events.sh --session <uuid> --record-dismissal  # Esc で閉じた質問の決着を書き戻す
#   wave-events.sh --session <uuid> --key-for <label>   # 選択肢に対応する <問い index>:<数字キー>
#   wave-events.sh --session <uuid> --purge             # 記録を削除する (wave 完了後)
#   wave-events.sh --self-check                         # 配線・記録先・直接実行可能性の確認
set -euo pipefail

EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
SETTINGS_FILE="${WAVE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# 「人が答えるまで止まる」通知。画面に描かれた文言は一切見ない (#435)。
#
# permission_prompt と agent_needs_input を分けているのは、auto mode での扱いが
# 違うから。permission_prompt は auto mode で自動承認され子は止まらない (#443)
# が、agent_needs_input は自動承認の対象ではないので auto mode でも止まる。
NOTIF_NEEDS_INPUT='^agent_needs_input$'
NOTIF_PERMISSION='^permission_prompt$'
# 「次の指示を待っている」通知。人が答えるべき問いではないので IDLE に分類する。
NOTIF_IDLE='^idle_prompt$'

# permission_prompt を自動承認する permission_mode。Notification payload には
# permission_mode が入らない (実測) ため、同じターンの他イベントから読む。
AUTO_APPROVE_MODES='["auto","bypassPermissions"]'

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

die() {
  echo "$1" >&2
  exit 2
}

# session_id はファイル名に連結される。記録側だけでなく読取側でも検証する
# (呼び出し側の値が外部入力に影響されても、イベントディレクトリの外を読ませない)。
validate_session() {
  printf '%s' "$1" | grep -qE "$UUID_RE" || die "session が UUID 形式でない"
}

event_file() {
  printf '%s/%s.jsonl' "$EVENT_DIR" "$1"
}

# 壊れた行は飛ばして読める分だけを返す。同一セッションへの同時 hook 書き込みは
# 直列化されていないため行が壊れうるが、1 行の破損で監視全体を止めない。
#
# **行単位でパースする**のが要点。`jq -c .` は JSON ストリームとして読むため
# 最初の壊れた行で停止し、それ以降の正常な行を一切出力しない。壊れた行が末尾に
# あるときだけ動く実装になっていた。-R + fromjson? なら位置に関わらず飛ばせる。
# shellcheck disable=SC2016  # jq のプログラム片なので shell 展開させない
read_events() {
  jq -R -c 'fromjson? // empty' "$1" 2>/dev/null || true
}

# 最新ターンのイベントだけを取り出す。prompt_id を持たない行は落とす。
#
# **「最後に到着した prompt_id」ではなく「初出が最も後の prompt_id」を最新とする**。
# hook は async なので到着順は発生順と一致しない。到着順で選ぶと、あるターンの
# 未回答 AskUserQuestion の後に別ターンの遅延 Stop が追記されただけで、遅延側の
# ターンが「最新」に選ばれ、停止中のセッションを IDLE と報告してしまう
# (#447 と同じ沈黙する故障をターン境界で再演する。実データで再現済み)。
#
# 遅延イベントは必ず**既存の**ターンに属するので、そのターンの初出位置は動かない。
# よって初出順で並べれば、どの順序でイベントが到着してもターンの選択は変わらない。
# これで「判定は到着順に依存しない」が、ターン内の述語だけでなくターンの選択
# まで含めて成立する。
latest_turn() {
  read_events "$1" | jq -sc '
    [ .[] | select(.prompt_id != null) ] as $evs
    | if ($evs | length) == 0 then []
      else
        # 各 prompt_id の初出 index を求め、その最大を持つ prompt_id を最新とする。
        ( [ $evs | to_entries[] | {pid: .value.prompt_id, i: .key} ]
          | group_by(.pid)
          | map({pid: .[0].pid, first: (map(.i) | min)})
          | max_by(.first) | .pid
        ) as $pid
        | [ $evs[] | select(.prompt_id == $pid) ]
      end
  '
}

# ターン内の判定に使う共通定義。
#
# open_questions が fail-safe な点に注意: tool_use_id を持たない PreToolUse は
# 決着と突き合わせられないので **未回答として残す**。決着信号が取れないことを
# 「回答済み」と解釈すると停止を見落とす。
# jq のプログラム片なので shell 展開させない (単一引用符が正しい)。
# shellcheck disable=SC2016
JQ_DEFS='
def ask_asks: [ .[] | select(.hook_event_name == "PreToolUse" and .tool_name == "AskUserQuestion") ];
def settled_ids:
  [ .[]
    | select((.hook_event_name == "PostToolUse" or .hook_event_name == "PostToolUseFailure")
             and .tool_name == "AskUserQuestion")
    | .tool_use_id
  ] | map(select(. != null));
def open_questions:
  settled_ids as $done
  | [ ask_asks[]
      | . as $e
      | select(($e.tool_use_id == null) or (($done | index($e.tool_use_id)) == null))
    ];
def has_notif($re):
  any(.[]; .hook_event_name == "Notification" and ((.notification_type // "") | test($re)));
def turn_modes: [ .[] | .permission_mode // empty ] | unique;
def auto_uniform($auto):
  (turn_modes | length) > 0 and ((turn_modes - $auto) | length) == 0;
'

# ターン内の状態を判定する。順序は fail-safe 方向に固定してある (冒頭のコメント参照)。
cmd_state() {
  local f turn st
  f="$(event_file "$1")"
  [ -s "$f" ] || {
    echo "UNKNOWN"
    return 0
  }
  turn="$(latest_turn "$f")"
  st="$(printf '%s' "$turn" | jq -r \
    --arg needs_input "$NOTIF_NEEDS_INPUT" \
    --arg perm "$NOTIF_PERMISSION" \
    --arg idle "$NOTIF_IDLE" \
    --argjson auto "$AUTO_APPROVE_MODES" \
    "$JQ_DEFS"'
    if length == 0 then "UNKNOWN"
    elif (open_questions | length) > 0 then "ASK_QUESTION"
    elif has_notif($needs_input) then "ASK_PERMISSION"
    elif has_notif($perm) and (auto_uniform($auto) | not) then "ASK_PERMISSION"
    elif any(.[]; .hook_event_name == "Stop" or .hook_event_name == "StopFailure") then "IDLE"
    elif has_notif($idle) then "IDLE"
    elif any(.[]; .hook_event_name == "UserPromptSubmit") then "RUNNING"
    else "UNKNOWN" end
  ' 2>/dev/null || true)"
  [ -n "$st" ] || st="UNKNOWN"
  echo "$st"
}

# 現在ターン最後の AskUserQuestion を返す。過去ターンの質問を掴まない
# (掴むと、前の質問の選択肢番号を今の画面へ送る事故になる)。
#
# **回答済みでも返る**点に注意。「今まさに答えるべき問い」が要るなら
# pending_question を使うこと。
current_question() {
  latest_turn "$1" | jq -c "$JQ_DEFS"'
    ask_asks | last | if . == null then empty else .tool_input end
  ' 2>/dev/null || true
}

# 未回答の AskUserQuestion だけを返す。監視と代理応答はこちらを使う。
pending_question() {
  latest_turn "$1" | jq -c "$JQ_DEFS"'
    open_questions | last | if . == null then empty else .tool_input end
  ' 2>/dev/null || true
}

# 未回答の AskUserQuestion を「<tool_use_id>\t<prompt_id>」で 1 行ずつ返す。
#
# Esc キャンセルは **hook イベントを一切出さない** (実機で確認)。そのため
# 「質問が閉じた」ことを記録できる主体は、閉鎖を画面で確認した送信側しかいない。
# send-to-pane.sh の --dismiss が決着を書き戻すために、その対象を引く。
#
# **prompt_id も返すのが要点**: latest_turn() は prompt_id が非 null の
# イベントだけを取り、最後の prompt_id で束ねる。prompt_id を欠いた行は
# ターンから丸ごと落ちるので、決着として書き戻しても state が解除されない
# (実機で踏んだ)。書き戻す側が同じ prompt_id を載せられるように渡す。
pending_ids() {
  latest_turn "$1" | jq -r "$JQ_DEFS"'
    open_questions[]
    | select(.tool_use_id != null and .prompt_id != null)
    | [.tool_use_id, .prompt_id] | @tsv
  ' 2>/dev/null || true
}

cmd_pending_ids() {
  local f ids
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  ids="$(pending_ids "$f")"
  [ -n "$ids" ] || die "未回答の選択肢が無い"
  printf '%s\n' "$ids"
}

# 指定した tool_use_id が決着済みかを返す (0=決着済み / 1=未回答)。
#
# 送信側が「送った選択が確定したか」を判定するために使う。state が
# ASK_QUESTION でなくなったことを完了と見なすと、UNKNOWN や RUNNING、
# 別理由の IDLE まで「確定した」と誤報告する。確定の根拠は
# **その tool_use_id に対応する決着イベントの存在**でなければならない。
cmd_is_settled() {
  local f open
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。決着を判定できない (UNKNOWN)"
  # jq はフィルタを 1 引数で受ける。オプションを先に置き、JQ_DEFS と本体は
  # シェルの文字列連結で 1 つのフィルタにする (cmd_state と同じ形)。
  # 「未回答に無い」だけを根拠にすると、綴り違い・別ターンの古い id まで
  # 決着済みと答えてしまう (fail-open)。現在ターンにその質問が実在することを
  # 先に確かめ、実在しない id は判定不能として拒否する。
  local known
  known="$(latest_turn "$f" | jq -r --arg t "$2" "$JQ_DEFS"'
    [ ask_asks[] | select(.tool_use_id == $t) ] | length
  ' 2>/dev/null || true)"
  [ -n "$known" ] || die "決着を判定できない"
  [ "$known" != "0" ] || die "現在ターンに tool_use_id=$2 の質問が無い。決着を判定できない"
  open="$(latest_turn "$f" | jq -r --arg t "$2" "$JQ_DEFS"'
    [ open_questions[] | select(.tool_use_id == $t) ] | length
  ' 2>/dev/null || true)"
  [ -n "$open" ] || die "決着を判定できない"
  [ "$open" = "0" ]
}

# Esc で閉じた質問の決着を書き戻す。決着イベントの JSON スキーマを知るのは
# このスクリプトだけに保つため、書き込みも読取と同じ場所に置く。
#
# **画面の確認は行わない**。閉鎖を確認するのは tmux を触れる送信側の責務で、
# ここは「確認できた事実を記録する」だけを担う。tmux にもプロセス状態にも
# 依存しないという性質は保たれる。
#
# 対象は **未回答のうち最後の 1 件**に限る。画面で閉鎖を確認できたのは表示中の
# 1 つだけであり、未回答集合を一括で決着させると、確認していない質問まで
# 解決済みにしてしまう (pending_question / --key-for が既に「最後の 1 件」を
# 前提に動いているので、ここも揃える)。
#
# 相関 ID を欠く未回答が対象になった場合は **書かずに非 0 で返す**。読取側の
# open_questions は tool_use_id 欠落を fail-safe で未回答として残すため、
# 書けないまま成功を報告すると固着したのに解除したと誤報告することになる。
cmd_record_dismissal() {
  local f target tuid pid line
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。決着を記録できない (UNKNOWN)"
  target="$(latest_turn "$f" | jq -c "$JQ_DEFS"'
    open_questions | last | if . == null then empty else . end
  ' 2>/dev/null || true)"
  [ -n "$target" ] || die "未回答の選択肢が無い。記録するものが無い"
  tuid="$(printf '%s' "$target" | jq -r '.tool_use_id // empty' 2>/dev/null || true)"
  pid="$(printf '%s' "$target" | jq -r '.prompt_id // empty' 2>/dev/null || true)"
  # prompt_id を欠くと latest_turn がこの行をターンから外し、決着として読まれない。
  [ -n "$tuid" ] && [ -n "$pid" ] || die "未回答の質問が相関 ID (tool_use_id / prompt_id) を欠く。決着を記録できない"
  line="$(jq -c -n --arg s "$1" --arg t "$tuid" --arg p "$pid" '
    {session_id: $s, prompt_id: $p, hook_event_name: "PostToolUseFailure",
     tool_name: "AskUserQuestion", tool_use_id: $t, synthetic: "dismiss"}
  ' 2>/dev/null || true)"
  [ -n "$line" ] || die "決着イベントを組み立てられない"
  ensure_event_dir || die "記録先を用意できない"
  umask 077
  printf '%s\n' "$line" >>"$f" || die "決着を書き戻せない"
  echo "記録: 決着 tool_use_id=${tuid}"
}

cmd_question() {
  local f q
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  q="$(current_question "$f")"
  [ -n "$q" ] || die "現在ターンに選択肢のイベントが無い"
  printf '%s\n' "$q"
}

cmd_pending_question() {
  local f q
  f="$(event_file "$1")"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  q="$(pending_question "$f")"
  [ -n "$q" ] || die "未回答の選択肢が無い"
  printf '%s\n' "$q"
}

# 選択肢ラベルに対応する「<問い index>:<数字キー>」を返す。
#
# **現在ターンかつ ASK_QUESTION かつ未回答の質問に限る**: 回答済み・過去ターンの
# 質問から番号を引くと、意図と別の選択肢を確定させる (あるいは選択肢が閉じた画面へ
# 裸の数字を打ち込む) 事故になる (#448 派生)。
#
# ラベルが複数の問いに出てくる場合は **曖昧として拒否する**。呼び出し側が
# どの問いに答えるつもりなのか決められないまま送るほうが危険だから。
#
# 数字キーが即確定するかは TUI のバージョンと選択肢の preview/notes の有無で
# 変わる (#441 実測)。だからここは番号を返すだけで、確定したかの検証は
# send-to-pane.sh 側が画面で行う。問い数や preview の有無から推論しない。
cmd_key_for() {
  local f label state out
  f="$(event_file "$1")"
  label="$2"
  [ -s "$f" ] || die "イベントが無い。検知できていない (UNKNOWN)"
  state="$(cmd_state "$1")"
  [ "$state" = "ASK_QUESTION" ] || die "現在このセッションは選択肢の応答待ちではない (state=$state)"
  out="$(pending_question "$f" | jq -r --arg label "$label" '
    if . == null then empty
    else
      [ (.questions // []) | to_entries[] as $q
        | ($q.value.options // []) | to_entries[]
        | select(.value.label == $label)
        | "\($q.key):\(.key + 1)"
      ] as $hits
      | if ($hits | length) == 0 then "NOT_PRESENTED"
        elif ($hits | length) > 1 then "AMBIGUOUS"
        else $hits[0] end
    end
  ' 2>/dev/null || true)"
  case "$out" in
    '' | null) die "未回答の質問を取得できない" ;;
    NOT_PRESENTED) die "現在の質問に提示されていない選択肢: $label" ;;
    AMBIGUOUS) die "複数の問いに同じラベルがある。曖昧なので拒否する: $label" ;;
  esac
  echo "$out"
}

# wave 完了後に記録を消す。payload は質問文と選択肢 (会話内容) を含むので、
# 作業が終わったら残さない。
cmd_purge() {
  local f
  f="$(event_file "$1")"
  rm -f "$f"
  echo "削除: $f"
}

# 記録先を安全な mode で用意する。hook 側の umask 077 は**既存**ディレクトリの
# mode を直さないため、こちらが先に 755 で作ってしまうと保護が崩れる。
ensure_event_dir() {
  (
    umask 077
    mkdir -p "$EVENT_DIR" 2>/dev/null
  ) || return 1
  chmod 700 "$EVENT_DIR" 2>/dev/null || true
}

# 検証できたことと、この時点では検証できないことを区別して報告する。
# 「未観測」を「検証済み」と言わないのが要点 (検知器の静かな故障を隠さない)。
cmd_self_check() {
  local ok=0

  if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1 &&
    jq -e '[.hooks[]?[]?.hooks[]?.command] | map(select(test("wave-session-event"))) | length > 0' \
      "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "配線: settings に hook が入っている"
  else
    echo "配線: settings に hook が見つからない — 停止は検知できない" >&2
    ok=1
  fi

  # 決着イベントの配線を個別に見る。これが無いと ASK_QUESTION が解除されず、
  # 状態遷移で駆動する監視が次の質問を取りこぼす (#448)。
  if [ -f "$SETTINGS_FILE" ] && command -v jq >/dev/null 2>&1 &&
    jq -e '[paths(scalars) as $p | select($p[-1] == "command" and (getpath($p) | test("wave-session-event")))
           | $p[1]] | unique as $k | (["PostToolUse","PostToolUseFailure"] - $k) | length == 0' \
      "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "決着イベント: PostToolUse / PostToolUseFailure が配線されている"
  else
    echo "決着イベント: 配線が足りない — 回答後も ASK_QUESTION が解除されない (#448)" >&2
    ok=1
  fi

  # SKILL.md は本スクリプトを直接実行する形で書かれている。chezmoi が実行ビットを
  # 落とすと exit 126 になり、呼び出し側が `|| echo UNKNOWN` で吸収すると
  # **全ポーリングが UNKNOWN に落ちる沈黙する故障**になる (#440)。bash 経由で
  # 叩ける限り self-check 自体は通ってしまうので、直接実行を明示的に試す。
  if [ -x "$0" ] && "$0" --probe >/dev/null 2>&1; then
    echo "直接実行: 可能 ($0)"
  else
    echo "直接実行: できない — SKILL.md の記述どおりに実行すると失敗する ($0)" >&2
    ok=1
  fi

  if ensure_event_dir && [ -w "$EVENT_DIR" ]; then
    echo "記録先: 書き込み可能 ($EVENT_DIR)"
  else
    echo "記録先: 書き込めない ($EVENT_DIR)" >&2
    ok=1
  fi

  local n
  n="$(find "$EVENT_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt 0 ]; then
    echo "イベント: ${n} セッション分を観測済み"
  else
    echo "イベント: 未観測（まだ子セッションが動いていないだけの可能性あり。検証はできていない）"
  fi

  return "$ok"
}

SESSION=""
ACTION=""
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --state | --question | --purge)
      ACTION="${1#--}"
      shift
      ;;
    --pending-question)
      ACTION="pending-question"
      shift
      ;;
    --pending-ids)
      ACTION="pending-ids"
      shift
      ;;
    --record-dismissal)
      ACTION="record-dismissal"
      shift
      ;;
    --is-settled)
      ACTION="is-settled"
      LABEL="${2:-}"
      shift 2
      ;;
    --key-for)
      ACTION="key-for"
      LABEL="${2:-}"
      shift 2
      ;;
    --self-check)
      ACTION="self-check"
      shift
      ;;
    # self-check が直接実行可能性を試すための最小 action。何もせず 0 で返る。
    --probe)
      ACTION="probe"
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

# probe は jq の有無に依存させない (実行ビットだけを見たいので)。
[ "$ACTION" = "probe" ] && exit 0

command -v jq >/dev/null 2>&1 || die "jq が必要"

case "$ACTION" in
  state | question | purge)
    [ -n "$SESSION" ] || die "--session は必須"
    validate_session "$SESSION"
    "cmd_${ACTION}" "$SESSION"
    ;;
  pending-question)
    [ -n "$SESSION" ] || die "--session は必須"
    validate_session "$SESSION"
    cmd_pending_question "$SESSION"
    ;;
  pending-ids)
    [ -n "$SESSION" ] || die "--session は必須"
    validate_session "$SESSION"
    cmd_pending_ids "$SESSION"
    ;;
  record-dismissal)
    [ -n "$SESSION" ] || die "--session は必須"
    validate_session "$SESSION"
    cmd_record_dismissal "$SESSION"
    ;;
  is-settled)
    [ -n "$SESSION" ] || die "--session は必須"
    [ -n "$LABEL" ] || die "--is-settled には tool_use_id が要る"
    validate_session "$SESSION"
    cmd_is_settled "$SESSION" "$LABEL"
    ;;
  key-for)
    [ -n "$SESSION" ] || die "--session は必須"
    [ -n "$LABEL" ] || die "--key-for にはラベルが要る"
    validate_session "$SESSION"
    cmd_key_for "$SESSION" "$LABEL"
    ;;
  self-check) cmd_self_check ;;
  *) die "--state / --question / --pending-question / --pending-ids / --is-settled / --record-dismissal / --key-for / --purge / --self-check のいずれかを指定すること" ;;
esac
