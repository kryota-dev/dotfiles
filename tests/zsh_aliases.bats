#!/usr/bin/env bats

load helpers/setup

# Behavioral regression guard for the unified claude/codex launcher wrappers (#345).
#
# Account isolation env injection now lives in the wrapper scripts
# home/dot_local/launchers/executable_{claude,codex}, reached as claude/cld/cld-r06 and
# codex/cdx/cdx-r06 (the -r06 / short names are symlinks; the wrapper dispatches on $0). These
# tests exercise the wrappers directly with a stub "real" binary that dumps the env + argv it
# received, so no mise/brew/codex install is needed (CI-safe). The residual zsh helpers that stay
# in claude.zsh (cldf/cldf-r06 orchestrator, claude-config) are driven with `zsh -fc` as before.
#
# _CODEX/_CLAUDE_LAUNCHER_BIN override the real-binary resolution so the wrapper execs our stub.

# Build a launcher dir mirroring the chezmoi layout (wrappers + $0-dispatch symlinks) plus a stub
# "real" binary that prints the environment and argv it was exec'd with.
_launchers() {
  # Clear any per-account env the test runner itself inherited (this suite may run inside a real
  # cld/cld-r06 session that exported these). Otherwise the wrapper's fill-gaps would correctly
  # keep the runner's account and the "no inherited account" assertions would see it — and a real
  # EXA/FIRECRAWL key would leak into the output. Tests that need an inherited value pass it
  # explicitly via `env`. In CI these are unset already, so this is a no-op there.
  # XDG_CACHE_HOME is in the list for a different reason than the rest: the #677 composite
  # append-system-prompt file is written under it, so an inherited value would send test writes
  # into the developer's real cache. Tests that exercise the composite pass it explicitly.
  unset CLAUDE_CONFIG_DIR CODEX_HOME EXA_API_KEY FIRECRAWL_API_KEY \
    ECC_AGENT_DATA_HOME CLV2_HOMUNCULUS_DIR GATEGUARD_STATE_DIR ECC_MCP_HEALTH_STATE_PATH \
    ECC_OBSERVER_TIMEOUT_SECONDS OBSERVER_ACTIVE_HOURS_START OBSERVER_ACTIVE_HOURS_END \
    ECC_OBSERVER_MAX_TURNS ECC_DISABLED_HOOKS_EXTRA XDG_CACHE_HOME
  LDIR="$BATS_TEST_TMPDIR/launchers"
  mkdir -p "$LDIR"
  cp "$HOME_DIR/dot_local/launchers/executable_claude" "$LDIR/claude"
  cp "$HOME_DIR/dot_local/launchers/executable_codex" "$LDIR/codex"
  chmod +x "$LDIR/claude" "$LDIR/codex"
  ln -sf claude "$LDIR/cld"
  ln -sf claude "$LDIR/cld-r06"
  ln -sf codex "$LDIR/cdx"
  ln -sf codex "$LDIR/cdx-r06"
  STUB="$BATS_TEST_TMPDIR/echo-real"
  cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
for v in CLAUDE_CONFIG_DIR ECC_AGENT_DATA_HOME CLV2_HOMUNCULUS_DIR GATEGUARD_STATE_DIR \
  ECC_MCP_HEALTH_STATE_PATH ECC_OBSERVER_TIMEOUT_SECONDS OBSERVER_ACTIVE_HOURS_START \
  OBSERVER_ACTIVE_HOURS_END ECC_OBSERVER_MAX_TURNS EXA_API_KEY FIRECRAWL_API_KEY \
  ECC_DISABLED_HOOKS_EXTRA CODEX_HOME; do
  printf '%s=%s\n' "$v" "${!v-}"
done
printf 'ARGV=%s\n' "$*"
# ARGV is a "$*" join, which cannot tell one spaced argument from two. The argc + one-line-per
# -argument form below pins the word boundaries the #677 argv rewrite has to preserve. Both are
# emitted so the assertions that predate it keep matching on ARGV alone.
printf 'ARGC=%s\n' "$#"
for a in "$@"; do printf '[%s]\n' "$a"; done
STUBEOF
  chmod +x "$STUB"
}

