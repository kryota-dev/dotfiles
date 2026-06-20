# `cd <path>` is committed via zle accept-line so the command lands in zsh
# history (Ctrl-R / atuin discoverable). `ghq list --full-path` is multi-root
# safe; `${(q)…}` preserves whitespace and special characters.
ghq-fzf-cd() {
  local selected
  selected=$(ghq list --full-path 2>/dev/null | fzf --height=40% --reverse --prompt='ghq> ') || {
    zle reset-prompt
    return
  }
  if [[ -n "$selected" ]]; then
    BUFFER="cd ${(q)selected}"
    zle accept-line
  else
    zle reset-prompt
  fi
}
zle -N ghq-fzf-cd
bindkey '^g' ghq-fzf-cd
