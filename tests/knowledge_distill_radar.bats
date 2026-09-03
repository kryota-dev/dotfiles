#!/usr/bin/env bats

# knowledge-distill radar wrapper (home/dot_claude/executable_knowledge-distill-radar.sh, #368).
# The wrapper is source-safe (side effects live in main() behind a BASH_SOURCE
# guard), so these tests both source it to exercise the pure helpers and run it
# end-to-end with claude + curl stubbed on PATH — no network, no server, CI-safe.
# Covers: permission allowlist hygiene, token hygiene, fail-open ntfy delivery,
# the same-week guard, the independent dry-pipeline precheck, and main()'s
# stamp/notification wiring for both healthy and dry weeks.

load helpers/setup

WRAPPER="${HOME_DIR}/dot_claude/executable_knowledge-distill-radar.sh"

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB_DIR"
  cat >"${STUB_DIR}/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${NTFY_TEST_STUB_DIR}/curl_args"
cat >"${NTFY_TEST_STUB_DIR}/curl_stdin"
exit "${NTFY_TEST_CURL_EXIT:-0}"
EOF
  chmod +x "${STUB_DIR}/curl"

  ENV_FILE="${BATS_TEST_TMPDIR}/notify-env"
  cat >"$ENV_FILE" <<'EOF'
NTFY_URL='http://127.0.0.1:9'
NTFY_TOKEN='tk_bats_secret'
NTFY_TOPIC_ATTENTION='claude-attention'
NTFY_TOPIC_DONE='claude-done'
NTFY_TOPIC_BRIEF='claude-brief'
EOF
  chmod 600 "$ENV_FILE"

  LOG_FILE="${BATS_TEST_TMPDIR}/knowledge-distill-radar.log"
}

# Source the wrapper (main() is guarded, so nothing runs) and call one of its
# functions with the stubbed PATH and fixture env.
run_fn() {
  run env \
    PATH="${STUB_DIR}:${PATH}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" \
    NTFY_TEST_CURL_EXIT="${NTFY_TEST_CURL_EXIT:-0}" \
    KNOWLEDGE_DISTILL_RADAR_NTFY_ENV_FILE="$ENV_FILE" \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="$LOG_FILE" \
    bash -c 'source "$1"; shift; fn="$1"; shift; "$fn" "$@"' _ "$WRAPPER" "$@"
}

@test "knowledge-distill-radar.sh exists and passes bash -n" {
  [ -f "$WRAPPER" ]
  bash -n "$WRAPPER"
}

@test "no dangerously-skip-permissions / bypassPermissions bypass" {
  run grep -q 'dangerously-skip-permissions' "$WRAPPER"
  [ "$status" -ne 0 ]
  run grep -q 'bypassPermissions' "$WRAPPER"
  [ "$status" -ne 0 ]
}

@test "keeps the explicit permission allowlist and pinned model/turns" {
  grep -q -- '--allowedTools' "$WRAPPER"
  grep -q -- '--max-turns' "$WRAPPER"
  grep -q -- '--model' "$WRAPPER"
  grep -q 'CLAUDE_CONFIG_DIR' "$WRAPPER"
}

@test "allowlist grants Skill(knowledge-distill) and confines writes to the report dir" {
  local allowed_tools_line
  allowed_tools_line="$(grep '^ALLOWED_TOOLS=' "$WRAPPER")"
  [[ "$allowed_tools_line" == *'Skill(knowledge-distill)'* ]]
  [[ "$allowed_tools_line" == *'Edit(~/dotfiles/.kryota-dev/knowledge-distill/**)'* ]]
  # No page-delivery tool for this radar (unlike morning-radar's brief page).
  [[ "$allowed_tools_line" != *'Artifact'* ]]
}

@test "allowlist pins the individual read-only Bash prefixes and excludes write commands" {
  local allowed_tools_line
  allowed_tools_line="$(grep '^ALLOWED_TOOLS=' "$WRAPPER")"
  for prefix in 'Bash(ls:*)' 'Bash(cat:*)' 'Bash(date:*)' 'Bash(jq:*)' 'Bash(grep:*)' \
    'Bash(find:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(wc:*)' 'Bash(printf:*)' 'Bash(ghq list:*)'; do
    [[ "$allowed_tools_line" == *"$prefix"* ]]
  done
  # instinct-cli.py must be scoped to the read-only `evolve` subcommand, not a
  # bare script-path wildcard (the CLI also has import/promote/prune, which
  # mutate or delete instinct state).
  [[ "$allowed_tools_line" == *'instinct-cli.py evolve:*'* ]]
  run grep -qE 'Bash\((rm|mv|cp|dd|truncate|shred)([[:space:]:]|$)' <<<"$allowed_tools_line"
  [ "$status" -ne 0 ]
}

