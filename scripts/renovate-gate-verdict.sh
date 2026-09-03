#!/usr/bin/env bash
# Verdict recorder for the Renovate merge gate
# (.github/workflows/renovate-gate.yml).
#
# This is the ONLY write tool the review agent is allowlisted to call, and it
# writes exactly one local file. It does not reach the network: it never invokes
# `gh`, never invokes `curl`, and cannot post a commit status. The workflow --
# not the agent -- reads this file afterwards and reports the status. That split
# is what makes "the agent cannot mark itself as passing" a structural property
# rather than a promise in a prompt.
#
# The destination is taken from the environment, never from argv, so the agent
# cannot redirect the verdict somewhere the workflow will not look (nor use this
# script as a general-purpose file writer).
#
# The recorded decision is data, not an action: `close` means "the workflow should
# close this PR", not "the agent closed it". Every state change stays on the
# workflow side of the split.
#
# Usage: renovate-gate-verdict.sh <pass|fail|close> <reason>
#   exit 64: usage / validation error
set -euo pipefail

usage() {
  printf 'usage: %s <pass|fail|close> <reason>\n' "$0" >&2
  exit 64
}

[ "$#" -eq 2 ] || usage
result=$1
reason=$2

case "$result" in
  pass | fail | close) ;;
  *)
    printf 'invalid verdict: %s (expected pass, fail or close)\n' "$result" >&2
    exit 64
    ;;
esac

[ -n "$reason" ] || {
  printf 'refusing to record an empty reason\n' >&2
  exit 64
}

out="${RENOVATE_GATE_VERDICT_FILE:?RENOVATE_GATE_VERDICT_FILE is not set}"

# jq builds the JSON so a reason containing quotes, backslashes or newlines
# cannot break the document the workflow parses next.
jq -n --arg result "$result" --arg reason "$reason" \
  '{result: $result, reason: $reason}' >"$out"
