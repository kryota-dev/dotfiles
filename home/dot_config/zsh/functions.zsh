# mkdirとtouchを同時に行う
function mduch() {
  mkdir -p "$(dirname "$1")"
  touch "$1"
}

# yazi: ディレクトリ移動連携
function y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  command yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}
