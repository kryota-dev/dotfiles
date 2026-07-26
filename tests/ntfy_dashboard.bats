#!/usr/bin/env bats

# ntfy notification-history dashboard credential provisioning
# (home/dot_config/ntfy/lib.sh.tmpl, kryota-dev/dotfiles#371). Covers the
# unattended-credential AC (dashboard-env is a 0600 runtime-state file,
# written by the same provisioning/rotation flow as the 1Password-stored
# subscriber password — not a live `op read` at request time) and the
# structural wiring into the two setup entry points (apply-time + ntfy-setup).

load helpers/setup

LIB="${HOME_DIR}/dot_config/ntfy/lib.sh.tmpl"

@test "lib.sh: dashboard-env writer and its wiring are present" {
  grep -qF 'ntfy_write_dashboard_env' "$LIB"
  grep -qF 'ntfy_dashboard_env_file' "$LIB"
  # Wired into both provisioning branches (existing password / newly generated)...
  grep -qF 'ntfy_write_dashboard_env "$ntfy_sub_user" "$stored"' "$LIB"
  grep -qF 'ntfy_write_dashboard_env "$ntfy_sub_user" "$pw"' "$LIB"
  # ...and into rotation, so `ntfy-setup --rotate subscriber` cannot leave the
  # dashboard holding a stale password.
  [ "$(grep -c 'ntfy_write_dashboard_env "\$ntfy_sub_user" "\$pw"' "$LIB")" -eq 2 ]
  # Credentials are Basic Auth (username+password), not a Bearer token like the
  # publisher — the dashboard reads NTFY_DASHBOARD_SUBSCRIBER_USER/PASSWORD.
  grep -qF 'NTFY_DASHBOARD_SUBSCRIBER_USER' "$LIB"
  grep -qF 'NTFY_DASHBOARD_SUBSCRIBER_PASSWORD' "$LIB"
  # Written 0600 via umask, same hygiene as notify-env.
  grep -A5 'ntfy_write_dashboard_env()' "$LIB" | grep -qF 'umask 077'
}

@test "lib.sh: dashboard tailnet serve assertion exists and never funnels" {
  grep -qF 'ntfy_assert_dashboard_serve' "$LIB"
  grep -qF 'ntfy_dashboard_serve_https' "$LIB"
  # Same tailnet-only posture as the rest of the ntfy assets.
  ! grep -qE '^[^#]*tailscale.*funnel' "$LIB"
}

@test "both setup entry points assert the dashboard serve front (apply + ntfy-setup)" {
  grep -qF 'ntfy_assert_dashboard_serve' "${HOME_DIR}/run_onchange_after_31-setup-ntfy.sh.tmpl"
  grep -qF 'ntfy_assert_dashboard_serve' "${HOME_DIR}/dot_local/bin/executable_ntfy-setup"
}

@test "ntfy_write_dashboard_env writes a 0600 file with the expected keys" {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Source the template-stripped library (same strip trick as make lint); the
  # stripped {{ ... }} assignment lines are gone, so the vars they would have
  # set are provided here instead.
  # shellcheck disable=SC1090
  source <(sed '/{{/d' "$LIB")

  ntfy_dashboard_env_file="${tmp}/dashboard-env"
  ntfy_serve_target="http://127.0.0.1:2586"
  ntfy_topic_attention="claude-attention"
  ntfy_topic_done="claude-done"

  ntfy_write_dashboard_env "subscriber" "bats-fixture-value-not-a-real-secret"

  [ -f "$ntfy_dashboard_env_file" ]
  local mode
  if stat --version >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$ntfy_dashboard_env_file")"
  else
    mode="$(stat -f '%Lp' "$ntfy_dashboard_env_file")"
  fi
  [ "$mode" = "600" ]
  grep -qF "NTFY_URL='http://127.0.0.1:2586'" "$ntfy_dashboard_env_file"
  grep -qF "NTFY_DASHBOARD_SUBSCRIBER_USER='subscriber'" "$ntfy_dashboard_env_file"
  grep -qF "NTFY_DASHBOARD_SUBSCRIBER_PASSWORD='bats-fixture-value-not-a-real-secret'" "$ntfy_dashboard_env_file"
  grep -qF "NTFY_TOPIC_ATTENTION='claude-attention'" "$ntfy_dashboard_env_file"
  grep -qF "NTFY_TOPIC_DONE='claude-done'" "$ntfy_dashboard_env_file"
}
