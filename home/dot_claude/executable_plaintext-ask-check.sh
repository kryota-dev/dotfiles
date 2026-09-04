#!/bin/bash
# Claude Code Stop hook -> 平文で判断を仰いだまま turn を終えた違反の検知（kryota-dev/dotfiles#616）。
#
# 何を見ているか（#616 で実機採取した Stop payload が根拠。docs/explanation/plaintext-ask-detection.md）:
#   - last_assistant_message  応答本文。実装が「トランスクリプトを読まずに済ませるため」と説明する
#                             フィールドで、末尾が判断を仰ぐ語句で終わっているかをここで見る。
#   - transcript_path / prompt_id
#                             prompt_id は turn を開始した user エントリの promptId と一致する
#                             （実データで確認済み）。そこから次のプロンプトまでの間に
#                             AskUserQuestion の tool_use があるかを見て、「この turn でちゃんと
#                             選択肢を出したか」を判定する。
#   - background_tasks        空でなければ「session is done」ではなく「バックグラウンド待ちで
#                             止まっている」。#447 の実測（サブエージェントへ委任した親は途中で
#                             Stop を出し、同じ prompt_id のまま再開して AskUserQuestion を出す）を
#                             ここで落とす。Stop はターンの終わりを意味しない。
#
# 誤検知の向き: 許容するのは「止めない側」＝ 見逃し。判断を仰ぐ語句は下の定数に明示列挙するだけで、
# 「〜ですか？」のような一般形は入れない。報告や要約が問いかけ調で終わる通常のケースを止めないため。
#
# 沈黙する故障の禁止（#616 の要件）: 検知器が壊れたときに「違反 0 件」と同じ出力になってはならない。
# stderr へ status=ok / skipped / violation / error を必ず 1 行出し、ok と error を別の値にする。
# 語句が一致したのに検証できなかった場合はユーザー向けにも「判定できなかった」と表示する。
#
# ブロックしない契約（同期 hook, timeout 5）: あらゆる経路で exit 0 を返し、decision:"block" も
# continue:false も出力しない。これは blocking gate ではなく気付きのための警告である。
#
# なぜ async ではないか: async hook の stdout はモデル向け attachment として後から配送される
# （実装の checkForNewResponses / responseAttachmentSent 経路）。ここで出したいのは turn 終了時点で
# 利用者の画面に出る systemMessage であってモデルへの差し戻しではないので、同期エントリにする。
#
# 応答本文はディスクに書かない。systemMessage に載せるのは一致した語句だけ。
set -euo pipefail

# 末尾だけを見る。違反の形が「応答の末尾に平文で書いて待つ」であり、報告の途中に現れて本人が後段で
# 答えている問いを拾わないため。
#
# 単位が「バイト」ではなく「文字」なのは実測に基づく: バイトで切ると多バイト文字の途中で切れることが
# あり、そうなると BSD/ugrep の `grep -F` は **その後ろにある完全な日本語語句すら一致しなくなる**
# （LC_ALL=C でも同じ）。1200 バイトを超える応答は珍しくないので、これは検知が黙って落ちる経路だった。
# bash の部分文字列展開は UTF-8 ロケールで文字単位に働き（bash 3.2 で確認済み）、境界を割らない。
TAIL_SCAN_CHARS="${PLAINTEXT_ASK_TAIL_SCAN_CHARS:-400}"
# 窓を極端に小さくすると、何も一致しなくなって「違反なし」に見える。他の失敗経路がすべて error に
# 倒れるのにここだけ ok に倒れるのは、この hook の設計目標そのものへの反例なので下限を設けて弾く。
TAIL_SCAN_CHARS_MIN=40
# これを超えるトランスクリプトは走査を諦める。諦めたことは error として必ず告げる（黙って ok にしない）。
# 上限の根拠（実測）: 実トランスクリプトを連結した 417 MB の JSONL を下の jq 走査が 3.4 秒で処理した
# （約 120 MB/s）。64 MiB なら約 0.55 秒で、hook の timeout 5 秒に対しておよそ 9 倍の余裕がある。
MAX_TRANSCRIPT_BYTES="${PLAINTEXT_ASK_MAX_TRANSCRIPT_BYTES:-67108864}"

