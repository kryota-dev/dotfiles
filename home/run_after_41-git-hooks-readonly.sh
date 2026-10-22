#!/bin/bash
# ほかのリポジトリの古い lefthook（2.1.4 以前の `lefthook run`、2.1.0 より前の `lefthook install`）が、
# グローバルの core.hooksPath のフックを上書きするのを、書き込みの権限を外して止める。
# chezmoi の readonly_ はディレクトリの中を更新できない（chezmoi が先に読み取り専用で作り、中に書けない）ので、
# run スクリプトで切り替える。apply の前に戻すのは run_before_06-git-hooks-writable.sh。
set -euo pipefail

hooks="${GIT_HOOKS_DIR:-$HOME/.config/git/hooks}"

[ -d "$hooks" ] || exit 0
chmod a-w "$hooks"
