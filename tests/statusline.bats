#!/usr/bin/env bats

load helpers/setup

# The statusline source is plain bash (no chezmoi templating), so it can be
# executed directly. External/network segments (ccusage, ping, curl, pmset)
# run in the background with stderr suppressed, so they never affect the exit
# code or the core (host/dir/model/context/cost) output exercised here.
#
# The rate-limits snapshot deliberately omits `effort` (#449): the snapshot
# file is keyed per-profile, so concurrent sessions under one profile would
# clobber each other's (session-scoped) effort there. Readers use
# `${CLAUDE_EFFORT}` instead. Line-2 TUI rendering of effort is unaffected.

SCRIPT="${HOME_DIR}/dot_claude/executable_statusline.sh"
MOCK_JSON='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'

# Same as MOCK_JSON but with a rate_limits block, exercising the
# write_rate_limits_snapshot contract.
MOCK_JSON_RL='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1700000000},"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'

# Same as MOCK_JSON_RL but five_hour.used_percentage is not a JSON number;
# seven_day stays valid so we can assert per-field (not whole-write) rejection.
MOCK_JSON_RL_INVALID='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":"not_a_number","resets_at":1700000000},"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'

# Same as MOCK_JSON_RL but rate_limits has only the five_hour window (no
# seven_day sibling), exercising the single-window JSON-shape branch of
# write_rate_limits_snapshot (the "%s," trailing-comma trim with nothing to
# append after it).
MOCK_JSON_RL_FH_ONLY='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1700000000}},"session_id":"bats-statusline"}'

# Same as MOCK_JSON_RL but rate_limits has only the seven_day window (no
# five_hour sibling).
MOCK_JSON_RL_SD_ONLY='{"model":{"display_name":"TestModel"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":1.23},"rate_limits":{"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'

# Every test that pipes MOCK_JSON exercises write_harness_cost (the harness-cost
# contract), which writes a cache file keyed by session_id into the resolved
# tmpdir. Each test gets its own TMPDIR so those files land somewhere private:
# the suite renders under more than one session id, and a shared-/tmp glob
# cleanup would reach into a concurrent run's files.
#
# write_rate_limits_snapshot writes under $XDG_CACHE_HOME/claude-statusline, so
# each test likewise gets a throwaway XDG_CACHE_HOME instead of touching the
# real ~/.cache.
setup() {
  RL_CACHE_HOME="$(mktemp -d)"
  HARNESS_COST_DIR="$(mktemp -d)"
  HARNESS_COST_FILE="${HARNESS_COST_DIR}/harness-cost-bats-statusline.json"
  export TMPDIR="$HARNESS_COST_DIR"
}

teardown() {
  rm -rf "$RL_CACHE_HOME" "$HARNESS_COST_DIR" 2>/dev/null || true
}

# --- Billable-delta helpers (#446) -----------------------------------------
# The rendered amount depends on the USD->JPY rate and on ccusage's daily total,
# both of which the statusline refreshes over the network in the background.
# Seeding both caches makes every assertion deterministic AND keeps those
# refreshes from firing at all: each file is written fresh, so its TTL (24 h for
# the rate, 5 min for the daily total) has not expired. The rate is 10 and the
# daily total 10.5, chosen so every expected amount stays under 1000 and no
# assertion depends on the locale's thousands separator.
BILLING_RATE=10
BILLING_DAILY=10.5

# _seed_billing_cache [daily_total] -- seed the FX rate and today's ccusage
# total. Tomorrow's file is seeded too: the test and the renderer each evaluate
# `date` themselves, so a run that straddles local midnight would otherwise have
# the renderer read an unseeded day, fire the background refresh, and make every
# amount assertion flaky.
_seed_billing_cache() {
  local daily="${1:-$BILLING_DAILY}"
  mkdir -p "${RL_CACHE_HOME}/claude-statusline"
  printf '%s' "$BILLING_RATE" >"${RL_CACHE_HOME}/claude-statusline/usdjpy"
  printf '%s' "$daily" >"${RL_CACHE_HOME}/claude-statusline/daily_$(date +%Y%m%d)"
  printf '%s' "$daily" >"${RL_CACHE_HOME}/claude-statusline/daily_$(_tomorrow)"
}

