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
readonly PASS_TITLE_RE='update dependency ([^ ]+) to v([0-9]+\.[0-9]+\.[0-9]+)$'

# The one file whose version pins may take the fast lane.
#
# Update titles do not carry the distinction that matters here. `update dependency
# phone-harness to v1.2.3` is shaped exactly like `update dependency gh to
# v2.99.0`, yet one of them ships Python that synthesises HID input on an unlocked
# phone and the other ships a CLI that prints GitHub issues. Naming the risky
# dependencies would work until the next time the toolchain changes -- a list of
# instances has to be maintained against a world that keeps moving.
#
# The repository already draws the line structurally, in where it keeps each pin:
#
#   home/dot_config/mise/config.toml   tools the user invokes deliberately --
#                                      gh, jq, terraform, ripgrep, the language
#                                      runtimes. Running one is a decision.
#
#   home/.chezmoidata.toml             pieces of the environment that run on
#                                      their own: ECC's hook code (every agent
#                                      session), phone-harness, the skill
#                                      archives. Nobody invokes these; they are
#                                      already running.
#
#   dot_config/ntfy/compose.yaml.tmpl  container images.
#   .github/workflows/*.yml            code that runs in CI holding secrets.
#
# So the rule is the category, not the instance: only a pin in the mise config is
# eligible for the fast lane. Adding a CLI to mise makes it eligible automatically;
# adding a skill, a hook or a new pin file does not, and a pin location nobody
# anticipated defaults to review rather than to merge.
readonly FAST_LANE_PIN_FILE='home/dot_config/mise/config.toml'

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
changed_path="$(field '.files[0].path // ""')"
additions="$(field '[.files[].additions] | add // 0')"
deletions="$(field '[.files[].deletions] | add // 0')"
labels="$(field '[.labels[].name] | join(" ")')"

for v in "$author" "$title" "$mergeable" "$file_count" "$changed_path" \
  "$additions" "$deletions" "$labels"; do
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

# Renovate writes `[SECURITY]` in caps, but matching only that spelling would let a
# differently-cased advisory title reach the fast lane. Fold the case first.
title_lc="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
case "$title_lc" in
  *'[security]'*) verdict needs-agent 'security advisory 付きの更新' ;;
esac
case " $labels " in
  *' security '* | *' vulnerability '*) verdict needs-agent 'security ラベルが付与されている' ;;
esac

# The shape allowlist. Anything Renovate words differently lands on the agent.
[[ "$title" =~ $PASS_TITLE_RE ]] || {
  verdict needs-agent 'タグ付きリリースのバージョンピン更新と判定できないタイトル'
}
# Narrowing checks. These can only reject; a title that failed the allowlist has
# already been sent to the agent above.
[ "$file_count" = '1' ] || {
  verdict needs-agent "変更ファイルが 1 つではない (${file_count} ファイル)"
}

# The category check: see FAST_LANE_PIN_FILE above. Everything pinned elsewhere --
# the skill archives, the hook code, the container images, the CI actions -- is the
# agent's to read, however ordinary its title looks.
[ "$changed_path" = "$FAST_LANE_PIN_FILE" ] || {
  verdict needs-agent "fast lane の対象外のファイル (${changed_path}) の更新のため要審査"
}
[ "$additions" = '1' ] && [ "$deletions" = '1' ] || {
  verdict needs-agent "バージョンピン 1 行の差分ではない (+${additions} -${deletions})"
}

# The title carries only the NEW version, so nothing above can tell a patch bump
# from a major one -- `update dependency X to v3.0.0` matches the shape allowlist
# exactly as `... to v2.99.0` does. Read the old version out of the diff's removed
# line (a version pin is `-gh = "2.98.0"` / `+gh = "2.99.0"`) and compare.
#
# Renovate PR bodies carry an old->new table too, but the diff is the artefact
# being merged: if the body and the diff ever disagree, the diff is what lands.
new_version="${BASH_REMATCH[2]}"
diff_out=''
if ! diff_out="$(gh pr diff "$number" --repo "$repo" 2>/dev/null)"; then
  verdict needs-agent '差分を取得できず旧バージョンを判定できないため要審査'
fi
# `|| true` matters here: under `set -o pipefail` a grep that matches nothing
# returns 1, which would abort the script inside the command substitution before
# the emptiness check below could route the PR to the agent. A diff with no
# readable old version has to become needs-agent, not a crash.
old_version="$(printf '%s' "$diff_out" |
  grep -E '^-[^-]' |
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
  head -n 1 || true)"
[ -n "$old_version" ] || {
  verdict needs-agent '差分から旧バージョンを読み取れないため要審査'
}

old_major="${old_version%%.*}"
new_major="${new_version%%.*}"
[ "$old_major" = "$new_major" ] || {
  verdict needs-agent "メジャー更新 (${old_version} -> ${new_version}) のため要審査"
}

# Under semver a 0.x minor bump is allowed to break, so 0.x only takes the fast
# lane when the minor is unchanged. This is why `npm:agent-browser 0.35.2 ->
# 0.36.0` does not sail through as an ordinary minor.
if [ "$new_major" = '0' ]; then
  old_minor="${old_version#*.}"
  old_minor="${old_minor%%.*}"
  new_minor="${new_version#*.}"
  new_minor="${new_minor%%.*}"
  [ "$old_minor" = "$new_minor" ] || {
    verdict needs-agent "0.x 系のマイナー更新 (${old_version} -> ${new_version}) は破壊的変更を許すため要審査"
  }
fi

verdict pass "タグ付きリリースへのバージョンピン 1 行更新 (${old_version} -> ${new_version})"
