#!/usr/bin/env bats

load helpers/setup

@test "shellcheck: run_once scripts pass" {
  for f in "${HOME_DIR}"/run_*.sh.tmpl; do
    # Strip all chezmoi template directives ({{ ... }}) for shellcheck
    sed -e '/{{/d' "$f" | shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 -
  done
}

@test "shellcheck: zsh modules have valid syntax" {
  for f in "${HOME_DIR}"/dot_config/zsh/*.zsh; do
    [ -f "$f" ]
  done
}