# Seed only the FX rate, leaving ccusage cold (no daily_* file). Used to drive
# the lazy daily-anchor path.
_seed_rate_only() {
  mkdir -p "${RL_CACHE_HOME}/claude-statusline"
  printf '%s' "$BILLING_RATE" >"${RL_CACHE_HOME}/claude-statusline/usdjpy"
}

# Tomorrow's YYYYMMDD on both GNU (-d) and BSD (-v) date.
_tomorrow() {
  date -d '+1 day' +%Y%m%d 2>/dev/null || date -v+1d +%Y%m%d
}

# Strip ANSI SGR sequences so assertions can pin an exact rendered segment.
_plain() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# _billing_json <cost> <fh_pct> <fh_reset> <sd_pct> <sd_reset> [session_id]
# The default uses ${6-...}, not ${6:-...}: an explicitly empty session id is a
# case under test, and :- would silently swap it for the default one.
_billing_json() {
  printf '{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":50},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}},"session_id":"%s"}' \
    "$1" "$2" "$3" "$4" "$5" "${6-bats-statusline}"
}

# _render <json> -- render with the throwaway cache home and default profile.
_render() {
  run bash -c "printf '%s' '$1' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
}

_billing_state() {
  printf '%s/claude-statusline/session_%s.json' "$RL_CACHE_HOME" "${1:-bats-statusline}"
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
# (five_hour/seven_day used_percentage + resets_at). The snapshot must NOT
# carry `effort` (#449): it's profile-scoped, not session-scoped, so multiple
# concurrent sessions under one profile would clobber each other's effort
# there; readers use `${CLAUDE_EFFORT}` instead.
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
    (has("effort") | not)
  ' "$snapshot"
  [ "$status" -eq 0 ]
}

# Non-regression for #449: only the *snapshot file* dropped effort. Line 2 of
# the rendered statusline (the TUI, sourced fresh from stdin each render) must
# keep showing it.
@test "statusline still renders the effort level on line 2 (#449 non-regression)" {
  run bash -c "printf '%s' '${MOCK_JSON}' | bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *high* ]]
}

# Guards the single-window JSON shape: when only one of five_hour/seven_day is
# present, write_rate_limits_snapshot must still emit valid, parseable JSON
# (the "%s," trailing-comma trim on `windows` must leave a well-formed object
# with no dangling comma) and must not fabricate the missing window.
@test "statusline writes valid JSON when only the five_hour window is present" {
  run bash -c "printf '%s' '${MOCK_JSON_RL_FH_ONLY}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  run jq -e '.' "$snapshot"
  [ "$status" -eq 0 ]
  run jq -e '.five_hour.used_percentage == 42 and (has("seven_day") | not)' "$snapshot"
  [ "$status" -eq 0 ]
}

@test "statusline writes valid JSON when only the seven_day window is present" {
  run bash -c "printf '%s' '${MOCK_JSON_RL_SD_ONLY}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  run jq -e '.' "$snapshot"
  [ "$status" -eq 0 ]
  run jq -e '.seven_day.used_percentage == 17.5 and (has("five_hour") | not)' "$snapshot"
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

# --- Billable-delta contract (#446) ----------------------------------------
# Under a subscription, spend inside the 5h/7d quota is already covered and only
# spend past an exhausted window is invoiced. Line 2 must therefore show the
# increment since a window ran out -- not the raw session/daily totals, which
# park never-billed money next to real charges behind the same glyph.

@test "statusline shows an incl. marker instead of amounts while inside quota" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 42 1700000000 17.5 1700600000)"
  [[ "$output" == *"incl."* ]]
  [[ "$output" != *"(session)"* ]]
  [[ "$output" != *"(daily)"* ]]
  # #499: the state file is no longer proof of a billing baseline -- context is
  # persisted every render regardless of quota state, so it now exists here
  # (context_window.remaining_percentage is always 50 in _billing_json). What
  # must be absent is the `billing` key itself.
  run jq -e '(has("billing") | not)' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# Pay-as-you-go sessions (API-key auth, or a subscription session before its
# first API response) have no rate_limits at all: there is no quota being
# consumed, so the raw totals ARE the bill and must keep rendering.
@test "statusline keeps raw cost totals when stdin carries no rate_limits" {
  run bash -c "printf '%s' '${MOCK_JSON}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(session)"* ]]
  [[ "$output" != *"incl."* ]]
}

