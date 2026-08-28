#!/bin/bash
# 子セッションへの送信 (kryota-dev/dotfiles#437 で hook ベースへ移行)。
#
# 送信そのものは tmux の操作だが、**何を送るか**はすべて hook イベントから決める。
# 画面テキストからセッションの状態や質問内容を読むことはしない (#435 / #436)。
#
# ## 画面参照の境界 (重要)
#
# capture-pane を使う用途を 2 つに分け、**片方だけ**を許容する。
#
#   許容: **自己検証可能な局所的事実**の確認 (UI の開閉・入力欄の残骸・確定済みの個数)
#         - 入力欄に本文が残っているか
#         - 選択肢 UI がまだ開いているか
#         - どの問いが確定済みか (確定マークの個数)
#   禁止: **セッション状態**の判定
#         - 停止しているか稼働中か / 何を問うているか
#         → wave-events.sh (hook payload) だけを根拠にする
#
# これが #437 の設計意図を壊さないのは、**失敗の方向が逆**だから。#435 / #436 は
# 「画面を見て状態を決め、合致しなければ稼働中と誤断定する」形で fail-open だった。
# ここでの画面参照は「送ってよいかを決め、確認できなければ送らない」形で
# fail-closed であり、TUI が変わったときに起きるのは機能停止であって無言の誤送信
# ではない。
#
# ### 画面には「誰も入力していない文字列」が出る (#472)
#
# TUI は入力欄が空のとき「次に送りそうな指示」をプレースホルダとして **ANSI dim
# 属性 (ESC[2m) で薄く描く**。`capture-pane -p` は色と属性を落とすので、これが
# 実入力とまったく同じ平文で返る。実測されたプレースホルダは直前の問いへの的確な
# 回答に見える文言だったため、内容からも見分けられなかった。
#
# 見分けずに「本文が入力欄に残っている」と読むと Enter を送ることになり、確定
# されるのは自分が送った本文ではなく **TUI が生成した提案文**になる。この skill が
# 設計目的に掲げる事故 (誰も答えていない指示が成果物に残る) と同じ性質で、経路が
# 違うだけ。
#
# よって画面は `-e` 付きで取得し、**dim 区間を落としてから**入力欄を判定する
# (capture_raw / input_box_has_body)。判定ロジックは 1 箇所に置く —— 呼び出し側へ
# 散らすと、誤った手順が SKILL.md や issue コメントへそのまま広まる。
#
# ## 送出は bracketed paste
#
# 以前は send-keys -l で本文を流し込んでいた。これは 2 通りに壊れた:
#   #442 長文で後続の確定キーを取りこぼし、本文が入力欄に残る (再送で二重入力)
#   #445 選択肢が開いたまま本文が**キー入力として解釈され**、誰も選んでいない
#        回答が確定した (この skill が設計目的に掲げる事故そのもの)
# bracketed paste なら TUI 側が「貼り付け」として扱うため、本文がキーとして
# 解釈されない。
#
# ## 送信結果は 3 値
#
# 成否の二値をやめた。UserPromptSubmit は**キュー経由で届いたメッセージでは
# 発火しない**ため (#448 / #450 実測)、これ単独では成否を判定できない。二値の
# ままでは稼働中の子への送信を必ず「失敗」と報告し、呼び出し側を二重キューへ
# 誘導する。
#
#   DELIVERED           送信され、ターン開始を確認できた            exit 0
#   QUEUED_UNCONFIRMED  本文は手元を離れたがターン開始は未確認      exit 10  <- 再送禁止
#   PENDING_CONFIRM     本文が入力欄に残っている                    exit 11  <- 本文の再送禁止
#   UNVERIFIED          送ったが確定を検証できない                  exit 2
#   (ガード失敗)        **何も送っていない**                        exit 1   <- 原因を直して再実行可
#
# 呼び出し側は exit code ではなく **標準出力の先頭トークン**で分岐すること。
# 「何かを送ったか」を知りたいだけなら exit 1 かどうかを見る。
#
# usage:
#   send-to-pane.sh <pane> --session <uuid> --select "<選択肢のラベル>"   # 1 問ぶん
#   send-to-pane.sh <pane> --session <uuid> --submit                      # 確認画面を確定
#   send-to-pane.sh <pane> --session <uuid> --dismiss                     # 選択肢を閉じる
#   send-to-pane.sh <pane> --session <uuid> --text "<自由記述の指示>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS="${WAVE_EVENTS_BIN:-${SCRIPT_DIR}/wave-events.sh}"
EVENT_DIR="${WAVE_EVENT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wave-orchestrator/events}"
# 送信後に確認が取れるまで待つ上限 (秒)
CONFIRM_TIMEOUT="${WAVE_CONFIRM_TIMEOUT:-10}"

