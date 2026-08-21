#!/usr/bin/env bats

load helpers/setup

@test "chezmoi source files exist: dot_zshrc.tmpl" {
  [ -f "${HOME_DIR}/dot_zshrc.tmpl" ]
}

@test "chezmoi source files exist: dot_zprofile.tmpl" {
  [ -f "${HOME_DIR}/dot_zprofile.tmpl" ]
}

@test "chezmoi source files exist: dot_gitconfig.tmpl" {
  [ -f "${HOME_DIR}/dot_gitconfig.tmpl" ]
}

@test "git lefthook-adopt alias sets a per-clone LOCAL core.hooksPath and never touches global" {
  local gc="${HOME_DIR}/dot_gitconfig.tmpl"
  # Coexistence helper for lefthook/husky repos: it must onboard a repo WITHOUT
  # disabling the global gitleaks guardrail (docs/architecture/dev-tooling.md).
  local def
  def="$(grep 'lefthook-adopt =' "$gc")"
  [ -n "$def" ]
  # The alias DEFINITION line must set a local hooksPath and must NEVER carry
  # --global: unsetting/rewriting the global core.hooksPath (what lefthook's own
  # --reset-hooks-path does) is exactly the guardrail-destroying move to avoid.
  [[ "$def" == *"config --local core.hooksPath"* ]]
  [[ "$def" != *"--global"* ]]
}

@test "chezmoi source files exist: private_dot_ssh/config.tmpl" {
  [ -f "${HOME_DIR}/private_dot_ssh/config.tmpl" ]
}

@test "chezmoi source files exist: dot_vimrc" {
  [ -f "${HOME_DIR}/dot_vimrc" ]
}

@test "chezmoi source files exist: dot_tmux.conf" {
  [ -f "${HOME_DIR}/dot_tmux.conf" ]
}

@test "chezmoi source files exist: dot_inputrc" {
  [ -f "${HOME_DIR}/dot_inputrc" ]
}

@test "chezmoi source files exist: dot_Brewfile" {
  [ -f "${HOME_DIR}/dot_Brewfile" ]
}

@test "chezmoi source files exist: .chezmoiexternal.toml" {
  [ -f "${HOME_DIR}/.chezmoiexternal.toml" ]
}

@test "chezmoi source files exist: .chezmoidata.toml" {
  [ -f "${HOME_DIR}/.chezmoidata.toml" ]
}

@test "chezmoi source files exist: starship.toml" {
  [ -f "${HOME_DIR}/dot_config/starship.toml" ]
}

@test "chezmoi source files exist: ghostty config" {
  [ -f "${HOME_DIR}/dot_config/ghostty/config" ]
}

@test "chezmoi source files exist: sheldon plugins.toml" {
  [ -f "${HOME_DIR}/dot_config/sheldon/plugins.toml" ]
}

@test "zsh modules exist" {
  local modules=(git docker claude codex functions completions wtp ghq)
  for mod in "${modules[@]}"; do
    [ -f "${HOME_DIR}/dot_config/zsh/${mod}.zsh" ]
  done
  # aliases.zsh is now a chezmoi template
  [ -f "${HOME_DIR}/dot_config/zsh/aliases.zsh.tmpl" ]
}

@test "chezmoi source files exist: dot_config/zsh/completions/_ghq" {
  [ -f "${HOME_DIR}/dot_config/zsh/completions/_ghq" ]
}

@test "ghq zsh completion has compdef directive on first line" {
  head -n1 "${HOME_DIR}/dot_config/zsh/completions/_ghq" | grep -q '^#compdef ghq'
}

@test "lifecycle scripts exist" {
  [ -f "${HOME_DIR}/run_once_before_00-install-prerequisites.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_before_10-brew-bundle.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_after_20-macos-defaults.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_after_30-register-launchd-agents.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_onchange_after_40-setup-sheldon.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_16-migrate-claude-binary.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_50-set-login-shell.sh.tmpl" ]
  [ -f "${HOME_DIR}/run_once_after_90-other-apps.sh.tmpl" ]
}

@test "morning-radar launchd agent source files exist" {
  [ -f "${HOME_DIR}/Library/LaunchAgents/dev.kryota.morning-radar.plist.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude/executable_morning-radar.sh" ]
  [ -f "${HOME_DIR}/run_onchange_after_30-register-launchd-agents.sh.tmpl" ]
}

@test "morning-radar plist schedules weekdays only and never runs at load" {
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.morning-radar.plist.tmpl"
  # RunAtLoad must stay absent so (re-)registration never triggers a billed run.
  run grep -q '<key>RunAtLoad</key>' "$plist"
  [ "$status" -ne 0 ]
  # Mon-Fri at 09:00 local time: exactly five Weekday/Hour entries (#257).
  [ "$(grep -c '<key>Weekday</key>' "$plist")" -eq 5 ]
  [ "$(grep -c '<key>Hour</key>' "$plist")" -eq 5 ]
  # The Weekday values must be exactly Mon-Fri (1-5), not just five entries.
  local weekdays
  weekdays="$(grep -A1 '<key>Weekday</key>' "$plist" | grep -oE '[0-9]+' | sort -u | paste -sd, -)"
  [ "$weekdays" = "1,2,3,4,5" ]
}

@test "morning-radar plist template renders to valid plist XML" {
  command -v plutil >/dev/null 2>&1 || skip "plutil unavailable"
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.morning-radar.plist.tmpl"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sed 's|{{ \.chezmoi\.homeDir }}|/Users/test|g' "$plist" >"${tmp}/agent.plist"
  plutil -lint "${tmp}/agent.plist"
}

@test "ntfy-dashboard launchd agent source files exist" {
  [ -f "${HOME_DIR}/Library/LaunchAgents/dev.kryota.ntfy-dashboard.plist.tmpl" ]
  [ -f "${HOME_DIR}/dot_config/ntfy-dashboard/server.ts" ]
  [ -f "${HOME_DIR}/dot_config/ntfy-dashboard/server_test.ts" ]
}

@test "ntfy-dashboard plist runs at load and stays alive (unlike morning-radar)" {
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.ntfy-dashboard.plist.tmpl"
  # This is the repo's first persistent LaunchAgent (#371): unlike morning-radar,
  # RunAtLoad + KeepAlive must both be present so the dashboard is reachable at
  # any time, not just at a scheduled fire.
  grep -q '<key>RunAtLoad</key>' "$plist"
  grep -q '<key>KeepAlive</key>' "$plist"
  # Never a scheduled one-shot job.
  run grep -q '<key>StartCalendarInterval</key>' "$plist"
  [ "$status" -ne 0 ]
}

@test "ntfy-dashboard plist scopes Deno permission flags (no --allow-all)" {
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.ntfy-dashboard.plist.tmpl"
  grep -q -- '--allow-net=' "$plist"
  grep -q -- '--allow-run=' "$plist"
  grep -q -- '--allow-read=' "$plist"
  run grep -qE -- '--allow-all|-A\b|--allow-run=claude<' "$plist"
  [ "$status" -ne 0 ]
  # --allow-run must be scoped to a path ending in /claude, not the bare
  # command name (which would need PATH resolution the unattended daemon
  # should not rely on). The value is a chezmoi template expression here
  # ({{ .chezmoi.homeDir }}/.../claude), not yet a literal absolute path.
  grep -qE -- '--allow-run=.+/claude<' "$plist"
}

@test "ntfy-dashboard plist template renders to valid plist XML" {
  command -v plutil >/dev/null 2>&1 || skip "plutil unavailable"
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.ntfy-dashboard.plist.tmpl"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sed -E 's|\{\{[^}]*\.ntfy_dashboard\.([a-z_]+)[^}]*\}\}|1|g; s|\{\{[^}]*\.ntfy\.port[^}]*\}\}|1|g; s|\{\{ \.chezmoi\.homeDir \}\}|/Users/test|g' "$plist" >"${tmp}/agent.plist"
  plutil -lint "${tmp}/agent.plist"
}

@test "knowledge-distill launchd agent source files exist" {
  [ -f "${HOME_DIR}/Library/LaunchAgents/dev.kryota.knowledge-distill.plist.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude/executable_knowledge-distill-radar.sh" ]
}

@test "knowledge-distill plist schedules Friday only and never runs at load" {
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.knowledge-distill.plist.tmpl"
  # RunAtLoad must stay absent so (re-)registration never triggers a billed run.
  run grep -q '<key>RunAtLoad</key>' "$plist"
  [ "$status" -ne 0 ]
  # Weekly on Friday at 18:00 local time: exactly one Weekday/Hour entry (#368).
  [ "$(grep -c '<key>Weekday</key>' "$plist")" -eq 1 ]
  [ "$(grep -c '<key>Hour</key>' "$plist")" -eq 1 ]
  local weekday hour
  weekday="$(grep -A1 '<key>Weekday</key>' "$plist" | grep -oE '[0-9]+')"
  [ "$weekday" = "5" ]
  hour="$(grep -A1 '<key>Hour</key>' "$plist" | grep -oE '[0-9]+')"
  [ "$hour" = "18" ]
}

@test "knowledge-distill plist template renders to valid plist XML" {
  command -v plutil >/dev/null 2>&1 || skip "plutil unavailable"
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.knowledge-distill.plist.tmpl"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sed 's|{{ \.chezmoi\.homeDir }}|/Users/test|g' "$plist" >"${tmp}/agent.plist"
  plutil -lint "${tmp}/agent.plist"
}

@test "macos-defaults-drift launchd agent source files exist (#365)" {
  [ -f "${HOME_DIR}/Library/LaunchAgents/dev.kryota.macos-defaults-drift.plist.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude/executable_macos-defaults-drift-check.sh" ]
  bash -n "${HOME_DIR}/dot_claude/executable_macos-defaults-drift-check.sh"
}

@test "macos-defaults-drift plist schedules exactly one weekly run and never runs at load" {
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.macos-defaults-drift.plist.tmpl"
  run grep -q '<key>RunAtLoad</key>' "$plist"
  [ "$status" -ne 0 ]
  # Weekly: exactly one Weekday/Hour/Minute entry, not one per weekday.
  [ "$(grep -c '<key>Weekday</key>' "$plist")" -eq 1 ]
  [ "$(grep -c '<key>Hour</key>' "$plist")" -eq 1 ]
  [ "$(grep -c '<key>Minute</key>' "$plist")" -eq 1 ]
  # Sunday 10:00, not just "some" values -- pin the actual schedule.
  grep -A1 '<key>Weekday</key>' "$plist" | grep -q '<integer>0</integer>'
  grep -A1 '<key>Hour</key>' "$plist" | grep -q '<integer>10</integer>'
  grep -A1 '<key>Minute</key>' "$plist" | grep -q '<integer>0</integer>'
}

@test "macos-defaults-drift plist template renders to valid plist XML" {
  command -v plutil >/dev/null 2>&1 || skip "plutil unavailable"
  local plist="${HOME_DIR}/Library/LaunchAgents/dev.kryota.macos-defaults-drift.plist.tmpl"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sed 's|{{ \.chezmoi\.homeDir }}|/Users/test|g' "$plist" >"${tmp}/agent.plist"
  plutil -lint "${tmp}/agent.plist"
}

@test "launcher dir reaches interactive (precmd+sync) and login (zprofile) shells (#345)" {
  local zshrc="${HOME_DIR}/dot_zshrc.tmpl"
  local zprofile="${HOME_DIR}/dot_zprofile.tmpl"
  # Interactive: the reorder is registered as a precmd hook AND called once synchronously, so
  # `zsh -ic '<cmd>'` (which runs before the first prompt fires precmd) still gets the wrapper.
  grep -qF 'add-zsh-hook precmd _launcher_path_precmd' "$zshrc"
  [ "$(grep -c '^_launcher_path_precmd$' "$zshrc")" -ge 1 ]
  # Login shells do NOT source ~/.zshrc, so the launcher dir is also prepended in ~/.zprofile.
  grep -qF '.local/launchers:$PATH' "$zprofile"
}

@test "launcher wrappers and account symlinks exist with the expected shape (#345)" {
  local ldir="${HOME_DIR}/dot_local/launchers"
  [ -f "${ldir}/executable_claude" ]
  [ -f "${ldir}/executable_codex" ]
  bash -n "${ldir}/executable_claude"
  bash -n "${ldir}/executable_codex"
  # chezmoi symlink_ sources: the file content is the (relative) symlink target, so bare `claude`
  # / `codex` and the -r06 / short names all resolve to the two dispatch-on-$0 wrappers.
  [ "$(cat "${ldir}/symlink_cld")" = "claude" ]
  [ "$(cat "${ldir}/symlink_cld-r06")" = "claude" ]
  [ "$(cat "${ldir}/symlink_cdx")" = "codex" ]
  [ "$(cat "${ldir}/symlink_cdx-r06")" = "codex" ]
}

@test "morning-radar wrapper keeps the explicit permission allowlist" {
  local wrapper="${HOME_DIR}/dot_claude/executable_morning-radar.sh"
  bash -n "$wrapper"
  # Permission model is an explicit allowlist (#257): flag any bypass creep.
  run grep -q 'dangerously-skip-permissions' "$wrapper"
  [ "$status" -ne 0 ]
  run grep -q 'bypassPermissions' "$wrapper"
  [ "$status" -ne 0 ]
  grep -q -- '--allowedTools' "$wrapper"
  grep -q -- '--max-turns' "$wrapper"
  # Model stays pinned so the pre-approved recurring cost is predictable (R2.7).
  grep -q -- '--model' "$wrapper"
  # Personal-account isolation must stay explicit (R2.1).
  grep -q 'CLAUDE_CONFIG_DIR' "$wrapper"
  # Delivery migrated osascript -> ntfy (#361): no osascript path may remain
  # (AC-002), and the publisher token must never reach curl argv (AC-006; it
  # travels via a `curl -K` config file, as ntfy-notify.sh does).
  run grep -qE 'osascript|display notification' "$wrapper"
  [ "$status" -ne 0 ]
  run grep -E -- '(-H|--header)["'"'"'[:space:]]*"?Authorization' "$wrapper"
  [ "$status" -ne 0 ]
}

@test "morning-radar delegates account env to the claude wrapper instead of hand-copying it (#336, #345)" {
  # The per-account isolation env — including the #336-critical CLV2_HOMUNCULUS_DIR that must sit
  # OUTSIDE the config dir (Claude Code treats paths under it as sensitive files that no headless
  # session can approve a write to) — now lives solely in the claude launcher wrapper, which the
  # brief reaches through PATH. The brief must NOT re-copy those assignments, or the copy could
  # drift (the exact failure #341 hit). The wrapper's own #336 guarantee is pinned in
  # zsh_aliases.bats; here we pin that the brief delegates instead of duplicating.
  local wrapper="${HOME_DIR}/dot_claude/executable_morning-radar.sh"
  # No per-account env assignments (comments naming the vars are fine; assignments are not).
  run grep -qE 'CLV2_HOMUNCULUS_DIR=|ECC_AGENT_DATA_HOME=|GATEGUARD_STATE_DIR=|ECC_MCP_HEALTH_STATE_PATH=' "$wrapper"
  [ "$status" -ne 0 ]
  run grep -q 'ecc-homunculus' "$wrapper"
  [ "$status" -ne 0 ]
  # It reaches the wrapper by putting the launcher dir first on its hand-built launchd PATH,
  # pins the personal account (the wrapper keeps an explicit CLAUDE_CONFIG_DIR via fill-gaps),
  # and opts out of web search by exporting empty MCP keys (the wrapper's +x guard then skips
  # sourcing the keys file), preserving the prior "brief needs no web-search keys" behavior.
  grep -qF '$HOME/.local/launchers:' "$wrapper"
  grep -qF 'CLAUDE_CONFIG_DIR="$HOME/.claude"' "$wrapper"
  grep -qF 'EXA_API_KEY=""' "$wrapper"
  grep -qF 'FIRECRAWL_API_KEY=""' "$wrapper"
}