@test "allowlist grants the Phase 0.5 memory-revalidate script by full path only (#631)" {
  local allowed_tools_line skill_dir
  allowed_tools_line="$(grep '^ALLOWED_TOOLS=' "$WRAPPER")"
  skill_dir="${HOME_DIR}/dot_agents/skills/knowledge-distill"
  # A command that is not on the allowlist is denied silently in a headless run, so a
  # phase written into SKILL.md but missing from here is indistinguishable from a phase
  # that does not exist -- the same class of failure as #491 (a phase that never ran).
  [[ "$allowed_tools_line" == *'Bash(python3 ~/.agents/skills/knowledge-distill/scripts/memory-revalidate.py:*)'* ]]
  # Full path only: widening to a bare `python3` prefix would turn the read-mostly
  # allowlist into arbitrary script execution.
  [[ "$allowed_tools_line" != *'Bash(python3:*)'* ]]
  # The granted script must actually exist in source, and SKILL.md must invoke that same
  # path -- otherwise the grant outlives the phase (or vice versa) without anything failing.
  [ -f "${skill_dir}/scripts/memory-revalidate.py" ]
  grep -qF 'scripts/memory-revalidate.py' "${skill_dir}/SKILL.md"
  # The headless prompt has to name the phase, or claude has no reason to run it.
  grep -qF 'Phase 0.5' "$WRAPPER"
  # `Bash(<full path>:*)` constrains the command NAME only -- everything after it is
  # unvalidated. --memory-dir / --repo / --rules / --config-dir all take arbitrary paths,
  # so a prompt injection carried in an instinct or a session summary could widen what the
  # weekly run reads, and the allowlist would not object. The prompt has to pin the
  # argument list and say so.
  grep -qF -- '--memory-dir / --repo / --rules / --config-dir は付けないでください' "$WRAPPER"
}

@test "token hygiene: no -H/--header Authorization, no set -x, token via -K" {
  run grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$WRAPPER"
  [ "$status" -ne 0 ]
  ! grep -qF 'set -x' "$WRAPPER"
  grep -qF 'curl -fs -K' "$WRAPPER"
}

@test "does not hand-copy per-account isolation env (delegates to the claude launcher, #336/#345)" {
  # Unlike morning-radar, this wrapper DOES legitimately reference the
  # ecc-homunculus-default fallback path (HOMUNCULUS_DIR, matching SKILL.md's
  # own Phase 0 fallback) for its independent precheck, and its PROMPT text
  # quotes SKILL.md's `CLV2_HOMUNCULUS_DIR="$H"` anti-pattern to tell claude
  # NOT to replicate it -- only a line-start (real shell) re-assignment of the
  # isolation env vars themselves is forbidden, so the check is anchored to
  # `^` to ignore prose that merely mentions the var name mid-line.
  run grep -qE '^CLV2_HOMUNCULUS_DIR=|^ECC_AGENT_DATA_HOME=|^GATEGUARD_STATE_DIR=|^ECC_MCP_HEALTH_STATE_PATH=' "$WRAPPER"
  [ "$status" -ne 0 ]
  grep -qF '$HOME/.local/launchers:' "$WRAPPER"
  grep -qF 'CLAUDE_CONFIG_DIR="$HOME/.claude"' "$WRAPPER"
  grep -qF 'EXA_API_KEY=""' "$WRAPPER"
  grep -qF 'FIRECRAWL_API_KEY=""' "$WRAPPER"
}

@test "ntfy_publish -> claude-attention topic with given priority and message" {
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: 昇華提案 4件"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_stdin" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "HEADLINE: 昇華提案 4件" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
  [ "$(jq -r 'has("click")' <"${STUB_DIR}/curl_stdin")" = "false" ]
  [ "$(jq -r '.tags | join(",")' <"${STUB_DIR}/curl_stdin")" = "microscope,knowledge-distill" ]
}

@test "notify_error publishes priority 5 to claude-attention" {
  run_fn notify_error "claude not found"
  [ "$status" -eq 0 ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "claude not found" ]
}

@test "token never reaches curl argv (travels via -K config file)" {
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ -f "${STUB_DIR}/curl_args" ]
  ! grep -q 'tk_bats_secret' "${STUB_DIR}/curl_args"
  grep -qE -- '-K' "${STUB_DIR}/curl_args"
}

@test "publish failure is fail-open: returns 0, token never logged" {
  NTFY_TEST_CURL_EXIT=1 run_fn ntfy_publish 5 "Knowledge Distill" "boom"
  [ "$status" -eq 0 ]
  ! grep -q 'tk_bats_secret' "$LOG_FILE"
}

@test "no env file -> silent no-op, no publish" {
  rm -f "$ENV_FILE"
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_stdin" ]
}

@test "group/other-readable env file fails open without publishing" {
  chmod 644 "$ENV_FILE"
  run_fn ntfy_publish 3 "Knowledge Distill" "HEADLINE: ok"
  [ "$status" -eq 0 ]
  [ ! -f "${STUB_DIR}/curl_stdin" ]
}

@test "same-week guard skips a second run within the same ISO week" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local tmp
  tmp="$(_mktemp_dir)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "${tmp}/state/knowledge-distill-radar"
  printf '%s\n' "$(date +%G-W%V)" >"${tmp}/state/knowledge-distill-radar/last-run"
  # claude is not resolvable from the sandboxed HOME, so a bypassed guard would exit 1.
  run env HOME="$tmp" XDG_STATE_HOME="${tmp}/state" bash "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "main(): healthy pipeline publishes the plain HEADLINE and stamps the week" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-healthy"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy" \
    "${home}/.local/share/ecc-homunculus-default/projects/proj1/instincts/personal"
  # 10 instincts == the MIN_INSTINCTS default: not dry. Project-scoped (#491):
  # CLV2 v2.1 moved instinct storage from the global tier to per-project.
  for i in $(seq 1 10); do
    printf 'instinct %s\n' "$i" >"${home}/.local/share/ecc-homunculus-default/projects/proj1/instincts/personal/inst-${i}.md"
  done
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
# Extract the report path from the -p prompt so the stub writes where the
# wrapper expects (mirrors the wrapper's own $REPORT_FILE construction).
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# Knowledge Distill\n\n昇華提案 4件。\n' >"$report"
echo "HEADLINE: 昇華提案 4件 / instinct 12件"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
  # The "HEADLINE:" prefix is stripped before publishing (matches morning-radar).
  [ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" = "昇華提案 4件 / instinct 12件" ]
  run grep -qF '縮退' <(jq -r .message <"${STUB_DIR}/curl_stdin")
  [ "$status" -ne 0 ]
}