# テストから差し替えられるようにする (キー送出の順序と回数を bats で固定するため)。
TMUX_BIN="${WAVE_TMUX_BIN:-tmux}"
PS_BIN="${WAVE_PS_BIN:-ps}"
PGREP_BIN="${WAVE_PGREP_BIN:-pgrep}"

# 選択肢 UI の検出マーカー。**TUI のバージョン差に耐えるよう共通部分だけを使う**。
# 実測した 2 バージョンのフッタは文言が違うが、いずれも "Enter to select" を含む:
#   旧: Enter to select . up/down to navigate . n to add notes . Tab to switch questions . Esc to cancel
#   新: Enter to select . Tab/Arrow keys to navigate . Esc to cancel
#
# 合致しなくなったときは「確認できない」として **送らずに落ちる** (fail-closed)。
# 状態判定に使っていないので、ここが壊れても停止の見落としにはならない。
OPTION_UI_MARKER="${WAVE_OPTION_UI_MARKER:-Enter to select}"
SUBMIT_MARKER="${WAVE_SUBMIT_MARKER:-Ready to submit}"
QUEUE_MARKER="${WAVE_QUEUE_MARKER:-Press up to edit queued messages}"
INPUT_PROMPT_MARKER="${WAVE_INPUT_PROMPT_MARKER:-❯}"
CONFIRMED_MARK="${WAVE_CONFIRMED_MARK:-☒}"

# ESC (0x1b)。capture-pane -e が返す属性シーケンスの解析に使う (#472)。
ESC=$'\033'

# bracketed paste は無効化できない。かつて env で落とせる逃げ道を置いていたが、
# -p は #445 (本文がキー入力として解釈され無断で回答が確定する) の対策の本体で
# あり、安全機構に off スイッチを持たせるべきではない。未対応環境では貼り付けを
# 諦めて送信を拒否する (fail-closed) 方が正しい。

die() {
  echo "$1" >&2
  exit 1
}

# source 側は executable_ プレフィックスを持つので chezmoi が 755 で配置する
# (#440)。よって bash を挟まず直接実行する。
events() {
  "$EVENTS" "$@"
}

tmux_cmd() {
  "$TMUX_BIN" "$@"
}

PANE="${1:-}"
[ -n "$PANE" ] || die "pane を指定すること"
shift

SESSION=""
MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --select | --text)
      MODE="${1#--}"
      ARG="${2:-}"
      shift 2
      ;;
    --submit | --dismiss)
      MODE="${1#--}"
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$SESSION" ] || die "--session は必須 (hook イベントの参照に要る)"
# session_id はイベントログのファイルパスに連結される。記録側・読取側と同じ検証を
# ここでも行う (多層防御)。現在は state_now() が先に走るので読取側の検証で間接的に
# 守られているが、それは「全モードで state_now が先に呼ばれる」という暗黙の前提に
# 依存した間接防御であり、モード追加や順序変更で静かに崩れる。
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
printf '%s' "$SESSION" | grep -qE "$UUID_RE" || die "session が UUID 形式でない"
[ -n "$MODE" ] || die "--select / --submit / --dismiss / --text のいずれかを指定すること"
case "$MODE" in
  select | text) [ -n "$ARG" ] || die "--${MODE} には値が要る" ;;
esac

# ペインとセッションの結び付きを実プロセスで検証する。ここを省くと、A のイベント
# から得た番号を B のペインへ送れてしまう (送信先の取り違え)。セッション終了後の
# shell へ本文がコマンドとして流れ込むのも防ぐ。
#
# **起動形式は 2 つある**。--session-id <uuid> で起動したセッションを終了して
# --resume <uuid> で再開すると、argv から --session-id が消える。片方しか見て
# いなかったため、再開後の wave では代理応答が一切通らなかった (#471)。
# ガード自体は正しいので外さない。直すのは検出条件の網羅性だけ。
#
# **プロセスの位置も 2 通りある**。ペインを対話 shell 経由で立てると claude は
# pane_pid の子になるが、tmux にコマンドを直接渡すと sh が exec で置き換わり
# **pane_pid 自身が claude** になる (実機で確認)。子だけを見ていると後者で
# 「動いていない」と誤判定するので、pane_pid 自身も照合する。
#
# なお `pgrep -P` は **自分自身とその祖先を既定で除外する** (man pgrep の -a)。
# 送信元セッションが自分のペインを対象にすると、ps は親子関係を返すのに pgrep は
# 空を返す。Leader は子ペインを対象にするため実運用では当たらないが、ガードを手で
# 検証するときは必ず別のペインを対象にすること。
assert_pane_runs_session() {
  local shell_pid pid args
  shell_pid="$(tmux_cmd display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$shell_pid" ] || die "ペインが見つからない: $PANE"
  # pane_pid 自身 → その子。どちらかが当該セッションなら生存。
  for pid in "$shell_pid" $("$PGREP_BIN" -P "$shell_pid" 2>/dev/null || true); do
    args="$("$PS_BIN" -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"--session-id $SESSION"* | *"--resume $SESSION"*) return 0 ;;
    esac
  done
  die "ペイン $PANE で session $SESSION が動いていない (終了済み / ID 取り違えの可能性)。送信中止"
}