@test "statusline anchors the baseline when a quota window is exhausted" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  # The baseline itself is not a charge: the anchoring render must bill zero on
  # both segments, and must not fall back to showing the raw totals (1.23 and
  # 10.5 USD, which at the seeded rate of 10 would read as ¥12 and ¥105).
  local plain
  plain="$(_plain "$output")"
  [[ "$plain" == *"¥0 (session)"* ]]
  [[ "$plain" == *"¥0 (daily)"* ]]
  [[ "$plain" != *"¥12"* ]]
  [[ "$plain" != *"¥105"* ]]
  [[ "$output" != *"incl."* ]]
  local state
  state="$(_billing_state)"
  [ -f "$state" ]
  run jq -e '
    .billing.window == "five_hour" and
    .billing.resets_at == 1700000000 and
    .billing.session_baseline == 1.23 and
    .billing.daily_baseline == 10.5 and
    .billing.daily_carry == 0 and
    (.ts | type == "number")
  ' "$state"
  [ "$status" -eq 0 ]
}

@test "statusline bills only the increment above the baseline" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  # 9.23 - 1.23 = 8.00 USD, at the seeded rate of 10 -> Y80.
  _render "$(_billing_json 9.23 100 1700000000 17.5 1700600000)"
  [[ "$output" == *"¥80 "* ]]
  # ccusage's daily total has not moved, so nothing is billable there yet.
  [[ "$output" == *"¥0 "* ]]
}

# A resumed session or a ccusage correction can put the current total below the
# baseline; a negative charge must never reach the line.
@test "statusline clamps a negative billable delta to zero" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  _render "$(_billing_json 0.5 100 1700000000 17.5 1700600000)"
  [[ "$output" == *"¥0 "* ]]
  # Scoped to the amount: line 1 legitimately carries hyphens (paths, branches).
  [[ "$output" != *"¥-"* ]]
  # The baseline itself must survive the dip rather than be re-taken lower.
  run jq -e '.billing.session_baseline == 1.23' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# The anchor must be the exhausted window that resets LAST: it is the one
