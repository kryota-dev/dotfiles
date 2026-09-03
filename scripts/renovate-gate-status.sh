#!/usr/bin/env bash
# Commit-status reporter for the Renovate merge gate
# (.github/workflows/renovate-gate.yml).
#
# Called by WORKFLOW STEPS ONLY. This script is deliberately absent from the
# review agent's --allowedTools list: the agent records its verdict with
# scripts/renovate-gate-verdict.sh (a local file write) and the workflow decides
# what status that verdict becomes. Handing this script to the agent would let it
# mark its own review as passing, which is the one thing the gate must prevent.
#
# The status context is a fixed constant, not an argument, so a caller cannot
# report under some other check's name. It is also the exact string that has to be
# registered as a required status check on `main` -- see
# docs/architecture/renovate-automation.md.
#
# Usage: renovate-gate-status.sh <sha> <success|failure|pending> <description>
#   exit 64: usage / validation error
set -euo pipefail

# The required-check name. Changing this string means re-registering the required
# status check in the repository ruleset, or the gate silently stops blocking
# merges -- tests/files.bats and the docs pin it for that reason.
readonly STATUS_CONTEXT='renovate-gate'

# GitHub truncates status descriptions at 140 characters; do it here so the API
# call cannot fail on an over-long agent-authored reason.
readonly DESCRIPTION_LIMIT=140

usage() {
  printf 'usage: %s <sha> <success|failure|pending> <description>\n' "$0" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage
sha=$1
state=$2
description=$3
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'invalid commit sha: %s\n' "$sha" >&2
  exit 64
}

case "$state" in
  success | failure | pending) ;;
  *)
    printf 'invalid state: %s (expected success, failure or pending)\n' "$state" >&2
    exit 64
    ;;
esac

[ -n "$description" ] || {
  printf 'refusing to report an empty description\n' >&2
  exit 64
}

# Cut by character, not byte, so a Japanese description is not sliced mid-rune.
description="$(printf '%s' "$description" | tr '\n' ' ' |
  jq -Rrs --argjson n "$DESCRIPTION_LIMIT" '.[0:$n]')"

exec gh api "repos/${repo}/statuses/${sha}" \
  -f "state=${state}" \
  -f "context=${STATUS_CONTEXT}" \
  -f "description=${description}"