# --- 画面参照 (自己検証可能な局所的事実の確認にのみ使う) -------------------

# 画面を取得する。**失敗と「取れたが空」を区別する**のが要点。
# かつて `|| true` で失敗を握り潰していたため、tmux が失敗すると空文字が返り、
# 「選択肢 UI が無い = 閉じた」と解釈されて、実際には選択肢が残っていても
# 決着を書き戻してしまった (fail-closed 設計に空いた fail-open の穴)。
# 取得できなかったことは呼び出し側で必ず非 0 として扱う。
# **-e を付けて属性ごと取る**のが要点 (#472)。色を落とした画面では、TUI が dim で
# 描くプレースホルダと実入力を区別できない。属性が要るのは入力欄の判定だけだが、
# 取得を 2 回に分けると 2 時点の画面を混ぜることになるので、取得は 1 本にして
# 用途ごとに整形する (capture が文言マッチ用、こちらが属性つきの生データ)。
#
# `-e` を解さない tmux では capture-pane 自体が失敗し、呼び出し側は fail-closed へ
# 落ちる (何も送らない)。属性を読めないまま平文として扱う経路は作らない。
capture_raw() {
  tmux_cmd capture-pane -p -e -t "$PANE" 2>/dev/null
}

# 文言マッチに使う素のテキスト。属性シーケンスを落として `-e` 以前と同じ形に戻す。
# マーカー照合に属性が混ざると、TUI が文言の途中で色を変えた瞬間にマッチしなく
# なる (fail-closed に落ちて送信できなくなる) ため、ここで必ず落とす。
capture() {
  local raw
  raw="$(capture_raw)" || return 1
  printf '%s\n' "$raw" | strip_ansi
}

# CSI シーケンス (ESC[ ... 英字) を落とす。capture-pane -e が返すのは色と属性なので
# これで足りる。
strip_ansi() {
  LC_ALL=C sed "s/${ESC}\[[0-9;:?]*[a-zA-Z]//g"
}

# 選択肢 UI (番号を選ぶ画面) が出ているか。**確認画面は含めない**。
# かつて SUBMIT_MARKER も true にしていたため、--select のガードが最終確認画面を
# 通過し、確認画面へ裸の数字キーを送れてしまった。確認画面の確定は --submit の
# 責務なので、両者を明確に分ける。
option_ui_open() {
  case "$1" in
    *"$OPTION_UI_MARKER"*) return 0 ;;
  esac
  return 1
}

# 選択肢 UI と確認画面のいずれかが出ているか。--dismiss は「質問に関する UI が
# 画面から消えたこと」を確認したいので、両方を対象にする。
question_ui_open() {
  option_ui_open "$1" && return 0
  submit_screen_open "$1" && return 0
  return 1
}

submit_screen_open() {
  case "$1" in
    *"$SUBMIT_MARKER"*) return 0 ;;
  esac
  return 1
}

queue_shown() {
  case "$1" in
    *"$QUEUE_MARKER"*) return 0 ;;
  esac
  return 1
}

