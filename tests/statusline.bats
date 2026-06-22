#!/usr/bin/env bats

load helpers/setup

# The statusline source is plain bash (no chezmoi templating), so it can be
# executed directly. External/network segments (ccusage, ping, curl, pmset)
# run in the background with stderr suppressed, so they never affect the exit
# code or the core (host/dir/model/context/cost) output exercised here.

SCRIPT="${HOME_DIR}/dot_claude/executable_statusline.sh"
MOCK_JSON='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'

# Every test that pipes MOCK_JSON exercises write_harness_cost (the harness-cost
# contract), which writes a cache file keyed by session_id into the resolved
# tmpdir. Clean it up so the suite leaves no stray tmpdir artifacts.
HARNESS_COST_FILE="${TMPDIR:-/tmp}"
HARNESS_COST_FILE="${HARNESS_COST_FILE%/}/harness-cost-bats-statusline.json"
teardown() {
  rm -f "$HARNESS_COST_FILE" 2>/dev/null || true
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
