# 親ディレクトリごとファイルを作る（mkdir -p ＋ touch）
mduch() {
  mkdir -p "$(dirname "$1")"
  touch "$1"
}

# yazi を終了したとき、そのディレクトリへシェルも移動する
y() {
  local tmp cwd
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
  command yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd <"$tmp"
  [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}

# Ctrl-G: ghq のリポジトリを fzf で選んで cd する（履歴に残る形で実行する）
ghq-fzf-cd() {
  local selected
  selected=$(ghq list --full-path 2>/dev/null | fzf --height=40% --reverse --prompt='ghq> ')
  if [[ -n "$selected" ]]; then
    BUFFER="cd ${(q)selected}"
    zle accept-line
  else
    zle reset-prompt
  fi
}
zle -N ghq-fzf-cd
bindkey '^g' ghq-fzf-cd
