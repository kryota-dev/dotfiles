#!/bin/bash
# Weekly macOS defaults drift check (kryota-dev/dotfiles#365).
# Launched by the dev.kryota.macos-defaults-drift LaunchAgent. Compares the
# live values of every domain/key managed by
# run_onchange_after_20-macos-defaults.sh.tmpl (#364) -- treated as the sole
# source of truth for "what should be set" -- against what that script would
# currently write, and publishes an ntfy notification (topic_attention) only
# when they differ. Detect + notify only: this script never writes back to
# the repo or touches git in any way (#365 hard constraint).
#
# Comparison strategy: rather than hand-normalizing `defaults write` value
# syntax against `defaults read` output per type (bool/int/float/string/array
# all format differently), the managed `defaults write` lines are replayed
# verbatim against a scratch plist path (`defaults write <path> ...` accepts
# a file path in place of a domain name) and then both sides are read back
# with the same `defaults read` call. Two outputs of the same tool for the
# same type are directly string-comparable, so no type-coercion table is
# needed. A full-domain `defaults export | plutil -convert json` alternative
# was tried and rejected: some real domains contain NSData-typed values that
# plutil refuses to convert to JSON ("Invalid object in plist for JSON
# format"), which per-key `defaults read` never touches.
#
# Not a chezmoi .tmpl: deployed as-is on every OS (like
# executable_morning-radar.sh), and no-ops at runtime on non-Darwin via the
# uname check in main(). Registration of the LaunchAgent that invokes this
# script IS macOS-gated, in run_onchange_after_30-register-launchd-agents.sh.tmpl.
#
# Source-safe: side effects live in main(), guarded by the BASH_SOURCE check
# at the end, so tests can source this file and exercise individual functions.
set -euo pipefail

# The dotfiles repo checkout on this machine -- same assumption
# executable_morning-radar.sh makes (`cd "$HOME/dotfiles"`). Overridable for
# tests so they can point at a fixture checkout instead.
REPO_DIR="${MACOS_DEFAULTS_DRIFT_REPO_DIR:-$HOME/dotfiles}"
SSOT="$REPO_DIR/home/run_onchange_after_20-macos-defaults.sh.tmpl"
DATA_TOML="$REPO_DIR/home/.chezmoidata.toml"
LOG_FILE="${MACOS_DEFAULTS_DRIFT_LOG_FILE:-$HOME/Library/Logs/dev.kryota.macos-defaults-drift.log}"
# Publisher credentials, written 0600 by ~/.config/ntfy/lib.sh (#337/#357).
# Overridable for tests. Sourced only inside a subshell so the token never
# enters this script's (or any child process's) environment.
ENV_FILE="${MACOS_DEFAULTS_DRIFT_NTFY_ENV_FILE:-$HOME/.config/ntfy/notify-env}"
BODY_LIMIT=3000

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Extract "defaults write <domain> <key> -<type> <value...>" lines from the
# SSOT script. The `^defaults write ` anchor already can't match a chezmoi
# template directive or a comment line, so no separate template-line-stripping
# pass is needed here (unlike the Makefile lint target, which strips template
# lines before shellcheck because it can't rely on such an anchor). Emits one
# TSV row per match: domain, key, type, value. For type=string the value's
# surrounding double quotes are stripped (so it round-trips as a single argv
# token in build_expected()); every other type keeps its raw text --
# type=array may hold multiple space-separated tokens, which is intentional
# (see below).
parse_ssot() {
  [ -f "$SSOT" ] || return 0
  awk '
    /^defaults write / {
      domain = $3
      key = $4
      type = $5
      sub(/^-/, "", type)
      value = ""
      for (i = 6; i <= NF; i++) {
        value = value (i > 6 ? " " : "") $i
      }
      if (type == "string") {
        gsub(/^"/, "", value)
        gsub(/"$/, "", value)
      }
      printf "%s\t%s\t%s\t%s\n", domain, key, type, value
    }
  ' "$SSOT"
}

# Replay the SSOT's defaults-write lines against per-domain scratch plist
# paths under $1 (a fresh mktemp -d), so the "expected" value for each
# managed key can be read back with the exact same `defaults read` call used
# on the real domain -- see the header comment for why this beats hand
# type-coercion. Domain names are safe to use as bare filenames (no `/`, no
# reserved characters on APFS). The unquoted $value in the array branch is
# deliberate word-splitting so a multi-element array replays as multiple
# `defaults write` arguments.
build_expected() {
  local tmp_dir="$1" domain key type value scratch
  while IFS=$'\t' read -r domain key type value; do
    scratch="$tmp_dir/$domain"
    case "$type" in
      string) defaults write "$scratch" "$key" -string "$value" >/dev/null 2>&1 ;;
      array) defaults write "$scratch" "$key" -array $value >/dev/null 2>&1 ;;
      *) defaults write "$scratch" "$key" "-$type" "$value" >/dev/null 2>&1 ;;
    esac
  done < <(parse_ssot)
}

# Print the trimmed `defaults read` output for <domain-or-path> <key>, or the
# literal string "(unset)" when the key doesn't exist there (`defaults read`
# exits non-zero and writes nothing useful to stdout in that case).
read_value() {
  local target="$1" key="$2" out
  if out="$(defaults read "$target" "$key" 2>/dev/null)"; then
    printf '%s' "$out"
  else
    printf '(unset)'
  fi
}