@test "main(): dry pipeline is flagged explicitly regardless of claude's own wording" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-dry"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy" \
    "${home}/.local/share/ecc-homunculus-default/projects/proj1/instincts/personal"
  # 3 instincts < the MIN_INSTINCTS default (10): dry pipeline. Project-scoped (#491).
  for i in 1 2 3; do
    printf 'instinct %s\n' "$i" >"${home}/.local/share/ecc-homunculus-default/projects/proj1/instincts/personal/inst-${i}.md"
  done
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# Knowledge Distill (degraded)\n\ninstinct 蓄積不足。\n' >"$report"
echo "HEADLINE: 縮退終了"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  local message
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  [[ "$message" == *"縮退"* ]]
  [[ "$message" == *"3/10"* ]]
}

@test "main(): instincts dir does not exist yet (zero accumulated) -> dry, does not abort under pipefail" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-no-instincts-dir"
  # Deliberately do NOT create .local/share/ecc-homunculus-default/projects:
  # this is the exact "zero instincts accumulated" case the precheck's `|| true`
  # guard exists to handle (find on a nonexistent dir exits non-zero under pipefail).
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# Knowledge Distill (degraded)\n\ninstinct 蓄積なし。\n' >"$report"
echo "HEADLINE: 縮退終了"
EOF
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  local message
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  [[ "$message" == *"縮退"* ]]
  [[ "$message" == *"0/10"* ]]
}

@test "count_instincts: project-scoped personal+inherited >= 10 -> healthy (not dry)" {
  local h="${BATS_TEST_TMPDIR}/count-healthy"
  mkdir -p "${h}/projects/proj1/instincts/personal" "${h}/projects/proj1/instincts/inherited"
  for i in $(seq 1 7); do
    printf 'instinct %s\n' "$i" >"${h}/projects/proj1/instincts/personal/inst-${i}.md"
  done
  for i in 1 2 3; do
    printf 'instinct %s\n' "$i" >"${h}/projects/proj1/instincts/inherited/inst-${i}.yaml"
  done
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" -eq 10 ]
}

@test "count_instincts: sums personal+inherited across multiple projects" {
  local h="${BATS_TEST_TMPDIR}/count-multi"
  mkdir -p "${h}/projects/proj1/instincts/personal" "${h}/projects/proj2/instincts/inherited"
  printf 'a\n' >"${h}/projects/proj1/instincts/personal/inst-1.md"
  printf 'b\n' >"${h}/projects/proj1/instincts/personal/inst-2.yml"
  printf 'c\n' >"${h}/projects/proj2/instincts/inherited/inst-3.yaml"
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ]
}

