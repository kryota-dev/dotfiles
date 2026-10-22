#!/bin/bash
# apply のあいだ ~/.config/git/hooks は書き込みの権限を外しているので、chezmoi が中を更新・削除できるように戻す。
# 外し直すのは run_after_41-git-hooks-readonly.sh。ディレクトリが無ければ何もしない。
set -euo pipefail

hooks="${GIT_HOOKS_DIR:-$HOME/.config/git/hooks}"

[ -d "$hooks" ] || exit 0
chmod u+w "$hooks"