# keeping the overage alive, so anchoring on the shorter one would throw the
# baseline away at its rollover while spend is still being billed.
@test "statusline anchors on the later-resetting window when both are exhausted" {
  _seed_billing_cache
  _render "$(_billing_json 1.0 100 1700000000 100 1700600000)"
  run jq -e '.billing.window == "seven_day" and .billing.resets_at == 1700600000' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# Anchored on five_hour, then seven_day also runs out: the anchor hands over
# while both are exhausted (so continuity transfers), and the baseline survives
# the five_hour window rolling over afterwards.
@test "statusline carries the baseline across a five_hour rollover during a seven_day overage" {
  _seed_billing_cache
  _render "$(_billing_json 1.0 100 1700000000 17.5 1700600000)"
  _render "$(_billing_json 2.0 100 1700000000 100 1700600000)"
  run jq -e '.billing.window == "seven_day" and .billing.session_baseline == 1.0' "$(_billing_state)"
  [ "$status" -eq 0 ]
  # five_hour has reset (new resets_at, back under the threshold) but seven_day
  # still bills: 4.0 - 1.0 = 3.00 USD -> Y30.
  _render "$(_billing_json 4.0 10 1700018000 100 1700600000)"
  [[ "$output" == *"¥30 "* ]]
}

# used_percentage is monotonic within one window instance, so a moved resets_at
# is the signal that the window rolled over and the old baseline is stale.
@test "statusline re-anchors when the anchor window rolls over" {
  _seed_billing_cache
  _render "$(_billing_json 1.0 100 1700000000 17.5 1700600000)"
  _render "$(_billing_json 5.0 100 1700018000 17.5 1700600000)"
  [[ "$output" == *"¥0 "* ]]
  run jq -e '.billing.resets_at == 1700018000 and .billing.session_baseline == 5.0' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

@test "statusline drops the baseline once the windows have room again" {
  _seed_billing_cache
  _render "$(_billing_json 1.0 100 1700000000 17.5 1700600000)"
  [ -f "$(_billing_state)" ]
  _render "$(_billing_json 3.0 42 1700018000 17.5 1700600000)"
  [[ "$output" == *"incl."* ]]
  # #499: context is persisted every render regardless of quota state, so the
  # file itself now survives the reset (context_window.remaining_percentage is
  # always 50 in _billing_json) -- only the `billing` key must be gone.
  run jq -e '(has("billing") | not)' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# ccusage resets its daily total at midnight, so the previous day's billable
# remainder has to be banked into a carry or it silently disappears.
@test "statusline carries the daily remainder across a day change" {
  _seed_billing_cache
  cat >"$(_billing_state)" <<'STATE'
{"ts":1700000000,"billing":{"window":"five_hour","resets_at":1700000000,"session_baseline":1.23,"daily_date":"20200101","daily_baseline":2.0,"daily_carry":0,"daily_last":5.0}}
STATE
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  # Banked remainder 5.0 - 2.0 = 3.0, plus all of today's 10.5 (the new day's
  # baseline is 0 because the overage started before it): 13.5 USD -> Y135.
  [[ "$output" == *"¥135 "* ]]
  run jq -e '
    .billing.daily_date == "'"$(date +%Y%m%d)"'" and
    .billing.daily_carry == 3 and
    .billing.daily_baseline == 0 and
    .billing.daily_last == 10.5
  ' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# Non-regression for #449 in the other direction: the baseline is session-scoped
# state, so unlike the profile-keyed rate-limits snapshot it must be keyed by
# session id -- concurrent sessions under one profile would otherwise clobber
# each other's baseline and bill each other's spend.
@test "statusline keeps billing baselines separate per session id" {
  _seed_billing_cache
  _render "$(_billing_json 1.0 100 1700000000 17.5 1700600000 bats-statusline)"
  _render "$(_billing_json 7.5 100 1700000000 17.5 1700600000 bats-statusline-b)"
  run jq -e '.billing.session_baseline == 1.0' "$(_billing_state bats-statusline)"
  [ "$status" -eq 0 ]
  run jq -e '.billing.session_baseline == 7.5' "$(_billing_state bats-statusline-b)"
  [ "$status" -eq 0 ]
}

# The baseline exposes spend and quota pressure, so it stays 0600 even when the
# session runs under a lax umask (mktemp otherwise honors the ambient umask).
@test "statusline writes the billing state as 0600 even under a lax umask" {
  _seed_billing_cache
  local json
  json="$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  run bash -c "umask 000; printf '%s' '${json}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ -f "$(_billing_state)" ]
  [ "$(_file_mode "$(_billing_state)")" = "600" ]
}

# Pins the platform ordering inside file_mtime, a trap this repo has hit twice
# (see the perms() note in tests/wave_orchestrator.bats). GNU `stat -f` is
# --file-system and prints its report on STDOUT before failing, so a BSD-first
# order corrupts every TTL check on Linux -- and a corrupt $(( )) tears down the
# enclosing function's subshell, so usd_jpy_rate and daily_cost return nothing
# and their segments silently vanish. Asserting that a seeded rate actually
# reaches the rendered amount catches that on the Linux CI leg.
@test "statusline honors the cached FX rate (file_mtime platform ordering)" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 42 1700000000 17.5 1700600000)"
  # Inside quota there is no amount, so drive the raw-total path instead: with
  # the seeded rate of 10, 1.23 USD renders as JPY, not as the $N.NN fallback.
  run bash -c "printf '%s' '${MOCK_JSON}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"¥12 "* ]]
  [[ "$output" != *"\$1.23"* ]]
  # A failed setlocale must not leak a warning into the rendered status line.
  [[ "$output" != *setlocale* ]]
}

# --- Coverage for the state-machine edges called out in review ---------------

# The daily half of the feature: the session total is held still so only the
# ccusage movement can produce the charge.
@test "statusline bills the daily increment within one day" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  # ccusage moves 10.5 -> 17.5, i.e. 7.00 USD at the seeded rate of 10 -> ¥70.
  _seed_billing_cache 17.5
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  local plain
  plain="$(_plain "$output")"
  [[ "$plain" == *"¥70 (daily)"* ]]
  [[ "$plain" == *"¥0 (session)"* ]]
  run jq -e '.billing.daily_baseline == 10.5 and .billing.daily_last == 17.5' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# ccusage refreshes in the background, so the daily total is empty on a cold
# cache. Anchoring it at 0 there would bill the whole day, so the daily half of
# the baseline is taken lazily on the first render that has a number.
@test "statusline defers the daily baseline until ccusage warms up" {
  _seed_rate_only
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  local plain
  plain="$(_plain "$output")"
  [[ "$plain" == *"¥0 (session)"* ]]
  [[ "$plain" != *"(daily)"* ]]
  run jq -e '.billing.session_baseline == 1.23 and (.billing | has("daily_date") | not)' "$(_billing_state)"
  [ "$status" -eq 0 ]

  # Once ccusage lands, the baseline is that value -- not 0, which would have
  # billed the entire day retroactively.
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  [[ "$(_plain "$output")" == *"¥0 (daily)"* ]]
  run jq -e '.billing.daily_baseline == 10.5 and .billing.daily_carry == 0' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# Without a usable session id there is nowhere to keep a baseline, and a delta
# cannot be invented -- so the raw totals are shown rather than a number with
# nothing behind it, and no state file is written.
@test "statusline falls back to raw totals when the session id is unusable" {
  _seed_billing_cache
  local escaping
  escaping="$(_billing_json 1.23 100 1700000000 17.5 1700600000 "../escape")"
  run bash -c "printf '%s' '${escaping}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local plain
  plain="$(_plain "$output")"
  # Raw totals at the seeded rate of 10: 1.23 -> ¥12, 10.5 -> ¥105.
  [[ "$plain" == *"¥12 (session)"* ]]
  [[ "$plain" == *"¥105 (daily)"* ]]
  [[ "$plain" != *"incl."* ]]
  run bash -c "ls '${RL_CACHE_HOME}/claude-statusline'/session_* 2>/dev/null"
  [ -z "$output" ]

  local empty_id
  empty_id="$(_billing_json 1.23 100 1700000000 17.5 1700600000 "")"
  run bash -c "printf '%s' '${empty_id}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [[ "$(_plain "$output")" == *"¥12 (session)"* ]]
  run bash -c "ls '${RL_CACHE_HOME}/claude-statusline'/session_* 2>/dev/null"
  [ -z "$output" ]
}

# The sweep must run whatever this session's quota state is: a machine sitting
# in a long overage would otherwise never collect the baselines left behind by
# sessions that have ended.
@test "statusline prunes expired baselines while itself being billed" {
  _seed_billing_cache
  local stale="${RL_CACHE_HOME}/claude-statusline/session_gone-long-ago.json"
  mkdir -p "${RL_CACHE_HOME}/claude-statusline"
  printf '{"ts":1,"billing":{"window":"five_hour","session_baseline":1}}' >"$stale"
  touch -t 202001010000 "$stale"
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  # The sweep is backgrounded, so wait for it rather than racing it.
  local i=0
  while [ -e "$stale" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -e "$stale" ]
  # This session's own (fresh) baseline must survive the sweep.
  [ -f "$(_billing_state)" ]
}

# A truncated or hand-edited state file must not take the statusline down, and
# must not be trusted: the baseline is simply re-taken at the current spend.
@test "statusline re-anchors on an unparseable state file" {
  _seed_billing_cache
  printf 'not json at all' >"$(_billing_state)"
  _render "$(_billing_json 4.5 100 1700000000 17.5 1700600000)"
  [[ "$(_plain "$output")" == *"¥0 (session)"* ]]
  run jq -e '.billing.session_baseline == 4.5 and .billing.window == "five_hour"' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

# pct_exhausted truncates at the decimal point, so pin the boundary: 99.9 is
# still inside quota, 100.0 and 100.1 are not.
@test "statusline places the quota boundary at 100 percent used" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 99.9 1700000000 17.5 1700600000)"
  [[ "$output" == *"incl."* ]]
  # #499: context is persisted every render regardless of quota state, so the
  # state file itself now exists here too -- only `billing` must be absent.
  run jq -e '(has("billing") | not)' "$(_billing_state)"
  [ "$status" -eq 0 ]

  _render "$(_billing_json 1.23 100.0 1700000000 17.5 1700600000)"
  [[ "$output" != *"incl."* ]]
  [ -f "$(_billing_state)" ]

  _render "$(_billing_json 1.23 99.9 1700000000 17.5 1700600000)"
  [[ "$output" == *"incl."* ]]

  _render "$(_billing_json 1.23 100.1 1700000000 17.5 1700600000)"
  [[ "$output" != *"incl."* ]]
  [ -f "$(_billing_state)" ]
}

# --- Context-window snapshot contract (#499) ---------------------------------
# billing_state_path's comment notes the `billing` wrapper key leaves room for
# other session-scoped statusline state to join the same file; this is that
# state joining. Unlike billing (rare, only during an overage),
# context_window.remaining_percentage is persisted on every render regardless
# of quota state, so a reader always sees a live value.

@test "statusline persists context_window.remaining_percentage with no rate_limits on stdin" {
  run bash -c "printf '%s' '${MOCK_JSON}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  run jq -e '.context.remaining_percentage == 50' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

@test "statusline keeps billing and context as sibling keys during an overage" {
  _seed_billing_cache
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  run jq -e '.billing.session_baseline == 1.23 and .context.remaining_percentage == 50' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

@test "statusline omits the context key for a missing or non-numeric remaining_percentage" {
  # No context_window field at all, and no rate_limits: nothing is billable
  # and nothing is a valid context body, so the state file must not exist.
  local no_ctx='{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'
  run bash -c "printf '%s' '${no_ctx}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ ! -f "$(_billing_state)" ]

  # remaining_percentage present but non-numeric: same outcome.
  local bad_ctx='{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":"n/a"},"cost":{"total_cost_usd":1.23},"session_id":"bats-statusline"}'
  run bash -c "printf '%s' '${bad_ctx}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ ! -f "$(_billing_state)" ]
}

# Guards session_state_write's umask 077 bracket on the no-rate_limits fallback
# path specifically -- the billed/reset paths already share the same core and
# are covered by the pre-existing billing-state 0600 test.
@test "statusline writes a context-only state file as 0600 even under a lax umask" {
  run bash -c "umask 000; printf '%s' '${MOCK_JSON}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  [ -f "$(_billing_state)" ]
  [ "$(_file_mode "$(_billing_state)")" = "600" ]
}

@test "statusline keeps context snapshots separate per session id" {
  local json_a json_b
  json_a='{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":30},"session_id":"bats-statusline"}'
  json_b='{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"remaining_percentage":70},"session_id":"bats-statusline-b"}'
  run bash -c "printf '%s' '${json_a}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '${json_b}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  run jq -e '.context.remaining_percentage == 30' "$(_billing_state)"
  [ "$status" -eq 0 ]
  run jq -e '.context.remaining_percentage == 70' "$(_billing_state bats-statusline-b)"
  [ "$status" -eq 0 ]
}

# Non-regression: context is session-scoped state and must never leak into the
# profile-scoped rate-limits snapshot (#449's failure mode for `effort`, now
# guarded for `context` too).
# Every write embeds the *current* context body, so `ts` and `context` always
# move together and a stale value can never sit behind a fresh timestamp. The
# remaining hazard is the write being skipped entirely: during an overage the
# billing half can be unchanged, so without an explicit test on the stored
# value the last reported percentage would stay on disk after the harness
# stopped sending `context_window` at all.
@test "statusline drops a stale context key once the harness stops reporting it" {
  _seed_billing_cache
  local without='{"model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"cost":{"total_cost_usd":1.23},"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1700000000},"seven_day":{"used_percentage":17.5,"resets_at":1700600000}},"session_id":"bats-statusline"}'
  _render "$(_billing_json 1.23 100 1700000000 17.5 1700600000)"
  run jq -e '.context.remaining_percentage == 50' "$(_billing_state)"
  [ "$status" -eq 0 ]

  # Same billing state, no context_window on stdin: the key must go, not linger.
  _render "$without"
  run jq -e '(.context | not) and .billing.session_baseline == 1.23' "$(_billing_state)"
  [ "$status" -eq 0 ]

  # Self-terminating: with nothing left to drop the write is skipped again, so
  # the file keeps the billing half rather than being churned every render.
  _render "$without"
  run jq -e '(.context | not) and .billing.session_baseline == 1.23' "$(_billing_state)"
  [ "$status" -eq 0 ]
}

@test "statusline never mixes context into the profile-scoped rate-limits snapshot" {
  run bash -c "printf '%s' '${MOCK_JSON_RL}' | XDG_CACHE_HOME='${RL_CACHE_HOME}' CLAUDE_CONFIG_DIR='' bash '${SCRIPT}'"
  [ "$status" -eq 0 ]
  local snapshot="${RL_CACHE_HOME}/claude-statusline/rate_limits_.claude.json"
  [ -f "$snapshot" ]
  run jq -e '(has("context") | not)' "$snapshot"
  [ "$status" -eq 0 ]
}