@test "count_instincts: MEMORY.md and non-instinct extensions are excluded" {
  local h="${BATS_TEST_TMPDIR}/count-exclusions"
  mkdir -p "${h}/projects/proj1/instincts/personal"
  printf 'real\n' >"${h}/projects/proj1/instincts/personal/inst-1.md"
  # MEMORY.md is a memory index, not an instinct -- no `id:` frontmatter, and
  # instinct-cli.py's own parser counts it as zero. Must be excluded by name.
  printf '# memory\n' >"${h}/projects/proj1/instincts/personal/MEMORY.md"
  # Extensions outside instinct-cli.py's ALLOWED_INSTINCT_EXTENSIONS (.md/.yaml/.yml).
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/notes.py"
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/inst-1.md.tmp"
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "count_instincts: global-tier instincts/personal/ (promotion destination) is not counted" {
  local h="${BATS_TEST_TMPDIR}/count-global-only"
  # Files placed directly at $H/instincts/personal (the OLD global-tier path,
  # not under projects/) must NOT be counted: instinct-cli.py's cmd_promote
  # COPIES a project instinct into this global dir (write_text on a new path;
  # the project-side file is left in place), so summing both tiers would
  # double-count an already-promoted instinct (#491).
  mkdir -p "${h}/instincts/personal"
  printf 'promoted\n' >"${h}/instincts/personal/inst-1.md"
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "count_instincts: no projects dir yet -> 0, does not fail under pipefail" {
  local h="${BATS_TEST_TMPDIR}/count-no-projects-dir"
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# instinct-cli.py compares `file.suffix.lower()` against its allowed
# extensions, so an upper/mixed-case suffix is a valid instinct to the engine.
# `find -name` is case-sensitive; `-iname` keeps the two counts aligned.
@test "count_instincts matches extensions case-insensitively (as instinct-cli.py does)" {
  local h="${BATS_TEST_TMPDIR}/case"
  mkdir -p "${h}/projects/proj1/instincts/personal"
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/lower.md"
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/upper.MD"
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/upper.YAML"
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/mixed.YmL"
  # MEMORY.md is excluded case-insensitively too (the engine parses zero
  # instincts out of a memory index whatever its casing).
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/memory.MD"
  run_fn count_instincts "$h"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "wrapper and SKILL.md Phase 0 instinct-count expressions agree" {
  # #491 completion condition: the wrapper's independent precheck and the
  # skill's own Phase 0 diagnostic must never silently disagree again. Extract
  # the actual expression from each source (delimited by matching marker
  # comments) and execute both against the same fixture tree, rather than
  # trusting a comment to say they match.
  local skill="${HOME_DIR}/dot_agents/skills/knowledge-distill/SKILL.md"
  local wrapper_expr skill_expr
  wrapper_expr="$(sed -n '/# knowledge-distill-instinct-count:begin/,/# knowledge-distill-instinct-count:end/p' "$WRAPPER" | sed '1d;$d')"
  skill_expr="$(sed -n '/# knowledge-distill-instinct-count:begin/,/# knowledge-distill-instinct-count:end/p' "$skill" | sed '1d;$d')"
  [ -n "$wrapper_expr" ]
  [ -n "$skill_expr" ]

  # String-level check too (normalized for indentation and trailing comments):
  # both sides should be the same logical command, not just agree by
  # coincidence on the one fixture exercised below.
  local wrapper_norm skill_norm
  wrapper_norm="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+#.*$//' <<<"$wrapper_expr")"
  skill_norm="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+#.*$//' <<<"$skill_expr")"
  [ "$wrapper_norm" = "$skill_norm" ]

  local h="${BATS_TEST_TMPDIR}/agree"
  mkdir -p "${h}/projects/proj1/instincts/personal" "${h}/projects/proj2/instincts/inherited"
  for i in $(seq 1 6); do
    printf 'x\n' >"${h}/projects/proj1/instincts/personal/inst-${i}.md"
  done
  for i in 1 2; do
    printf 'x\n' >"${h}/projects/proj2/instincts/inherited/inst-${i}.yaml"
  done
  printf 'x\n' >"${h}/projects/proj1/instincts/personal/MEMORY.md"

  # `wc -l` pads its count on BSD but not on GNU, so compare the trimmed
  # values -- the point of this test is the count, not wc's field width.
  local wrapper_result skill_result
  wrapper_result="$(H="$h" bash -c "$wrapper_expr" | tr -d '[:space:]')"
  skill_result="$(H="$h" bash -c "$skill_expr" | tr -d '[:space:]')"
  [ "$wrapper_result" = "8" ]
  [ "$skill_result" = "8" ]
  [ "$wrapper_result" = "$skill_result" ]
}

# The skill's copy of the expression is executed by a headless claude under
# this wrapper's --allowedTools, so every binary it names has to be one of the
# granted Bash prefixes -- `printf` is on that list for exactly this reason.
# An expression that reaches for `tr`, `xargs` or `|| true` parses fine here
# and is silently denied in production, which is the same class of failure
# #491 itself was (a phase that never runs). Pin the shared region to the
# allowlist so that cannot be reintroduced unnoticed.
@test "the shared instinct-count expression only uses allowlisted binaries" {
  local skill="${HOME_DIR}/dot_agents/skills/knowledge-distill/SKILL.md"
  local allowed_tools_line expr word
  allowed_tools_line="$(grep '^ALLOWED_TOOLS=' "$WRAPPER")"

  for src in "$WRAPPER" "$skill"; do
    expr="$(sed -n '/# knowledge-distill-instinct-count:begin/,/# knowledge-distill-instinct-count:end/p' "$src" | sed '1d;$d')"
    [ -n "$expr" ]
    # Fold the backslash continuations onto one line first, so each `|` stage
    # becomes exactly one line and its command word is that line's first token.
    for word in $(printf '%s' "$expr" | tr '\n' ' ' | tr '|' '\n' | sed -E 's/^[[:space:]]*//; s/[[:space:]].*$//' | grep -v '^$'); do
      [[ "$allowed_tools_line" == *"Bash(${word}:*)"* ]]
    done
    # No shell-level chaining: each of these introduces a command the
    # allowlist does not cover (`true`) or an unparsed compound.
    [[ "$expr" != *'|| '* ]]
    [[ "$expr" != *'&& '* ]]
    [[ "$expr" != *';'* ]]
  done
}

@test "main(): a failed run notifies attention priority 5 and leaves no stamp" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-fail"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  printf '%s\n' '#!/bin/bash' 'exit 1' >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 1 ]
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
}

@test "main(): claude exits 0 but writes no report file -> treated as failure, no stamp" {
  [ "$(uname)" = "Darwin" ] || skip "main() is Darwin-only (uname guard exits early)"
  local home="${BATS_TEST_TMPDIR}/home-no-report"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  # Exits 0 and prints a HEADLINE, but never writes the report file -- this is
  # the output-contract violation design.md Error Scenario 3 describes, distinct
  # from the claude-exit-1 path covered by the test above.
  printf '%s\n' '#!/bin/bash' 'echo "HEADLINE: ok"' >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=2 \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
  [ "$status" -eq 1 ]
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
  grep -qF 'report file missing' "${home}/radar.log"
  [ "$(jq -r .topic <"${STUB_DIR}/curl_stdin")" = "claude-attention" ]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
}

# --- Failure tracking and measured limits (#643) --------------------------
#
# Four consecutive weeks failed with nothing recorded anywhere, so nobody
# noticed for five weeks. The tests below pin the two halves of the fix: the
# limits are sized from measurement, and every run leaves a record behind.

# Build a fake HOME with the launchers, the ntfy env file and a stubbed curl.
# Mirrors the fixture the four main() tests above assemble by hand; the run
# history tests need the same scaffolding several more times.
#
# It also stubs `uname` to report Darwin. The wrapper opens main() with a
# `[ "$(uname)" = "Darwin" ] || exit 0` guard because the job is a macOS
# LaunchAgent, and the CI Bats job runs on ubuntu-latest -- so without this the
# entire failure-tracking path would be verified on a developer's Mac and
# nowhere else, which is close to not being verified at all. The stub is
# resolvable because main()'s first act is to put ~/.local/launchers at the
# front of PATH. What it lets us test is the platform-independent half
# (classification, recording, retry, notification); the platform gate itself is
# not what these tests are about.
mkfixture() {
  local home="$1"
  mkdir -p "${home}/.local/launchers" "${home}/.config/ntfy"
  printf '%s\n' '#!/bin/bash' 'echo Darwin' >"${home}/.local/launchers/uname"
  chmod +x "${home}/.local/launchers/uname"
  cp "${STUB_DIR}/curl" "${home}/.local/launchers/curl"
  cp "$ENV_FILE" "${home}/.config/ntfy/notify-env"
  chmod 600 "${home}/.config/ntfy/notify-env"
}

# A fake claude that records its argv, then behaves as the caller asked.
# `$HOME/argv` receives one argument per line so a test can assert on the exact
# flags the wrapper passed, rather than on the source text that produced them.
mkclaude() {
  local home="$1" body="$2"
  {
    printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$@" >"$HOME/argv"'
    printf '%s\n' "$body"
  } >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
}

# The body of a fake claude that succeeds: writes the report the wrapper expects
# and prints a JSON envelope carrying the headline.
CLAUDE_OK_BODY='report="$(printf "%s" "$*" | grep -oE "[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md" | head -1)"
mkdir -p "$(dirname "$report")"
printf "# report\n" >"$report"
printf "%s\n" "{\"session_id\":\"s\",\"is_error\":false,\"subtype\":\"success\",\"num_turns\":37,\"result\":\"HEADLINE: 昇華提案 2件\"}"'

# Run the wrapper against a fixture HOME. Extra env assignments may be passed
# as KEY=VALUE arguments. TMPDIR is handed through deliberately: launchd sets
# it in production, and `env -i` without it is a less faithful fixture, not a
# stricter one.
runmain() {
  local home="$1"
  shift
  run env -i HOME="$home" XDG_STATE_HOME="${home}/state" \
    TMPDIR="${BATS_TEST_TMPDIR}" \
    NTFY_TEST_STUB_DIR="$STUB_DIR" NTFY_TEST_CURL_EXIT=0 \
    KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=3 \
    KNOWLEDGE_DISTILL_RADAR_RETRY_DELAY_SECONDS=0 \
    KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${HOME_DIR}/dot_claude/job-runlog.sh" \
    KNOWLEDGE_DISTILL_RADAR_LOG_FILE="${home}/radar.log" \
    "$@" \
    bash -c 'bash "$1" >/dev/null 2>&1' _ "$WRAPPER"
}

runlog_of() {
  printf '%s\n' "$1/state/knowledge-distill-radar/runs.jsonl"
}

@test "limits are sized from measured runs, not raised blindly (#643)" {
  # Measured on the real job: ~10.5s per tool call across three runs; the two
  # max-turns deaths spent 523s and 539s reaching turn 50, and the one success
  # finished in 589s of a 600s budget -- 1.8% of headroom. At that throughput a
  # 600s watchdog cannot hold 50 serialized turns, so the backstop had become
  # the primary limit. 80 x 10.5s is about 840s, which puts --max-turns back in
  # front of the watchdog, the relationship the watchdog comment claims.
  grep -qE '^MAX_TURNS=80$' "$WRAPPER"
  grep -qE '^TIMEOUT_SECONDS="\$\{KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS:-1200\}"$' "$WRAPPER"
  # The reasoning has to travel with the numbers, or the next person raising
  # them has no baseline to argue against.
  grep -qF '589' "$WRAPPER"
}

@test "prompt forbids shell chaining but allows batching calls into one turn (#643)" {
  # The allowlist is prefix-matched per command, which is why the prompt bans
  # `;` and `&&`. That ban is about the shell, not about how many independent
  # Bash calls one turn may carry -- and reading it as the latter is what burnt
  # 50 turns on 50 calls. The measured run that did batch reached 1.93 calls
  # per turn, i.e. the same work inside 30 turns.
  grep -qF 'セミコロンや && で連結しないでください' "$WRAPPER"
  grep -qF '同一ターンでまとめて発行' "$WRAPPER"
}

@test "main(): a failed run is recorded with a machine-readable cause" {
  local home="${BATS_TEST_TMPDIR}/home-record-fail"
  mkfixture "$home"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
echo "Error: Reached max turns (80)" >&2
exit 1
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 1 ]
  local log
  log="$(runlog_of "$home")"
  [ -f "$log" ]
  [ "$(wc -l <"$log")" -eq 1 ]
  [ "$(jq -r .status <"$log")" = "max_turns" ]
  [ "$(jq -r .exit_code <"$log")" = "1" ]
  [ "$(jq -r .attempt <"$log")" = "1" ]
  [ "$(jq -r .period <"$log")" = "$(date +%G-W%V)" ]
  # Which signal decided the classification, following the convention #526
  # established for the same ambiguity in frontier-harness.
  [ "$(jq -r .decided_by <"$log")" = "stderr" ]
  run bash -c 'jq -e ".duration_seconds | type == \"number\"" <"$1"' _ "$log"
  [ "$status" -eq 0 ]
  # The record is per-user state, not something to leave world-readable.
  [ "$(_file_mode "$log")" = "600" ]
  [ "$(_file_mode "$(dirname "$log")")" = "700" ]
}

@test "main(): the same cause twice running is called out in the notification" {
  local home="${BATS_TEST_TMPDIR}/home-streak"
  mkfixture "$home"
  mkdir -p "${home}/state/knowledge-distill-radar"
  printf '%s\n' \
    '{"status":"max_turns","period":"2026-W35","ts_epoch":1}' \
    >"$(runlog_of "$home")"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
echo "Error: Reached max turns (80)" >&2
exit 1
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 1 ]
  local message
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  # Two distinct scheduled slots, same cause: this is the signal that separates
  # a one-off outage from something that will keep happening.
  [[ "$message" == *"2週連続"* ]]
  [[ "$message" == *"max_turns"* ]]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "5" ]
}