@test "morning-radar wrapper does not carry a dead ECC_DISABLED_HOOKS alias-level default (#280)" {
  # settings.json's env block is the effective SSOT for ECC_DISABLED_HOOKS (Claude Code
  # applies it with precedence over shell-inherited env vars), so a "${ECC_DISABLED_HOOKS:-...}"
  # default here would be dead code that never actually takes effect.
  local wrapper="${HOME_DIR}/dot_claude/executable_morning-radar.sh"
  [ -f "$wrapper" ]
  run grep -qF 'ECC_DISABLED_HOOKS="${ECC_DISABLED_HOOKS:-' "$wrapper"
  [ "$status" -ne 0 ]
}

@test "morning-radar wrapper skips a second run on the same day" {
  local wrapper="${HOME_DIR}/dot_claude/executable_morning-radar.sh"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # Pre-seed today's stamp in a sandboxed HOME/XDG state dir (R1.5). claude is
  # not resolvable from the sandbox HOME, so a bypassed guard exits 1 instead.
  mkdir -p "${tmp}/state/morning-radar"
  printf '%s\n' "$(date +%F)" >"${tmp}/state/morning-radar/last-run"
  run env HOME="$tmp" XDG_STATE_HOME="${tmp}/state" bash "$wrapper"
  [ "$status" -eq 0 ]
}

@test "launchd registration script embeds all plist hashes and guards CI (#365, #368)" {
  local script="${HOME_DIR}/run_onchange_after_30-register-launchd-agents.sh.tmpl"
  # Re-registration is keyed to each plist's own content (embedded-hash trick,
  # one per agent so each is tracked independently, #371).
  grep -Fq 'plist hash: {{ include "Library/LaunchAgents/dev.kryota.morning-radar.plist.tmpl" | sha256sum }}' "$script"
  grep -Fq 'plist hash: {{ include "Library/LaunchAgents/dev.kryota.knowledge-distill.plist.tmpl" | sha256sum }}' "$script"
  grep -Fq 'plist hash: {{ include "Library/LaunchAgents/dev.kryota.macos-defaults-drift.plist.tmpl" | sha256sum }}' "$script"
  grep -Fq 'plist hash: {{ include "Library/LaunchAgents/dev.kryota.ntfy-dashboard.plist.tmpl" | sha256sum }}' "$script"
  # All four labels must be registered via the shared loop, not hardcoded once.
  grep -Fq 'labels=(dev.kryota.morning-radar dev.kryota.knowledge-distill dev.kryota.macos-defaults-drift dev.kryota.ntfy-dashboard)' "$script"
  grep -Fq 'for label in "${labels[@]}"; do' "$script"
  # CI runners have no gui launchd domain; the script must self-skip there.
  grep -Fq 'if [ -n "${CI:-}" ]; then' "$script"
  # Template-stripped body must be valid bash (same strip trick as make lint).
  bash -n <(sed '/{{/d' "$script")
}

@test "launchd registration script registers all four LaunchAgents" {
  local script="${HOME_DIR}/run_onchange_after_30-register-launchd-agents.sh.tmpl"
  grep -qF 'dev.kryota.morning-radar' "$script"
  grep -qF 'dev.kryota.knowledge-distill' "$script"
  grep -qF 'dev.kryota.macos-defaults-drift' "$script"
  grep -qF 'dev.kryota.ntfy-dashboard' "$script"
}