# 判断を仰ぐ語句（日本語）。bash の固定パターン照合なのでロケールにも外部コマンドにも依存しない。
# 意図的に狭い。「お知らせください」「教えてください」のような通常の結びは入れない。
DECISION_SEEKING_JA=(
  "よろしいですか"
  "よろしいでしょうか"
  "いかがしますか"
  "いかがでしょうか"
  "いかがいたしましょうか"
  "いかがなさいますか"
  "どちらにしますか"
  "どちらにしましょうか"
  "どちらがよいですか"
  "どちらが良いですか"
  "どうしますか"
  "どうしましょうか"
  "どうされますか"
  "どういたしますか"
  "どれにしますか"
  "進めますか"
  "進めましょうか"
  "進めてよいですか"
  "進めていいですか"
  "進めてもよいですか"
  "進めてもいいですか"
  "続けますか"
  "続けましょうか"
  "実施しますか"
  "対応しますか"
  "ご指示ください"
  "ご判断ください"
  "お選びください"
  "選択してください"
  "指定してください"
)

# 判断を仰ぐ語句（英語）。ASCII のみなので大文字小文字を無視した ERE で照合する。
DECISION_SEEKING_EN='shall i (proceed|continue|go ahead)|should i (proceed|continue)|would you like me to|do you want me to|let me know (which|whether|if you)|which (one|option|approach) (do|would|should)'

# 行末から取り除く「飾り」。閉じ括弧・閉じ引用符・空白まで。文末句読点はここには入れない
# （英語の「? で終わるか」判定に必要なので、日本語側だけがあとから追加で剥がす）。
# U+201D / U+2019 はバイト列で書く。リテラルの curly quote は shellcheck が SC1112
# （タイプミスで混入した引用符）として弾くため。
TRAILING_DECORATIONS=(' ' $'\t' $'\r' '"' "'" '）' ')' '」' '』' '】' ']'
  $'\xe2\x80\x9d' $'\xe2\x80\x99')
# 日本語側で追加に剥がす文末句読点。剥がしたあと「語句で終わっているか」を見る。
SENTENCE_TERMINATORS=('？' '?' '。' '.' '！' '!' '…')

# status は必ず 1 行出す。ok と error が別の値であることが、この検知器が沈黙で壊れないための条件。
emit_status() {
  printf 'plaintext-ask-check: status=%s reason=%s\n' "$1" "${2:--}" >&2
}

emit_system_message() {
  jq -n --arg m "$1" '{systemMessage: $m}'
}

# 指定した接尾辞群を、変化しなくなるまで末尾から剥がす。
strip_suffixes() {
  local s="$1" prev="" p
  shift
  while [ "$s" != "$prev" ]; do
    prev="$s"
    for p in "$@"; do
      s="${s%"$p"}"
    done
  done
  printf '%s' "$s"
}

# 応答が「問いで終わっている」かを見るための締めの 1 行を取り出す。
# 末尾から空行と箇条書き・引用・表の行を捨てていき、最初に現れた通常の行を返す。観測された違反形は
# 問いの「下」に選択肢を並べることが多く、最終行がそのまま `- B: ...` になるため、最終行をそのまま
# 使うと取り落とす。
closing_line() {
  local text="$1" line
  while [ -n "$text" ]; do
    line="${text##*$'\n'}"
    line="$(strip_suffixes "$line" "${TRAILING_DECORATIONS[@]}")"
    case "$line" in
      '') ;;
      '- '* | '* '* | '+ '* | '>'* | '|'* | '#'*) ;;
      [0-9]'. '* | [0-9][0-9]'. '*) ;;
      *)
        printf '%s' "$line"
        return 0
        ;;
    esac
    if [ "$text" = "${text##*$'\n'}" ]; then
      text=""
    else
      text="${text%$'\n'*}"
    fi
  done
  return 1
}