# #677 fixtures: the rule file the wrapper injects, plus a cache dir for the composite it folds
# a caller's own append prompt into. Both live under the test HOME so nothing touches the real one.
_ask_rule() {
  mkdir -p "$BATS_TEST_TMPDIR/.claude"
  RULE="$BATS_TEST_TMPDIR/.claude/ask-user-question-prompt.md"
  printf 'ASK-RULE-BODY\n' >"$RULE"
  CACHE="$BATS_TEST_TMPDIR/xdg-cache"
}

# ---------- claude wrapper: account selection + env injection ----------

@test "claude wrapper: claude/cld select the personal account and derive the per-account env" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/claude" --resume
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude"
  printf '%s\n' "$output" | grep -qFx "ECC_AGENT_DATA_HOME=$BATS_TEST_TMPDIR/.claude"
  printf '%s\n' "$output" | grep -qFx "CLV2_HOMUNCULUS_DIR=$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-default"
  printf '%s\n' "$output" | grep -qFx "GATEGUARD_STATE_DIR=$BATS_TEST_TMPDIR/.claude/.gateguard"
  printf '%s\n' "$output" | grep -qFx "ARGV=--resume"
  # cld is a symlink to the same wrapper and must behave identically to bare `claude`.
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/cld" --resume
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude"
  printf '%s\n' "$output" | grep -qFx "ARGV=--resume"
}

@test "claude wrapper: cld-r06 selects the work account unconditionally" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/cld-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude-r06"
  printf '%s\n' "$output" | grep -qFx "CLV2_HOMUNCULUS_DIR=$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-r06"
}

@test "claude wrapper: fill-gaps keeps an inherited account, override ignores it (isolation)" {
  _launchers
  # A hook-spawned child in an r06 session: bare `claude` must KEEP the inherited r06 account.
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude-r06" "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude-r06"
  printf '%s\n' "$output" | grep -qFx "CLV2_HOMUNCULUS_DIR=$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-r06"
  # cld-r06 must override an inherited personal account back to r06 (never resolve to personal).
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude" "$LDIR/cld-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude-r06"
}

@test "claude wrapper: keeps the CLV2 homunculus dir out of the config dir (#336)" {
  # Relocated #336 guard: the headless CLV2 analysis pass can never get an instinct write
  # approved under the config dir, so the storage dir must stay outside ~/.claude*.
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/claude"
  [ "$status" -eq 0 ]
  default_dir="$(printf '%s\n' "$output" | sed -n 's/^CLV2_HOMUNCULUS_DIR=//p')"
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/cld-r06"
  [ "$status" -eq 0 ]
  r06_dir="$(printf '%s\n' "$output" | sed -n 's/^CLV2_HOMUNCULUS_DIR=//p')"
  [ "$default_dir" = "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-default" ]
  [ "$r06_dir" = "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus-r06" ]
  # Neither may resolve under the config dir; both stay distinct from each other and from the
  # bare-`claude` fallback store (which carries no account suffix).
  [[ "$default_dir" != "$BATS_TEST_TMPDIR/.claude"* ]]
  [[ "$r06_dir" != "$BATS_TEST_TMPDIR/.claude"* ]]
  [ "$default_dir" != "$r06_dir" ]
  [ "$default_dir" != "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus" ]
  [ "$r06_dir" != "$BATS_TEST_TMPDIR/.local/share/ecc-homunculus" ]
}

@test "claude wrapper: observer knobs default and stay overridable" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ECC_OBSERVER_TIMEOUT_SECONDS=300"
  printf '%s\n' "$output" | grep -qFx "OBSERVER_ACTIVE_HOURS_START=0"
  printf '%s\n' "$output" | grep -qFx "OBSERVER_ACTIVE_HOURS_END=0"
  printf '%s\n' "$output" | grep -qFx "ECC_OBSERVER_MAX_TURNS=100"
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" \
    ECC_OBSERVER_TIMEOUT_SECONDS=45 OBSERVER_ACTIVE_HOURS_START=900 \
    OBSERVER_ACTIVE_HOURS_END=2200 ECC_OBSERVER_MAX_TURNS=40 "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ECC_OBSERVER_TIMEOUT_SECONDS=45"
  printf '%s\n' "$output" | grep -qFx "OBSERVER_ACTIVE_HOURS_START=900"
  printf '%s\n' "$output" | grep -qFx "OBSERVER_ACTIVE_HOURS_END=2200"
  printf '%s\n' "$output" | grep -qFx "ECC_OBSERVER_MAX_TURNS=40"
}