@test "main(): a single failure is not dressed up as a streak" {
  local home="${BATS_TEST_TMPDIR}/home-no-streak"
  mkfixture "$home"
  mkdir -p "${home}/state/knowledge-distill-radar"
  # Last week failed for a DIFFERENT reason, so the streak restarts.
  printf '%s\n' \
    '{"status":"timeout","period":"2026-W35","ts_epoch":1}' \
    >"$(runlog_of "$home")"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
echo "Error: Reached max turns (80)" >&2
exit 1
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 1 ]
  local message
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  [[ "$message" != *"週連続"* ]]
}

@test "main(): the watchdog timeout is recorded as its own cause" {
  local home="${BATS_TEST_TMPDIR}/home-timeout"
  mkfixture "$home"
  printf '%s\n' '#!/bin/bash' 'sleep 30' >"${home}/.local/launchers/claude"
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home" KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=1
  [ "$status" -eq 1 ]
  local log
  log="$(runlog_of "$home")"
  [ "$(jq -r .status <"$log")" = "timeout" ]
  [ "$(jq -r .decided_by <"$log")" = "exit_code" ]
  # No envelope survives a SIGTERM (#526 §1.3), so the turn count is absent
  # rather than invented.
  [ "$(jq -r .num_turns <"$log")" = "null" ]
  grep -qF 'timed out' "${home}/radar.log"
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
}