# 確定済みの問いの個数。複数問の TUI はタブ見出しに確定マークを描くので、
# 「自分の操作がどこまで進んだか」をこれで数える。単一問では 0 のまま。
confirmed_count() {
  local n
  n="$(printf '%s' "$1" | grep -o "$CONFIRMED_MARK" 2>/dev/null | wc -l | tr -d ' ')" || n=0
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# 入力欄の行を **capture_raw の出力から** 1 行だけ取り出し、プレースホルダを
# 除いた素のテキストにして返す (#472)。引数は属性つきの生画面。
#
# 手順は 2 段階で、**順序に意味がある**:
#
#   1. 属性を落とした形で「最後の入力プロンプト行」を選ぶ
#   2. その行の dim (ESC[2m) 以降を捨ててから属性を落とす
#
# 先に dim を捨てると、行全体が dim のときその行ごと消える。すると tail が
# **会話領域にエコーされた過去の送信本文**（行頭が同じプロンプトマーカー）を
# 掴み、入力欄と取り違えて「本文が残っている」と誤判定する。
#
# dim 以降を行末まで捨てるのは、プレースホルダが入力欄の末尾を占めるから。
# 実入力があるときプレースホルダは描かれないので、両者が同じ行に混在しない。
#
# 出力は必ず 1 行で、先頭トークンが結果を表す (`NONE` / `LINE<行>`)。**「出力が
# 空」を「入力欄が空」と読ませない**ため —— awk が無い・落ちた・PATH が壊れて
# いるといった判定器側の失敗も空文字になるので、区別できないと呼び出し側が
# 「実入力なし」と「判定できない」を混同する。
input_box_line() {
  LC_ALL=C awk -v esc="$ESC" -v marker="$INPUT_PROMPT_MARKER" '
    function plain(s) { gsub(esc "\\[[0-9;:?]*[a-zA-Z]", "", s); return s }
    { if (plain($0) ~ ("^[ \t]*" marker)) last = $0 }
    END {
      if (last == "") { print "NONE"; exit 0 }
      sub(esc "\\[2m.*$", "", last)
      print "LINE" plain(last)
    }
  '
}

# 入力欄に**人が入力した本文**が残っているか。最後の入力プロンプト行の、マーカー
# 以降に非空白があれば「残っている」と見なす。**送信済みの本文が会話領域に
# エコーされている**ことと区別するため、行頭がプロンプトマーカーの行だけを見る。
#
# プレースホルダ (dim) は本文と見なさない (#472)。
#
# 戻り値は 4 値: **0=実入力あり / 1=入力欄は空 / 2=判定不能 / 3=適用不可**。
#
# 実運用で、その場で書かれた判定ワンライナーが 4 通り壊れた。**4 通りとも
# 「実入力（＝送ってよい）」側へ落ちた** (fail-open):
#
#   1. `grep -q $'\033\[2m'` —— zsh のクォート解釈で `\[` がリテラル化し、grep が
#      パースエラーで非 0。`if` が else に落ちて「dim が無い ＝ 実入力」と判定した
#   2. `capture-pane -p -e | grep "S0 " | head -1` —— 入力欄ではなく画面に残って
#      いた**報告本文**の行にマッチした。その行に dim は無いので「実入力」と判定した
#   3. `sed` が illegal byte sequence (マルチバイト) で失敗し、本文が空と判定された
#   4. 選択肢 UI (AskUserQuestion) の**選択中の項目を指すカーソル**も `❯` で描かれる。
#      入力欄マーカーと取り違え、選択肢のラベルを「user が入力した本文」と報告した
#
# 共通するのは「判定器が失敗したとき、または対象を取り違えたときに、送信を許す側へ
# 落ちる」こと。よってこの関数は **失敗を必ず『送るな』へ写像する**ことを最優先に
# する。具体的には:
#
#   (a) 対象行を入力欄の行に限定する (画面全体を grep しない)         → 誤り 2
#   (b) 判定器が失敗したら 2 を返す。0 として返す経路を作らない       → 誤り 1
#   (c) バイト単位で処理する (LC_ALL=C)。ロケール依存の失敗を作らない → 誤り 3
#   (d) 選択肢 / 確認 UI が開いている間は**判定そのものを行わない**   → 誤り 4
#
# (d) は状態でも画面でも見る。`--state` が RUNNING / IDLE でないとき (ASK_QUESTION /
# ASK_PERMISSION / UNKNOWN) は入力欄を読まない —— 状態が確定していないまま画面を
# 読むと、今回のように別の UI 要素を拾う。呼び出し側は `--text` の入口でも状態を
# 見ているが、貼り付けから確認までの間に子が新しい質問を開くことがあるので、
# 読む直前にもう一度見る。
input_box_has_body() {
  local out rest plain st
  # (d) 選択肢 UI / 確認画面が出ている間は入力欄を判定しない (適用不可)。
  plain="$(printf '%s\n' "$1" | strip_ansi)"
  if question_ui_open "$plain"; then
    return 3
  fi
  # (d) 状態が確定していないときも読まない。
  st="$(state_now)"
  case "$st" in
    RUNNING | IDLE) ;;
    *) return 3 ;;
  esac
  out="$(printf '%s\n' "$1" | input_box_line)" || return 2
  case "$out" in
    # 入力欄の行そのものが見つからない。空だったのか画面が取れなかったのかを
    # 区別できないので、空とは言わない。
    NONE) return 2 ;;
    LINE*) ;;
    # 想定外の出力 = 判定器が期待どおり動いていない。
    *) return 2 ;;
  esac
  rest="${out#LINE}"
  rest="${rest#*"${INPUT_PROMPT_MARKER}"}"
  # 内容ガード (irreversible_instruction) が読めるように、空白除去前の本文を残す。
  INPUT_BOX_BODY="$rest"
  rest="${rest//[[:space:]]/}"
  [ -n "$rest" ]
}

# 入力欄から取り出した本文。input_box_has_body が設定する。
INPUT_BOX_BODY=""

