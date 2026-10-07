#!/bin/bash
# Claude Code の statusline（https://code.claude.com/docs/en/statusline）。
#   1 行目: ディレクトリ  git ブランチ（変更ありなら *）
#   2 行目: モデル  effort  context の残り  5 時間 / 7 日の rate limit 使用率

# jq は mise で入れている。mise を有効にしていない環境から起動されても見つかるようにする。
command -v jq >/dev/null || PATH="$HOME/.local/share/mise/shims:$PATH"

input=$(cat)

IFS=$'\x1f' read -r model effort cwd ctx five seven < <(jq -r '[
  (.model.display_name // "Claude"),
  (.effort.level // ""),
  (.workspace.current_dir // .cwd // ""),
  (.context_window.remaining_percentage // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring)
] | join("\u001f")' <<<"$input")

DIM=$'\033[2m' RST=$'\033[0m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'

# 使用率に色を付ける: 50 未満は緑、80 未満は黄、それ以上は赤。
used_color() {
  local p=${1%.*}
  if [ "$p" -lt 50 ]; then printf '%s' "$GREEN"; elif [ "$p" -lt 80 ]; then printf '%s' "$YELLOW"; else printf '%s' "$RED"; fi
}

dir="${cwd/#$HOME/~}"
line1="${BLUE}${dir}${RST}"
if [ -n "$cwd" ] && branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null); then
  dirty=""
  [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null | head -1)" ] && dirty="*"
  line1+="  ${branch}${YELLOW}${dirty}${RST}"
fi

line2="${model}"
[ -n "$effort" ] && line2+=" ${DIM}${effort}${RST}"
if [ -n "$ctx" ]; then
  used=$((100 - ${ctx%.*}))
  line2+="  ctx 残り$(used_color "$used")${ctx%.*}%${RST}"
fi
[ -n "$five" ] && line2+="  5h $(used_color "$five")${five%.*}%${RST}"
[ -n "$seven" ] && line2+="  7d $(used_color "$seven")${seven%.*}%${RST}"

printf '%s\n%s\n' "$line1" "$line2"