@test "prerequisites installs Rosetta 2 behind an arm64 guard" {
  local tmpl="${HOME_DIR}/run_once_before_00-install-prerequisites.sh.tmpl"
  # Installs Rosetta 2 non-interactively (Intel-only casks need it).
  grep -Fq 'softwareupdate --install-rosetta --agree-to-license' "$tmpl"
  # Idempotent: skips when x86_64 binaries already run (Rosetta present).
  grep -Fq 'arch -x86_64' "$tmpl"
  # The install must sit inside an arm64 template guard, not just anywhere: the
  # Homebrew shellenv block also opens an arm64 guard, so a bare grep for the
  # guard string would pass even if the Rosetta block lost its own guard.
  awk '
    /\{\{ if eq \.chezmoi\.arch "arm64" -\}\}/ { guard = 1; next }
    /\{\{ (else|end)/ { guard = 0 }
    /softwareupdate --install-rosetta/ && guard { inside = 1 }
    END { exit !inside }
  ' "$tmpl"
}

@test "claude agents exist" {
  [ -d "${HOME_DIR}/dot_claude/agents" ]
  local count
  count=$(find "${HOME_DIR}/dot_claude/agents" -name "*.md" | wc -l)
  [ "$count" -gt 0 ]
}

@test "language specialist reviewer agents exist with expected frontmatter" {
  local lang agent
  for lang in typescript react python database; do
    agent="${HOME_DIR}/dot_claude/agents/${lang}-reviewer.md"
    [ -f "$agent" ]
    grep -q "^name: ${lang}-reviewer$" "$agent"
    grep -q "^model: sonnet$" "$agent"
    grep -q "^tools: Read, Glob, Grep, Bash$" "$agent"
  done
}

@test "adversarial-verifier agent exists with a pinned refutation tier" {
  local agent="${HOME_DIR}/dot_claude/agents/adversarial-verifier.md"
  [ -f "$agent" ]
  grep -q "^name: adversarial-verifier$" "$agent"
  grep -q "^model: sonnet$" "$agent"
  # The Agent tool cannot pass effort per call, so xhigh has to live in frontmatter.
  grep -q "^effort: xhigh$" "$agent"
}

@test "cross-cutting specialist reviewer agents exist with expected frontmatter" {
  # #347: sdd's built-in review (Phase 5) was removed and its performance/test/ux
  # perspectives moved to multi-review as dedicated specialist agents, mirroring the
  # language reviewer pattern (SSOT in the agent definition, sonnet + high pinned).
  local role agent
  for role in performance test ux; do
    agent="${HOME_DIR}/dot_claude/agents/${role}-reviewer.md"
    [ -f "$agent" ]
    grep -q "^name: ${role}-reviewer$" "$agent"
    grep -q "^model: sonnet$" "$agent"
    grep -q "^effort: high$" "$agent"
    grep -q "^tools: Read, Glob, Grep, Bash$" "$agent"
  done
}

@test "every agent definition pins both model and effort" {
  # Sweeps the whole directory rather than a hardcoded roster, so a newly added agent is
  # covered automatically. `model:` accepts aliases only — switching an agent to a literal
  # slug (the pinning philosophy settings.json uses) would need this pattern widened.
  local agent name
  for agent in "${HOME_DIR}"/dot_claude/agents/*.md; do
    [ -e "$agent" ] || continue
    name="$(basename "$agent")"
    grep -qE '^model: (sonnet|opus|haiku|fable)$' "$agent" || {
      echo "${name}: model is unpinned (inherit or missing) — Opus sessions would run it at top tier"
      false
    }
    grep -qE '^effort: (low|medium|high|xhigh|max)$' "$agent" || {
      echo "${name}: effort is unpinned — a low-effort session would silently degrade its output"
      false
    }
  done
}

@test "every agent definition forbids write and execution via Bash" {
  # Reviewer agents read diffs that are, by definition, unverified input. `permissions.allow`
  # pre-approves npm/npx/vitest/docker, so the technical layer lets a runner through — this
  # prompt-level constraint is the only control, and it must not be missing from any agent.
  local agent name
  for agent in "${HOME_DIR}"/dot_claude/agents/*.md; do
    [ -e "$agent" ] || continue
    name="$(basename "$agent")"
    # Agents without Bash cannot execute anything, so the constraint is moot for them.
    grep -qE '^tools:.*\bBash\b' "$agent" || continue
    grep -q '読み取り専用' "$agent" || {
      echo "${name}: no read-only Bash constraint — the agent could execute repo code under review"
      false
    }
  done
}

@test "model-fitness-check skill exists as the model/effort contract SSOT" {
  local skill="${HOME_DIR}/dot_agents/skills/model-fitness-check/SKILL.md"
  [ -f "$skill" ]
  grep -q "^name: model-fitness-check$" "$skill"
  # The three orchestration skills must call it instead of restating the table.
  local caller
  for caller in pr-workflow sdd multi-review; do
    grep -q 'model-fitness-check' "${HOME_DIR}/dot_agents/skills/${caller}/SKILL.md" || {
      echo "${caller}/SKILL.md does not invoke model-fitness-check"
      false
    }
  done
}

@test "reviewer agents steer to a valid gh pr diff filter idiom" {
  # gh pr diff has no include pathspec (only --exclude / --name-only), so every
  # reviewer agent must reference --name-only rather than the unsupported
  # `gh pr diff <n> -- <path>` form. Positive guard (the docs mention the bad form
  # only as a counter-example, so a negative grep would false-positive on it).
  local agent
  for agent in "${HOME_DIR}/dot_claude/agents"/{cc-code-review,typescript-reviewer,react-reviewer,python-reviewer,database-reviewer,architecture-reviewer}.md; do
    grep -q -- "--name-only" "$agent"
  done
}

@test "architecture-reviewer agent exists as a separate aggregate-view layer" {
  # #223: whole-repo/architecture reviewer, distinct from the diff-triggered
  # specialist roster. Pinned to sonnet (#28 model-tier) and scans the repo tree
  # (not just the diff), so it must reference a repo-wide enumeration command.
  local agent="${HOME_DIR}/dot_claude/agents/architecture-reviewer.md"
  [ -f "$agent" ]
  grep -q "^name: architecture-reviewer$" "$agent"
  grep -q "^model: sonnet$" "$agent"
  grep -q "^tools: Read, Glob, Grep, Bash$" "$agent"
  grep -q "git ls-files" "$agent"
}

@test "shared agent skills exist" {
  [ -d "${HOME_DIR}/dot_agents/skills" ]
  local count
  count=$(find "${HOME_DIR}/dot_agents/skills" -type d -mindepth 1 | wc -l)
  [ "$count" -gt 0 ]
}

@test "retrospective-codify skill exists with valid frontmatter and structure" {
  local skill="${HOME_DIR}/dot_agents/skills/retrospective-codify/SKILL.md"
  [ -f "$skill" ]
  # Frontmatter delimiter on line 1, name matches the directory.
  head -n1 "$skill" | grep -q '^---$'
  grep -q '^name: retrospective-codify$' "$skill"
  grep -q '^description:' "$skill"
  grep -q '^argument-hint:' "$skill"
  # Args were split into --range/--target (the old --scope was overloaded).
  grep -q -- '--range=' "$skill"
  grep -q -- '--target=' "$skill"
  # Core sections are present.
  grep -q '## 実行フロー' "$skill"
}

@test "claude and codex skills are symlinked" {
  [ -f "${HOME_DIR}/dot_claude/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex/symlink_skills.tmpl" ]
}

@test "pr-workflow orchestrator skill exists with tier paths and gates" {
  local skill="${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
  [ -f "$skill" ]
  head -n1 "$skill" | grep -q '^---$'
  grep -q '^name: pr-workflow$' "$skill"
  grep -q '^argument-hint:' "$skill"
  grep -q '^user-invocable: true$' "$skill"
  # The four size tiers, the operation variants, and the three gates.
  local t
  for t in trivial small standard large; do grep -q "$t" "$skill"; done
  grep -q 'add-feature' "$skill"
  grep -q 'GATE 1' "$skill"; grep -q 'GATE 2' "$skill"; grep -q 'GATE 3' "$skill"
  # Merge stays the user's action; never auto-merge.
  grep -q '自動マージしない' "$skill"
  ! grep -q '自動マージする' "$skill"
  # Must not reference the removed sdd-worker agent (Phase 4-1, task #25).
  ! grep -q 'sdd-worker' "$skill"
  # Referenced curated skills that this orchestrator delegates to must exist.
  local s
  for s in sdd multi-review review-resolve-loop monitor-ci grill-me commit create-pr planning; do
    [ -f "${HOME_DIR}/dot_agents/skills/${s}/SKILL.md" ] || { echo "delegated skill missing: $s"; return 1; }
  done
  # tdd-workflow / santa-method are described as inline protocols, not skills;
  # they must NOT be referenced as if they were invokable curated skills.
  [ ! -d "${HOME_DIR}/dot_agents/skills/tdd-workflow" ]
  [ ! -d "${HOME_DIR}/dot_agents/skills/santa-method" ]
}

@test "Plan-PRD pipeline flags are wired into grill-me / planning / sdd (opt-in)" {
  local skills="${HOME_DIR}/dot_agents/skills"
  # grill-me emits the PRD; planning consumes it and emits the Plan; sdd
  # optionally consumes either or both (--prd / --plan are independent opt-ins).
  grep -q -- '--output-prd' "${skills}/grill-me/SKILL.md"
  grep -q -- '--input-prd' "${skills}/planning/SKILL.md"
  grep -q -- '--output-plan' "${skills}/planning/SKILL.md"
  grep -q -- '--prd' "${skills}/sdd/SKILL.md"
  grep -q -- '--plan' "${skills}/sdd/SKILL.md"
  grep -q -- '--mode' "${skills}/grill-me/SKILL.md"
  grep -q -- '--mode' "${skills}/planning/SKILL.md"
  # Each must declare the flags are opt-in (default behaviour preserved).
  grep -q '任意 / opt-in' "${skills}/grill-me/SKILL.md"
  grep -q '任意 / opt-in' "${skills}/planning/SKILL.md"
  grep -q '任意 / opt-in' "${skills}/sdd/SKILL.md"
  # Pipeline contract: PRD/Plan frontmatter + no-overwrite collision handling.
  grep -q 'grill_session:' "${skills}/grill-me/SKILL.md"
  grep -q 'planning_session:' "${skills}/planning/SKILL.md"
  grep -q '上書きしない\|上書き禁止' "${skills}/grill-me/SKILL.md"
  grep -q '上書きしない\|上書き禁止' "${skills}/planning/SKILL.md"
}

@test "sdd is a single-pass component with no built-in review phase (#347)" {
  local skill="${HOME_DIR}/dot_agents/skills/sdd/SKILL.md"
  [ -f "$skill" ]
  # The review phase and its review-team machinery are gone; review is owned by
  # pr-workflow's post-PR pipeline (monitor-ci -> multi-review -> review-resolve-loop).
  ! grep -q '^## Phase 5: レビュー' "$skill"
  ! grep -q 'shutdown_request' "$skill"
  ! grep -q 'Review Team' "$skill"
  # Phases are renumbered and contiguous after the removal.
  grep -q '^## Phase 5: コミット & PR' "$skill"
  grep -q '^## Phase 6: 完了報告' "$skill"
  # Hidden from the / menu so a user cannot run it standalone, while pr-workflow can
  # still invoke it via the Skill tool (user-invocable: false blocks menu/user access
  # but NOT Skill-tool access; per the CC docs it keeps "Claude can invoke: yes").
  # NB: disable-model-invocation is deliberately NOT set — it would also set
  # "Claude can invoke: no", which would stop pr-workflow from invoking sdd.
  # user-invocable defaults to true when absent, so the false must be explicit.
  grep -q '^user-invocable: false$' "$skill"
  ! grep -q '^disable-model-invocation:' "$skill"
}

@test "multi-review wires the cross-cutting specialist roster and spec-context (#347)" {
  local skill="${HOME_DIR}/dot_agents/skills/multi-review/SKILL.md"
  [ -f "$skill" ]
  # The three ported specialists are referenced by subagent_type.
  grep -q 'performance-reviewer' "$skill"
  grep -q 'test-reviewer' "$skill"
  grep -q 'ux-reviewer' "$skill"
  # spec-implementation consistency context is an opt-in flag from the caller.
  grep -q -- '--spec-context' "$skill"
  # pr-workflow passes the spec dir on the standard/large path.
  grep -q -- '--spec-context' "${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
}

@test "multi-review tier-aware roster / Codex-offload contract (#407)" {
  local skill="${HOME_DIR}/dot_agents/skills/multi-review/SKILL.md"
  local pw="${HOME_DIR}/dot_agents/skills/pr-workflow/SKILL.md"
  [ -f "$skill" ]
  # The four size tiers each own a row in the roster gating table.
  local t
  for t in trivial small standard large; do
    grep -qE "^\| \*\*${t}\*\*" "$skill" || { echo "missing gating row for tier: $t"; return 1; }
  done
  # Codex observation/offload wiring: --json stream + -o result file + named
  # concurrency cap + resume's fresh fallback.
  grep -q -- '--json' "$skill"
  grep -q -- '-o <RESULT_FILE>' "$skill"
  grep -q 'CODEX_MAX_CONCURRENCY' "$skill"
  grep -q 'fresh フォールバック' "$skill"
  # #407 robustness — phrase-level assertions that guard semantic regression, not
  # mere word presence (a bare 'fail-open'/'--tier' elsewhere must not satisfy these):
  # fail-open guard — an undefined --tier value is treated as empty, not fail-open.
  grep -q 'fail-open' "$skill"
  grep -qE '未定義値.*空扱い' "$skill"
  # security floor is a post-determination, UNCONDITIONAL backstop that overrides
  # even an explicit --tier=trivial/small (M1) — assert the max() formula + override.
  grep -q 'security フロア' "$skill"
  grep -qF 'final = max(TIER, standard)' "$skill"
  grep -qE '明示.*--tier.*上書き' "$skill"
  grep -q '決定的' "$skill"
  # floor keyword coverage is case-insensitive and floor-not-ceiling (S3).
  grep -q '大文字小文字を無視' "$skill"
  grep -q 'jwt' "$skill"; grep -q 'oauth' "$skill"
  grep -q 'floor であって ceiling ではない' "$skill"
  # resolved OQ-005 (sessions.json TTL / cleanup).
  grep -q 'OQ-005: 解決済み' "$skill"
  # tier auto-inference points at pr-workflow's tier table as SSOT (no paraphrase).
  grep -qE 'size tier の判定軸.*SSOT' "$skill"
  grep -q 'size tier の判定軸' "$pw"
  # pr-workflow Phase 6 explicitly forwards the determined tier to multi-review.
  grep -q -- '--tier' "$pw"
  # The stale "always-on 3 tools" framing must be gone from the tier-aware roster.
  ! grep -q '3ツールレビュー' "$skill"
  ! grep -q '常設 3 ツール' "$skill"
}

@test "review-fleet reflects tier gating + Codex offload, not a fixed 3-tool roster (#407)" {
  local skill="${HOME_DIR}/dot_agents/skills/review-fleet/SKILL.md"
  [ -f "$skill" ]
  # No stale "always-on 3 tools" wording remains.
  ! grep -q '常設 3 ツール' "$skill"
  # Tier gating + Codex offload framing and the --tier decision are documented.
  grep -q 'tier gating' "$skill"
  grep -q 'offload' "$skill"
  grep -q -- '--tier' "$skill"
  # review-fleet must not pass --tier by default (phrase-level, not mere '--tier').
  grep -q '既定で渡さない' "$skill"
}

# The pipeline Plan (<slug>.plan.md) must be git-trackable while ad-hoc
# timestamp plans stay ignored — the handoff artifact would break otherwise.
@test "Plan-PRD pipeline plans are un-ignored in the global gitignore" {
  local gi="${HOME_DIR}/dot_gitignore_global"
  local tmp; tmp=$(mktemp -d)
  cd "$tmp"
  git init -q
  git config core.excludesfile "$gi"
  mkdir -p .claude/plans
  touch .claude/plans/20260101_adhoc.md .claude/plans/feat.plan.md
  # ad-hoc timestamp plan stays ignored, pipeline .plan.md is tracked.
  # Capture with && || so a non-zero check-ignore does not abort the test.
  local adhoc_ignored plan_ignored
  git check-ignore -q .claude/plans/20260101_adhoc.md && adhoc_ignored=yes || adhoc_ignored=no
  git check-ignore -q .claude/plans/feat.plan.md && plan_ignored=yes || plan_ignored=no
  cd "$REPO_ROOT"
  rm -rf "$tmp"
  [ "$adhoc_ignored" = yes ]
  [ "$plan_ignored" = no ]
}

@test "codex-r06 work profile sources exist" {
  [ -f "${HOME_DIR}/dot_codex-r06/symlink_AGENTS.md.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/private_shared.config.toml.tmpl" ]
}

@test "codex shared config SSOT exists" {
  [ -f "${HOME_DIR}/.chezmoitemplates/codex-shared-config.toml" ]
  [ -f "${HOME_DIR}/dot_codex/private_shared.config.toml.tmpl" ]
}

@test "codex model pin and agent profile sources exist" {
  [ -f "${HOME_DIR}/.chezmoitemplates/codex-model-pin.toml" ]
  [ -f "${HOME_DIR}/.chezmoitemplates/codex-agent-config.toml" ]
  [ -f "${HOME_DIR}/dot_codex/private_agent.config.toml.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/private_agent.config.toml.tmpl" ]
}

# Rendered-target checks: verify the composed profiles actually produce the intended
# permission posture, not just that the sources exist. The agent profile must carry
# workspace-write/approval-never/network-off; the shared profile (used by interactive
# cdx/cdx-r06) must NOT carry any permission keys, or interactive sessions would silently
# gain write access.
@test "codex agent profile renders the workspace-write permission posture" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  local rendered
  rendered="$(chezmoi cat "${HOME}/.codex/agent.config.toml" --source "${HOME_DIR}" 2>/dev/null)"
  grep -qx 'sandbox_mode = "workspace-write"' <<<"$rendered"
  grep -qx 'approval_policy = "never"' <<<"$rendered"
  grep -qx 'web_search = "cached"' <<<"$rendered"
  grep -qx 'network_access = false' <<<"$rendered"
}

@test "codex shared profile does not leak permission keys to interactive sessions" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  local rendered
  rendered="$(chezmoi cat "${HOME}/.codex/shared.config.toml" --source "${HOME_DIR}" 2>/dev/null)"
  grep -qx 'model_reasoning_effort = "xhigh"' <<<"$rendered"
  # The shared profile must stay permission-free (AC-004).
  run grep -Eq '^(sandbox_mode|approval_policy|network_access|web_search)[[:space:]]*=' <<<"$rendered"
  [ "$status" -ne 0 ]
}

@test "claude-r06 work profile symlinks exist" {
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_CLAUDE.md.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_skills.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_settings.json.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_agents.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_statusline.sh.tmpl" ]
  [ -f "${HOME_DIR}/dot_claude-r06/symlink_commands.tmpl" ]
}

@test "aside command is fetched from ECC via chezmoi external and delivered to r06" {
  local ext="${HOME_DIR}/.chezmoiexternal.toml"
  # The aside command is referenced (not vendored): a chezmoi external file entry
  # targeting ~/.claude/commands/aside.md, fetched verbatim from ECC. Verbatim
  # external fetch means this public repo references rather than redistributes
  # the file, so it is NOT committed under home/dot_claude/commands/.
  [ ! -e "${HOME_DIR}/dot_claude/commands/aside.md" ]
  grep -q '\[".claude/commands/aside.md"\]' "$ext"
  grep -q 'raw.githubusercontent.com/affaan-m/ECC' "$ext"
  grep -q 'commands/aside.md' "$ext"
  # Pinned to the shared ECC commit (version-locked with the hook runtime), not a
  # mutable branch/tag.
  grep -q '{{ .ecc.commit }}/commands/aside.md' "$ext"
  # r06 work profile shares the commands dir via a symlink that points at the
  # DEFAULT profile (exact match: a self-referential ~/.claude-r06/commands
  # target would loop, and a loose grep would not catch it).
  [ "$(cat "${HOME_DIR}/dot_claude-r06/symlink_commands.tmpl")" = '{{ .chezmoi.homeDir }}/.claude/commands' ]
}

@test "claude statusline script exists" {
  [ -f "${HOME_DIR}/dot_claude/executable_statusline.sh" ]
}

@test "ecc hook launcher script exists" {
  [ -f "${HOME_DIR}/dot_claude/executable_ecc-hook.sh" ]
}

@test "settings.json blanks the commit/PR attribution byline" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Empty `commit`/`pr` strings hide Claude Code's own "Generated with…" line and the
  # Co-Authored-By trailer. Both must stay empty strings, not null/absent: an absent
  # `attribution` falls back to the default byline. The older `includeCoAuthoredBy` key is
  # DEPRECATED in the Claude Code settings schema ("Use 'attribution' instead") and takes
  # effect only when `attribution` is absent, so asserting on `attribution` alone pins the
  # key that is actually load-bearing.
  # Scope note: this covers the byline, and only the byline. It is not a claim that every
  # attribution channel is closed. `attribution.sessionUrl` is deliberately left at its
  # default (true), so web/Remote Control sessions still append a Claude-Session trailer —
  # that is wanted, not an oversight, and is why this test does not assert on it. Anything
  # else reading this file (a third-party wrapper, say) may honour different keys entirely.
  jq -e '.attribution.commit == "" and .attribution.pr == ""' "$s" >/dev/null
}

@test "settings.json wires the CLV2 observer as direct observe.sh hooks (pre + post)" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Structural assertion (not a substring grep): exactly one pre + one post observe entry,
  # each matcher "*", a command-type hook, async, timeout 10, invoking observe.sh directly
  # with the right phase — and NOT observe-runner.js (which can't resolve observe.sh under
  # this layout and would silently no-op).
  jq -e '
    [.hooks.PreToolUse[] | select(.id=="pre:observe:continuous-learning")] as $m
    | ($m|length)==1
      and $m[0].matcher=="*"
      and $m[0].hooks[0].type=="command"
      and $m[0].hooks[0].async==true
      and $m[0].hooks[0].timeout==10
      and ($m[0].hooks[0].command|endswith("/continuous-learning-v2/hooks/observe.sh pre"))
      and ($m[0].hooks[0].command|contains("observe-runner")|not)
  ' "$s" >/dev/null
  jq -e '
    [.hooks.PostToolUse[] | select(.id=="post:observe:continuous-learning")] as $m
    | ($m|length)==1
      and $m[0].matcher=="*"
      and $m[0].hooks[0].type=="command"
      and $m[0].hooks[0].async==true
      and $m[0].hooks[0].timeout==10
      and ($m[0].hooks[0].command|endswith("/continuous-learning-v2/hooks/observe.sh post"))
      and ($m[0].hooks[0].command|contains("observe-runner")|not)
  ' "$s" >/dev/null
}

@test "settings.json ECC_DISABLED_HOOKS is the effective SSOT for disabling gateguard-fact-force (#280)" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # Claude Code applies settings.json's env block with precedence over shell-inherited env
  # vars, so this is the only place that can actually disable the gate; it must carry the
  # gateguard-fact-force id alongside the three pre-existing post:bash:* ids (none dropped).
  jq -e '
    (.env.ECC_DISABLED_HOOKS | split(",")) as $ids
    | ($ids | index("pre:edit-write:gateguard-fact-force")) != null
      and ($ids | index("post:bash:command-log-audit")) != null
      and ($ids | index("post:bash:command-log-cost")) != null
      and ($ids | index("post:bash:build-complete")) != null
  ' "$s" >/dev/null
}

@test "settings.json pins the session effort level" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # The model pin is covered by docs_facts (it is cross-checked against the FACT marker),
  # but effortLevel has no doc counterpart — without this it could vanish unnoticed and
  # every session would silently drop to the default effort.
  local effort
  effort="$(jq -r '.effortLevel' "$s")"
  [ "$effort" = "xhigh" ] || {
    echo "settings.json .effortLevel is '${effort}' but the declared session default is xhigh"
    false
  }
}

@test "settings.json declares codex and claude-code-setup as enabled plugins" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # settings.json is the single source of truth for the plugin set:
  # run_onchange_after_17-setup-claude-plugins.sh.tmpl renders its install list from
  # exactly these entries, so dropping one here silently stops installing it.
  jq -e '
    .enabledPlugins["codex@openai-codex"] == true
      and .enabledPlugins["claude-code-setup@claude-plugins-official"] == true
  ' "$s" >/dev/null
}

@test "settings.json: every enabled plugin resolves to a known marketplace (#17 reconciler contract)" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # The reconciler resolves a plugin's "<name>@<marketplace>" suffix to a source it can pass to
  # `claude plugin marketplace add`. It knows exactly two origins: the built-in
  # claude-plugins-official, and whatever extraKnownMarketplaces declares. A plugin whose
  # marketplace is neither would fail at apply time on a fresh machine, so catch it here instead.
  # The `as $known` binding must be parenthesized: jq binds `as` tighter than `+`, so
  # `a + b as $x | c` means `a + (b as $x | c)` and would try to add an array to a boolean.
  jq -e '
    (((.extraKnownMarketplaces | keys) + ["claude-plugins-official"]) as $known
      | .enabledPlugins
      | keys
      | map(sub("^.*@"; ""))
      | all(IN($known[])))
  ' "$s" >/dev/null
}

@test "settings.json: extraKnownMarketplaces entries carry a source the reconciler can resolve" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # The reconciler resolves only the `github` (repo) and `git` (url) source types of the seven the
  # settings schema allows; the rest (url, hostPattern, npm, file, directory) carry a different
  # identifying field and would make `marketplace add` fail at apply time.
  jq -e '
    .extraKnownMarketplaces
    | all(.[]; .source
      | if .source == "github" then (.repo | length) > 0
        elif .source == "git" then (.url | length) > 0
        else false end)
  ' "$s" >/dev/null
}

@test "settings.json: every extraKnownMarketplaces entry is pinned to a ref" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  # A marketplace is executable code installed unattended by `chezmoi apply`, so it must not track a
  # moving default branch. Only branches and tags work: `#<commit-sha>` reaches `git clone --branch`
  # and fails, so the pin is necessarily a tag rather than a commit.
  jq -e '.extraKnownMarketplaces | all(.[]; (.source.ref | length) > 0)' "$s" >/dev/null
}

@test "chezmoi source files exist: claude plugin reconciler script" {
  [ -f "${HOME_DIR}/run_onchange_after_17-setup-claude-plugins.sh.tmpl" ]
}

# Drive the rendered reconciler against a throwaway HOME with fake `mise`/`claude` on PATH. The fake
# claude reproduces the two behaviours the script exists to handle: it rewrites settings.json with its
# own serializer (dropping the hook `id` annotations), and it replaces the work account's settings.json
# symlink with a regular file via an atomic rename.
_reconciler_sandbox() {
  local sandbox="$1"
  mkdir -p "${sandbox}/home/.claude" "${sandbox}/home/.claude-r06" "${sandbox}/bin"
  cp "${HOME_DIR}/dot_claude/settings.json" "${sandbox}/home/.claude/settings.json"
  ln -sfn "${sandbox}/home/.claude/settings.json" "${sandbox}/home/.claude-r06/settings.json"

  cat >"${sandbox}/bin/mise" <<'FAKE_MISE'
#!/usr/bin/env bash
[ "${1:-}" = "exec" ] && shift
[ "${1:-}" = "--" ] && shift
exec "$@"
FAKE_MISE

  cat >"${sandbox}/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail
cfg="${CLAUDE_CONFIG_DIR:?}"
log="${FAKE_CLAUDE_LOG:?}"
case "${1:-} ${2:-}" in
  "plugin list")
    # Exits non-zero before the runtime exists, exactly like the real CLI.
    [ -f "${cfg}/plugins/installed.json" ] || exit 1
    cat "${cfg}/plugins/installed.json"
    ;;
  "plugin marketplace")
    sub="$3"
    mkdir -p "${cfg}/plugins"
    [ -f "${cfg}/plugins/known_marketplaces.json" ] || echo '{}' >"${cfg}/plugins/known_marketplaces.json"
    case "$sub" in
      add)
        src="$4"
        # FAKE_CLAUDE_ADD_FAILS=<ref> fails `marketplace add` for that specific ref, reproducing a
        # re-register whose clone fails. It exits before writing, so the previous registration stays intact.
        if [ -n "${FAKE_CLAUDE_ADD_FAILS:-}" ] && [ "${src#*#}" = "${FAKE_CLAUDE_ADD_FAILS}" ]; then
          echo "boom-add ${src}" >&2
          exit 1
        fi
        echo "marketplace-add ${cfg##*/} ${src}" >>"$log"
        repo="${src%%#*}"
        case "$repo" in
          anthropics/claude-plugins-official) key=claude-plugins-official ;;
          openai/codex-plugin-cc) key=openai-codex ;;
          NoritakaIkeda/chatshelf) key=chatshelf ;;
          *) echo "unknown marketplace source: $src" >&2; exit 1 ;;
        esac
        ref=""
        [ "$src" != "$repo" ] && ref="${src#*#}"
        # FAKE_CLAUDE_IGNORES_REF drops the stored ref to reproduce the CLI ignoring a ref on a path the
        # reconciler must post-verify and warn about.
        [ "${FAKE_CLAUDE_IGNORES_REF:-0}" = "1" ] && ref=""
        # Mirror the real known_marketplaces.json shape (.<name>.source.{repo,ref}) so a later run can
        # detect that the registration lags a bumped pin.
        jq --arg k "$key" --arg repo "$repo" --arg ref "$ref" \
          '.[$k] = {source: ({source: "github", repo: $repo} + (if $ref == "" then {} else {ref: $ref} end))}' \
          "${cfg}/plugins/known_marketplaces.json" >"${cfg}/plugins/km.tmp"
        mv "${cfg}/plugins/km.tmp" "${cfg}/plugins/known_marketplaces.json"
        ;;
      # No `remove | rm` handler on purpose: the reconciler must never call `marketplace remove` (it
      # cascade-uninstalls the plugin). The catch-all below fails the test if a regression reintroduces it.
      *) echo "unexpected fake marketplace subcommand: $*" >&2; exit 1 ;;
    esac
    ;;
  "plugin install")
    id="$3"
    [ "${FAKE_CLAUDE_INSTALL_FAILS:-0}" = "1" ] && { echo "boom" >&2; exit 1; }
    echo "install ${cfg##*/} ${id}" >>"$log"
    mkdir -p "${cfg}/plugins"
    [ -f "${cfg}/plugins/installed.json" ] || echo '[]' >"${cfg}/plugins/installed.json"
    jq --arg i "$id" '. + [{id: $i, scope: "user"}]' "${cfg}/plugins/installed.json" >"${cfg}/plugins/inst.tmp"
    mv "${cfg}/plugins/inst.tmp" "${cfg}/plugins/installed.json"
    # Reproduce the CLI's settings.json rewrite: drop the hook annotations, and replace the file (an
    # atomic rename, which clobbers the work account's symlink).
    jq 'del(.hooks.SessionStart[0].id, .hooks.SessionStart[0].description)' "${cfg}/settings.json" >"${cfg}/settings.tmp"
    mv "${cfg}/settings.tmp" "${cfg}/settings.json"
    ;;
  "plugin update")
    id="$3"
    [ "${FAKE_CLAUDE_UPDATE_FAILS:-0}" = "1" ] && { echo "boom-update" >&2; exit 1; }
    echo "plugin-update ${cfg##*/} ${id}" >>"$log"
    ;;
  *) echo "unexpected fake claude invocation: $*" >&2; exit 1 ;;