@test "claude wrapper: sources the MCP keys, but a caller-set key opts out (morning-radar)" {
  _launchers
  mkdir -p "$BATS_TEST_TMPDIR/.config/zsh"
  cat >"$BATS_TEST_TMPDIR/.config/zsh/claude-secrets.zsh" <<'EOF'
EXA_API_KEY='sk-exa-test'
FIRECRAWL_API_KEY='fc-test'
EOF
  # No caller key: the wrapper sources the file and exports the keys.
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "EXA_API_KEY=sk-exa-test"
  printf '%s\n' "$output" | grep -qFx "FIRECRAWL_API_KEY=fc-test"
  # Caller already decided the key (even to empty): the wrapper must NOT source over it.
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" EXA_API_KEY="" "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "EXA_API_KEY="
}

@test "claude wrapper: execs with full env inheritance (claude-config's ECC_DISABLED_HOOKS_EXTRA)" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" \
    ECC_DISABLED_HOOKS_EXTRA="pre:config-protection" "$LDIR/claude"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ECC_DISABLED_HOOKS_EXTRA=pre:config-protection"
}

@test "claude wrapper: fails loudly when the real binary cannot be resolved" {
  _launchers
  run -127 env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$BATS_TEST_TMPDIR/nope" "$LDIR/claude"
  [[ "$output" == *"could not resolve"* ]]
}

# ---------- claude wrapper: append-system-prompt normalisation (#677) ----------
#
# The rule that decisions go through AskUserQuestion is injected as a system prompt instead of
# being left in CLAUDE.md. Three measured CLI properties drive what these tests pin
# (claude 2.1.259): --append-system-prompt-file is not repeatable and a later occurrence silently
# replaces an earlier one; it must sit before the first positional or a subcommand aborts with
# "unknown option"; and it is mutually exclusive with --append-system-prompt. Together they mean
# the wrapper cannot layer its flag on top of a caller's — it has to fold both into one file.
# Everything below fails if that folding degrades into "last one wins", because the loss would
# otherwise be silent.

@test "claude wrapper: prepends the ask rule as a system prompt file (#677)" {
  _launchers
  _ask_rule
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --resume
  [ "$status" -eq 0 ]
  # Ahead of the caller's own arguments: after a subcommand the flag would abort the CLI.
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE --resume"
  # The rule file is shared by absolute path across accounts, like the fable prompt (#345), so all
  # four entry points must carry it — bare `cld` included, since that is the name hooks and
  # launchd jobs reach the wrapper by.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/cld"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/cld-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE"
}

@test "claude wrapper: a repeated append flag resolves last-wins like the CLI (#677)" {
  _launchers
  _ask_rule
  # This is the property the whole fold exists for: the CLI keeps only the last occurrence and
  # drops the earlier one without a word. If the scan ever stopped at the first match instead, the
  # wrapper would fold the wrong prompt and nothing else here would notice.
  printf 'FIRST-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/first.md"
  printf 'LAST-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/last.md"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/first.md" \
    --append-system-prompt-file "$BATS_TEST_TMPDIR/last.md"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cFx -- '[--append-system-prompt-file]')" -eq 1 ]
  composite="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  grep -qFx 'LAST-PROMPT-BODY' "$composite"
  ! grep -qFx 'FIRST-PROMPT-BODY' "$composite"
  # …and the last occurrence is also the one whose readability decides the exit, even when an
  # earlier one would have been fine.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/first.md" \
    --append-system-prompt-file "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/missing.md"* ]]
}

@test "claude wrapper: hands a value-less append flag back to the CLI (#677)" {
  _launchers
  _ask_rule
  # `claude --append-system-prompt` with nothing after it is an error the CLI reports as
  # "option '--append-system-prompt <prompt>' argument missing". Folding it as an empty prompt
  # would start the session instead — the one silent drop this wrapper would otherwise have.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --resume --append-system-prompt
  [ "$status" -eq 0 ]
  # Restored at the END, not the front: prepending it would hand it the next token as the value it
  # never had, turning "argument missing" into a silently accepted prompt.
  printf '%s\n' "$output" | grep -qFx 'ARGV=--resume --append-system-prompt'
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --resume --append-system-prompt-file
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx 'ARGV=--resume --append-system-prompt-file'
  # An explicitly *empty* value is a different case: the CLI accepts and ignores it, so the wrapper
  # treats it as "no caller prompt" and the rule still goes in rather than being passed through.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt= --resume
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE --resume"
}

