#compdef wtp
compdef _wtp wtp

_wtp() {
	local -a opts
	local current
	current=${words[-1]}
	if [[ "$current" == "-"* ]]; then
		opts=("${(@f)$(env WTP_SHELL_COMPLETION=1 ${words[@]:0:#words[@]-1} ${current} --generate-shell-completion)}")
	else
		opts=("${(@f)$(env WTP_SHELL_COMPLETION=1 ${words[@]:0:#words[@]-1} --generate-shell-completion)}")
	fi

	if [[ "${opts[1]}" != "" ]]; then
		_describe 'values' opts
	else
		_files
	fi
}

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
