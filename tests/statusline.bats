#!/usr/bin/env bats

load helpers/setup

# The statusline source is plain bash (no chezmoi templating), so it can be
# executed directly. External/network segments (ccusage, ping, curl, pmset)
# run in the background with stderr suppressed, so they never affect the exit
# code or the core (host/dir/model/context/cost) output exercised here.

SCRIPT="${HOME_DIR}/dot_claude/executable_statusline.sh"
MOCK_JSON='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'

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

@test "statusline emits at least the two always-present lines" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 2 ]
}