@test "claude wrapper: leaves argv alone when the rule file is absent (#677)" {
  _launchers
  # Before `chezmoi apply`, or after a manual removal: the session still starts, it just runs
  # without the rule. Same trade-off _claude_fable already makes for the orchestrator prompt.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg-cache" \
    CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/claude" --resume
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--resume"
}

@test "claude wrapper: folds a caller's prompt file and the rule into one composite (#677)" {
  _launchers
  _ask_rule
  printf 'CALLER-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/caller.md"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --model claude-fable-5-1 \
    --append-system-prompt-file "$BATS_TEST_TMPDIR/caller.md"
  [ "$status" -eq 0 ]
  # Exactly one occurrence reaches the CLI: a second one would silently drop the first.
  [ "$(printf '%s\n' "$output" | grep -cFx -- '[--append-system-prompt-file]')" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^ARGV=--append-system-prompt-file '
  composite="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  [ -f "$composite" ]
  [[ "$composite" == "$CACHE/claude-launcher/append-system-prompt-"*".md" ]]
  grep -qFx 'CALLER-PROMPT-BODY' "$composite"
  grep -qFx 'ASK-RULE-BODY' "$composite"
  # The rule goes last: #677 is about it being buried, and the tail is the salient end.
  [ "$(grep -nFx 'CALLER-PROMPT-BODY' "$composite" | cut -d: -f1)" \
    -lt "$(grep -nFx 'ASK-RULE-BODY' "$composite" | cut -d: -f1)" ]
  # The caller's own occurrence is gone, and its other flags are untouched.
  ! printf '%s\n' "$output" | grep -qF "$BATS_TEST_TMPDIR/caller.md"
  printf '%s\n' "$output" | grep -qFx '[--model]'
  printf '%s\n' "$output" | grep -qFx '[claude-fable-5-1]'
}

@test "claude wrapper: folds the equals and content spellings too (#677)" {
  _launchers
  _ask_rule
  printf 'CALLER-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/caller.md"
  # --flag=value is the same option to commander, so it has to be the same option to the scan.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" "--append-system-prompt-file=$BATS_TEST_TMPDIR/caller.md" -p hi
  [ "$status" -eq 0 ]
  composite="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  grep -qFx 'CALLER-PROMPT-BODY' "$composite"
  grep -qFx 'ASK-RULE-BODY' "$composite"
  ! printf '%s\n' "$output" | grep -qF -- '--append-system-prompt-file='
  # The content spelling is mutually exclusive with the file one, so it is folded into a file
  # rather than left alongside — leaving both would abort the CLI.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt 'CALLER-TEXT-BODY' -p hi
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qFx -- '[--append-system-prompt]'
  composite="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  grep -qFx 'CALLER-TEXT-BODY' "$composite"
  grep -qFx 'ASK-RULE-BODY' "$composite"
  # …and the content spelling has an equals form too, which the scan has to recognise separately.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt=EQUALS-TEXT-BODY -p hi
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qF -- '--append-system-prompt='
  composite="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  grep -qFx 'EQUALS-TEXT-BODY' "$composite"
  grep -qFx 'ASK-RULE-BODY' "$composite"
}

@test "claude wrapper: hands both spellings back so the CLI refuses them itself (#677)" {
  _launchers
  _ask_rule
  printf 'CALLER-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/caller.md"
  # "Cannot use both ... Please use only one." is the CLI's call. Normalising here would turn a
  # loud error into a winner the caller never chose.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt 'CALLER-TEXT-BODY' \
    --append-system-prompt-file "$BATS_TEST_TMPDIR/caller.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx -- '[--append-system-prompt]'
  printf '%s\n' "$output" | grep -qFx -- '[CALLER-TEXT-BODY]'
  printf '%s\n' "$output" | grep -qFx -- '[--append-system-prompt-file]'
  printf '%s\n' "$output" | grep -qFx -- "[$BATS_TEST_TMPDIR/caller.md]"
  [ ! -d "$CACHE/claude-launcher" ]
}

@test "claude wrapper: stops scanning at -- and keeps word boundaries (#677)" {
  _launchers
  _ask_rule
  # After a literal `--` the same text is a positional, not our flag: it must survive untouched
  # and still get the rule prepended.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" -- --append-system-prompt-file /x
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE -- --append-system-prompt-file /x"
  # A spaced argument and an empty one pin the boundaries the rewrite must preserve: rebuilding
  # argv through a "$*" round trip would collapse them and ARGV alone could not tell.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --resume 'two words' '' --model claude-fable-5-1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx 'ARGC=7'
  # Everything after the ARGC line is one argument per line, so this compares the whole rebuilt
  # argv at once — order included — without depending on how many env lines the stub dumps first.
  args="$(printf '%s\n' "$output" | sed -n '/^ARGC=/,$p' | tail -n +2)"
  expected="$(printf '[--append-system-prompt-file]\n[%s]\n[--resume]\n[two words]\n[]\n[--model]\n[claude-fable-5-1]' "$RULE")"
  [ "$args" = "$expected" ]
}

@test "claude wrapper: refuses to drop the rule when the caller's prompt file is unreadable (#677)" {
  _launchers
  _ask_rule
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not readable"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/missing.md"* ]]
}

