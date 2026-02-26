# ========== zsh config ==========
setopt auto_pushd
setopt pushd_ignore_dups
# setopt auto_cd
setopt hist_ignore_dups
setopt share_history
setopt inc_append_history
export HISTSIZE=100000
export SAVEHIST=100000
# =============================

# ========== User specific aliases and functions ==========
function ccdpaths(){
  local dir="${1:-.}"
  # シンプルで安全な実装
  echo "=== Directories ==="
  /usr/bin/find "$dir" -type d -exec echo "- @{}/" \;
  echo "=== Files ==="
  /usr/bin/find "$dir" -type f -exec echo "- @{}" \;
}

function ccdcommands(){
  local base_dir="${1:-.}"
  local commands_dir=".claude/commands"
  if [ ! -d "$commands_dir" ]; then
    echo "Error: .claude/commands directory not found in ${base_dir}" >&2
    return 1
  fi
  /usr/bin/find "$commands_dir" -name "*.md" -type f -exec echo "- @{}" \;
}

function claude-rc() {
  # settings.jsonのテレメトリ設定を一時退避して remote-control を起動
  local settings=~/.claude/settings.json
  local backup=$(mktemp)
  cp "$settings" "$backup"

  # DISABLE_TELEMETRY と DISABLE_NONESSENTIAL_TRAFFIC だけ除去
  jq '.env |= with_entries(select(.key | test("DISABLE_TELEMETRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") | not))' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"

  # 終了時（Ctrl+Cを含む）に復元
  trap 'cp "$backup" "$settings"; rm -f "$backup"' EXIT INT TERM

  claude remote-control "$@"

  # 復元
  cp "$backup" "$settings"
  rm -f "$backup"
  trap - EXIT INT TERM
}

# 短縮エイリアス
alias ccdcmds='ccdcommands'
alias cld='claude'

alias c='code'

alias ll='ls -lF'
alias la='ls -lAF'

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias relogin='exec $SHELL -l'


# alias rm='rm -i'
alias rmtrash='rm -rf ${HOME}/.Trash/* && rm -rf ${HOME}/.Trash/.*'
alias rmdownloads='mv --backup=numbered ${HOME}/Downloads/{.,}* ${HOME}/.Trash/ '
alias rmnm='rm -rf ./node_modules'

alias delds='find . -name ".DS_Store" -type f -ls -delete'

alias g='git'
alias gb='git branch'
alias gs='git status'
function gcl (){
  local URL=$1
  git clone "${URL}"
}
function gch (){
  local BRANCH=${1:-main}
  git checkout "${BRANCH}"
}
function gcb (){
  local BRANCH=$1
  git checkout -b "${BRANCH}"
}
function ga (){
  local FILE=${1:-.}
  git add "${FILE}"
}
function gc (){
  local MESSAGE=${1:-minor adjustment}
  git commit -m "${MESSAGE}"
}
alias gca='git commit --amend'
alias gf='git fetch'
function gr(){
  local BRANCH=${1:-main}
  git rebase "${BRANCH}"
}
alias gpl='git pull origin HEAD'
alias gps='git push origin HEAD'
alias gac='git reset HEAD .'
alias gcc='git reset --hard HEAD~'
function gss (){
  local MESSAGE=$1
  git stash save "${MESSAGE}"
}
alias gsl='git stash list'
function gsa (){
  local STASH_NAME=$1
  git stash apply "${STASH_NAME}"
}
function gsd (){
  local STASH_NAME=$1
  git stash drop "${STASH_NAME}"
}

# function gi (){
# local QUERY=$1
# curl -sLw "\n" https://www.toptal.com/developers/gitignore/api/${QUERY} >> .gitignore
# }
# alias gil='curl -sLw "\n" https://www.toptal.com/developers/gitignore/api/list'
# alias gihelp='echo "gitignore.io help:\n - gil: lists the operating systems, programming languages and IDE input types\n - gi <types>: creates .gitignore files for types of operating systems, programming languages or IDEs"'