esac
FAKE_CLAUDE
  chmod +x "${sandbox}/bin/mise" "${sandbox}/bin/claude"
  chezmoi execute-template --source "${HOME_DIR}" \
    <"${HOME_DIR}/run_onchange_after_17-setup-claude-plugins.sh.tmpl" >"${sandbox}/reconcile.sh"
}

@test "claude plugin reconciler: installs per account, passes the pinned ref, restores settings.json" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  [ "$status" -eq 0 ]

  # The declared ref must reach the CLI: declaring it in settings.json alone does not pin anything.
  grep -qF 'marketplace-add .claude openai/codex-plugin-cc#v1.0.6' "${sandbox}/calls.log"
  grep -qF 'marketplace-add .claude-r06 openai/codex-plugin-cc#v1.0.6' "${sandbox}/calls.log"
  grep -qF 'marketplace-add .claude anthropics/claude-plugins-official' "${sandbox}/calls.log"
  # chatshelf is registered at its own pinned tag (a distinct marketplace + ref from openai-codex).
  grep -qF 'marketplace-add .claude NoritakaIkeda/chatshelf#v0.1.0' "${sandbox}/calls.log"
  grep -qF 'marketplace-add .claude-r06 NoritakaIkeda/chatshelf#v0.1.0' "${sandbox}/calls.log"

  # All three plugins land in both accounts.
  [ "$(grep -c '^install .claude ' "${sandbox}/calls.log")" -eq 3 ]
  [ "$(grep -c '^install .claude-r06 ' "${sandbox}/calls.log")" -eq 3 ]

  # The hook annotations the fake CLI stripped are back, and the work account's symlink was repaired.
  jq -e '.hooks.SessionStart[0] | has("id") and has("description")' "${sandbox}/home/.claude/settings.json"
  [ -L "${sandbox}/home/.claude-r06/settings.json" ]

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a second run is a no-op" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  : >"${sandbox}/calls.log"
  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  [ "$status" -eq 0 ]
  # Nothing to add, nothing to install.
  [ ! -s "${sandbox}/calls.log" ]

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a failed install exits non-zero so chezmoi retries" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" FAKE_CLAUDE_INSTALL_FAILS=1 bash "${sandbox}/reconcile.sh"
  [ "$status" -ne 0 ]
  # A partially-reconciled run must still leave settings.json as chezmoi wrote it.
  jq -e '.hooks.SessionStart[0] | has("id")' "${sandbox}/home/.claude/settings.json"

  rm -rf "$sandbox"
}

# Simulate a pin bump by rendering the reconciler once, then advancing the embedded ref. The ref string
# (v1.0.6) appears only as the pinned ref in the embedded declaration, so a global sed replace is safe;
# settings.json is the only place the ref lives, and the rendered script embeds the declaration verbatim.
@test "claude plugin reconciler: a pin bump re-registers the marketplace and updates the plugin in both accounts" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  sed 's/v1\.0\.6/v1.0.7/g' "${sandbox}/reconcile.sh" >"${sandbox}/reconcile-bumped.sh"
  : >"${sandbox}/calls.log"

  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile-bumped.sh"
  [ "$status" -eq 0 ]

  # The marketplace is re-registered in place (a plain `marketplace add`, no rm) at the bumped ref and
  # the plugin updated -- in both accounts.
  grep -qF 'marketplace-add .claude openai/codex-plugin-cc#v1.0.7' "${sandbox}/calls.log"
  grep -qF 'plugin-update .claude codex@openai-codex' "${sandbox}/calls.log"
  grep -qF 'marketplace-add .claude-r06 openai/codex-plugin-cc#v1.0.7' "${sandbox}/calls.log"
  grep -qF 'plugin-update .claude-r06 codex@openai-codex' "${sandbox}/calls.log"
  # `marketplace remove` must never be used -- it cascade-uninstalls the plugin (claude 2.1.220).
  ! grep -qF 'marketplace-remove' "${sandbox}/calls.log"
  # The unpinned official plugin has no ref, so it never drifts and is left untouched.
  ! grep -qF 'claude-code-setup' "${sandbox}/calls.log"
  # The "restart required to apply" notice is surfaced.
  echo "$output" | grep -qi 'restart Claude Code'

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a ref the CLI ignores warns but does not fail the run" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  sed 's/v1\.0\.6/v1.0.7/g' "${sandbox}/reconcile.sh" >"${sandbox}/reconcile-bumped.sh"
  : >"${sandbox}/calls.log"

  # FAKE_CLAUDE_IGNORES_REF makes `marketplace add` drop the ref, so post-verify still sees a lag.
  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" FAKE_CLAUDE_IGNORES_REF=1 bash "${sandbox}/reconcile-bumped.sh"
  # Warn -- neither an endless-retry exit 1 nor a silent success.
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'did not converge'

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a failed plugin update warns but does not fail the run" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  sed 's/v1\.0\.6/v1.0.7/g' "${sandbox}/reconcile.sh" >"${sandbox}/reconcile-bumped.sh"
  : >"${sandbox}/calls.log"

  # A convergence-step failure is best-effort: warn, but do not fail the apply (unlike the fresh-install
  # path, which stays fatal so chezmoi retries).
  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" FAKE_CLAUDE_UPDATE_FAILS=1 bash "${sandbox}/reconcile-bumped.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'failed to update plugin'

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a failed re-register leaves the previous registration intact and does not fail the run" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  sed 's/v1\.0\.6/v1.0.7/g' "${sandbox}/reconcile.sh" >"${sandbox}/reconcile-bumped.sh"
  : >"${sandbox}/calls.log"

  # The plain `marketplace add` for the bumped ref fails (no rm precedes it), so the previous registration
  # is untouched and the plugin stays at its old version. Warn without failing the apply (a non-zero exit
  # would only make chezmoi retry a ref the CLI has already refused).
  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" FAKE_CLAUDE_ADD_FAILS=v1.0.7 bash "${sandbox}/reconcile-bumped.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'previous registration is left intact'
  # The previous ref is preserved (not orphaned) in both accounts, and no rm was attempted.
  jq -e '.["openai-codex"].source.ref == "v1.0.6"' "${sandbox}/home/.claude/plugins/known_marketplaces.json"
  jq -e '.["openai-codex"].source.ref == "v1.0.6"' "${sandbox}/home/.claude-r06/plugins/known_marketplaces.json"
  ! grep -qF 'marketplace-remove' "${sandbox}/calls.log"

  rm -rf "$sandbox"
}

@test "claude plugin reconciler: a lost registration with the plugin still installed re-registers and updates it" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local sandbox
  sandbox="$(mktemp -d)"
  _reconciler_sandbox "$sandbox"

  # Fresh apply: marketplace registered, plugin installed.
  env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  # Drop the marketplace registration (e.g. a manual `marketplace rm`) while the plugin stays installed --
  # the state the fresh path must recover from without leaving the installed plugin stale.
  for acct in .claude .claude-r06; do
    jq 'del(."openai-codex")' "${sandbox}/home/${acct}/plugins/known_marketplaces.json" >"${sandbox}/km.tmp"
    mv "${sandbox}/km.tmp" "${sandbox}/home/${acct}/plugins/known_marketplaces.json"
  done
  : >"${sandbox}/calls.log"

  run env HOME="${sandbox}/home" PATH="${sandbox}/bin:${PATH}" \
    FAKE_CLAUDE_LOG="${sandbox}/calls.log" bash "${sandbox}/reconcile.sh"
  [ "$status" -eq 0 ]
  # The marketplace is re-added AND the already-installed plugin is updated (not silently left stale).
  grep -qF 'marketplace-add .claude openai/codex-plugin-cc#v1.0.6' "${sandbox}/calls.log"
  grep -qF 'plugin-update .claude codex@openai-codex' "${sandbox}/calls.log"
  grep -qF 'plugin-update .claude-r06 codex@openai-codex' "${sandbox}/calls.log"

  rm -rf "$sandbox"
}

@test "clv2 observer enable script is present and idempotently forces observer.enabled" {
  local script="${HOME_DIR}/run_onchange_after_14-enable-clv2-observer.sh.tmpl"
  [ -f "$script" ]
  bash -n "$script"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d)
  # Pin XDG_DATA_HOME inside the sandbox so the bare-`claude` fallback branch can never
  # touch the developer's real ~/.local/share/ecc-homunculus.
  local run=(env "HOME=$tmp" "XDG_DATA_HOME=$tmp/.local/share" bash "$script")
  # The account config dir still selects WHICH accounts are in use, but the state it enables
  # now lives at ~/.local/share/ecc-homunculus-<slug>, outside that config dir (#336).
  # Seed a pre-existing config (disabled + unrelated keys) to exercise the jq-merge branch:
  # it must force enabled=true while preserving every other field, and stay stable on re-run.
  mkdir -p "$tmp/.claude" "$tmp/.local/share/ecc-homunculus-default"
  printf '%s' '{"version":"2.1","observer":{"enabled":false,"run_interval_minutes":7},"custom":42}' \
    > "$tmp/.local/share/ecc-homunculus-default/config.json"
  "${run[@]}" >/dev/null 2>&1
  "${run[@]}" >/dev/null 2>&1
  local cfg="$tmp/.local/share/ecc-homunculus-default/config.json"
  [ "$(jq -r '.observer.enabled' "$cfg")" = "true" ]
  [ "$(jq -r '.observer.run_interval_minutes' "$cfg")" = "7" ]
  [ "$(jq -r '.custom' "$cfg")" = "42" ]
  # Nothing is created under the Claude config dir: a headless observer can never get a write
  # there approved, which is exactly what kept instinct generation dead (#336).
  [ ! -e "$tmp/.claude/ecc-homunculus" ]
  # The state dir stays private. observations.jsonl records tool input/output, and it now lives
  # in the shared ~/.local/share tree rather than under the config dir.
  local mode
  mode=$(_file_mode "$tmp/.local/share/ecc-homunculus-default")
  [ "$mode" = "700" ]
  # Fresh-write branch: an account dir with no prior config gets a fully-formed enabled config.
  mkdir -p "$tmp/.claude-r06"
  "${run[@]}" >/dev/null 2>&1
  [ "$(jq -r '.observer.enabled' "$tmp/.local/share/ecc-homunculus-r06/config.json")" = "true" ]
  [ ! -e "$tmp/.claude-r06/ecc-homunculus" ]
  # Bare-`claude` fallback: a distinct, unsuffixed dir — not created speculatively, but enabled
  # once it exists, and never conflated with either account's dir.
  [ ! -e "$tmp/.local/share/ecc-homunculus/config.json" ]
  mkdir -p "$tmp/.local/share/ecc-homunculus"
  "${run[@]}" >/dev/null 2>&1
  [ "$(jq -r '.observer.enabled' "$tmp/.local/share/ecc-homunculus/config.json")" = "true" ]
  rm -rf "$tmp"
}

@test "ecc governance-capture fork exists and passes node syntax check" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  [ -f "$fork" ]
  node --check "$fork"
}

# Regression guard: a bare process.exit() after stdout.write() truncates output
# larger than the OS pipe buffer (~64 KB), which would corrupt PostToolUse
# pass-through of large tool_response payloads. The fork must pass input through
# byte-for-byte regardless of size. No ECC runtime needed (a benign tool yields
# zero events, so the hook only passes stdin through).
@test "ecc governance-capture fork passes large input through without truncation" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  local tmp; tmp=$(mktemp -d)
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/x"},tool_response:"A".repeat(200000)}))' > "$tmp/in.json"
  local in_bytes out_bytes
  in_bytes=$(wc -c < "$tmp/in.json")
  out_bytes=$(ECC_GOVERNANCE_CAPTURE=1 ECC_AGENT_DATA_HOME="$tmp" node "$fork" < "$tmp/in.json" 2>/dev/null | wc -c)
  rm -rf "$tmp"
  [ "$in_bytes" -gt 65536 ]
  [ "$in_bytes" -eq "$out_bytes" ]
}

# Functional smoke: with the ECC runtime present and node:sqlite available, a
# governance-relevant tool call must persist a row to the per-account state.db.
# Skips in minimal CI (no ECC external / older Node without node:sqlite).
@test "ecc governance-capture fork persists an event to state.db" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/governance-capture.js"
  local ecc="${HOME}/.agents/skills/ecc/scripts/hooks/governance-capture.js"
  [ -f "$ecc" ] || skip "ECC external runtime not deployed"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main --force"},"session_id":"bats-gov"}' \
    | CLAUDE_PLUGIN_ROOT="${HOME}/.agents/skills/ecc" ECC_GOVERNANCE_CAPTURE=1 ECC_AGENT_DATA_HOME="$tmp" node "$fork" >/dev/null 2>&1
  local count
  count=$(node -e 'const{DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});process.stdout.write(String(db.prepare("SELECT count(*) c, session_id s FROM governance_events").get().c));db.close()' "$tmp/ecc/state.db" 2>/dev/null)
  rm -rf "$tmp"
  [ "$count" -ge 1 ]
}

@test "ecc post-bash-command-log fork exists and passes node syntax check" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  [ -f "$fork" ]
  node --check "$fork"
}

