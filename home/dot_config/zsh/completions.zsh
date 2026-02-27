# Docker CLI completions
fpath=(${HOME}/.docker/completions $fpath)

autoload -Uz compinit
compinit