# 締めの行が判断要求で「終わって」いれば、その語句を stdout に出して 0 を返す。
#
# 位置を要求するのが要点。窓の中のどこかに語句があれば当てる形にすると、完了報告の中で
# 「『この方針で進めてよろしいですか？』と尋ねた」と引用しただけで violation になる。
# 日本語の語句は文末に来るので「文末句読点を剥がした行がその語句で終わること」を、英語の語句は
# 文頭寄りに来るので「行が ? で終わること」を条件にする。
match_decision_phrase() {
  local line="$1" phrase stripped hit
  stripped="$(strip_suffixes "$line" "${SENTENCE_TERMINATORS[@]}" "${TRAILING_DECORATIONS[@]}")"
  for phrase in "${DECISION_SEEKING_JA[@]}"; do
    case "$stripped" in
      *"$phrase")
        printf '%s' "$phrase"
        return 0
        ;;
    esac
  done
  case "$line" in
    *'?')
      hit="$(printf '%s' "$line" | grep -m 1 -oiE -- "$DECISION_SEEKING_EN" || true)"
      if [ -n "$hit" ]; then
        printf '%s' "$hit"
        return 0
      fi
      ;;
  esac
  return 1
}

# トランスクリプトを 1 パスで畳み、`<bad> <seen> <ask>` の 1 行にして返す。
#
# 行ごとに独立に parse するので、壊れた 1 行が jq 全体を中断させて検知を静かに落とすことはない
# （壊れた行は bad として必ず告げる）。窓は prompt_id が現れた行から**次のプロンプトの手前**まで。
# turn の途中で返る tool_result エントリは同じ promptId を持つので窓を閉じない（実データで確認）。
# 状態を畳むだけなので、走査中に保持するのは定数個の真偽値だけで、行数に比例して増えない。
scan_turn() {
  local transcript="$1" prompt_id="$2"
  jq -nRr --arg pid "$prompt_id" '
    reduce inputs as $line (
      {bad: false, seen: false, closed: false, ask: false};
      if .closed then .
      else
        ($line | try fromjson catch null) as $e
        | if $e == null then
            (if ($line | test("^[[:space:]]*$")) then . else .bad = true end)
          elif (.seen | not) then
            (if (($e.promptId // "") == $pid) then .seen = true else . end)
          elif (($e.promptId // null) != null and $e.promptId != $pid) then
            .closed = true
          elif ($e.type == "assistant"
                and ($e.isSidechain != true)
                and (($e.message.content // []) | type == "array")
                and (($e.message.content // [])
                     | any(.type == "tool_use" and .name == "AskUserQuestion"))) then
            .ask = true
          else .
          end
      end
    )
    | "\(.bad) \(.seen) \(.ask)"
  ' "$transcript" 2>/dev/null
}

main() {
  local input fields ev active agent bgcount prompt_id transcript
  local msg tail_text line phrase verdict bad seen ask size

  # jq が無い環境では判定できない。他の hook のような silent no-op にはしない —— 判定不能を
  # 「違反 0 件」と同じ沈黙で表すことこそ、この検知器が禁じている故障だから。
  if ! command -v jq >/dev/null 2>&1; then
    emit_status error "jq-unavailable"
    return 0
  fi

  # 窓の大きさが壊れていたら、何も一致しないのを「違反なし」と呼ばずに error として告げる。
  case "$TAIL_SCAN_CHARS" in
    '' | *[!0-9]*)
      emit_status error "invalid-tail-scan-chars"
      return 0
      ;;
  esac
  if [ "$TAIL_SCAN_CHARS" -lt "$TAIL_SCAN_CHARS_MIN" ]; then
    emit_status error "invalid-tail-scan-chars"
    return 0
  fi
  case "$MAX_TRANSCRIPT_BYTES" in
    '' | *[!0-9]*)
      emit_status error "invalid-max-transcript-bytes"
      return 0
      ;;
  esac

  input="$(cat 2>/dev/null || true)"
  if [ -z "$input" ]; then
    emit_status error "empty-payload"
    return 0
  fi

  # 区切りに U+001F（unit separator）を使う。タブや空白は bash の IFS で連続分が 1 個に畳まれ、
  # 空フィールドが詰まって以降の値が 1 つずつずれるため、空になりうる値の並びには使えない。
  fields="$(printf '%s' "$input" | jq -j '
    (.hook_event_name // ""), "\u001f",
    ((.stop_hook_active // false) | tostring), "\u001f",
    (.agent_id // ""), "\u001f",
    ((.background_tasks // []) | length | tostring), "\u001f",
    (.prompt_id // ""), "\u001f",
    (.transcript_path // "")
  ' 2>/dev/null)" || fields=""
  if [ -z "$fields" ]; then
    emit_status error "payload-unparseable"
    return 0
  fi
  IFS=$'\037' read -r ev active agent bgcount prompt_id transcript <<<"$fields" || true

  # 以下は「評価対象外」であって「違反なし」ではない。理由を添えて skipped で抜ける。
  if [ "$ev" != "Stop" ]; then
    emit_status skipped "not-stop-event"
    return 0
  fi
  if [ "$active" = "true" ]; then
    emit_status skipped "stop-hook-active"
    return 0
  fi
  if [ -n "$agent" ]; then
    emit_status skipped "subagent"
    return 0
  fi
  if [ "$bgcount" != "0" ]; then
    # バックグラウンド待ちで止まっているだけ。turn はまだ終わっていない（#447）。
    emit_status skipped "background-tasks-in-flight"
    return 0
  fi

  msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || true)"
  if [ -z "$msg" ]; then
    # tool 呼び出しだけで終わった turn など。本文が無ければ判定材料が無い。
    emit_status skipped "no-assistant-message"
    return 0
  fi

  # 長さでクランプする。bash 3.2 の `${var: -N}` は N が文字列長を超えると **黙って空文字列を返す**
  # （実測）。窓より短い応答がすべて「語句なし」に落ちる沈黙経路になるので、負の offset を渡さない。
  if [ "${#msg}" -gt "$TAIL_SCAN_CHARS" ]; then
    tail_text="${msg: -$TAIL_SCAN_CHARS}"
  else
    tail_text="$msg"
  fi
  if ! line="$(closing_line "$tail_text")"; then
    emit_status ok "no-closing-line"
    return 0
  fi
  if ! phrase="$(match_decision_phrase "$line")"; then
    emit_status ok "no-decision-seeking-phrase"
    return 0
  fi

  # ここから先はトランスクリプトを読む。締めの行が判断要求で終わっていたときだけなので、
  # 通常の turn では走らない。
  if [ -z "$prompt_id" ]; then
    emit_status error "no-prompt-id"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、payload に prompt_id が無く turn を特定できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  # 読む前に、渡されたパスが素性のわかる通常ファイルであることを確かめる（姉妹 hook の
  # wave-session-event.sh が session_id を UUID 検証してから使うのと同じ方針。ランタイムが
  # 生成した値でも未検証の入力として扱う）。
  case "$transcript" in
    *.jsonl) ;;
    *)
      emit_status error "transcript-not-jsonl"
      emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、transcript_path が想定の形式ではなく確認できませんでした（判定不能であって違反なしではありません）。"
      return 0
      ;;
  esac
  if [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    emit_status error "transcript-unreadable"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、トランスクリプトを読めず AskUserQuestion の有無を確認できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  size="$(wc -c <"$transcript" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$MAX_TRANSCRIPT_BYTES" ]; then
    emit_status error "transcript-too-large"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、トランスクリプトが大きすぎて走査を打ち切りました（判定不能であって違反なしではありません）。"
    return 0
  fi

  verdict="$(scan_turn "$transcript" "$prompt_id" || true)"
  read -r bad seen ask <<<"${verdict:-}" || true
  if [ "${bad:-}" = "true" ]; then
    emit_status error "transcript-unparseable-line"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、トランスクリプトに解釈できない行があり確認できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  if [ "${seen:-}" != "true" ]; then
    emit_status error "prompt-not-in-transcript"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、この turn をトランスクリプト上で特定できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  if [ "${ask:-}" = "true" ]; then
    emit_status ok "askuserquestion-used"
    return 0
  fi

  emit_status violation "plaintext-ask"
  emit_system_message "⚠️ 平文で判断を仰いだまま turn を終えています（この turn で AskUserQuestion は呼ばれていません）。検出した語句: 「${phrase}」。判断を仰ぐときは AskUserQuestion を使ってください。"
}

main || true
exit 0
