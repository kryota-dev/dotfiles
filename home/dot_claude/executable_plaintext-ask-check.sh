#!/bin/bash
# Claude Code Stop hook -> warn when a turn ends by asking for a decision in plain text
# (kryota-dev/dotfiles#616).
#
# What it reads, and why (the payload was captured on a real machine in #616; see
# docs/explanation/plaintext-ask-detection.md):
#   - last_assistant_message  The reply text. The runtime documents this field as existing so
#                             hooks can avoid reading and parsing the transcript; stage 1 tests
#                             its closing line for a decision-seeking phrase.
#   - transcript_path / prompt_id
#                             prompt_id equals the promptId of the user entry that opened the
#                             turn (verified against real transcripts). Everything from there
#                             until the next prompt is this turn, and that is the window in
#                             which AskUserQuestion either was or was not called.
#   - background_tasks        A non-empty array means the session is paused waiting for
#                             background work, not finished. #447 measured a parent that
#                             delegated to a subagent emitting Stop mid-turn and resuming under
#                             the same prompt_id: Stop is not the end of a turn.
#
# Direction of error: the tolerated one is "do not stop" — a missed violation is acceptable, a
# warning on an ordinary report is not. The phrase lists below are enumerated on purpose and
# exclude general question forms, and position is part of the test (see match_decision_phrase).
#
# No silent failure (#616): a broken detector must not look like zero findings. Exactly one
# status line — ok / skipped / violation / error — always goes to stderr, and ok and error are
# different values. When a phrase matched but the turn could not be checked, the user is told
# so as well.
#
# Never blocks (synchronous hook, timeout 5): every path exits 0 and nothing emits
# decision:"block" or continue:false. This is a nudge, not a gate.
#
# Why not async: an async hook's stdout is collected later and delivered as a model-facing
# attachment (the runtime's checkForNewResponses / responseAttachmentSent path). The message
# here is for the user at turn end, so the settings.json entry is synchronous.
#
# The reply text is never written to disk; only the matched phrase reaches the systemMessage.
set -euo pipefail

# Only the tail of the reply is examined: the observed violation shape is a question written at
# the very end, and looking further back would pick up questions the reply itself goes on to
# answer.
#
# The unit is characters rather than bytes, and that is load-bearing. A byte cut can land inside
# a multi-byte character, and BSD/ugrep's `grep -F` then fails to match even a fully intact
# Japanese phrase that follows the damaged bytes (measured; LC_ALL=C does not help). Replies
# longer than the window are the common case, so a byte window failed silently on exactly the
# turns this hook exists for. Bash substring expansion counts characters in a UTF-8 locale
# (verified on bash 3.2) and never splits one.
TAIL_SCAN_CHARS="${PLAINTEXT_ASK_TAIL_SCAN_CHARS:-400}"
# A window shrunk to nothing matches nothing and looks like a clean turn. Every other failure
# mode here reports error, so leaving this one to report ok would be the single way to disable
# the detector without a trace — the exact asymmetry this hook is built not to have.
TAIL_SCAN_CHARS_MIN=40
# Transcripts past this size are not scanned, and giving up is reported as error rather than
# quietly passing. The bound is measured: the jq scan below processed 417 MB of concatenated
# real transcripts in 3.4 s (~120 MB/s), so 64 MiB is roughly 0.55 s — about nine times under
# the hook's 5 s timeout.
MAX_TRANSCRIPT_BYTES="${PLAINTEXT_ASK_MAX_TRANSCRIPT_BYTES:-67108864}"

# Decision-seeking phrases, Japanese. Matched with bash pattern matching, so this depends on
# neither the locale nor an external command. Deliberately narrow: ordinary closings such as
# "お知らせください" and "教えてください" are left out.
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

# Decision-seeking phrases, English. ASCII only, so a case-insensitive ERE is safe here.
DECISION_SEEKING_EN='shall i (proceed|continue|go ahead)|should i (proceed|continue)|would you like me to|do you want me to|let me know (which|whether|if you)|which (one|option|approach) (do|would|should)'