# 取り消せない / 取り消しが目立つ操作を指示する本文か。
#
# **実入力と判定できても自動では確定しない**ための最後の砦 (#472)。プレースホルダは
# 「セッションが直前に尋ねた問いへの回答」だけでなく、**マージのような不可逆操作を
# 提案してくる**ことが実測されている（PR のレビューを終えた子の入力欄に
# `❯ #478 をマージして` が dim で描かれていた。user は一度も入力していない）。
#
# これは安全原則 1（マージは代理しない）に対する実効的な迂回路になる。orchestrator は
# 「user が入力したが Enter を押していない」と読み、内容が妥当に見えるぶん自分では
# 気付けない。**内容が妥当に見えるかどうかで送信可否を決めてはならない。**
#
# dim 判定は必要条件であって十分条件ではない。判定が正しくても、その入力が user の
# 意図である保証にはならない（入力途中で放置された / 別の話題への入力の可能性）。
# よってここは env で無効化できるようにしない（安全機構に off スイッチを持たせない）。
IRREVERSIBLE_RE='(マージ|merge|force[- ]?push|push --force|--force-with-lease|クローズ|close|リリース|release|デプロイ|deploy)'

irreversible_instruction() {
  printf '%s' "$1" | LC_ALL=C grep -qiE "$IRREVERSIBLE_RE"
}

# 現在までの UserPromptSubmit の件数。
#
# **これは「プロンプトが投入された」件数であって「user が入力した」件数ではない。**
# harness がセッションへ注入する <task-notification> ブロック (バックグラウンドタスクの
# 完了通知) も同じイベントを発火させる。実測 68 件中 28 件が task-notification で、
# **唯一の UserPromptSubmit が task-notification だったセッションが 7 件**あった。
#
# よって「増分がある = 自分の本文が届いた」とは厳密には言えない (貼り付け直後に背景通知が
# 届けば増える)。失敗の向きは「配信済みと報告して再送しない」= 送らない側なので致命的では
# ないが、**この件数を『user が何かを送った』証拠として使う実装を足さないこと**。
count_prompt_submits() {
  local f n
  f="${EVENT_DIR}/${SESSION}.jsonl"
  [ -s "$f" ] || {
    echo 0
    return 0
  }
  # grep -c は 0 件でも "0" を出力して exit 1 を返す。`|| echo 0` を足すと
  # 0 が二重に出て以降の整数比較が壊れるので、出力を捨てて数え直さない。
  n="$(grep -c '"hook_event_name":"UserPromptSubmit"' "$f" 2>/dev/null)" || n=0
  [ -n "$n" ] || n=0
  echo "$n"
}

state_now() {
  events --session "$SESSION" --state 2>/dev/null || echo UNKNOWN
}

# 送信対象の質問が決着したかを、**その tool_use_id の決着イベント**で判定する。
#
# かつて「state が ASK_QUESTION でなくなったこと」を完了と見なしていたため、
# UNKNOWN / RUNNING / 別理由の IDLE まで「確定した」と誤報告していた。確定の根拠は
# 送った選択に対応する決着イベントの存在でなければならない。
#
# TARGET_TOOL_USE_ID は送信前に固定する (送信後に引き直すと、次の質問の id を
# 掴んでしまう)。固定できていない場合は判定不能として非 0 を返す。
TARGET_TOOL_USE_ID=""

settled() {
  [ -n "$TARGET_TOOL_USE_ID" ] || return 1
  events --session "$SESSION" --is-settled "$TARGET_TOOL_USE_ID" >/dev/null 2>&1
}

# --- 送出 -----------------------------------------------------------------

# 本文を bracketed paste で流し込む。send-keys -l を使わないのが要点 (#442 / #445)。
# 選択肢の閉鎖を**画面で確認したうえで**、決着イベントの記録を wave-events.sh へ
# 委譲する。
#
# **なぜ委譲するのか**: 決着イベントの JSON スキーマは記録側 (射影) と読取側
# (JQ_DEFS の消費) が既に持っている。ここで 3 箇所目としてゼロから組み立てると、
# 読取側が要求するフィールド集合を変えたときに、ここは構造的に追随を強制されない。
# スキーマを知るのは wave-events.sh だけに保ち、こちらは「閉鎖を確認できた」という
# 事実を伝えるだけにする。画面を見るのは tmux を触れるこちらの責務なので、
# 責務境界は変わらない (確認はここ / 記録はあちら)。
#
# **なぜ書き戻しが必要なのか**: Esc キャンセルは hook イベントを一切発火させない
# (実機で確認)。Escape を送って閉じた場合も同じ。書き戻さないと state が
# ASK_QUESTION に固着し、--select は「UI が無い」、--text は「選択肢が開いている」、
# --purge 後は「UNKNOWN」で拒否され、Leader が完全に手詰まりになる。
record_dismissal() {
  events --session "$SESSION" --record-dismissal >/dev/null 2>&1
}