@test "claude wrapper: stays ahead of subcommands and reuses the composite (#677)" {
  _launchers
  _ask_rule
  printf 'CALLER-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/caller.md"
  # `claude --append-system-prompt-file <path> mcp list` parses the flag on the root command and
  # runs the subcommand; the reverse order aborts with "unknown option" (measured, 2.1.259).
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" mcp list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--append-system-prompt-file $RULE mcp list"
  # Content-addressed: the same inputs converge on one file instead of accumulating a new one per
  # launch, so concurrent launches cannot read a half-written or foreign composite.
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/caller.md"
  [ "$status" -eq 0 ]
  first="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/caller.md"
  [ "$status" -eq 0 ]
  second="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  [ "$first" = "$second" ]
  [ "$(find "$CACHE/claude-launcher" -name 'append-system-prompt-*.md' | wc -l)" -eq 1 ]
  # A different input has to land on a different path with different content. Without this, a
  # regression that made the key constant — every prompt colliding on one file — would still show
  # "same input, one file" above and pass.
  printf 'OTHER-PROMPT-BODY\n' >"$BATS_TEST_TMPDIR/other.md"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    "$LDIR/claude" --append-system-prompt-file "$BATS_TEST_TMPDIR/other.md"
  [ "$status" -eq 0 ]
  other="$(printf '%s\n' "$output" | sed -n 's/^ARGV=--append-system-prompt-file \([^ ]*\).*/\1/p')"
  [ "$other" != "$first" ]
  grep -qFx 'OTHER-PROMPT-BODY' "$other"
  grep -qFx 'CALLER-PROMPT-BODY' "$first"
  [ "$(find "$CACHE/claude-launcher" -name 'append-system-prompt-*.md' | wc -l)" -eq 2 ]
  # No half-written temporaries left behind by the write-every-launch path.
  [ "$(find "$CACHE/claude-launcher" -name '.append-system-prompt.*' | wc -l)" -eq 0 ]
}

@test "claude.zsh + wrapper: cldf keeps the whole fable prompt and gains the rule (#677)" {
  _launchers
  _ask_rule
  # The end-to-end pin for "the new injection does not break the existing one": _claude_fable
  # still passes its own --append-system-prompt-file, and the wrapper folds rather than replaces.
  # The fixture is multi-line on purpose — grepping one line would pass even if the fold dropped
  # everything around it, and the real orchestrator prompt is 200+ lines.
  printf 'FABLE-LINE-1\nFABLE-LINE-2\n\nFABLE-LINE-4\n' \
    >"$BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md"
  run env HOME="$BATS_TEST_TMPDIR" XDG_CACHE_HOME="$CACHE" CLAUDE_LAUNCHER_BIN="$STUB" \
    PATH="$LDIR:$PATH" zsh -fc "
      export HOME='$BATS_TEST_TMPDIR'
      source '${HOME_DIR}/dot_config/zsh/claude.zsh'
      _claude_fable \"\$HOME/.claude\" --resume 'two words' ''
    "
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cFx -- '[--append-system-prompt-file]')" -eq 1 ]
  composite="$(printf '%s\n' "$output" | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p' | head -1)"
  # Compare the whole composite, not a line of it: the orchestrator prompt must arrive intact and
  # the rule must be last (the tail is the salient end — that is the point of #677).
  printf 'FABLE-LINE-1\nFABLE-LINE-2\n\nFABLE-LINE-4\n\nASK-RULE-BODY\n' \
    >"$BATS_TEST_TMPDIR/expected-composite.md"
  cmp "$BATS_TEST_TMPDIR/expected-composite.md" "$composite"
  ! printf '%s\n' "$output" | grep -qF "$BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md"
  # …and the rest of argv survives in order, with word boundaries intact.
  args="$(printf '%s\n' "$output" | sed -n '/^ARGC=/,$p' | tail -n +2)"
  expected="$(printf '[--append-system-prompt-file]\n[%s]\n[--resume]\n[two words]\n[]\n[--model]\n[claude-fable-5-1]' "$composite")"
  [ "$args" = "$expected" ]
}