@test "ecc-state-reader aggregates pending governance events from a sandbox state.db" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  [ -f "$reader" ]
  node --check "$reader"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/ecc"
  # Seed 2 pending + 1 resolved event; the reader must count only the 2 pending ones.
  node -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});
    db.exec("CREATE TABLE governance_events(id TEXT PRIMARY KEY, session_id TEXT, event_type TEXT NOT NULL, payload TEXT NOT NULL, resolved_at TEXT, resolution TEXT, created_at TEXT NOT NULL)");
    const ins=db.prepare("INSERT INTO governance_events(id,session_id,event_type,payload,resolved_at,created_at) VALUES(?,?,?,?,?,?)");
    ins.run("1","s","approval_requested","{}",null,"2026-01-01T01:00:00Z");
    ins.run("2","s","secret_detected","{}",null,"2026-01-01T02:00:00Z");
    ins.run("3","s","approval_requested","{}","2026-01-01T03:00:00Z","2026-01-01T00:30:00Z");
    db.close();
  ' "$tmp/ecc/state.db"
  local out
  out=$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" status --json)
  [ "$(echo "$out" | jq -r '.pendingGovernanceEvents')" = "2" ]
  [ "$(echo "$out" | jq -r '[.governanceByType[].c] | add')" = "2" ]
  # sessions / work-items tables are absent in this sandbox → graceful empty, never a crash.
  [ "$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" sessions)" = "No sessions recorded." ]
  [ "$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" work-items)" = "No work items." ]
  rm -rf "$tmp"
}

@test "ecc-state-reader is graceful when state.db is absent and creates nothing" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  run env "ECC_AGENT_DATA_HOME=$tmp" node "$reader" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No state.db"* ]]
  # A read-only CLI must never materialize a database on a fresh account.
  [ ! -e "$tmp/ecc/state.db" ]
  rm -rf "$tmp"
}

@test "ecc-state-reader counts only non-closed work items (ECC status domain)" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local tmp; tmp=$(mktemp -d); mkdir -p "$tmp/ecc"
  # Only "open" is non-closed; resolved/merged/done/cancelled are all closed in ECC's domain.
  node -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1],{enableForeignKeyConstraints:false});
    db.exec("CREATE TABLE work_items(id TEXT PRIMARY KEY, source TEXT NOT NULL, source_id TEXT, title TEXT NOT NULL, status TEXT NOT NULL, priority TEXT, url TEXT, owner TEXT, repo_root TEXT, session_id TEXT, metadata TEXT, created_at TEXT, updated_at TEXT NOT NULL)");
    const ins=db.prepare("INSERT INTO work_items(id,source,title,status,updated_at) VALUES(?,?,?,?,?)");
    for (const [id,st] of [["w1","open"],["w2","resolved"],["w3","merged"],["w4","done"],["w5","cancelled"]]) ins.run(id,"gh",id,st,"2026-01-01");
    db.close();
  ' "$tmp/ecc/state.db"
  local out; out=$(ECC_AGENT_DATA_HOME="$tmp" node "$reader" status --json)
  [ "$(echo "$out" | jq -r '.openWorkItems')" = "1" ]
  rm -rf "$tmp"
}

@test "ecc-state-reader rejects an unknown subcommand with exit 2 even on a fresh account" {
  local reader="${HOME_DIR}/dot_claude/hooks-fork/ecc-state-reader.js"
  node -e 'require("node:sqlite")' 2>/dev/null || skip "node:sqlite unavailable"
  local tmp; tmp=$(mktemp -d)
  # No state.db: validation must still fire before the graceful "no db" path.
  run env "ECC_AGENT_DATA_HOME=$tmp" node "$reader" bogus-subcommand
  [ "$status" -eq 2 ]
  rm -rf "$tmp"
}

@test "claude.zsh defines the ecc-* reader functions" {
  grep -q 'ecc-status()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-sessions()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-work-items()' "${HOME_DIR}/dot_config/zsh/claude.zsh"
  grep -q 'ecc-state-reader.js' "${HOME_DIR}/dot_config/zsh/claude.zsh"
}

# Regression guard: a bare process.exit() after stdout.write() truncates output
# larger than the OS pipe buffer (~64 KB). The fork must pass the PostToolUse Bash
# payload through byte-for-byte regardless of size. No ECC runtime needed (logging
# is best-effort; the pass-through is unconditional).
@test "ecc post-bash-command-log fork passes large input through without truncation" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  local tmp; tmp=$(mktemp -d)
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"echo "+"A".repeat(200000)}}))' > "$tmp/in.json"
  ECC_AGENT_DATA_HOME="$tmp" node "$fork" audit < "$tmp/in.json" > "$tmp/out.json" 2>/dev/null
  local in_bytes; in_bytes=$(wc -c < "$tmp/in.json")
  # Byte-exact pass-through: input exceeds the OS pipe buffer AND output is identical
  # (cmp catches reordering/corruption that an equal byte count would miss).
  run cmp "$tmp/in.json" "$tmp/out.json"
  local cmp_status=$status
  rm -rf "$tmp"
  [ "$in_bytes" -gt 65536 ]
  [ "$cmp_status" -eq 0 ]
}

# Functional smoke: with the ECC runtime present, the fork appends a sanitized, 0600
# line to the per-account bash-commands.log resolved via getClaudeDir()
# (ECC_AGENT_DATA_HOME), proving account isolation (task #11) — not the hardcoded
# ~/.claude of the ECC original — and that extraRedact() strips a secret ECC's own
# sanitizer misses. Assertions are split so a failure pinpoints which guarantee broke.
# Skips in minimal CI (no ECC external deployed).
@test "ecc post-bash-command-log fork appends a redacted 0600 line to the per-account log" {
  local fork="${HOME_DIR}/dot_claude/hooks-fork/post-bash-command-log.js"
  local ecc="${HOME}/.agents/skills/ecc/scripts/hooks/post-bash-command-log.js"
  [ -f "$ecc" ] || skip "ECC external runtime not deployed"
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/bash-commands.log"
  # AWS_SECRET_ACCESS_KEY=... is a secret shape ECC's sanitizeCommand does not catch;
  # extraRedact() must strip it before the line is written.
  printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"AWS_SECRET_ACCESS_KEY=abcdEFGH1234 aws s3 ls"}}' \
    | CLAUDE_PLUGIN_ROOT="${HOME}/.agents/skills/ecc" ECC_AGENT_DATA_HOME="$tmp" node "$fork" audit >/dev/null 2>&1
  local file_exists=0 has_cmd=0 secret_leaked=0 perms=""
  [ -f "$log" ] && file_exists=1
  grep -q 'aws s3 ls' "$log" 2>/dev/null && has_cmd=1
  grep -q 'abcdEFGH1234' "$log" 2>/dev/null && secret_leaked=1
  perms=$(stat -f '%Lp' "$log" 2>/dev/null || stat -c '%a' "$log" 2>/dev/null)
  rm -rf "$tmp"
  [ "$file_exists" -eq 1 ]   # account-aware log created under ECC_AGENT_DATA_HOME
  [ "$has_cmd" -eq 1 ]       # command recorded
  [ "$secret_leaked" -eq 0 ] # extraRedact stripped the secret env value
  [ "$perms" = "600" ]       # owner-only permissions
}

@test "prompt-conform-suggest hook exists and passes node syntax check" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  [ -f "$hook" ]
  node --check "$hook"
}

@test "prompt-conform-suggest triggers on a long JP task-shaped prompt" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='ユーザー認証機能を実装してください。要件は以下の通りです。メールアドレスとパスワードでログインできること。セッションはJWTで管理すること。パスワードはbcryptでハッシュ化すること。ログイン失敗時は適切なエラーメッセージを返すこと。既存のミドルウェアとの統合方法も検討し、テストも一緒に書いてください。ドキュメントの更新も忘れずにお願いします。'
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" | node "$hook")
  [ "$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
  [ -n "$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')" ]
}

@test "prompt-conform-suggest triggers on a long EN task-shaped prompt" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='Please implement a new caching layer for the API responses. It should support TTL-based eviction, be pluggable so we can swap Redis for an in-memory store in tests, and include unit tests covering the eviction edge cases as well as documentation for future maintainers.'
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" | node "$hook")
  [ "$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
}

@test "prompt-conform-suggest triggers on a long prompt matching only the keyword regex (no task verb)" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='新しい SKILL.md の設計について相談したいです。プロンプトエンジニアリングの観点から、既存のエージェント定義との整合性やシステムプロンプトとの重複をどう避けるか、指示文の粒度をどう決めるか、命名規則をどう統一するかなど、検討すべき論点が多くあります。実装方針が固まる前に一度目線を揃えたいです。'
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" | node "$hook")
  [ -n "$out" ]
}

@test "prompt-conform-suggest is silent on a short conversational prompt" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:"ありがとうございます、完璧です"}))' | node "$hook")
  [ -z "$out" ]
}

@test "prompt-conform-suggest is silent on a long prompt with no task/keyword shape" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:"A".repeat(300)}))' | node "$hook")
  [ -z "$out" ]
}

# Regression guard for a false positive found in review: a bare \b(verb)\b match
# anywhere in the string fired on ordinary questions that merely contain a task
# verb mid-sentence, not as an imperative directive.
@test "prompt-conform-suggest is silent on a long EN question that merely contains a task verb" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='How should I write a good commit message for a large refactor that touches many files across the repository and changes the public API surface in several places, while keeping the history readable for future maintainers?'
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" | node "$hook")
  [ -z "$out" ]
}

# Regression guard for a false positive found in review: a standalone politeness
# marker ("お願いします") is not a task-request shape and must not fire on a long
# question that has no imperative verb.
@test "prompt-conform-suggest is silent on a long JP question closed with a bare politeness marker" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='先日リリースしたバージョンでユーザーからいくつか問い合わせが来ているのですが、ログを見る限り原因の切り分けが難しく、どこから調査を始めるのが良さそうか、これまでの経験に基づいたアドバイスをいただけると非常に助かります。あくまで一般論としての意見で構いませんので、お忙しいところ大変恐縮ですが、何卒よろしくお願いします。'
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" | node "$hook")
  [ -z "$out" ]
}

@test "prompt-conform-suggest is silent when the prompt field is missing" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit"}))' | node "$hook")
  [ -z "$out" ]
}

@test "prompt-conform-suggest fails open on malformed stdin JSON and logs to stderr" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  run --separate-stderr bash -c "printf 'not json' | node \"$hook\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"failed to parse stdin"* ]]
}

@test "prompt-conform-suggest honours a PROMPT_CONFORM_SUGGEST_MIN_LENGTH override" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:"直してください"}))' \
    | PROMPT_CONFORM_SUGGEST_MIN_LENGTH=5 node "$hook")
  [ -n "$out" ]
}

@test "prompt-conform-suggest falls back to the default min length on a non-integer override" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local out err
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:"skill"}))' \
    | PROMPT_CONFORM_SUGGEST_MIN_LENGTH=0.5 node "$hook" 2>"${BATS_TEST_TMPDIR}/stderr.log")
  err=$(cat "${BATS_TEST_TMPDIR}/stderr.log")
  [ -z "$out" ]
  [[ "$err" == *"ignoring invalid PROMPT_CONFORM_SUGGEST_MIN_LENGTH"* ]]
}

@test "prompt-conform-suggest falls back to the built-in task regex on an invalid override" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  local prompt='ユーザー認証機能を実装してください。要件は以下の通りです。メールアドレスとパスワードでログインできること。セッションはJWTで管理すること。パスワードはbcryptでハッシュ化すること。ログイン失敗時は適切なエラーメッセージを返すこと。既存のミドルウェアとの統合方法も検討し、テストも一緒に書いてください。ドキュメントの更新も忘れずにお願いします。'
  local out err
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" \
    | PROMPT_CONFORM_SUGGEST_TASK_REGEX='(' node "$hook" 2>"${BATS_TEST_TMPDIR}/stderr.log")
  err=$(cat "${BATS_TEST_TMPDIR}/stderr.log")
  [ -n "$out" ]
  [[ "$err" == *"ignoring invalid PROMPT_CONFORM_SUGGEST_TASK_REGEX regex"* ]]
}

@test "prompt-conform-suggest applies a valid PROMPT_CONFORM_SUGGEST_TASK_REGEX override" {
  local hook="${HOME_DIR}/dot_claude/hooks-fork/prompt-conform-suggest.js"
  # "hogehoge" matches neither the default task nor keyword regex, so this proves
  # the override — not the built-in default — is what triggers the match.
  local prompt="hogehoge $(printf 'x%.0s' {1..150})"
  local out
  out=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt:process.argv[1]}))' "$prompt" \
    | PROMPT_CONFORM_SUGGEST_TASK_REGEX='hogehoge' node "$hook")
  [ -n "$out" ]
}

@test "settings.json wires the prompt-conform-suggest UserPromptSubmit hook" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local settings="${HOME_DIR}/dot_claude/settings.json"
  local hook
  hook=$(jq -r '.hooks.UserPromptSubmit[]? | select(.id == "user-prompt-submit:prompt-conform-suggest")' "$settings")
  [ -n "$hook" ]
  # UserPromptSubmit does not support `matcher` (silently ignored per the
  # official Hooks reference), so this entry intentionally omits it.
  [ "$(echo "$hook" | jq -r '.matcher')" = "null" ]
  [ "$(echo "$hook" | jq -r '.hooks[0].command')" = 'node "$HOME/.claude/hooks-fork/prompt-conform-suggest.js"' ]
  [ "$(echo "$hook" | jq -r '.hooks[0].timeout')" -eq 5 ]
  [[ "$(echo "$hook" | jq -r '.description')" == *"PROMPT_CONFORM_SUGGEST_MIN_LENGTH"* ]]
}

@test "1password-backed secret template exists" {
  [ -f "${HOME_DIR}/private_dot_aws/config.tmpl" ]
}

@test "1password validation script exists" {
  [ -f "${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl" ]
}

@test "mise config exists" {
  [ -f "${HOME_DIR}/dot_config/mise/config.toml" ]
}

@test "mise setup script exists" {
  [ -f "${HOME_DIR}/run_onchange_after_12-setup-mise.sh.tmpl" ]
}

@test "dmux provisioning is retired (guard against reintroduction)" {
  # dmux was removed entirely (PR #229); none of its source artefacts may come back.
  [ ! -e "${HOME_DIR}/dot_config/dmux" ]
  [ ! -e "${HOME_DIR}/dot_config/zsh/dmux.zsh" ]
  [ ! -e "${HOME_DIR}/dot_config/zsh/private_dmux-secrets.zsh.tmpl" ]
  # Same fail-open trap the happy guard below documents: grep exits 2 on a missing file, so
  # assert existence first and require exactly 1 rather than merely non-zero.
  [ -f "${HOME_DIR}/dot_config/mise/config.toml" ]
  [ -f "${HOME_DIR}/dot_config/sheldon/plugins.toml" ]
  run grep -Ei 'dmux' "${HOME_DIR}/dot_config/mise/config.toml"
  [ "$status" -eq 1 ]
  run grep -Ei 'dmux' "${HOME_DIR}/dot_config/sheldon/plugins.toml"
  [ "$status" -eq 1 ]
  # Deployed leftovers must stay declared for cleanup on every machine.
  grep -qFx '.config/dmux' "${HOME_DIR}/.chezmoiremove"
  grep -qFx '.agents/skills/dmux-workflows' "${HOME_DIR}/.chezmoiremove"
  grep -qFx '.dmux-r06' "${HOME_DIR}/.chezmoiremove"
}

@test "happy provisioning is retired (guard against reintroduction)" {
  # happy (slopus/happy) was removed entirely (#331). Unlike dmux, it never owned files of
  # its own — it lived as lines inside shared ones — so this guards the host files instead
  # of asserting that paths are absent.
  local cz="${HOME_DIR}/dot_config/zsh/claude.zsh"
  local cx="${HOME_DIR}/dot_config/zsh/codex.zsh"
  local mc="${HOME_DIR}/dot_config/mise/config.toml"
  local st="${HOME_DIR}/dot_claude/settings.json"
  local cr="${HOME_DIR}/.chezmoiremove"
  # grep exits 2 (not 1) when the file is missing, so a bare `status -ne 0` would pass
  # vacuously if any of these were renamed away. Assert existence first, then require
  # exactly 1 (matched nothing) rather than "non-zero".
  local f
  for f in "$cz" "$cx" "$mc" "$st" "$cr"; do [ -f "$f" ]; done

  run grep -Ei 'happy|hcld' "$cz"
  [ "$status" -eq 1 ]
  run grep -Ei 'happy|hcdx' "$cx"
  [ "$status" -eq 1 ]
  # Substring rather than the exact `"npm:happy"` spelling: TOML also accepts literal-string
  # keys ('npm:happy' = ...), which an exact match would wave through. config.toml holds no
  # "happy" substring at all today, so the broader pattern cannot false-positive.
  run grep -Ei 'happy' "$mc"
  [ "$status" -eq 1 ]
  # includeCoAuthoredBy is DEPRECATED in the Claude Code settings schema and survived only
  # because happy-cli read that one key. For Claude Code itself, attribution.commit/.pr now
  # carry the commit/PR byline suppression (asserted by the attribution test above); the
  # third key, sessionUrl, is deliberately left at its default.
  run grep -F 'includeCoAuthoredBy' "$st"
  [ "$status" -eq 1 ]
  # Deliberately the inverse of the dmux guard above: ~/.happy must NOT be declared in
  # .chezmoiremove. Entries there are standing per-apply deletions, and ~/.happy holds phone
  # pairing and E2E key material rather than dmux's regenerable socket dir — a lingering
  # entry would wipe the keys with no warning if happy were ever reinstalled. The manual
  # cleanup procedure that replaces it is recorded in .chezmoiremove itself.
  # Match `.happy`, `.happy/` and `.happy/<subpath>`: an exact-line -Fx would miss the
  # latter two and let a real key-material registration slip past this guard.
  run grep -E '^[[:space:]]*\.happy(/|$)' "$cr"
  [ "$status" -eq 1 ]
}