# Whether "<domain>:<key>" appears in the [macos_defaults_drift].exclude_keys
# array in home/.chezmoidata.toml. Parsed with the same dependency-free awk
# pattern tests/helpers/setup.bash uses for [ecc].skills (no chezmoi/yq
# dependency -- this script runs standalone under launchd).
is_excluded() {
  local domain="$1" key="$2"
  [ -f "$DATA_TOML" ] || return 1
  awk '
    /^\[macos_defaults_drift\]$/ { in_section = 1; next }
    /^\[/                        { in_section = 0; in_list = 0 }
    in_section && /^[[:space:]]*exclude_keys[[:space:]]*=[[:space:]]*\[/ { in_list = 1; next }
    in_section && in_list && /^[[:space:]]*\]/ { in_list = 0; next }
    in_section && in_list { print }
  ' "$DATA_TOML" | grep -oE '"[^"]+"' | tr -d '"' | grep -qxF "${domain}:${key}"
}

# Build a `defaults write` candidate reflecting the CURRENT (drifted) value,
# so a human can paste it into run_onchange_after_20-macos-defaults.sh.tmpl to
# adopt the drift. Array types are not auto-regenerated: the SSOT has exactly
# one array-typed key today, and `defaults read`'s multi-line parenthesized
# form isn't worth round-tripping generically for a single key -- the
# candidate line says so and points at a manual `defaults read` instead.
build_candidate() {
  local domain="$1" key="$2" type="$3" actual="$4"
  case "$type" in
    bool)
      case "$actual" in
        1) printf 'defaults write %s %s -bool true' "$domain" "$key" ;;
        0) printf 'defaults write %s %s -bool false' "$domain" "$key" ;;
        *) printf '# %s %s: unexpected bool value %s -- inspect manually' "$domain" "$key" "$actual" ;;
      esac
      ;;
    array)
      printf '# %s %s is array-typed -- inspect manually: defaults read %s %s' "$domain" "$key" "$domain" "$key"
      ;;
    string)
      printf 'defaults write %s %s -string %q' "$domain" "$key" "$actual"
      ;;
    *)
      printf 'defaults write %s %s -%s %s' "$domain" "$key" "$type" "$actual"
      ;;
  esac
}

# Publish a Markdown ntfy notification to topic_attention. Fail-open: a
# broken/absent ntfy provisioning is a silent no-op; nothing here ever aborts
# the run. Token hygiene mirrors executable_morning-radar.sh /
# executable_ntfy-notify.sh: the env file is sourced inside a subshell so
# NTFY_TOKEN never enters this script's environment, and it reaches curl only
# through a 0600 `curl -K` config file, never argv/stdout/trace.
ntfy_publish() {
  local count="$1" body="$2" env_mode
  [ -f "$ENV_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0
  [ -O "$ENV_FILE" ] || return 0
  if stat --version >/dev/null 2>&1; then
    env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
  else
    env_mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  fi
  case "$env_mode" in 600 | 400) ;; *) return 0 ;; esac
  body="$(printf '%s' "$body" | jq -Rrs --argjson n "$BODY_LIMIT" '.[0:$n]')"
  (
    umask 077
    # shellcheck source=/dev/null
    . "$ENV_FILE" 2>/dev/null || exit 0
    { [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC_ATTENTION:-}" ] && [ -n "${NTFY_TOKEN:-}" ]; } || exit 0
    payload="$(jq -n --arg topic "$NTFY_TOPIC_ATTENTION" \
      --arg title "macOS defaults drift detected (${count} key(s))" \
      --arg message "$body" \
      '{topic: $topic, title: $title, message: $message, priority: 4,
        markdown: true, tags: ["rotating_light", "macos-defaults-drift"]}')" || exit 0
    curl_cfg="$(mktemp "${TMPDIR:-/tmp}/macos-defaults-drift-ntfy.XXXXXX")" || exit 0
    # EXIT alone misses signal deaths -- cover the catchable signals so the
    # token file never lingers.
    trap 'rm -f "$curl_cfg"' EXIT INT TERM HUP
    printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" >"$curl_cfg"
    if ! printf '%s' "$payload" | curl -fs -K "$curl_cfg" --max-time 5 \
      -o /dev/null -d @- "$NTFY_URL" 2>/dev/null; then
      log "ntfy publish failed: topic=${NTFY_TOPIC_ATTENTION} url=${NTFY_URL}"
    fi
  ) || true
}

main() {
  [ "$(uname)" = "Darwin" ] || exit 0

  mkdir -p "$(dirname "$LOG_FILE")"

  # Rotate the log once it exceeds 1 MiB (weekly appends stay tiny; this is
  # just a safety net, mirroring executable_morning-radar.sh).
  if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
  fi

  if [ ! -f "$SSOT" ]; then
    log "warn: SSOT script not found at $SSOT; skipping this cycle"
    exit 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-defaults-drift.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT

  build_expected "$tmp_dir"

  local domain key type value expected actual candidate
  local drift_lines="" drift_count=0

  while IFS=$'\t' read -r domain key type value; do
    is_excluded "$domain" "$key" && continue
    expected="$(read_value "$tmp_dir/$domain" "$key")"
    actual="$(read_value "$domain" "$key")"
    if [ "$expected" != "$actual" ]; then
      drift_count=$((drift_count + 1))
      candidate="$(build_candidate "$domain" "$key" "$type" "$actual")"
      drift_lines="${drift_lines}${domain} ${key}: expected [${expected}] actual [${actual}]
${candidate}

"
    fi
  done < <(parse_ssot)

  if [ "$drift_count" -eq 0 ]; then
    log "no drift detected"
    exit 0
  fi

  log "drift detected: ${drift_count} key(s)"
  ntfy_publish "$drift_count" "$drift_lines"
  # Explicit exit (rather than falling off the end of main): the EXIT trap
  # above references the function-local $tmp_dir, and that trap must fire
  # while main()'s call frame -- and thus $tmp_dir -- is still alive. Falling
  # through to the caller and letting the script exit naturally after main()
  # has already returned would evaluate the trap with $tmp_dir out of scope
  # (an unbound-variable error under `set -u`).
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
