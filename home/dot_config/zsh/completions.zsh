# Local completions (vendored from upstream tools)
fpath=(${HOME}/.config/zsh/completions $fpath)

# Docker CLI completions
fpath=(${HOME}/.docker/completions $fpath)

# Drop duplicates on re-source / nested shell. fpath is tied to FPATH
# (typeset -U on either deduplicates both), so this is safe to do once
# before compinit.
typeset -U fpath FPATH

autoload -Uz compinit
compinit