@test ".chezmoiremove entries never collide with a managed path by case only (#351)" {
  # On macOS's default case-insensitive APFS, a .chezmoiremove entry that
  # differs from a real managed path only by case (e.g. skill.md vs SKILL.md)
  # resolves to the SAME file: every apply deletes the managed file it just
  # wrote, then the next apply re-detects it as "changed since last written"
  # and never converges (#351, github-projects/skill.md vs SKILL.md). Cross-
  # check every entry against `chezmoi managed` to guard against reintroducing
  # this class of bug.
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi unavailable"
  local remove_file="${HOME_DIR}/.chezmoiremove"
  local managed
  managed="$(chezmoi managed --source "${HOME_DIR}" 2>/dev/null)"
  [ -n "$managed" ]

  local entries=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    entries+=("$line")
  done <"$remove_file"
  [ "${#entries[@]}" -gt 0 ]

  local collisions="" entry lower_entry m lower_m
  for entry in "${entries[@]}"; do
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      [ "$m" = "$entry" ] && continue
      lower_m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
      if [ "$lower_m" = "$lower_entry" ]; then
        collisions+="${entry} <-> ${m}"$'\n'
      fi
    done <<<"$managed"
  done

  [ -z "$collisions" ] || { printf '%s' "$collisions" >&2; false; }
}

@test "mcp setup registers all servers as user scope for every account config dir" {
  local script="${HOME_DIR}/run_onchange_after_13-setup-mcp.sh.tmpl"
  [ -f "$script" ]
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  # Fake mise that emulates `mise exec -- <cmd...>` by logging the wrapped command together
  # with the CLAUDE_CONFIG_DIR it ran under. Lets us assert the script's real behaviour
  # (per-account loop + --scope user) instead of just matching strings in the source.
  cat >"$tmp/bin/mise" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "exec" ] && [ "$2" = "--" ]; then
  shift 2
  printf '%s ::: %s\n' "${CLAUDE_CONFIG_DIR:-NONE}" "$*" >>"$MISE_FAKE_LOG"
fi
exit 0
FAKE
  chmod +x "$tmp/bin/mise"

  run env HOME="$tmp/home" PATH="$tmp/bin:$PATH" MISE_FAKE_LOG="$tmp/log" \
    bash "$script"
  [ "$status" -eq 0 ]

  # Every server is add-json'd with user scope for both account config dirs. The trailing
  # " :::" anchors ".claude" so it does not also match ".claude-r06".
  local d name
  for d in '\.claude' '\.claude-r06'; do
    for name in context7 deepwiki exa firecrawl; do
      grep -qE "/home/${d} ::: claude mcp add-json ${name} .* --scope user" "$tmp/log"
    done
  done

  # exa/firecrawl carry the literal env placeholder (expanded by Claude Code at spawn, never
  # baked here): the ${EXA_API_KEY} / ${FIRECRAWL_API_KEY} text must survive verbatim into the
  # logged add-json invocation.
  grep -qF '"EXA_API_KEY":"${EXA_API_KEY}"' "$tmp/log"
  grep -qF '"FIRECRAWL_API_KEY":"${FIRECRAWL_API_KEY}"' "$tmp/log"

  # The key-bearing servers are version-pinned to shrink the npx supply-chain surface.
  grep -qE 'exa-mcp-server@[0-9]+\.[0-9]+\.[0-9]+' "$tmp/log"
  grep -qE 'firecrawl-mcp@[0-9]+\.[0-9]+\.[0-9]+' "$tmp/log"
}

@test "mcp setup script declares valid JSON server configs" {
  local script="${HOME_DIR}/run_onchange_after_13-setup-mcp.sh.tmpl"
  local json count=0
  # Each server config is a single-quoted JSON literal; ensure every one parses.
  while IFS= read -r json; do
    [ -n "$json" ] || continue
    echo "$json" | jq -e . >/dev/null
    count=$((count + 1))
  done < <(grep -oE "'\{[^']*\}'" "$script" | tr -d "'")
  [ "$count" -ge 4 ]
}

@test "claude MCP secrets are a private 1Password template, never committed in clear" {
  # The keys are rendered from 1Password into a 0600 file; the source must be a private_
  # template that reads via onepasswordRead and must not contain a literal key.
  local tmpl="${HOME_DIR}/dot_config/zsh/private_claude-secrets.zsh.tmpl"
  [ -f "$tmpl" ]
  grep -q 'onepasswordRead' "$tmpl"
  grep -qE 'EXA_API_KEY=.*onepasswordRead' "$tmpl"
  grep -qE 'FIRECRAWL_API_KEY=.*onepasswordRead' "$tmpl"
  # Not exported in the secrets file (scoping is done by the claude wrapper when it sources this).
  ! grep -qE '^export ' "$tmpl"
}

@test "the claude wrapper sources the MCP secrets and scopes them to its own process (#345)" {
  # Secret injection moved out of claude.zsh into the wrapper, so it applies from any shell, not
  # only interactive zsh. The wrapper sources the 0600 file only when the caller has not already
  # decided the key (the ${VAR+x} guard, which lets morning-radar opt out), then exports both keys
  # with :- defaults scoped to its own process.
  local w="${HOME_DIR}/dot_local/launchers/executable_claude"
  grep -qF 'claude-secrets.zsh' "$w"
  grep -qF '${EXA_API_KEY+x}' "$w"
  grep -qF 'export EXA_API_KEY="${EXA_API_KEY:-}"' "$w"
  grep -qF 'export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}"' "$w"
  # claude.zsh must no longer source secrets — the wrapper is the single source of truth.
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  run grep -qE '&& source' "$zsh"
  [ "$status" -ne 0 ]
}

@test "claude.zsh no longer pulls the MCP keys into the shell env (#345)" {
  command -v zsh >/dev/null || skip "zsh not available"
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.config/zsh"
  # Stand in for the 1Password-rendered secrets file (non-exported assignments, single-quoted).
  cat >"$tmp/.config/zsh/claude-secrets.zsh" <<'SECRETS'
EXA_API_KEY='exa-test-key'
FIRECRAWL_API_KEY='fc-test-key'
SECRETS

  # -f: no rc files. Sourcing claude.zsh must NOT read or export the keys — the wrapper (a
  # separate process, exercised in zsh_aliases.bats) is the only place they are ever read now, so
  # they never enter the interactive shell's environment. Isolate from any inherited keys (#269).
  run env -u EXA_API_KEY -u FIRECRAWL_API_KEY zsh -fc "
    export HOME='$tmp'
    source '$zsh'
    printf 'PARENT_EXA=[%s]\n' \"\$(printenv EXA_API_KEY)\"
    printf 'PARENT_FC=[%s]\n' \"\$(printenv FIRECRAWL_API_KEY)\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'PARENT_EXA=[]'
  echo "$output" | grep -qF 'PARENT_FC=[]'
}

@test "claude.zsh does not carry a dead ECC_DISABLED_HOOKS alias-level default (#280)" {
  # settings.json's env block is the effective SSOT for ECC_DISABLED_HOOKS (Claude Code
  # applies it with precedence over shell-inherited env vars), so a "${ECC_DISABLED_HOOKS:-...}"
  # default in claude.zsh or the claude wrapper's env injection would be dead code that never
  # actually takes effect.
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  [ -f "$zsh" ]
  run grep -qF 'ECC_DISABLED_HOOKS="${ECC_DISABLED_HOOKS:-' "$zsh"
  [ "$status" -ne 0 ]
}

@test "ecc-hook.sh merges ECC_DISABLED_HOOKS_EXTRA into ECC_DISABLED_HOOKS for the hook runtime (#281)" {
  # settings.json's env block overrides any shell-exported ECC_DISABLED_HOOKS, so a
  # per-session opt-out needs a variable settings.json does NOT define: the launcher
  # comma-joins a shell-exported ECC_DISABLED_HOOKS_EXTRA into ECC_DISABLED_HOOKS
  # before the ECC runtime (hook-flags.js) resolves it as a single value.
  local launcher="${HOME_DIR}/dot_claude/executable_ecc-hook.sh"
  [ -f "$launcher" ]
  command -v node >/dev/null 2>&1 || skip "node unavailable"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts/hooks"
  # Stub bootstrap that prints the value the ECC runtime would read.
  printf '%s\n' 'process.stdout.write(process.env.ECC_DISABLED_HOOKS || "")' \
    >"$tmp/scripts/hooks/plugin-hook-bootstrap.js"

  # Base + extra: comma-joined union.
  run env CLAUDE_PLUGIN_ROOT="$tmp" ECC_DISABLED_HOOKS="a,b" ECC_DISABLED_HOOKS_EXTRA="c,d" \
    bash "$launcher" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "a,b,c,d" ]

  # Extra only (no base): no leading comma.
  run env -u ECC_DISABLED_HOOKS CLAUDE_PLUGIN_ROOT="$tmp" ECC_DISABLED_HOOKS_EXTRA="c,d" \
    bash "$launcher" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "c,d" ]

  # No extra: base value passes through untouched (pre-#281 behaviour preserved).
  run env -u ECC_DISABLED_HOOKS_EXTRA CLAUDE_PLUGIN_ROOT="$tmp" ECC_DISABLED_HOOKS="a,b" \
    bash "$launcher" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "a,b" ]

  # Bootstrap missing + extra set: fail-open passthrough still wins (no merge attempted).
  local tmp2; tmp2=$(mktemp -d)
  run env CLAUDE_PLUGIN_ROOT="$tmp2" ECC_DISABLED_HOOKS_EXTRA="c,d" \
    bash "$launcher" <<<"passthrough"
  [ "$status" -eq 0 ]
  [ "$output" = "passthrough" ]
  rm -rf "$tmp" "$tmp2"
}

@test "claude-config routes its per-session gate opt-out through ECC_DISABLED_HOOKS_EXTRA (#281)" {
  # A plain ECC_DISABLED_HOOKS= assignment on the alias is dead code (settings.json env
  # wins over shell-inherited values); the alias must use the launcher-merged EXTRA channel.
  local zsh="${HOME_DIR}/dot_config/zsh/claude.zsh"
  [ -f "$zsh" ]
  grep -qF "claude-config='ECC_DISABLED_HOOKS_EXTRA=pre:config-protection,pre:edit-write:gateguard-fact-force " "$zsh"
  # Catch the dead pattern anywhere on the alias line, not just right after the opening
  # quote (e.g. a FOO=1 ECC_DISABLED_HOOKS=... prefix would regress silently otherwise).
  run grep -E "alias claude-config=.*['[:space:]]ECC_DISABLED_HOOKS=" "$zsh"
  [ "$status" -ne 0 ]
}

@test "settings.json leaves ECC_DISABLED_HOOKS_EXTRA undefined so the shell passthrough works (#281)" {
  # The EXTRA channel only works because settings.json's env does NOT define it — a
  # settings.json entry would override the shell export and kill the channel.
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  jq -e '.env | has("ECC_DISABLED_HOOKS_EXTRA") | not' "$s" >/dev/null
}

@test "1Password validation requires the exa and firecrawl API keys" {
  local script="${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
  grep -qF 'op://kryota.dev/Dotfiles - Exa API/credential' "$script"
  grep -qF 'op://kryota.dev/Dotfiles - Firecrawl API/credential' "$script"
}

@test "1Password validation requires the redact-patterns item" {
  local script="${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
  grep -qF 'op://kryota.dev/Dotfiles - Redact Patterns/pattern' "$script"
}

@test "project .mcp.json keeps only project-scoped servers" {
  # context7/deepwiki were moved to user scope (run_onchange_after_13); the repo's own
  # .mcp.json must keep the project-specific spec-workflow but no longer declare them.
  local mcp="${REPO_ROOT}/.mcp.json"
  [ -f "$mcp" ]
  grep -q 'spec-workflow' "$mcp"
  ! grep -q 'context7' "$mcp"
  ! grep -q 'deepwiki' "$mcp"
}

@test "bootstrap script exists" {
  [ -f "${REPO_ROOT}/install/install.sh" ]
}

@test "chezmoi source files exist: VS Code settings.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/settings.json" ]
}

@test "chezmoi source files exist: VS Code keybindings.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/keybindings.json" ]
}

# --- Cross-harness gateguard: Codex PreToolUse Bash gate (task #26) ---

@test "codex cross-harness gateguard script exists and passes node syntax check" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  [ -f "$gate" ]
  node --check "$gate"
}

@test "codex hooks.json registers the gateguard as a PreToolUse Bash hook for both accounts" {
  local shared="${HOME_DIR}/.chezmoitemplates/codex-hooks.json"
  [ -f "$shared" ]
  # Shared template is valid JSON once the homeDir placeholder is filled.
  HOME_RENDER="/home/test" \
    node -e 'const fs=require("fs");let s=fs.readFileSync(process.argv[1],"utf8").replace(/\{\{[^}]*\}\}/g,process.env.HOME_RENDER+"/.config/gateguard/codex-bash-gate.js");const j=JSON.parse(s);const m=j.hooks.PreToolUse[0];if(m.matcher!=="^Bash$")throw new Error("matcher");if(m.hooks[0].type!=="command")throw new Error("type");if(!/codex-bash-gate\.js/.test(m.hooks[0].command))throw new Error("command")' "$shared"
  # Both accounts include the shared template (config.toml itself is unmanaged).
  [ -f "${HOME_DIR}/dot_codex/hooks.json.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/hooks.json.tmpl" ]
  grep -q 'includeTemplate "codex-hooks.json"' "${HOME_DIR}/dot_codex/hooks.json.tmpl"
  grep -q 'includeTemplate "codex-hooks.json"' "${HOME_DIR}/dot_codex-r06/hooks.json.tmpl"
}

# Drive the gate with an ISOLATED HOME (empty BATS_TEST_TMPDIR, no .claude)
# so an empty GATEGUARD_BASH_EXTRA_DESTRUCTIVE does not silently fall back to
# the developer's real ~/.claude/settings.json. Echoes "deny" or "allow".
_gate_decision() {
  local gate="$1" cmd="$2" json
  json=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")
  if printf '%s' "$json" | HOME="$BATS_TEST_TMPDIR" GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null \
      | grep -q '"permissionDecision":"deny"'; then
    echo deny
  else
    echo allow
  fi
}

@test "codex gateguard denies a built-in destructive command (rm -rf)" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  [ "$(_gate_decision "$gate" 'rm -rf build')" = deny ]
}

@test "codex gateguard allows benign commands without false positives" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js" c
  # Each must pass through. A destructive phrase inside quotes, a safe
  # --force-with-lease, and env-assignment prefixes must not trip the gate.
  for c in \
    'ls -la && git status' \
    'git commit -m "drop table notes from the agenda"' \
    'git push --force-with-lease origin main' \
    'git checkout -b feature/x' \
    'env FOO=bar npm run build' \
    'dd --help'; do
    [ "$(_gate_decision "$gate" "$c")" = allow ] || { echo "false positive: $c"; return 1; }
  done
}

