# Local completions (vendored from upstream tools)
fpath=(${HOME}/.config/zsh/completions $fpath)

# Docker CLI completions
fpath=(${HOME}/.docker/completions $fpath)

autoload -Uz compinit
compinit