@test "main(): a transient API error is retried once and both attempts are recorded" {
  local home="${BATS_TEST_TMPDIR}/home-retry"
  mkfixture "$home"
  # 08-07 failed this way on a coalesced wake fire, before the network was up.
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
n=$(cat "$HOME/attempts" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$HOME/attempts"
if [ "$n" -eq 1 ]; then
  echo "API Error: Unable to connect to API (ENOTFOUND)" >&2
  exit 1
fi
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# report\n' >"$report"
printf '%s\n' '{"session_id":"s","is_error":false,"subtype":"success","num_turns":21,"result":"HEADLINE: 復旧後の縮退レポート"}'
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 0 ]
  [ "$(cat "${home}/attempts")" = "2" ]
  local log
  log="$(runlog_of "$home")"
  [ "$(wc -l <"$log")" -eq 2 ]
  [ "$(head -1 "$log" | jq -r .status)" = "api_error" ]
  [ "$(head -1 "$log" | jq -r .attempt)" = "1" ]
  [ "$(tail -1 "$log" | jq -r .status)" = "ok" ]
  [ "$(tail -1 "$log" | jq -r .attempt)" = "2" ]
  # The week is only stamped once the retry actually produced the report.
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
}

@test "main(): budget exhaustion is not retried" {
  local home="${BATS_TEST_TMPDIR}/home-noretry"
  mkfixture "$home"
  # Re-running a run that ran out of turns just spends the budget twice and
  # dies in the same place, so this path must stay single-shot.
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
n=$(cat "$HOME/attempts" 2>/dev/null || echo 0)
echo "$((n + 1))" >"$HOME/attempts"
echo "Error: Reached max turns (80)" >&2
exit 1
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 1 ]
  [ "$(cat "${home}/attempts")" = "1" ]
  [ "$(wc -l <"$(runlog_of "$home")")" -eq 1 ]
}

@test "main(): a success after a failure records ok and says it recovered" {
  local home="${BATS_TEST_TMPDIR}/home-recover"
  mkfixture "$home"
  mkdir -p "${home}/state/knowledge-distill-radar"
  printf '%s\n' \
    '{"status":"max_turns","period":"2026-W35","ts_epoch":1}' \
    >"$(runlog_of "$home")"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# report\n' >"$report"
printf '%s\n' '{"session_id":"s","is_error":false,"subtype":"success","num_turns":37,"result":"HEADLINE: 昇華提案 2件"}'
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 0 ]
  local log message
  log="$(runlog_of "$home")"
  [ "$(tail -1 "$log" | jq -r .status)" = "ok" ]
  # num_turns is the number that had to be dug out of session transcripts to
  # size the limits at all; from now on it is in the record.
  [ "$(tail -1 "$log" | jq -r .num_turns)" = "37" ]
  [ "$(tail -1 "$log" | jq -r .subtype)" = "success" ]
  message="$(jq -r .message <"${STUB_DIR}/curl_stdin")"
  [[ "$message" == *"復旧"* ]]
  # The headline still comes through, now read out of the JSON envelope.
  [[ "$message" == *"昇華提案 2件"* ]]
  [ "$(jq -r .priority <"${STUB_DIR}/curl_stdin")" = "3" ]
}