# 本文から制御文字を除去する (改行とタブは残す)。
#
# **bracketed paste だけでは本文をキー入力から隔離できない**。本文中に paste の
# 終端シーケンス ESC [ 201 ~ が含まれていると、受け手はそこで paste モードを抜け、
# 以降のバイトを通常のキー入力として解釈する。実機検証で、この経路から埋め込んだ
# コマンドが実際に実行されることを確認した (使い捨ての tmux セッションで再現)。
#
# これは tmux の実装バグではなく xterm bracketed paste protocol の仕様どおりの
# 挙動で、protocol に忠実な consumer ほど同じ弱点を持つ。よって送る側で ESC を
# 落とすしかない。ANSI 色付きのログ抜粋を転記する用途を壊さないよう、拒否では
# なく除去にして、除去したことは呼び出し側へ報告する。
sanitize_body() {
  # C0 制御文字のうち改行 (\n) と水平タブ (\t) 以外を落とす。
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

paste_body() {
  local body="$1" buf clean removed
  clean="$(printf '%s' "$body" | sanitize_body)"
  if [ "$clean" != "$body" ]; then
    removed=$(($(printf '%s' "$body" | LC_ALL=C wc -c) - $(printf '%s' "$clean" | LC_ALL=C wc -c)))
    echo "注意: 本文から制御文字を ${removed} バイト除去した (paste 境界の注入を防ぐため)" >&2
  fi
  buf="wave-$$-${RANDOM}"
  printf '%s' "$clean" | tmux_cmd load-buffer -b "$buf" - ||
    die "本文をバッファへ読み込めなかった。何も送っていない"
  # -d は貼り付け後にバッファを消す (利用者のバッファを汚さない)。
  # -p は bracketed paste。無効化する経路は持たない (安全機構なので)。
  if ! tmux_cmd paste-buffer -d -p -b "$buf" -t "$PANE"; then
    # 貼り付けに失敗するとバッファに本文が残る。利用者のバッファを汚さないよう消す。
    tmux_cmd delete-buffer -b "$buf" 2>/dev/null || true
    die "本文を貼り付けられなかった。何も送っていない"
  fi
}

send_key() {
  tmux_cmd send-keys -t "$PANE" "$@"
}

# 条件が成立するまで待つ。成立したら 0、時間切れなら 1。
wait_until() {
  local deadline
  deadline=$((SECONDS + CONFIRM_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

assert_pane_runs_session

case "$MODE" in

  dismiss)
    st="$(state_now)"
    if [ "$st" != "ASK_QUESTION" ]; then
      echo "ALREADY_DISMISSED 選択肢の応答待ちではない (state=$st)。何も送っていない"
      exit 0
    fi
    # 画面が取得できなければ閉鎖を確認できない。「取れなかった」を「閉じた」と
    # 解釈すると、選択肢が残っているのに決着を書き戻す fail-open になる。
    cap="$(capture)" ||
      die "画面を取得できない。閉鎖を確認できないので中止 (何も送っていない)"
    if ! question_ui_open "$cap"; then
      # 人が Esc で閉じた場合がここに来る。イベントが出ないので state だけが
      # 取り残されている。閉鎖は画面で確認できているので決着を書き戻して回復する。
      if record_dismissal; then
        echo "ALREADY_CLOSED 選択肢は既に閉じていた (Esc 等)。決着を記録して state を解除した"
        exit 0
      fi
      echo "UNVERIFIED 選択肢は閉じているが決着を記録できなかった。state は ASK_QUESTION のまま" >&2
      exit 2
    fi
    if submit_screen_open "$cap"; then
      die "確認画面が出ている。Escape の行き先が曖昧なので中止。Cancel を明示的に選ぶこと (何も送っていない)"
    fi
    send_key Escape || die "Escape を送れなかった"
    ui_closed() {
      local c
      # 取得できなければ「閉じた」と判定しない (fail-closed)。
      c="$(capture)" || return 1
      if question_ui_open "$c"; then return 1; fi
      return 0
    }
    if wait_until ui_closed; then
      # Escape も hook イベントを出さないので、ここでも書き戻さないと固着する。
      if record_dismissal; then
        echo "CLOSED 選択肢を閉じ、決着を記録した"
        exit 0
      fi
      echo "UNVERIFIED 選択肢は閉じたが決着を記録できなかった。state は ASK_QUESTION のまま" >&2
      exit 2
    fi
    echo "UNVERIFIED Escape を送ったが選択肢 UI が閉じたことを確認できない。本文は送っていない" >&2
    exit 2
    ;;

  select)
    st="$(state_now)"
    [ "$st" = "ASK_QUESTION" ] || die "選択肢の応答待ちではない (state=$st)。送信中止"
    # 送信対象の tool_use_id を**送る前に**固定する。送信後に引き直すと、確定して
    # 次の質問が開いた後にその id を掴み、決着していないものを決着と読み違える。
    TARGET_TOOL_USE_ID="$(events --session "$SESSION" --pending-ids 2>/dev/null | head -1 | cut -f1)"
    [ -n "$TARGET_TOOL_USE_ID" ] ||
      die "未回答の質問の tool_use_id を特定できない。確定を検証できないので中止 (何も送っていない)"
    cap="$(capture)" ||
      die "画面を取得できない。選択肢 UI の実在を確認できないので中止 (何も送っていない)"
    # Esc で閉じた後も wave-events.sh の条件は成立しうる。選択肢 UI が実在する
    # ことを確かめないと、閉じた画面へ**裸の数字が入力欄に打ち込まれる** (#448 派生)。
    if ! option_ui_open "$cap"; then
      die "選択肢 UI を画面で確認できない。数字キーが入力欄へ入る危険があるので中止 (何も送っていない)"
    fi
    # 最終確認画面では番号を選ぶのではなく Enter で確定する。ここへ裸の数字を送ると
    # 意図しない操作になるので、--select は確認画面を明示的に拒否する (確定は --submit)。
    if submit_screen_open "$cap"; then
      die "画面は最終確認 (${SUBMIT_MARKER}) を表示している。数字キーではなく --submit を使うこと (何も送っていない)"
    fi

    before_confirmed="$(confirmed_count "$cap")"
    # 現在ターンの未回答の質問に限って番号を引く。過去ターン・回答済みからは引かない。
    key_spec="$(events --session "$SESSION" --key-for "$ARG")" || die "選択肢を特定できない。送信中止"
    qidx="${key_spec%%:*}"
    num="${key_spec##*:}"
    # 1 問ずつ順に答える前提なので、確定済みの個数が今答えるべき問いの index になる。
    [ "$qidx" = "$before_confirmed" ] ||
      die "指定した選択肢は問い ${qidx} のものだが、画面は問い ${before_confirmed} を表示している。1 問ずつ順に送ること (何も送っていない)"

    # **数字キーのみを送る。** claude 2.1.221 以降は数字キーが確定して次の問いへ
    # 進むため、続けて Enter を送ると**次の問いの既定値を確定させる** (#441 実測)。
    # 確定するかは問い数ではなく選択肢の preview/notes の有無で変わるので、
    # キー列を固定せず「送って検証する」形にしてある。
    send_key -l "$num" || die "数字キーを送れなかった"

    advanced() {
      local c
      # 取得できなければ「進んだ」と判定しない (fail-closed)。
      c="$(capture)" || return 1
      if [ "$(confirmed_count "$c")" -gt "$before_confirmed" ]; then return 0; fi
      if submit_screen_open "$c"; then return 0; fi
      return 1
    }
    confirmed_or_done() {
      if settled; then return 0; fi
      advanced
    }

    if wait_until confirmed_or_done; then
      if settled; then
        echo "CONFIRMED_CALL_COMPLETE 選択を確定し、呼び出し全体が完了した: ${ARG} (問い ${qidx}, key=${num})"
      else
        echo "CONFIRMED_MORE 選択を確定した。続きの問いがある: ${ARG} (問い ${qidx}, key=${num})"
      fi
      exit 0
    fi

    # 数字キーで確定しない TUI / 選択肢 (preview 付き等) では Enter が要る。
    # **1 回だけ**送る。投機的に複数送ると次の問いを既定値で確定させる。
    send_key Enter || die "確定キーを送れなかった"
    if wait_until confirmed_or_done; then
      if settled; then
        echo "CONFIRMED_CALL_COMPLETE 選択を確定し、呼び出し全体が完了した (Enter 併用): ${ARG}"
      else
        echo "CONFIRMED_MORE 選択を確定した。続きの問いがある (Enter 併用): ${ARG}"
      fi
      exit 0
    fi
    echo "UNVERIFIED 数字キー ${num} と Enter を送ったが確定を検証できない。画面を確認すること" >&2
    exit 2
    ;;

  submit)
    TARGET_TOOL_USE_ID="$(events --session "$SESSION" --pending-ids 2>/dev/null | head -1 | cut -f1)"
    [ -n "$TARGET_TOOL_USE_ID" ] ||
      die "未回答の質問の tool_use_id を特定できない。確定を検証できないので中止 (何も送っていない)"
    cap="$(capture)" ||
      die "画面を取得できない。確認画面の実在を確認できないので中止 (何も送っていない)"
    if ! submit_screen_open "$cap"; then
      die "確認画面 (${SUBMIT_MARKER}) を画面で確認できない。中止 (何も送っていない)"
    fi
    send_key Enter || die "確定キーを送れなかった"
    if wait_until settled; then
      echo "CONFIRMED_CALL_COMPLETE 確認画面を確定した"
      exit 0
    fi
    echo "UNVERIFIED Enter を送ったが呼び出しの完了を検証できない。画面を確認すること" >&2
    exit 2
    ;;

  text)
    st="$(state_now)"
    case "$st" in
      RUNNING | IDLE) ;;
      ASK_QUESTION)
        # 暗黙に Escape を送って状態を変えない。効かなかったときに本文が
        # キー入力として解釈され、誰も選んでいない回答が確定する (#445)。
        die "選択肢が開いている (state=ASK_QUESTION)。先に --dismiss で明示的に閉じること (何も送っていない)"
        ;;
      ASK_PERMISSION)
        die "権限確認で停止している (state=ASK_PERMISSION)。自由記述で答える場面ではないので中止 (何も送っていない)"
        ;;
      *)
        die "状態を検知できない (state=$st)。送信中止 (何も送っていない)"
        ;;
    esac

    before="$(count_prompt_submits)"
    paste_body "$ARG"
    send_key Enter || die "確定キーを送れなかった"

    submitted() {
      [ "$(count_prompt_submits)" -gt "$before" ]
    }

    if wait_until submitted; then
      echo "DELIVERED 送信を確認した (UserPromptSubmit)"
      exit 0
    fi

    # UserPromptSubmit はキュー経由の配信では発火しない (#450 実測)。ここから先は
    # 「自分の本文が入力欄を離れたか」だけを画面で見る。セッション状態は見ない。
    # 入力欄の判定には属性つきの画面が要る (#472)。同じ 1 回の取得から、文言
    # マッチ用の素のテキストを派生させる (2 回取ると別時点の画面を混ぜてしまう)。
    raw="$(capture_raw)"
    cap="$(printf '%s\n' "$raw" | strip_ansi)"
    if queue_shown "$cap"; then
      echo "QUEUED_UNCONFIRMED キューに入った。ターン開始は未確認。**再送しないこと** (二重キューになる)"
      exit 10
    fi
    # `set -e` 下では素の呼び出しが非 0 を返した時点で落ちるので、必ず条件文脈で受ける。
    body_rc=0
    input_box_has_body "$raw" || body_rc=$?
    case "$body_rc" in
      1)
        echo "QUEUED_UNCONFIRMED 入力欄は空。配信された可能性が高いがターン開始は未確認。**再送しないこと**"
        exit 10
        ;;
      2)
        echo "UNVERIFIED 入力欄の状態を判定できない。本文は送信済みなので **本文も Enter も再送しないこと**。画面を確認すること" >&2
        exit 2
        ;;
      3)
        echo "UNVERIFIED 選択肢 UI が開いている / 状態を確定できないため入力欄を判定できない。本文は送信済みなので **本文も Enter も再送しないこと**。画面を確認すること" >&2
        exit 2
        ;;
    esac

    # 実入力と判定できても、内容が不可逆操作を指示しているなら自動確定しない (#472)。
    if irreversible_instruction "$INPUT_BOX_BODY"; then
      echo "PENDING_CONFIRM 入力欄の本文が不可逆操作（マージ / 強制 push / クローズ等）を指示している。**Enter を自動で送らない**。誰が書いた本文かを画面と UserPromptSubmit で確かめ、user へ上げること" >&2
      exit 11
    fi

    # 本文は届いており、失われたのは確定キーだけ (#442)。**入力欄をクリアしない** --
    # クリアは届いた指示を捨てることになる。Enter を 1 回だけ送って再判定する。
    send_key Enter || die "確定キーを再送できなかった"
    if wait_until submitted; then
      echo "DELIVERED 送信を確認した (Enter 再送後)"
      exit 0
    fi
    raw="$(capture_raw)"
    body_rc=0
    input_box_has_body "$raw" || body_rc=$?
    case "$body_rc" in
      1)
        echo "QUEUED_UNCONFIRMED 入力欄は空になった。ターン開始は未確認。**再送しないこと**"
        exit 10
        ;;
      2)
        echo "UNVERIFIED 入力欄の状態を判定できない。**再送しないこと**。画面を確認すること" >&2
        exit 2
        ;;
      3)
        echo "UNVERIFIED 選択肢 UI が開いている / 状態を確定できないため入力欄を判定できない。**再送しないこと**。画面を確認すること" >&2
        exit 2
        ;;
    esac
    echo "PENDING_CONFIRM 本文が入力欄に残っている。**本文を再送しないこと** (連結して二重入力になる)。Enter のみ送るか画面を確認すること" >&2
    exit 11
    ;;
esac