# ---------- codex wrapper: account selection ----------

@test "codex wrapper: cdx-r06 overrides CODEX_HOME; codex/cdx follow CLAUDE_CONFIG_DIR" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/cdx-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex-r06"
  # A codex run inside a cld-r06 session (CLAUDE_CONFIG_DIR set) stays on r06.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude-r06" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex-r06"
  # Inside a personal session -> personal.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex"
}

@test "codex wrapper: CLAUDE_CONFIG_DIR is authoritative — a mismatched CODEX_HOME cannot leak" {
  _launchers
  # Personal Claude session but a stray r06 CODEX_HOME inherited: must be overridden to personal.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude" CODEX_HOME="$BATS_TEST_TMPDIR/.codex-r06" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex"
  # r06 Claude session but a stray personal CODEX_HOME: overridden to r06.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/.claude-r06" CODEX_HOME="$BATS_TEST_TMPDIR/.codex" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex-r06"
  # No Claude session in scope: an explicit CODEX_HOME is respected.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CODEX_HOME="$BATS_TEST_TMPDIR/.codex-r06" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex-r06"
}

@test "codex wrapper: an empty CLAUDE_CONFIG_DIR maps to personal, not a stray CODEX_HOME (#345 review)" {
  _launchers
  # CLAUDE_CONFIG_DIR set-but-empty means the personal account (Claude Code treats unset/empty as
  # ~/.claude); a stray r06 CODEX_HOME must NOT survive. Guards the ${VAR+x} presence check.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    CLAUDE_CONFIG_DIR="" CODEX_HOME="$BATS_TEST_TMPDIR/.codex-r06" "$LDIR/codex"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex"
}

@test "wrappers: the -r06 override survives a case-insensitive filesystem (\$0 case, #345 review)" {
  _launchers
  # On a case-insensitive FS (macOS APFS default) a symlink invoked as CLD-R06/CDX-R06 resolves to
  # the same file but \$0 keeps the typed case; the wrapper lowercases \$0 so the override still
  # fires. Skip on a case-sensitive FS (e.g. Linux CI), where the uppercase path does not resolve.
  touch "$BATS_TEST_TMPDIR/ci_probe"
  [ -e "$BATS_TEST_TMPDIR/CI_PROBE" ] || skip "case-sensitive filesystem"
  run env HOME="$BATS_TEST_TMPDIR" CLAUDE_LAUNCHER_BIN="$STUB" "$LDIR/CLD-R06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/.claude-r06"
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/CDX-R06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "CODEX_HOME=$BATS_TEST_TMPDIR/.codex-r06"
}

# ---------- codex wrapper: --profile injection ----------

@test "codex wrapper: injects --profile shared only when argv carries no profile flag" {
  _launchers
  # bare cdx -> inject
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/cdx"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile shared"
  # explicit --profile agent -> pass through, no injection
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" --profile agent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile agent"
  # equals form
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" --profile=agent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile=agent"
  # short forms
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" -p agent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=-p agent"
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" -pagent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=-pagent"
}

@test "codex wrapper: a --profile substring in a prompt does not suppress injection" {
  _launchers
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" \
    "$LDIR/codex" exec "explain the --profile flag"
  [ "$status" -eq 0 ]
  # injected at the global position, ahead of the subcommand; the prompt survives intact.
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile shared exec explain the --profile flag"
}

@test "codex wrapper: injection stops scanning at -- and is placed before subcommands" {
  _launchers
  # `--` stops the scan, so a post-`--` --profile is a positional, not our flag -> still inject.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" -- --profile agent
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile shared -- --profile agent"
  # exec review form: --profile must land at the global position (before `exec`), where it parses.
  run env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$STUB" "$LDIR/codex" exec review --base main
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "ARGV=--profile shared exec review --base main"
}