alias d='docker'
alias db='docker build .'
alias dil='docker image ls'
alias dcl='docker container ls -a'
function dce (){
  local CONTAINER=$1
  docker container exec -it ${CONTAINER} bash
}
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

alias vi="nvim"
alias vim="nvim"
alias view="nvim -R"

alias -g C='| pbcopy'

alias pn='pnpm'
alias pni='pnpm install'
alias pnx='pnpx'

# alias notify='afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Alert.m4r && \
#   afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Glass.m4r'
alias notify='afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Glass.m4r && \
  afplay  /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/Bamboo.m4r'
# mkdirとtouchを同時に行う
function mduch(){
  mkdir -p "$(dirname "$1")"
  touch "$1"
}

function update-brewfile(){
  rm -rf ~/dotfiles/.bin/.Brewfile
  brew bundle dump --file ~/dotfiles/.bin/.Brewfile
  git -C ~/dotfiles add .bin/.Brewfile
  git -C ~/dotfiles commit -m "Update Brewfile"
  git -C ~/dotfiles push
}

function pull-update-brewfile(){
  git -C ~/dotfiles pull
  brew bundle cleanup --global --force --file ~/dotfiles/.bin/.Brewfile
  brew bundle --global --file ~/dotfiles/.bin/.Brewfile
}

function push-dotfiles(){
  git -C ~/dotfiles add .
  git -C ~/dotfiles commit -m "Update dotfiles"
  git -C ~/dotfiles push
}

function pull-dotfiles(){
  git -C ~/dotfiles pull
}

function y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  command yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}

alias alhelp='cat ${HOME}/.zshrc'
# ===============================================

eval "$(direnv hook zsh)"
# The following lines have been added by Docker Desktop to enable Docker CLI completions.
fpath=(/Users/ryota/.docker/completions $fpath)
autoload -Uz compinit
compinit
# End of Docker CLI completions

# pnpm
export PNPM_HOME="/Users/ryota/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

eval "$(starship init zsh)"
export PATH="$HOME/.local/bin:$PATH"

#compdef wtp
compdef _wtp wtp

# This is a shell completion script auto-generated by https://github.com/urfave/cli for zsh.

_wtp() {
	local -a opts # Declare a local array
	local current
	current=${words[-1]} # -1 means "the last element"
	if [[ "$current" == "-"* ]]; then
		# Current word starts with a hyphen, so complete flags/options
		opts=("${(@f)$(env WTP_SHELL_COMPLETION=1 ${words[@]:0:#words[@]-1} ${current} --generate-shell-completion)}")
	else
		# Current word does not start with a hyphen, so complete subcommands
		opts=("${(@f)$(env WTP_SHELL_COMPLETION=1 ${words[@]:0:#words[@]-1} --generate-shell-completion)}")
	fi

	if [[ "${opts[1]}" != "" ]]; then
		_describe 'values' opts
	else
		_files
	fi
}

# Don't run the completion function when being source-ed or eval-ed.
# See https://github.com/urfave/cli/issues/1874 for discussion.
if [ "$funcstack[1]" = "_wtp" ]; then
	_wtp
fi

# wtp cd command hook for zsh
wtp() {
    for arg in "$@"; do
        if [[ "$arg" == "--generate-shell-completion" ]]; then
            command wtp "$@"
            return $?
        fi
    done
    if [[ "$1" == "cd" ]]; then
        local target_dir
        if [[ -z "$2" ]]; then
            target_dir=$(command wtp cd 2>/dev/null)
        else
            target_dir=$(command wtp cd "$2" 2>/dev/null)
        fi
        if [[ $? -eq 0 && -n "$target_dir" ]]; then
            cd "$target_dir"
        else
            if [[ -z "$2" ]]; then
                command wtp cd
            else
                command wtp cd "$2"
            fi
        fi
    else
        command wtp "$@"
    fi
}
