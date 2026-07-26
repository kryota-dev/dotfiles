#!/usr/bin/env bats

load helpers/setup

# The statusline source is plain bash (no chezmoi templating), so it can be
# executed directly. External/network segments (ccusage, ping, curl, pmset)
# run in the background with stderr suppressed, so they never affect the exit
# code or the core (host/dir/model/context/cost) output exercised here.

SCRIPT="${HOME_DIR}/dot_claude/executable_statusline.sh"
MOCK_JSON='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'

# Same as MOCK_JSON but with a rate_limits block, exercising the
# write_rate_limits_snapshot contract.
MOCK_JSON_RL='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1700000000},"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'

# Same as MOCK_JSON_RL but five_hour.used_percentage is not a JSON number;
# seven_day stays valid so we can assert per-field (not whole-write) rejection.
MOCK_JSON_RL_INVALID='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":"not_a_number","resets_at":1700000000},"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'

# Every test that pipes MOCK_JSON exercises write_harness_cost (the harness-cost
# contract), which writes a cache file keyed by session_id into the resolved
# tmpdir. Clean it up so the suite leaves no stray tmpdir artifacts.
HARNESS_COST_FILE="${TMPDIR:-/tmp}"
HARNESS_COST_FILE="${HARNESS_COST_FILE%/}/harness-cost-bats-statusline.json"

# write_rate_limits_snapshot writes under $XDG_CACHE_HOME/claude-statusline, so
# give each test its own throwaway XDG_CACHE_HOME instead of touching the
# real ~/.cache.
setup() {
  RL_CACHE_HOME="$(mktemp -d)"
}

teardown() {
  rm -f "$HARNESS_COST_FILE" 2>/dev/null || true
  rm -rf "$RL_CACHE_HOME" 2>/dev/null || true
}

@test "statusline script is present" {
  [ -f "$SCRIPT" ]
}

@test "statusline exits 0 and renders the model name on mock input" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *TestModel* ]]
}

@test "statusline renders the context percentage on mock input" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"50%"* ]]
}

# Guards against a regression where the jq field delimiter is lost and all
# fields collapse into the first (model) variable: effort and cost only render
# as independent segments when the  delimiter splits correctly.
@test "statusline splits jq fields into independent segments" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *high* ]]
  [[ "$output" == *"(session)"* ]]
}

@test "statusline shows a profile badge for a non-default CLAUDE_CONFIG_DIR" {
  run bash -c "printf '%s' '${MOCK_JSON}' | CLAUDE_CONFIG_DIR='${HOME}/.claude-r06' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *R06* ]]
}

@test "statusline shows no profile badge for the default profile" {
  run bash -c "printf '%s' '${MOCK_JSON}' | CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *R06* ]]
}

@test "statusline emits at least the two always-present lines" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 2 ]
}

# Guards the harness-cost contract (#2): the statusline must persist the
# harness-authoritative cost to <tmpdir>/harness-cost-<session_id>.json as
# {ts, cost_usd} so ECC's stop:cost-tracker can prefer it over its estimate.
@test "statusline writes a valid harness-cost cache file for the session" {
  rm -f "$HARNESS_COST_FILE"
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ -f "$HARNESS_COST_FILE" ]
  run jq -e '.cost_usd == 1.23 and (.ts | type == "number")' "$HARNESS_COST_FILE"
  [ "$status" -eq 0 ]
}

# Guards the rate-limits-snapshot contract: model-fitness-check reads
# $CACHE_DIR/rate_limits_<profile>.json to see measured quota pressure
# (five_hour/seven_day used_percentage + resets_at) and the current effort.
@test "statusline writes a valid rate-limits snapshot for the default profile" {
  run bash -c "printf '%s' '${MOCK_JSON_RL}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  run jq -e '
    (.ts | type == "number") and
    .five_hour.used_percentage == 42 and
    .five_hour.resets_at == 1700000000 and
    .seven_day.used_percentage == 17.5 and
    .seven_day.resets_at == 1700600000 and
    .effort == "high"
  ' "$snapshot"
  [ "$status" -eq 0 ]
}

@test "statusline writes no rate-limits snapshot when stdin has no rate_limits" {
  run bash -c "printf '%s' '${MOCK_JSON}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ ! -f "${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json" ]
  run bash -c "ls '${RL_CACHE_HOME}/claude-statusline'/rate_limits_* 2>/dev/null"
  [ -z "$output" ]
}

@test "statusline separates rate-limits snapshots by CLAUDE_CONFIG_DIR profile" {
  run bash -c "printf '%s' '${MOCK_JSON_RL}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='${HOME}/.claude-r06' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ -f "${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude-r06.json" ]
  [ ! -f "${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json" ]
}

@test "statusline drops an invalid rate-limits field instead of writing it" {
  run bash -c "printf '%s' '${MOCK_JSON_RL_INVALID}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  # five_hour must be absent (its used_percentage was non-numeric); seven_day
  # (still valid) must be present and untouched by the invalid sibling field.
  run jq -e '(.five_hour | not) and .seven_day.used_percentage == 17.5' "$snapshot"
  [ "$status" -eq 0 ]
  [[ "$(cat "$snapshot")" != *not_a_number* ]]
}

# Guards the umask-077 bracket around the snapshot's mktemp: the file holds
# quota-pressure data and must stay 0600 even when the session runs under a lax
# umask (mktemp otherwise honors the ambient umask, e.g. 000 -> 0666).
@test "statusline writes the rate-limits snapshot as 0600 even under a lax umask" {
  run bash -c "umask 000; printf '%s' '${MOCK_JSON_RL}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  [ "$(_file_mode "$snapshot")" = "600" ]
}