# Regression guard for the evasion vectors surfaced by multi-review (cc-code /
# cc-security / codex): wrappers, subshell/brace/process-substitution groups,
# quoted command substitution, sh -c / psql -c bodies, dd arg order, and the
# ECC git-parity gaps. Each MUST be blocked.
@test "codex gateguard resists destructive-command evasion vectors" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js" c
  for c in \
    'dd if=/dev/zero of=/dev/sda' \
    'dd of=/dev/disk1 if=/dev/zero' \
    'env rm -rf /tmp/x' \
    'command rm -rf /tmp/x' \
    'sudo rm -rf /tmp/x' \
    '/bin/rm -rf /tmp/x' \
    '(rm -rf /tmp/x)' \
    '{ rm -rf /tmp/x; }' \
    'cat <(rm -rf /tmp/x)' \
    'echo "$(rm -rf /tmp/x)"' \
    'sh -c "rm -rf /tmp/x"' \
    'bash -c "rm -rf /tmp/x"' \
    'psql -c "drop table users"' \
    'git push --force --force-with-lease origin main' \
    'git push origin +main' \
    'git --git-dir .git reset --hard' \
    'git checkout -- .' \
    'git commit --amend' \
    'git rm -r src/'; do
    [ "$(_gate_decision "$gate" "$c")" = deny ] || { echo "bypass: $c"; return 1; }
  done
}

@test "codex gateguard consumes the task #12 EXTRA regex from the environment" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local out
  # chezmoi destroy is NOT a built-in; only the operator EXTRA set covers it.
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chezmoi destroy"}}' \
    | GATEGUARD_BASH_EXTRA_DESTRUCTIVE='chezmoi\s+destroy\b' node "$gate" 2>/dev/null)
  echo "$out" | grep -q '"permissionDecision":"deny"'
}

# Proves the single-source-of-truth path: with no env override, the gate reads
# GATEGUARD_BASH_EXTRA_DESTRUCTIVE out of ~/.claude/settings.json (task #12 SSOT).
@test "codex gateguard reads the EXTRA regex from settings.json when no env override" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude"
  printf '%s' '{"env":{"GATEGUARD_BASH_EXTRA_DESTRUCTIVE":"chezmoi\\s+destroy\\b"}}' > "$tmp/.claude/settings.json"
  local out
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chezmoi destroy"}}' \
    | HOME="$tmp" GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null)
  rm -rf "$tmp"
  echo "$out" | grep -q '"permissionDecision":"deny"'
}

# Guard against quoted-string false positives: a destructive phrase inside a
# commit message must not trip the gate.
@test "codex gateguard does not false-positive on a destructive phrase inside quotes" {
  local gate="${HOME_DIR}/dot_config/gateguard/executable_codex-bash-gate.js"
  local out
  out=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"drop table notes from the agenda\""}}' \
    | GATEGUARD_BASH_EXTRA_DESTRUCTIVE= node "$gate" 2>/dev/null)
  [ -z "$out" ]
}

@test "chezmoi source files exist: VS Code mcp.json" {
  [ -f "${HOME_DIR}/Library/Application Support/Code/User/mcp.json" ]
}

# --- PR9: secret-scan + AGENTS.md split + house coding-standards ---

@test "AGENTS.md is templated and inlines the house coding-standards" {
  local agents="${HOME_DIR}/AGENTS.md.tmpl"
  [ -f "$agents" ]
  # Old plain path must be gone (renamed via git mv).
  [ ! -f "${HOME_DIR}/AGENTS.md" ]
  grep -q 'includeTemplate "coding-standards.md"' "$agents"
  # Agnostic core keeps provenance; Claude-only sections must have moved out.
  grep -q 'Skill provenance' "$agents"
  ! grep -q 'Mandatory skill usage' "$agents"
  ! grep -q 'memory への記録ポリシー' "$agents"
  # The agnostic core must NOT reference Claude-only hooks or the @-import
  # mechanism — Codex reads this file and has neither.
  ! grep -q 'git-push-reminder' "$agents"
  ! grep -q 'auto-tmux-dev' "$agents"
  ! grep -q '@~/AGENTS.md' "$agents"
}

@test "house coding-standards SSOT exists" {
  local cs="${HOME_DIR}/.chezmoitemplates/coding-standards.md"
  [ -f "$cs" ]
  grep -q 'Coding standards (house)' "$cs"
}

@test "Claude layer CLAUDE.md imports the agnostic core and holds Claude-only rules" {
  local claude="${HOME_DIR}/dot_claude/CLAUDE.md"
  [ -f "$claude" ]
  grep -q '@~/AGENTS.md' "$claude"
  grep -q 'Mandatory skill usage' "$claude"
  grep -q 'memory への記録ポリシー' "$claude"
  # The Claude-only relaxations of the conservative core rules live here.
  grep -q 'git-push-reminder' "$claude"
  grep -q 'auto-tmux-dev' "$claude"
  # The personal-account symlink was replaced by this real file.
  [ ! -f "${HOME_DIR}/dot_claude/symlink_CLAUDE.md.tmpl" ]
}

@test "claude-r06 CLAUDE.md symlink points at the shared Claude layer" {
  grep -q '/.claude/CLAUDE.md' "${HOME_DIR}/dot_claude-r06/symlink_CLAUDE.md.tmpl"
}

@test "codex AGENTS.md symlinks still point at the agnostic core (not the .tmpl source)" {
  # Target must be the deployed ~/AGENTS.md, never the source AGENTS.md.tmpl.
  grep -qE '/AGENTS\.md$' "${HOME_DIR}/dot_codex/symlink_AGENTS.md.tmpl"
  grep -qE '/AGENTS\.md$' "${HOME_DIR}/dot_codex-r06/symlink_AGENTS.md.tmpl"
}

@test "global gitleaks pre-commit hook is wired and well-behaved" {
  grep -q 'hooksPath = ~/.config/git/hooks' "${HOME_DIR}/dot_gitconfig.tmpl"
  local hook="${HOME_DIR}/dot_config/git/hooks/executable_pre-commit"
  [ -f "$hook" ]
  bash -n "$hook"
  grep -q 'gitleaks' "$hook"
  grep -q 'git --staged' "$hook"
  # Prefers a repo-local gitleaks config over the global one.
  grep -q '.gitleaks.toml' "$hook"
  # Chains the repo's own pre-commit so core.hooksPath does not silently drop it,
  # WITHOUT self-recursion: `git rev-parse --git-path hooks/pre-commit` respects
  # core.hooksPath and would resolve back to THIS global hook (infinite loop), so
  # the hook must resolve the default hooks dir via --git-common-dir (ignores
  # core.hooksPath and also works in linked worktrees) and guard self-reference
  # with -ef against ${BASH_SOURCE[0]}.
  ! grep -q 'git-path hooks/pre-commit' "$hook"
  grep -q 'git-common-dir' "$hook"
  grep -q 'BASH_SOURCE' "$hook"
  grep -q -- '-ef' "$hook"
  [ -f "${HOME_DIR}/dot_config/git/private_gitleaks-own.toml.tmpl" ]
  # The global config must not carry a path allowlist (it would blind every repo).
  ! grep -qE '^[[:space:]]*paths[[:space:]]*=' "${HOME_DIR}/dot_config/git/private_gitleaks-own.toml.tmpl"
  # The client-identifier pattern must be injected from 1Password, never hardcoded.
  grep -q 'onepasswordRead' "${HOME_DIR}/dot_config/git/private_gitleaks-own.toml.tmpl"
}

# Regression (this PR): the chain step must not infinite-loop when core.hooksPath
# points at the global hook's own dir. Drives a real commit through a temp repo
# whose core.hooksPath is the hook dir; the buggy idiom would exec itself forever.
@test "global pre-commit hook does not self-recurse under core.hooksPath" {
  local to
  if command -v timeout >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  else skip "timeout not available"; fi
  local hooksdir repo
  hooksdir=$(mktemp -d)
  cp "${HOME_DIR}/dot_config/git/hooks/executable_pre-commit" "${hooksdir}/pre-commit"
  chmod +x "${hooksdir}/pre-commit"
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath "$hooksdir"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf 'x\n' >"${repo}/f"
  git -C "$repo" add f
  # timeout returns 124 if the hook loops; a clean commit returns 0.
  run "$to" 15 git -C "$repo" commit -q -m regression
  rm -rf "$hooksdir" "$repo"
  [ "$status" -eq 0 ]
}

# Regression (this PR): in a linked worktree the chain must still reach the
# common-dir repo-local hook. The earlier --git-dir idiom resolved the
# per-worktree gitdir (which has no hooks/) and silently dropped the chain;
# --git-common-dir points at the shared .git so the repo-local hook still runs.
@test "global pre-commit chains the common-dir hook from a linked worktree" {
  local to
  if command -v timeout >/dev/null 2>&1; then to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then to=gtimeout
  else skip "timeout not available"; fi
  local hooksdir repo wt
  hooksdir=$(mktemp -d)
  cp "${HOME_DIR}/dot_config/git/hooks/executable_pre-commit" "${hooksdir}/pre-commit"
  chmod +x "${hooksdir}/pre-commit"
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath "$hooksdir"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  git -C "$repo" commit --allow-empty -qm init
  wt=$(mktemp -d)
  git -C "$repo" worktree add -q "$wt" -b wt
  # Repo-local hook that drops a marker into the shared .git dir when it runs.
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf ran >"$(git rev-parse --path-format=absolute --git-common-dir)/local-hook-ran"' \
    >"${repo}/.git/hooks/pre-commit"
  chmod +x "${repo}/.git/hooks/pre-commit"
  printf 'x\n' >"${wt}/f"
  git -C "$wt" add f
  run "$to" 15 git -C "$wt" commit -q -m wt
  local marker=no
  [ -f "${repo}/.git/local-hook-ran" ] && marker=yes
  rm -rf "$hooksdir" "$repo" "$wt"
  [ "$status" -eq 0 ]
  [ "$marker" = yes ]
}

# Rendered-target checks (codex review): verify the template actually produces
# the intended files, not just that the source greps right.
@test "AGENTS.md renders with the coding-standards inlined" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  chezmoi cat "${HOME}/AGENTS.md" --source "${REPO_ROOT}/home" 2>/dev/null | grep -q 'Coding standards (house)'
}

# ---------------------------------------------------------------------------
# PR-F: CLV2 instinct→skill flow wiring (SessionStart producer + statusline +
# retrospective-codify input mode).
# ---------------------------------------------------------------------------

@test "clv2-session-notify hook exists, is valid bash, and degrades gracefully" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  [ -f "$hook" ]
  bash -n "$hook"
  # Reads the pinned engine and parses its cluster-count line.
  grep -q 'instinct-cli.py' "$hook"
  grep -q 'Potential skill clusters found' "$hook"
  # Caches the count for the statusline and throttles notifications for 7 days.
  grep -q '.review-ready-clusters' "$hook"
  grep -q '604800' "$hook"
  grep -q 'osascript' "$hook"
  # No-op guards: needs a python interpreter and macOS notifier before acting.
  grep -q 'command -v python3' "$hook"
}

# Behavioral: drive the hook with fake python/osascript so it never touches the
# real engine or fires a real notification, then assert it caches the parsed
# count and that the 7-day throttle suppresses a second notification.
@test "clv2-session-notify caches the cluster count and throttles notifications" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh hb
  td=$(mktemp -d)
  hh=$(mktemp -d)
  hb=$(mktemp -d)
  # Fake engine file: only needs to be readable; the fake python ignores it.
  mkdir -p "${hh}/.agents/skills/continuous-learning-v2/scripts"
  printf 'x\n' >"${hh}/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py"
  # Fake python3: emit canned evolve output with N=3.
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Potential skill clusters found: 3"' >"${hb}/python3"
  chmod +x "${hb}/python3"
  # Fake osascript: record each notification call.
  printf '%s\n' '#!/usr/bin/env bash' "echo call >>\"${td}/.osa-calls\"" >"${hb}/osascript"
  chmod +x "${hb}/osascript"

  # First run: cache == 3, exactly one notification (no throttle stamp yet).
  # CLV2_PYTHON_CMD is pinned to the fake so an inherited value cannot bypass it.
  HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$(cat "${td}/.review-ready-clusters")" = "3" ]
  [ -f "${td}/.last-instinct-notify" ]
  [ "$(wc -l <"${td}/.osa-calls")" -eq 1 ]

  # Second run immediately after: still caches, but throttle suppresses notify #2.
  HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$(cat "${td}/.review-ready-clusters")" = "3" ]
  [ "$(wc -l <"${td}/.osa-calls")" -eq 1 ]

  rm -rf "$td" "$hh" "$hb"
}

# Regression: a corrupt throttle stamp that looks octal ("09") must not abort the
# arithmetic (10# base-10 coercion). The hook must still exit 0 and refresh the cache.
@test "clv2-session-notify tolerates a corrupt octal-looking throttle stamp" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh hb
  td=$(mktemp -d)
  hh=$(mktemp -d)
  hb=$(mktemp -d)
  mkdir -p "${hh}/.agents/skills/continuous-learning-v2/scripts"
  printf 'x\n' >"${hh}/.agents/skills/continuous-learning-v2/scripts/instinct-cli.py"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "Potential skill clusters found: 2"' >"${hb}/python3"
  chmod +x "${hb}/python3"
  printf '%s\n' '#!/usr/bin/env bash' ':' >"${hb}/osascript"
  chmod +x "${hb}/osascript"
  printf '09\n' >"${td}/.last-instinct-notify"
  run env HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" CLV2_PYTHON_CMD="${hb}/python3" PATH="${hb}:$PATH" bash "$hook"
  [ "$status" -eq 0 ]
  [ "$(cat "${td}/.review-ready-clusters")" = "2" ]
  rm -rf "$td" "$hh" "$hb"
}

# Graceful no-op when the CLV2 engine is not deployed: no cache, clean exit.
@test "clv2-session-notify is a no-op when the engine is absent" {
  local hook="${HOME_DIR}/dot_claude/executable_clv2-session-notify.sh"
  local td hh
  td=$(mktemp -d)
  hh=$(mktemp -d)
  run env HOME="$hh" CLV2_HOMUNCULUS_DIR="$td" bash "$hook"
  [ "$status" -eq 0 ]
  [ ! -f "${td}/.review-ready-clusters" ]
  rm -rf "$td" "$hh"
}

@test "settings.json wires the clv2 SessionStart notify hook (async)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local s="${HOME_DIR}/dot_claude/settings.json"
  run jq -e '.hooks.SessionStart[]
    | select(.id=="session:start:clv2-notify")
    | .hooks[0]
    | select(.command=="$HOME/.claude/clv2-session-notify.sh" and .async==true)' "$s"
  [ "$status" -eq 0 ]
}

@test "statusline renders the instinct-cluster segment from the cache" {
  local sl="${HOME_DIR}/dot_claude/executable_statusline.sh"
  grep -q 'I_INSTINCT=' "$sl"
  grep -q 'clv2_cluster_count' "$sl"
  grep -q '.review-ready-clusters' "$sl"
  grep -qF '${I_INSTINCT} ${icc}' "$sl"
}

@test "retrospective-codify documents the instinct-cluster input mode" {
  local sk="${HOME_DIR}/dot_agents/skills/retrospective-codify/SKILL.md"
  grep -q 'instinct-cluster 入力モード' "$sk"
  grep -q -- '--input=instinct-clusters' "$sk"
  grep -q 'instinct-cli.py' "$sk"
  grep -q 'clv2-session-notify' "$sk"
}

# --- Self-hosted ntfy notification system (#337) ---

