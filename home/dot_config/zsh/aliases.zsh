# 全般
alias c='code'
alias ll='ls -lF'
alias la='ls -lAF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias relogin='exec $SHELL -l'
alias vi='nvim'
alias vim='nvim'
alias view='nvim -R'
alias -g C='| pbcopy'
alias rmnm='rm -rf ./node_modules'
alias delds='find . -name ".DS_Store" -type f -ls -delete'
alias notify='afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Glass.m4r && afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/Bamboo.m4r'

# pnpm
alias pn='pnpm'
alias pni='pnpm install'
alias pnx='pnpx'

# git
alias g='git'
alias gb='git branch'
alias gs='git status'
alias gca='git commit --amend'
alias gf='git fetch'
alias gpl='git pull origin HEAD'
alias gps='git push origin HEAD'
alias gun='git reset HEAD .'
alias gsl='git stash list'
gcl() { git clone "$1"; }
gch() { git checkout "${1:-main}"; }
gcb() { git checkout -b "$1"; }
ga() { git add "${1:-.}"; }
gc() { git commit -m "${1:-minor adjustment}"; }
gr() { git rebase "${1:-main}"; }
gss() { git stash push -m "$1"; }
gsa() { git stash apply "$1"; }
gsd() { git stash drop "$1"; }

# docker
alias d='docker'
alias db='docker build .'
alias dil='docker image ls'
alias dcl='docker container ls -a'
alias dip='docker image prune'
alias dcp='docker container prune'
alias dsp='docker system prune --volumes'
alias dc='docker compose'
alias dcu='docker compose up'
alias dcud='docker compose up -d'
alias dcd='docker compose down'
alias dcstart='docker compose start'
alias dcstop='docker compose stop'
alias dcrestart='docker compose restart'
alias dclogs='docker compose logs -f'
dce() { docker container exec -it "$1" bash; }

# ゴミ箱を空にする。(DN): 隠しファイルも含め、何もなければ空のまま（エラーにしない）。
rmtrash() {
  local -a items=("$HOME"/.Trash/*(DN))
  ((${#items})) && command rm -rf -- "${items[@]}"
}

# ダウンロードフォルダの中身をゴミ箱へ移す（同名は番号付きで退避）。
rmdownloads() {
  local -a items=("$HOME"/Downloads/*(DN))
  ((${#items})) && gmv --backup=numbered -- "${items[@]}" "$HOME/.Trash/"
}
