#!/bin/bash
# codex-cu（Codex の computer use）が出す「Allow Computer Use to use "<App>"?」の elicitation に、
# Claude Code の Elicitation hook として応答する（https://code.claude.com/docs/en/hooks#elicitation）。
#
#   1. ALWAYS_ASK のアプリ   → 何も出力しない（ダイアログに委ねる）
#   2. ALWAYS_ALLOW のアプリ → accept（permission mode が auto / bypassPermissions のときだけ）
#   3. それ以外             → 何も出力しない（ダイアログに委ねる）
# 判断に迷う入力はすべて「何も出力しない」に倒す（fail-closed。最終判断は人がする）。
# 承認の単位はアプリ（cua.getApp ごと）で、クリック単位ではない。
#
# codex-cu は Codex アプリが「常に許可」を記憶する前提で作られていて、サーバー側に記憶も設定もない。
# Claude Code 側にも hook 以外の自動応答の手段がない（設定キーも、ダイアログの「今後聞かない」もない）。
# hook の入力に permission mode は渡らないので、transcript に書かれる permission-mode の記録から読む。

# jq は mise で入れている。mise を有効にしていない環境から起動されても見つかるようにする。
command -v jq >/dev/null || PATH="$HOME/.local/share/mise/shims:$PATH"

input=$(cat)
message=$(jq -r '.message // ""' <<<"$input")

# アプリの許可以外の elicitation（音声録画など）はダイアログに委ねる。
[[ "$message" =~ ^Allow\ Computer\ Use\ to\ use\ \"(.+)\"\?$ ]] || exit 0
app="${BASH_REMATCH[1]}"

ask() {
  echo "codex-cu-gate: ask \"$app\" ($1)" >&2
  exit 0
}

# 1. 操作を人が必ず確認するアプリ。認証情報・OS 設定・任意のコマンドに至るもの（ターミナル・エディタの
#    統合ターミナル・スクリプト実行）・第三者へ送信するもの。
case "$app" in
  "1Password" | "Passwords" | "Keychain Access" | "System Settings" | \
    "Terminal" | "Ghostty" | "iTerm2" | "Warp" | "Alacritty" | "kitty" | "WezTerm" | \
    "Script Editor" | "Automator" | "Shortcuts" | "Code" | "Visual Studio Code" | "Cursor" | \
    "Mail" | "Messages" | "Slack" | "Discord" | "LINE" | "Spark Desktop")
    ask "always ask"
    ;;
esac

# 自動承認は auto / bypassPermissions のときだけ。transcript が無い（--no-session-persistence など）か、
# permission-mode の記録が読めなければ人に聞く。
transcript=$(jq -r '.transcript_path // ""' <<<"$input")
[ -f "$transcript" ] || ask "no transcript"
mode=$(jq -r 'select(.permissionMode) | .permissionMode' "$transcript" 2>/dev/null | tail -1)
case "$mode" in
  auto | bypassPermissions) ;;
  *) ask "permission mode: ${mode:-unknown}" ;;
esac

# 2. 聞かずに許可するアプリ（読むだけ・手元で完結し、第三者にも認証情報にも届かないもの）。
case "$app" in
  "Music" | "Calculator" | "TextEdit" | "Preview" | "Podcasts" | "Reminders")
    echo "codex-cu-gate: accept \"$app\" (always allow)" >&2
    jq -n '{hookSpecificOutput: {hookEventName: "Elicitation", action: "accept", content: {}}}'
    exit 0
    ;;
esac

# 3. どちらのリストにも無いアプリは人に聞く。
ask "not listed"