@test "ntfy compose pins an exact image tag, stays loopback-only, and restarts" {
  local c="${HOME_DIR}/dot_config/ntfy/compose.yaml.tmpl"
  [ -f "$c" ]
  # Exact version pin + digest — Renovate's regex manager tracks this line;
  # `latest` (or any non-vX.Y.Z tag) would make the deployment unauditable.
  # The namespace is asserted literally: `binwiederhier` is the official ntfy
  # publisher (a wrong namespace once shipped as `binary/ntfy`, which does not
  # exist upstream and would trust an unrelated Docker Hub account).
  grep -qE '^    image: binwiederhier/ntfy:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$' "$c"
  ! grep -q 'image:.*latest' "$c"
  ! grep -q 'binary/ntfy' "$c"
  grep -q 'restart: unless-stopped' "$c"
  # Host exposure must be loopback-only; tailnet access goes through
  # `tailscale serve`, never a direct bind.
  grep -qF '"127.0.0.1:{{ .ntfy.port }}:80"' "$c"
  ! grep -q '0\.0\.0\.0' "$c"
  # The `ntfy user`/`access`/`token` management subcommands (run via
  # `docker compose exec` from lib.sh) read the auth backend from env, NOT from
  # the mounted server.yml — without these, provisioning fails "auth-file not
  # set". Pin them so that regression can't return.
  grep -qF 'NTFY_AUTH_FILE: /var/lib/ntfy/user.db' "$c"
  grep -qF 'NTFY_AUTH_DEFAULT_ACCESS: deny-all' "$c"
  # base-url is REQUIRED (upstream-base-url is set) and is the tailnet MagicDNS
  # URL — injected at runtime via this env from ~/.config/ntfy/.env, never a
  # repo literal. The value must stay an env reference, not a hardcoded URL.
  grep -qF 'NTFY_BASE_URL: ${NTFY_BASE_URL:-}' "$c"
  ! grep -qE 'NTFY_BASE_URL:.*https://' "$c"
}

@test "ntfy server config enforces deny-all auth and persistent cache" {
  local y="${HOME_DIR}/dot_config/ntfy/private_server.yml.tmpl"
  [ -f "$y" ]
  grep -q 'auth-default-access: "deny-all"' "$y"
  grep -q 'auth-file:' "$y"
  grep -q 'cache-file:' "$y"
  grep -qF 'cache-duration: "{{ .ntfy.cache_duration }}"' "$y"
  # iOS instant-push relay, the sole user-approved metadata egress (#337 PRD D2').
  grep -qF 'upstream-base-url: "https://ntfy.sh"' "$y"
  # base-url was dropped (optional for core messaging); the server config no
  # longer reads anything from 1Password.
  ! grep -qE '^[[:space:]]*base-url:' "$y"
  ! grep -q 'onepasswordRead' "$y"
  # tailscale funnel must never be USED in the ntfy config assets. A comment that
  # warns against it (as the lib does) is fine — strip inline comments before
  # matching so a trailing `# … funnel …` note never masks a real usage.
  [ -z "$(grep -rn 'funnel' "${HOME_DIR}/dot_config/ntfy" | sed 's/#.*//' | grep 'funnel')" ]
}

@test "ntfy setup script sources the lib, carries the embedded hashes and CI guard" {
  local s="${HOME_DIR}/run_onchange_after_31-setup-ntfy.sh.tmpl"
  [ -f "$s" ]
  # embedded-hash trick: re-runs when the compose file, server config, OR the
  # shared library changes (the last is what lets a lib edit re-fire apply).
  grep -qF 'include "dot_config/ntfy/compose.yaml.tmpl" | sha256sum' "$s"
  grep -qF 'include "dot_config/ntfy/private_server.yml.tmpl" | sha256sum' "$s"
  grep -qF 'include "dot_config/ntfy/lib.sh.tmpl" | sha256sum' "$s"
  # all logic is delegated to the SSOT library (sourced), not duplicated here
  grep -qF '.config/ntfy/lib.sh' "$s"
  grep -qF 'ntfy_provision' "$s"
  # CI must never start services from lifecycle scripts
  grep -qF 'if [ -n "${CI:-}" ]; then' "$s"
  # darwin-only: the whole body is inside the OS guard
  head -1 "$s" | grep -qF '{{ if eq .chezmoi.os "darwin" -}}'
  # template-stripped body must still parse
  sed '/{{/d' "$s" | bash -n
  # fail-open: the apply path only ever exits 0 (never hard-fails)
  ! grep -qE '(^|[[:space:];])exit 1([[:space:];]|$)' "$s"
}

@test "ntfy shared library provisions and rotates with secret hygiene" {
  local l="${HOME_DIR}/dot_config/ntfy/lib.sh.tmpl"
  [ -f "$l" ]
  # template-stripped body must still parse
  sed '/{{/d' "$l" | bash -n
  # secrets are never traced
  ! grep -qF 'set -x' "$l"
  # publisher token -> notify-env (0600 via umask, heredoc)
  grep -qF 'ntfy_write_notify_env' "$l"
  grep -qF 'umask 077' "$l"
  grep -qF '.config/ntfy/notify-env' "$l"
  # device auth is username/password: change-pass fed via NTFY_PASSWORD env, not a token
  grep -qF 'change-pass' "$l"
  grep -qF 'NTFY_PASSWORD' "$l"
  # 1Password item is created only when absent (op item get gate), never overwritten
  grep -qF 'op item get' "$l"
  grep -qF 'op item create' "$l"
  # publisher rotation reads the OLD token first, then revokes it after issuing the new one
  grep -qF 'ntfy_read_notify_env_token' "$l"
  grep -qF 'token remove' "$l"
  # serve --bg lives here now; funnel is forbidden across the ntfy assets
  grep -qF 'serve --bg' "$l"
  ! grep -qE '^[^#]*tailscale.*funnel' "$l"
  # the removed token-in-1Password / subscriber-token paths must not resurrect
  ! grep -qF 'credential[concealed]' "$l"
  ! grep -qF 'subscriber-token' "$l"
  # R-008 interactive rotate guard (central safety design): the prompt reads
  # /dev/tty and defaults to N without a tty. Pin the helpers so a regression
  # that silently rotates live credentials is caught.
  grep -qF 'ntfy_creds_exist' "$l"
  grep -qF 'ntfy_prompt_yn' "$l"
  grep -qF '/dev/tty' "$l"
  # op read failures must be distinguished from an empty value (a swallowed
  # error must not overwrite a real subscriber password → device lockout).
  grep -qF 'op error' "$l"
  # base-url is required (upstream-base-url) and is the tailnet MagicDNS URL:
  # derived at server start and written to the compose .env as runtime state,
  # never a repo literal (no *.ts.net in the source).
  grep -qF 'ntfy_write_compose_env' "$l"
  grep -qF 'NTFY_BASE_URL' "$l"
  ! grep -qE '\.ts\.net' "$l"
  # Provisioning is idempotent / race-proof: a `user add` "already exists"
  # outcome (a racy `user list` right after container start reported no user)
  # must be tolerated, and publisher reissue keys off the actual add result
  # (ntfy_user_created), not a fragile pre-check.
  grep -qF 'already exists' "$l"
  grep -qF 'ntfy_user_created' "$l"
}

@test "ntfy provisions the morning-brief page delivery (#361)" {
  local l="${HOME_DIR}/dot_config/ntfy/lib.sh.tmpl"
  local c="${HOME_DIR}/dot_config/ntfy/compose.yaml.tmpl"
  local r="${HOME_DIR}/dot_claude/executable_morning-radar.sh"
  # Dedicated brief topic + sidecar port are SSOT-declared.
  grep -qF 'topic_brief = "claude-brief"' "${HOME_DIR}/.chezmoidata.toml"
  grep -qF 'brief_port = ' "${HOME_DIR}/.chezmoidata.toml"
  grep -qF '{{ .ntfy.topic_brief }}' "$l"
  grep -qF 'ntfy_topic_brief' "$l"
  grep -qF 'NTFY_TOPIC_BRIEF' "$l"
  # Delivery is a rendered HTML page served by a loopback nginx sidecar fronted
  # by a tailscale PORT proxy on a dedicated HTTPS port (macOS cannot serve
  # files/directories directly). The click opens NTFY_BRIEF_BASE_URL/<date>.html.
  grep -qE 'image: nginx:[0-9.]+-alpine@sha256:[a-f0-9]{64}' "$c"
  grep -qF '127.0.0.1:{{ .ntfy.brief_port }}:80' "$c"
  grep -qF 'ntfy_assert_brief_serve' "$l"
  grep -qF 'serve --bg --https' "$l"
  ! grep -qE '^[^#]*serve.*--set-path' "$l"
  grep -qF 'NTFY_BRIEF_BASE_URL' "$l"
  # Both setup entry points assert the front so it self-heals on apply/ntfy-setup.
  grep -qF 'ntfy_assert_brief_serve' "${HOME_DIR}/run_onchange_after_31-setup-ntfy.sh.tmpl"
  grep -qF 'ntfy_assert_brief_serve' "${HOME_DIR}/dot_local/bin/executable_ntfy-setup"
  # Existing installs (token already present) still get the new notify-env keys
  # without reissuing the token (migration on upgrade).
  grep -qF 'ntfy_write_notify_env "$existing"' "$l"
  # The brief page escapes raw HTML from untrusted brief content (pandoc
  # markdown-raw_html; a <script> in a GitHub title must not execute on the page).
  grep -qF 'markdown-raw_html' "$r"
  # Existing hook-notification bodies render as Markdown in the web app (#361).
  grep -qF 'markdown: true' "${HOME_DIR}/dot_claude/executable_ntfy-notify.sh"
}

@test "ntfy-setup: deploys under ~/.local/bin, sources the lib, prompts before rotating, rotates" {
  local n="${HOME_DIR}/dot_local/bin/executable_ntfy-setup"
  [ -f "$n" ]
  bash -n "$n"
  # It deploys to ~/.local/bin (already on PATH via dot_zshrc.tmpl) — the
  # executable_ prefix + this path is the wiring; no separate PATH edit exists.
  grep -qF '.local/bin/ntfy-setup' "${HOME_DIR}/.chezmoiignore"
  # sources the SSOT library rather than duplicating provisioning logic
  grep -qF '.config/ntfy/lib.sh' "$n"
  # full flow: brings the server up (not check-only) so it can restart a downed container
  grep -qF 'ntfy_start_server' "$n"
  grep -qF 'ntfy_assert_serve' "$n"
  # rotation entry point for both credentials
  grep -qF -- '--rotate' "$n"
  grep -qF 'ntfy_rotate_publisher' "$n"
  grep -qF 'ntfy_rotate_subscriber' "$n"
  # R-008: with no --rotate and live creds present, ask before rotating.
  grep -qF 'ntfy_creds_exist' "$n"
  grep -qF 'ntfy_prompt_yn' "$n"
  # fail-clear: three DISTINCT exit codes (op error / usage / prereq), not collapsed.
  grep -qE '^EXIT_ERR=1( |$)' "$n"
  grep -qE '^EXIT_USAGE=2( |$)' "$n"
  grep -qE '^EXIT_PREREQ=3( |$)' "$n"
  ! grep -qF 'set -x' "$n"
}

@test "settings.json disables stop:desktop-notify and wires the ntfy hooks (#337)" {
  local s="${HOME_DIR}/dot_claude/settings.json"
  [ -f "$s" ]
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  jq -e '
    (.env.ECC_DISABLED_HOOKS | split(",")) as $ids
    | ($ids | index("stop:desktop-notify")) != null
  ' "$s" >/dev/null
  # Notification hook entry: the four subscribed matchers, async command wrapper
  jq -e '
    .hooks.Notification[] | select(.id=="notification:ntfy-notify")
    | .matcher=="permission_prompt|idle_prompt|agent_needs_input|agent_completed"
      and .hooks[0].type=="command"
      and .hooks[0].command=="$HOME/.claude/ntfy-notify.sh"
      and .hooks[0].async==true
      and .hooks[0].timeout==10
  ' "$s" >/dev/null
  # Stop hook entry replacing desktop-notify (same structural bar as Notification)
  jq -e '
    .hooks.Stop[] | select(.id=="stop:ntfy-notify")
    | .hooks[0].type=="command"
      and .hooks[0].command=="$HOME/.claude/ntfy-notify.sh"
      and .hooks[0].async==true
      and .hooks[0].timeout==10
  ' "$s" >/dev/null
}

@test "CI keeps the ntfy server config excluded in both jobs" {
  local w="${REPO_ROOT}/.github/workflows/setup-validation.yml"
  [ -f "$w" ]
  # server.yml no longer reads 1Password (base-url was dropped), but it stays on
  # the hardcoded mv list — a 0600 config of container-only paths with no CI
  # value in rendering — once per job (macOS + Ubuntu).
  [ "$(grep -cF 'home/dot_config/ntfy/private_server.yml.tmpl' "$w")" -eq 2 ]
  # notify-env is not a chezmoi target — the lib writes it as runtime state — so
  # it must not linger in the exclude list.
  ! grep -qF 'private_notify-env' "$w"
}

@test "renovate tracks the ntfy image tag via the compose regex manager" {
  local r="${REPO_ROOT}/.github/renovate.json5"
  grep -qF 'binwiederhier/ntfy' "$r"
  grep -qF "compose\\\\.yaml\\\\.tmpl" "$r"
}

@test "1password ITEMS no longer references the ntfy item" {
  # base-url was dropped; the ntfy item (read-only subscriber username/password)
  # is provisioned by ntfy-setup after Tailscale/Docker come up, a later phase
  # than the validate gate, so the gate must validate nothing ntfy — otherwise a
  # fresh apply would hard-fail before the item exists.
  ! _onepassword_item_list | grep -qF 'op://kryota.dev/Dotfiles - ntfy/'
  # server.yml no longer reads any ntfy field from 1Password.
  ! grep -qF 'onepasswordRead' "${HOME_DIR}/dot_config/ntfy/private_server.yml.tmpl"
  # The base-url format-validation stanza (R-003) was removed from the validate
  # gate too. If it is reintroduced, `op read` returns empty for the now-absent
  # base-url and the stanza hard-fails every fresh `chezmoi apply` before the
  # ntfy item is provisioned. Guard the removal.
  ! grep -qF 'ts.net' "${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
  ! grep -qE 'ntfy_(url|tok)=' "${HOME_DIR}/run_once_after_11-validate-1password.sh.tmpl"
}

@test "ntfy runtime state never lands in the chezmoi source tree" {
  # user.db / cache.db are runtime state under ~/Library/Application Support/ntfy.
  # Structural check first: chezmoi must not manage that target dir (the sibling
  # Application Support/Code entry for VS Code is unrelated and stays).
  [ ! -e "${HOME_DIR}/Library/Application Support/ntfy" ]
  run find "${HOME_DIR}" -name 'user.db*' -o -name 'cache.db*'
  [ -z "$output" ]
}

@test "chezmoiignore excludes the ntfy config dir and command on non-darwin" {
  grep -qF '.config/ntfy' "${HOME_DIR}/.chezmoiignore"
  # the ntfy-setup command is macOS-only too (the server only runs on this Mac)
  grep -qF '.local/bin/ntfy-setup' "${HOME_DIR}/.chezmoiignore"
}

@test "ntfy templates render without a Go template parse error (#357 guard)" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
  # The template-stripped 'bash -n' checks above cannot catch a stray literal
  # open-brace pair in a comment: sed deletes that very line before bash sees
  # it, yet chezmoi would fail to render. Assert a real render — this is exactly
  # the #357 parse-error regression the non-functional requirements forbid.
  chezmoi execute-template --source "${HOME_DIR}" \
    <"${HOME_DIR}/dot_config/ntfy/lib.sh.tmpl" >/dev/null
  chezmoi execute-template --source "${HOME_DIR}" \
    <"${HOME_DIR}/run_onchange_after_31-setup-ntfy.sh.tmpl" >/dev/null
  chezmoi execute-template --source "${HOME_DIR}" \
    <"${HOME_DIR}/dot_config/ntfy/private_server.yml.tmpl" >/dev/null
  # compose carries the brief_port template var (#361); render it too.
  chezmoi execute-template --source "${HOME_DIR}" \
    <"${HOME_DIR}/dot_config/ntfy/compose.yaml.tmpl" >/dev/null
}

@test "install.sh points at ntfy-setup on darwin only, and never provisions at bootstrap" {
  local s="${REPO_ROOT}/install/install.sh"
  [ -f "$s" ]
  bash -n "$s"
  # R-009: bootstrap stays thin — it points at ntfy-setup for the two-phase
  # setup but performs no provisioning (no docker/tailscale/op) itself.
  grep -qF 'ntfy-setup' "$s"
  grep -qF 'if [ "$OS" = "Darwin" ]; then' "$s"
  ! grep -qF 'docker compose' "$s"
  ! grep -qF 'tailscale serve' "$s"
  ! grep -qF 'op item' "$s"
}
