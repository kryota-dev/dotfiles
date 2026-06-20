#!/usr/bin/env bash
# Extract the mise-pinned ghq version from the given mise config (or the
# default path) and print it on stdout. Exits non-zero if the version is
# missing or does not match X.Y.Z. Shared by `make sync-ghq-completion`
# and the CI job that re-vendors the zsh completion.
set -euo pipefail

config="${1:-home/dot_config/mise/config.toml}"

if [ ! -f "$config" ]; then
  printf 'ERROR: mise config not found: %s\n' "$config" >&2
  exit 1
fi

version=$(sed -nE 's/^ghq[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*$/\1/p' "$config")

if [ -z "$version" ]; then
  printf 'ERROR: ghq version (X.Y.Z) not found in %s\n' "$config" >&2
  exit 1
fi

printf '%s\n' "$version"
