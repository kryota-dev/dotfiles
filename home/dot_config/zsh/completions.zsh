fpath=("$HOME/.docker/completions" $fpath)
typeset -U fpath FPATH

autoload -Uz compinit
compinit

if command -v wtp >/dev/null; then eval "$(wtp shell-init zsh)"; fi