@test "main(): a missing run-history library degrades loudly, not silently" {
  local home="${BATS_TEST_TMPDIR}/home-nolib"
  mkfixture "$home"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
report="$(printf '%s' "$*" | grep -oE '[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md' | head -1)"
mkdir -p "$(dirname "$report")"
printf '# report\n' >"$report"
printf '%s\n' '{"session_id":"s","is_error":false,"subtype":"success","num_turns":12,"result":"HEADLINE: ok"}'
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home" KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${home}/absent-lib.sh"
  # Losing the bookkeeping must not lose the report.
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  # But it must not pass for a normal week either: a record that is quietly
  # absent is indistinguishable from a week that never ran, which is the exact
  # failure this whole change exists to remove.
  grep -qF 'run history unavailable' "${home}/radar.log"
  [[ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" == *"実行履歴を記録できませんでした"* ]]
}

@test "main(): a long gap since the last success is surfaced on the notification" {
  local home="${BATS_TEST_TMPDIR}/home-stale"
  mkfixture "$home"
  mkdir -p "${home}/state/knowledge-distill-radar"
  local now
  now="$(date +%s)"
  # Succeeded 35 days ago, has failed since: the shape #643 sat in unnoticed.
  printf '%s\n' \
    "{\"status\":\"ok\",\"period\":\"2026-W31\",\"ts_epoch\":$((now - 35 * 86400))}" \
    "{\"status\":\"timeout\",\"period\":\"2026-W35\",\"ts_epoch\":$((now - 7 * 86400))}" \
    >"$(runlog_of "$home")"
  cat >"${home}/.local/launchers/claude" <<'EOF'
#!/bin/bash
echo "Error: Reached max turns (80)" >&2
exit 1
EOF
  chmod +x "${home}/.local/launchers/claude"
  runmain "$home"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" == *"最終成功から35日"* ]]
}

@test "main(): claude missing from PATH is recorded too" {
  local home="${BATS_TEST_TMPDIR}/home-noclaude"
  mkfixture "$home"
  runmain "$home"
  [ "$status" -eq 1 ]
  [ "$(jq -r .status <"$(runlog_of "$home")")" = "no_claude" ]
}

# Echo the argument that follows <flag> in a captured argv file (one arg/line),
# so a test can assert on what the wrapper actually passed rather than on the
# source text that produced it.
argv_value() {
  awk -v f="$2" '$0 == f { getline; print; exit }' "$1"
}

@test "main(): the measured limits reach claude as actual arguments" {
  # Pinning MAX_TURNS=80 in the source does not prove the launch used it: the
  # value could stay while CLAUDE_ARGS drifts. AC-1 is about the invocation.
  local home="${BATS_TEST_TMPDIR}/home-argv"
  mkfixture "$home"
  mkclaude "$home" "$CLAUDE_OK_BODY"
  runmain "$home"
  [ "$status" -eq 0 ]
  [ "$(argv_value "${home}/argv" --max-turns)" = "80" ]
  [ "$(argv_value "${home}/argv" --model)" = "sonnet" ]
  # The envelope is what carries num_turns into the record.
  [ "$(argv_value "${home}/argv" --output-format)" = "json" ]
  grep -qFx -- '--allowedTools' "${home}/argv"
}

@test "main(): exit 0 without a report is classified no_report, decided by the output contract" {
  local home="${BATS_TEST_TMPDIR}/home-noreport-class"
  mkfixture "$home"
  # Exits 0 and prints a well-formed envelope, but writes no report file.
  mkclaude "$home" 'printf "%s\n" "{\"session_id\":\"s\",\"is_error\":false,\"subtype\":\"success\",\"num_turns\":12,\"result\":\"HEADLINE: ok\"}"'
  runmain "$home"
  [ "$status" -eq 1 ]
  local log
  log="$(runlog_of "$home")"
  [ "$(jq -r .status <"$log")" = "no_report" ]
  # Neither the exit code nor the envelope called this a failure -- the missing
  # artifact did, and the record has to say so.
  [ "$(jq -r .decided_by <"$log")" = "output_contract" ]
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
}

@test "main(): an unrecognised non-zero exit is classified exec_error" {
  local home="${BATS_TEST_TMPDIR}/home-exec-error"
  mkfixture "$home"
  # Fails with a message that matches none of the known causes.
  mkclaude "$home" 'echo "something else entirely" >&2
exit 3'
  runmain "$home"
  [ "$status" -eq 1 ]
  local log
  log="$(runlog_of "$home")"
  [ "$(jq -r .status <"$log")" = "exec_error" ]
  [ "$(jq -r .decided_by <"$log")" = "exit_code" ]
  [ "$(jq -r .exit_code <"$log")" = "3" ]
}

@test "main(): the envelope subtype outranks the stderr text when both speak" {
  # #526: an envelope and an exit code do not always agree, so which signal
  # decided has to be recorded. Here the envelope names error_max_turns while
  # stderr says something unrelated -- the envelope is the more direct claim.
  local home="${BATS_TEST_TMPDIR}/home-envelope"
  mkfixture "$home"
  mkclaude "$home" 'printf "%s\n" "{\"session_id\":\"s\",\"is_error\":true,\"subtype\":\"error_max_turns\",\"num_turns\":80,\"result\":\"\"}"
echo "unrelated diagnostic noise" >&2
exit 1'
  runmain "$home"
  [ "$status" -eq 1 ]
  local log
  log="$(runlog_of "$home")"
  [ "$(jq -r .status <"$log")" = "max_turns" ]
  [ "$(jq -r .decided_by <"$log")" = "envelope" ]
  [ "$(jq -r .num_turns <"$log")" = "80" ]
  [ "$(jq -r .subtype <"$log")" = "error_max_turns" ]
}

@test "main(): no failure other than a transient one is retried" {
  # AC-6 names four non-retryable causes. Testing only max_turns would let a
  # widened retry condition through, and every extra attempt is a billed run.
  local home base
  for case in timeout:'sleep 30' \
    no_report:'printf "%s\n" "{\"session_id\":\"s\",\"is_error\":false,\"subtype\":\"success\",\"result\":\"HEADLINE: ok\"}"' \
    exec_error:'echo boom >&2
exit 3' \
    max_turns:'echo "Error: Reached max turns (80)" >&2
exit 1'; do
    base="${case%%:*}"
    home="${BATS_TEST_TMPDIR}/home-noretry-${base}"
    mkfixture "$home"
    mkclaude "$home" "n=\$(cat \"\$HOME/attempts\" 2>/dev/null || echo 0)
echo \$((n + 1)) >\"\$HOME/attempts\"
${case#*:}"
    runmain "$home" KNOWLEDGE_DISTILL_RADAR_TIMEOUT_SECONDS=1
    [ "$status" -eq 1 ]
    [ "$(cat "${home}/attempts")" = "1" ]
    [ "$(wc -l <"$(runlog_of "$home")")" -eq 1 ]
    [ "$(jq -r .status <"$(runlog_of "$home")")" = "$base" ]
  done
}

@test "main(): a transient failure is retried exactly once, not in a loop" {
  # The retry budget has to be bounded even when the transient condition never
  # clears, or a bad week turns into an unbounded billing loop.
  local home="${BATS_TEST_TMPDIR}/home-retry-cap"
  mkfixture "$home"
  mkclaude "$home" 'n=$(cat "$HOME/attempts" 2>/dev/null || echo 0)
echo $((n + 1)) >"$HOME/attempts"
echo "API Error: Unable to connect to API (ENOTFOUND)" >&2
exit 1'
  runmain "$home"
  [ "$status" -eq 1 ]
  [ "$(cat "${home}/attempts")" = "2" ]
  local log
  log="$(runlog_of "$home")"
  [ "$(wc -l <"$log")" -eq 2 ]
  [ "$(head -1 "$log" | jq -r .attempt)" = "1" ]
  [ "$(tail -1 "$log" | jq -r .attempt)" = "2" ]
  [ "$(tail -1 "$log" | jq -r .status)" = "api_error" ]
  [ ! -f "${home}/state/knowledge-distill-radar/last-run" ]
}

@test "main(): a run log that accepts init but refuses writes degrades loudly too" {
  # The library being absent is only one way the bookkeeping can fail. A write
  # that fails after a successful init (permissions, full disk) has to reach the
  # same explicit degradation, or the record goes missing quietly -- which is
  # indistinguishable from a week that never ran.
  local home="${BATS_TEST_TMPDIR}/home-write-fails"
  mkfixture "$home"
  cat >"${home}/broken-lib.sh" <<'EOF'
job_runlog_available() { return 0; }
job_runlog_init() { return 0; }
job_runlog_last_field() { printf '\n'; }
job_runlog_repeat_periods() { printf '0\n'; }
job_runlog_stale_days() { printf 'never\n'; }
job_runlog_record() { return 1; }
EOF
  mkclaude "$home" "$CLAUDE_OK_BODY"
  runmain "$home" KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB="${home}/broken-lib.sh"
  # The report is the product; losing the bookkeeping must not lose it.
  [ "$status" -eq 0 ]
  [ -f "${home}/state/knowledge-distill-radar/last-run" ]
  grep -qF 'could not append to the run history' "${home}/radar.log"
  [[ "$(jq -r .message <"${STUB_DIR}/curl_stdin")" == *"実行履歴を記録できませんでした"* ]]
}

@test "main(): a run log library owned by someone else is not sourced" {
  # Sourcing is code execution. The wrapper checks ownership for the same reason
  # ntfy_publish checks it on the env file; a path that fails the check has to
  # take the loud degradation path rather than being executed.
  local home="${BATS_TEST_TMPDIR}/home-foreign-lib"
  mkfixture "$home"
  mkclaude "$home" "$CLAUDE_OK_BODY"
  # /etc/hosts exists on both macOS and Linux and is owned by root, so it is
  # readable-but-not-ours: exactly the shape the ownership check exists for.
  [ -r /etc/hosts ] || skip "no readable root-owned file to stand in for a foreign library"
  [ -O /etc/hosts ] && skip "running as the owner of /etc/hosts; the check cannot be exercised"
  runmain "$home" KNOWLEDGE_DISTILL_RADAR_RUNLOG_LIB=/etc/hosts
  [ "$status" -eq 0 ]
  grep -qF 'run history unavailable' "${home}/radar.log"
}

@test "main(): control characters are stripped from the recorded headline" {
  # The headline is model-authored and this run's inputs are not under our
  # control. It now persists into a file that keeps 200 records, so escape
  # sequences must not survive into whatever later prints it.
  local home="${BATS_TEST_TMPDIR}/home-headline-sanitise"
  mkfixture "$home"
  mkclaude "$home" 'report="$(printf "%s" "$*" | grep -oE "[^ ]+\.kryota-dev/knowledge-distill/[^ ]+\.md" | head -1)"
mkdir -p "$(dirname "$report")"
printf "# report\n" >"$report"
printf "HEADLINE: 縮退\033[31m終了\033[0m\n"'
  runmain "$home"
  [ "$status" -eq 0 ]
  local recorded
  recorded="$(jq -r .headline <"$(runlog_of "$home")")"
  [ -n "$recorded" ]
  # No control byte survives, so nothing here can be read as an escape
  # sequence. What remains of "\033[31m" is the inert literal "[31m": dropping
  # the ESC is enough to disarm it, and stripping whole CSI sequences would
  # risk eating text a headline may legitimately contain.
  run bash -c 'printf "%s" "$1" | LC_ALL=C grep -q "[[:cntrl:]]"' _ "$recorded"
  [ "$status" -ne 0 ]
  # The Japanese text itself is untouched.
  [[ "$recorded" == *"縮退"* ]]
  [[ "$recorded" == *"終了"* ]]
}