@test "codex wrapper: fails loudly when the real binary cannot be resolved" {
  _launchers
  run -127 env HOME="$BATS_TEST_TMPDIR" CODEX_LAUNCHER_BIN="$BATS_TEST_TMPDIR/nope" "$LDIR/codex"
  [[ "$output" == *"no executable codex found"* ]]
}

# ---------- residual zsh helpers in claude.zsh ----------

@test "claude.zsh: _claude_fable pins claude-fable-5-1 and skips the prompt when absent" {
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$CLAUDE_CONFIG_DIR|\$*\"; }
    _claude_fable \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|$BATS_TEST_TMPDIR/.claude|--model claude-fable-5-1" ]
}

@test "claude.zsh: _claude_fable appends the orchestrator prompt file when readable" {
  mkdir -p "$BATS_TEST_TMPDIR/.claude"
  : >"$BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md"
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"claude|\$*\"; }
    _claude_fable \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "claude|--model claude-fable-5-1 --append-system-prompt-file $BATS_TEST_TMPDIR/.claude/fable-orchestrator-prompt.md" ]
}

# The mock reports argc and one argument per line rather than "$*", and the caller passes an
# argument with a space plus an empty one. A single "$*" observation cannot tell "$@" from "$*":
# with one caller flag both spellings render the same joined string, so a regression that collapses
# argv into one word would pass unnoticed. Counting arguments catches it (5 vs 2), and the spaced /
# empty arguments pin the word boundaries the helper must preserve.
@test "claude.zsh: _claude_fable passes the caller's own flags through before the fable flags" {
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"argc=\$#\"; for a in \"\$@\"; do print -r -- \"[\$a]\"; done; }
    _claude_fable \"\$HOME/.claude\" --resume 'two words' ''
  "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "argc=5" ]
  [ "${lines[1]}" = "[--resume]" ]
  [ "${lines[2]}" = "[two words]" ]
  [ "${lines[3]}" = "[]" ]
  [ "${lines[4]}" = "[--model]" ]
  [ "${lines[5]}" = "[claude-fable-5-1]" ]
}

# #627 decided to leave CLAUDE_CODE_SUBAGENT_MODEL unset: since Claude Code 2.1.251 it is only the
# default (a per-spawn model and the agent frontmatter's model: both outrank it), so setting it
# would not close the "escalate a hard verification to fable" path — but it would split the
# declaration of the subagent default between this helper and the orchestrator prompt. That
# decision only lived in prose across four files, so this test makes it executable: it fails the
# moment the helper starts injecting either variable. _FORCE stays unset for the original reason
# (setting it really does close the escalation path). The vars are unset first so an exported value
# in the caller's environment cannot make this pass vacuously, and "-" (not ":-") is used so
# assigning an empty string still counts as set.
@test "claude.zsh: _claude_fable leaves CLAUDE_CODE_SUBAGENT_MODEL and its _FORCE variant unset (#627)" {
  run zsh -fc "
    export HOME='$BATS_TEST_TMPDIR'
    unset CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE
    source '${HOME_DIR}/dot_config/zsh/claude.zsh'
    claude() { print -r -- \"model=\${CLAUDE_CODE_SUBAGENT_MODEL-__NONE__}|force=\${CLAUDE_CODE_SUBAGENT_MODEL_FORCE-__NONE__}\"; }
    _claude_fable \"\$HOME/.claude\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "model=__NONE__|force=__NONE__" ]
}

@test "claude.zsh: cldf/cldf-r06 wire the fable orchestrator per account" {
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/claude.zsh'; alias cldf cldf-r06"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "cldf='_claude_fable \"\$HOME/.claude\"'"
  printf '%s\n' "$output" | grep -qFx "cldf-r06='_claude_fable \"\$HOME/.claude-r06\"'"
}

@test "claude.zsh: claude-config prefixes the hook opt-out and pins the default account" {
  run zsh -fc "source '${HOME_DIR}/dot_config/zsh/claude.zsh'; alias claude-config"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qFx "claude-config='ECC_DISABLED_HOOKS_EXTRA=pre:config-protection CLAUDE_CONFIG_DIR=\"\$HOME/.claude\" claude'"
}
