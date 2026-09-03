#!/usr/bin/env bash
# Deterministic classifier for the Renovate merge gate
# (.github/workflows/renovate-gate.yml). Decides, using shell only, whether a
# Renovate PR can be approved without spending an agent session on it.
#
# Prints exactly one line to stdout:
#   pass<TAB><reason>          -- safe to approve without an agent
#   needs-agent<TAB><reason>   -- hand this PR to the agent for review
#
# Usage: renovate-gate-classify.sh <pr-number>
#   exit 64: usage / validation error
#
# Design notes that are easy to get wrong later:
#
#   1. CI state is deliberately NOT part of the pass conditions. The gate runs
#      the moment the PR opens, while the Test job takes minutes, so a snapshot
#      read here would report "still running" for nearly every PR and push the
#      whole deterministic lane into the agent. Worse, this gate's own commit
#      status and check run appear in statusCheckRollup, so reading it here is
#      self-referential. CI greenness is enforced where it belongs: the ruleset
#      requires the CI checks alongside this gate, so a merge needs all of them.
#      "Passing the gate" is not "merging".
#
#   2. Line counts do NOT make an update safe. A digest bump is a one-line diff
#      whose single line hides an arbitrary amount of upstream change, and the
#      skill archives tracked that way follow a moving `main` with no upstream
#      release step at all. So the pass lane is an allowlist keyed on the update
#      SHAPE (a tagged three-part semver release of a named dependency), not on
#      how small the diff looks. The `+1/-1` check narrows the allowlist further;
#      it never widens it.
#
#   3. Anything this script cannot positively classify becomes needs-agent. A
#      failed `gh` call, an unparsable payload, an unrecognised title -- all fall
#      to the agent, never to pass.
set -euo pipefail

# A pass-eligible title: Renovate's phrasing for a plain version bump of a single
# named dependency to a three-part semver release. Everything Renovate words
# differently -- `digest to`, `docker tag to`, `action to`, `<name> monorepo to`,
# `pin ... to`, and bare-major forms like `to v25` -- fails to match and is sent
# to the agent. Keeping this as a positive allowlist (rather than a denylist of
# the risky shapes) means a new Renovate title form Renovate invents later is
# routed to the agent by default instead of silently joining the fast lane.
readonly PASS_TITLE_RE='update dependency ([^ ]+) to v[0-9]+\.[0-9]+\.[0-9]+$'

# Dependencies that always get agent review, whatever shape their update takes.
#
# This is NOT the `automerge: false` config lane that .github/renovate.json5 used
# to carry. That lane said "never merge this automatically" and Renovate decided
# it from updateType alone; this says "always let the agent look", and the gate
# still decides the outcome. The distinction is why this list can live here
# without recreating the weakness that removing those rules was meant to fix.
#
# The entries are here because their update titles are shaped exactly like an
# ordinary CLI bump -- `update dependency phone-harness to v1.2.3` is
# indistinguishable by shape from `update dependency gh to v2.99.0` -- while what
# ships inside them is not ordinary at all:
#
#   phone-harness   executable Python that captures the screen and synthesises
#                   HID-level input on a real, unlocked phone.
#   affaan-m/ecc    third-party hook code that runs automatically in every agent
#                   session, with that session's tool access.
#
# Everything else the removed packageRules covered (the skill archives, the
# claude-code-action pin) is tracked as a digest, which the shape allowlist below
# already routes to the agent.
readonly ALWAYS_REVIEW_DEPS='phone-harness affaan-m/ecc'

# Renovate's bot login, matching the `--author app/renovate` filter the rest of
# the repo's tooling uses (scripts/renovate-triage-comment.sh).
readonly RENOVATE_LOGIN='app/renovate'

usage() {
  printf 'usage: %s <pr-number>\n' "$0" >&2
  exit 64
}

# Emit the verdict and stop. Reasons are Japanese because they end up in the
# workflow log and, for the needs-agent path, in the agent's prompt.
verdict() {
  printf '%s\t%s\n' "$1" "$2"
  exit 0
}

[ "$#" -eq 1 ] || usage
number=$1
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

[[ "$number" =~ ^[1-9][0-9]*$ ]] || {
  printf 'invalid PR number: %s\n' "$number" >&2
  exit 64
}

# One fetch for every field the decision needs. A failure here is not an error:
# it is simply a PR we could not classify, which is the agent's problem, not a
# reason to let the PR through.
payload=''
if ! payload="$(gh pr view "$number" --repo "$repo" \
  --json author,title,mergeable,files,labels 2>/dev/null)"; then
  verdict needs-agent 'PR 情報を取得できなかったため判定不能'
fi
[ -n "$payload" ] || verdict needs-agent 'PR 情報が空のため判定不能'

# jq failures are treated the same way as a failed fetch: unclassifiable.
field() {
  printf '%s' "$payload" | jq -r "$1" 2>/dev/null || printf 'JQ_FAILED'
}

author="$(field '.author.login // ""')"
title="$(field '.title // ""')"
mergeable="$(field '.mergeable // ""')"
file_count="$(field '.files | length')"
additions="$(field '[.files[].additions] | add // 0')"
deletions="$(field '[.files[].deletions] | add // 0')"
labels="$(field '[.labels[].name] | join(" ")')"

for v in "$author" "$title" "$mergeable" "$file_count" "$additions" "$deletions" "$labels"; do
  [ "$v" = 'JQ_FAILED' ] && verdict needs-agent 'PR 情報を解釈できなかったため判定不能'
done

# Not a Renovate PR at all. The workflow short-circuits these before calling us
# (a required check must report on every PR, including human ones), so reaching
# here means the caller skipped that step -- still not something to pass.
[ "$author" = "$RENOVATE_LOGIN" ] || {
  verdict needs-agent "Renovate 以外の作者 (${author}) のため決定論ゲートの対象外"
}

# A conflicted branch is never in the fast lane. `mergeable` is computed lazily
# by GitHub and UNKNOWN is common right after a PR opens; the caller retries once
# before invoking us, and a still-UNKNOWN value is explicitly NOT treated as a
# conflict -- only CONFLICTING is.
[ "$mergeable" = 'CONFLICTING' ] && {
  verdict needs-agent 'コンフリクトしているため要対応'
}

case "$title" in
  *'[SECURITY]'*) verdict needs-agent 'security advisory 付きの更新' ;;
esac
case " $labels " in
  *' security '* | *' vulnerability '*) verdict needs-agent 'security ラベルが付与されている' ;;
esac

# The shape allowlist. Anything Renovate words differently lands on the agent.
[[ "$title" =~ $PASS_TITLE_RE ]] || {
  verdict needs-agent 'タグ付きリリースのバージョンピン更新と判定できないタイトル'
}
dep="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"

# Shape is not enough for these: see ALWAYS_REVIEW_DEPS above.
for reviewed in $ALWAYS_REVIEW_DEPS; do
  [ "$dep" = "$reviewed" ] && {
    verdict needs-agent "実行コードを配布する依存 (${dep}) のため形に依らず要審査"
  }
done

# Narrowing checks. These can only reject; a title that failed the allowlist has
# already been sent to the agent above.
[ "$file_count" = '1' ] || {
  verdict needs-agent "変更ファイルが 1 つではない (${file_count} ファイル)"
}
[ "$additions" = '1' ] && [ "$deletions" = '1' ] || {
  verdict needs-agent "バージョンピン 1 行の差分ではない (+${additions} -${deletions})"
}

verdict pass 'タグ付きリリースへのバージョンピン 1 行更新'
