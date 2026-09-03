#!/usr/bin/env bash
# Create-only comment wrapper for the Renovate automation workflows
# (.github/workflows/renovate-gate.yml, renovate-review-action.yml and
# renovate-digest.yml). Their agents are allowlisted to call ONLY this script and
# the verdict recorder for writes, so the write surface is structurally limited to
# CREATING a comment on either the Dependency Dashboard (issue #12) or an OPEN,
# Renovate-authored PR. It can never edit or delete a comment, never call `gh api`,
# and never comment on an arbitrary issue/PR. This makes the read-only guarantee
# structural rather than prompt-dependent.
#
# Usage: renovate-triage-comment.sh <dashboard|pr> <number> <body>
#   exit 64: usage / validation error   exit 65: target is not an open Renovate PR
set -euo pipefail

usage() {
  printf 'usage: %s <dashboard|pr> <number> <body>\n' "$0" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage
target=$1
number=$2
body=$3
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

[ -n "$body" ] || {
  printf 'refusing to post an empty comment body\n' >&2
  exit 64
}

case "$target" in
  dashboard)
    [ "$number" = "12" ] || {
      printf 'dashboard target must be issue 12, got: %s\n' "$number" >&2
      exit 64
    }
    exec gh issue comment 12 --repo "$repo" --body "$body"
    ;;
  pr)
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || {
      printf 'invalid PR number: %s\n' "$number" >&2
      exit 64
    }
    # Only comment on an OPEN PR authored by Renovate. Reuse the exact author filter
    # (`app/renovate`) the triage collection step uses, so authorship semantics match.
    if ! gh pr list --repo "$repo" --author app/renovate --state open --limit 100 \
      --json number --jq '.[].number' | grep -qx "$number"; then
      printf 'PR %s is not an open Renovate PR; refusing to comment\n' "$number" >&2
      exit 65
    fi
    exec gh pr comment "$number" --repo "$repo" --body "$body"
    ;;
  *)
    usage
    ;;
esac