# Trailing ornaments stripped from a line: closing brackets, closing quotes and whitespace.
# Sentence punctuation is deliberately NOT here — the English test needs to know whether the
# line ends in "?", so only the Japanese test strips terminators on top of these.
# U+201D and U+2019 are written as bytes because shellcheck flags literal curly quotes (SC1112)
# as characters typed by mistake.
TRAILING_DECORATIONS=(' ' $'\t' $'\r' '"' "'" '）' ')' '」' '』' '】' ']'
  $'\xe2\x80\x9d' $'\xe2\x80\x99')
# Sentence terminators the Japanese test strips in addition, before asking whether what is left
# ends with a phrase.
SENTENCE_TERMINATORS=('？' '?' '。' '.' '！' '!' '…')

# Exactly one status line, always. ok and error being distinguishable is what keeps this
# detector from failing silently.
emit_status() {
  printf 'plaintext-ask-check: status=%s reason=%s\n' "$1" "${2:--}" >&2
}

emit_system_message() {
  jq -n --arg m "$1" '{systemMessage: $m}'
}

# Strip the given suffixes from the end, repeatedly, until nothing changes.
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

# Find the closing line — the one that decides whether the reply ends by asking. Blank, list,
# quote and heading lines are discarded from the bottom up: the observed violation shape puts
# the choices *under* the question, so the literal last line is often `- B: ...` rather than
# the ask, and taking it verbatim would miss the case this hook was written for.
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

# Print the phrase and return 0 when the closing line *ends* by asking for a decision.
#
# Requiring the position is the point. Matching a phrase anywhere in the window would flag a
# completion report that merely quotes the question it once asked. Japanese phrases are
# sentence-final, so the line must end with one once sentence punctuation is stripped; English
# phrases are sentence-initial, so the line must end with "?" instead. That one rule is what
# separates "Let me know if you want me to proceed?" from "Done. Let me know if you spot
# anything else."
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

# Fold the transcript into one `<bad> <seen> <ask>` line in a single pass.
#
# Each line is parsed on its own, so one corrupt line cannot abort the scan and take the
# detection down with it quietly — a corrupt line sets bad, which is reported. The window runs
# from the line carrying prompt_id up to, but not including, the next prompt: tool_result
# entries returned during the turn carry the same promptId and therefore do not close it
# (verified against real transcripts), while a later well-behaved turn cannot reach back and
# clear this one. Folding into a fixed set of booleans keeps memory constant no matter how
# large or how corrupt the file is.
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

  # Without jq nothing can be decided. Unlike the sibling hooks this is not a silent no-op:
  # expressing "cannot evaluate" as the same silence as "no violations" is precisely the
  # failure this detector forbids.
  if ! command -v jq >/dev/null 2>&1; then
    emit_status error "jq-unavailable"
    return 0
  fi

  # A broken window size is reported as error rather than allowed to masquerade as a clean turn.
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

  # U+001F (unit separator) is the delimiter. Tabs and spaces are IFS whitespace, which bash
  # collapses in runs, so an empty field would vanish and shift every value after it by one —
  # unusable for a sequence in which several fields can legitimately be empty.
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

  # What follows is out of scope, which is not the same as "no violation" — each exit says why.
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
    # Paused waiting for background work; the turn has not ended yet (#447).
    emit_status skipped "background-tasks-in-flight"
    return 0
  fi

  msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || true)"
  if [ -z "$msg" ]; then
    # A turn that ended on tool calls alone, for instance. No text, nothing to judge.
    emit_status skipped "no-assistant-message"
    return 0
  fi

  # Clamp before slicing. Bash 3.2's `${var: -N}` returns the empty string when N exceeds the
  # length instead of clamping (measured), which would drop every reply shorter than the window
  # into "no phrase found" — another silent path to a clean-looking result.
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

  # Only now is the transcript read. Because the closing line rarely ends by asking, an
  # ordinary turn never gets this far.
  if [ -z "$prompt_id" ]; then
    emit_status error "no-prompt-id"
    emit_system_message "plaintext-ask-check: 末尾に「${phrase}」を検出しましたが、payload に prompt_id が無く turn を特定できませんでした（判定不能であって違反なしではありません）。"
    return 0
  fi
  # Check the path before reading it. The sibling hook wave-session-event.sh validates
  # session_id as a UUID before putting it in a filename for the same reason: a value the
  # runtime generated is still treated as untrusted input.
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
