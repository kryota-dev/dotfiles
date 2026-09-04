#!/bin/bash
# Claude Code Stop hook -> 平文で判断を仰いだまま turn を終えた違反の検知（kryota-dev/dotfiles#616）。
#
# 何を見ているか（#616 で実機採取した Stop payload が根拠。docs/explanation/plaintext-ask-detection.md）:
#   - last_assistant_message  応答本文。実装が「トランスクリプトを読まずに済ませるため」と説明する
#                             フィールドで、末尾が判断を仰ぐ語句で終わっているかをここで見る。
#   - transcript_path / prompt_id
#                             prompt_id は turn を開始した user エントリの promptId と一致する
#                             （実データで確認済み）。そこから後ろに AskUserQuestion の tool_use が
#                             あるかを見て「この turn でちゃんと選択肢を出したか」を判定する。
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
# 答えている問いを拾わないため。行単位ではなくバイト単位なのは、「どちらにしますか？」の直後に
# 選択肢の箇条書きが続く形（最終行が "- B: ..." になる）を取り落とさないため。日本語でおよそ 400 字。
TAIL_SCAN_BYTES="${PLAINTEXT_ASK_TAIL_SCAN_BYTES:-1200}"
# これを超えるトランスクリプトは走査を諦める。諦めたことは error として必ず告げる（黙って ok にしない）。
MAX_TRANSCRIPT_BYTES="${PLAINTEXT_ASK_MAX_TRANSCRIPT_BYTES:-67108864}"

# 判断を仰ぐ語句（日本語）。固定文字列照合なのでロケールに依存しない。
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
  "どちらを選び"
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
DECISION_SEEKING_EN='shall i (proceed|continue|go ahead)|should i (proceed|continue)|would you like me to|do you want me to|let me know (which|whether|if you)|which (one|option|approach) (do|would|should)|(proceed|continue)\?[[:space:]]*$'

# status は必ず 1 行出す。ok と error が別の値であることが、この検知器が沈黙で壊れないための条件。
emit_status() {
  printf 'plaintext-ask-check: status=%s reason=%s\n' "$1" "${2:--}" >&2
}

emit_system_message() {
  jq -n --arg m "$1" '{systemMessage: $m}'
}

# 末尾に判断を仰ぐ語句があれば、その語句を stdout に出して 0 を返す。
match_decision_phrase() {
  local tail_text="$1" phrase hit
  for phrase in "${DECISION_SEEKING_JA[@]}"; do
    if printf '%s' "$tail_text" | grep -qF -- "$phrase"; then
      printf '%s' "$phrase"
      return 0
    fi
  done
  hit="$(printf '%s' "$tail_text" | grep -oiE -- "$DECISION_SEEKING_EN" | head -n 1 || true)"
  if [ -n "$hit" ]; then
    printf '%s' "$hit"
    return 0
  fi
  return 1
}

# トランスクリプトを 3 種のマーカー列へ射影する。行ごとに独立に parse するので、壊れた 1 行が
# jq 全体を中断させて検知を静かに落とすことはない（壊れた行は BAD として必ず告げる）。
scan_turn_markers() {
  local transcript="$1" prompt_id="$2"
  jq -Rr --arg pid "$prompt_id" '
    if test("^[[:space:]]*$") then empty
    else
      (try fromjson catch null) as $e
      | if $e == null then "BAD"
        elif (($e.promptId // "") == $pid) then "PROMPT"
        elif ($e.type == "assistant"
              and ($e.isSidechain != true)
              and (($e.message.content // []) | type == "array")
              and (($e.message.content // [])
                   | any(.type == "tool_use" and .name == "AskUserQuestion")))
          then "ASK"
        else empty
        end
    end
  ' "$transcript" 2>/dev/null
}

main() {
  local input fields ev active agent bgcount prompt_id transcript
  local msg tail_text phrase markers size

  # jq が無い環境では判定できない。他の hook のような silent no-op にはしない —— 判定不能を
  # 「違反 0 件」と同じ沈黙で表すことこそ、この検知器が禁じている故障だから。
  if ! command -v jq >/dev/null 2>&1; then
    emit_status error "jq-unavailable"
    return 0
  fi

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

  tail_text="$(printf '%s' "$msg" | tail -c "$TAIL_SCAN_BYTES")"
  if ! phrase="$(match_decision_phrase "$tail_text")"; then
    emit_status ok "no-decision-seeking-phrase"
    return 0
  fi

  # ここから先はトランスクリプトを読む。語句が一致したときだけなので、通常の turn では走らない。
  if [ -z "$prompt_id" ]; then
    emit_status error "no-prompt-id"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、payload に prompt_id が無く turn を特定できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  if [ -z "$transcript" ] || [ ! -r "$transcript" ]; then
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

  markers="$(scan_turn_markers "$transcript" "$prompt_id" || true)"
  if printf '%s\n' "$markers" | grep -qx 'BAD'; then
    emit_status error "transcript-unparseable-line"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、トランスクリプトに解釈できない行があり確認できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  if ! printf '%s\n' "$markers" | grep -qx 'PROMPT'; then
    emit_status error "prompt-not-in-transcript"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、この turn をトランスクリプト上で特定できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  if printf '%s\n' "$markers" | awk '/^PROMPT$/ { seen = 1 } seen && /^ASK$/ { found = 1 } END { exit found ? 0 : 1 }'; then
    emit_status ok "askuserquestion-used"
    return 0
  fi

  emit_status violation "plaintext-ask"
  emit_system_message "⚠️ 平文で判断を仰いだまま turn を終えています（この turn で AskUserQuestion は呼ばれていません）。検出した語句: 「${phrase}」。判断を仰ぐときは AskUserQuestion を使ってください。"
}

main || true
exit 0
