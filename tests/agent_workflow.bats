#!/usr/bin/env bats

load helpers/setup

RUNNER_SOURCE="${HOME_DIR}/dot_local/bin/executable_agent-workflow"
RUNNER_IMPLEMENTATION_SOURCE="${HOME_DIR}/dot_local/bin/executable_agent-workflow-host"
GH_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/agent-workflow"

setup() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  REPOSITORY="${TEST_ROOT}/repo"
  WORKTREE="${TEST_ROOT}/worktree"
  STATE_DIR="${TEST_ROOT}/state/agent-workflow"
  RUNNER="${TEST_ROOT}/agent-workflow"
  RUNNER_IMPLEMENTATION="${TEST_ROOT}/agent-workflow-host"
  sed \
    -e "s|^STATE_ROOT=.*|STATE_ROOT=\"${STATE_DIR}\"|" \
    -e "s|^GH_BIN=\"\"|GH_BIN=\"${GH_FIXTURE}/gh\"\nexport GH_CAPTURE=\"${TEST_ROOT}/gh-args\"|" \
    -e "s|^HOST_PRE_COMMIT=\"\"|HOST_PRE_COMMIT=\"${GH_FIXTURE}/host-pre-commit\"\nexport HOST_PRE_COMMIT_CAPTURE=\"${TEST_ROOT}/host-pre-commit\"|" \
    "${RUNNER_IMPLEMENTATION_SOURCE}" >"${RUNNER_IMPLEMENTATION}"
  sed "s|^IMPLEMENTATION=.*|IMPLEMENTATION=\"${RUNNER_IMPLEMENTATION}\"|" \
    "${RUNNER_SOURCE}" >"${RUNNER}"
  chmod +x "${RUNNER}" "${RUNNER_IMPLEMENTATION}"

  git init "${REPOSITORY}" >/dev/null
  git -C "${REPOSITORY}" checkout -b main >/dev/null
  git -C "${REPOSITORY}" config user.name "Test User"
  git -C "${REPOSITORY}" config user.email "test@example.invalid"
  git -C "${REPOSITORY}" config commit.gpgsign false
  printf '%s\n' 'initial' >"${REPOSITORY}/fixture.txt"
  git -C "${REPOSITORY}" add fixture.txt
  git -C "${REPOSITORY}" -c commit.gpgsign=false commit -m "test: 初期化" >/dev/null
  git -C "${REPOSITORY}" remote add origin git@github.com:example/repository.git
  git -C "${REPOSITORY}" worktree add -b feat/runner "${WORKTREE}" >/dev/null
  WORKTREE="$(cd "${WORKTREE}" && pwd -P)"
  cd "${REPOSITORY}"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

@test "agent-workflow: linked worktree の run state を private に初期化する" {
  run bash -c 'cd "$1" && bash "$2" init run-1 --phase classified' _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -eq 0 ]
  [ "$output" = "run-1" ]
  run bash "${RUNNER}" status run-1
  [ "$status" -eq 0 ]
  [[ "$output" == *$'worktree\t'"${WORKTREE}"* ]]
  [[ "$output" == *$'phase\tclassified'* ]]
  [[ "$output" != *$'approved_gates\t'* ]]
  [[ "$output" == *$'common_git_dir\t'* ]]
  [ "$(_file_mode "${STATE_DIR}/run-1/state.tsv")" = "600" ]
}

@test "agent-workflow: TTY ベースの approve action を公開しない" {
  run bash "${RUNNER}" approve run-1 commit

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: approve"* ]]
}

@test "agent-workflow: main worktree の state 初期化を拒否する" {
  run bash -c 'cd "$1" && bash "$2" init run-main' _ "${REPOSITORY}" "${RUNNER}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to operate on the main worktree"* ]]
  [ ! -e "${STATE_DIR}/run-main" ]
}

@test "agent-workflow: worktree-init は native approval 後の host action として linked worktree と state を作成する" {
  local fake_wtp="${TEST_ROOT}/wtp"
  local hook_dir="${TEST_ROOT}/worktree-hooks"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$WTP_CALLED"' >"${fake_wtp}"
  mkdir -p "${hook_dir}"
  printf '%s\n' '#!/bin/sh' 'touch "'"${TEST_ROOT}"'/post-checkout-ran"' >"${hook_dir}/post-checkout"
  chmod +x "${fake_wtp}" "${hook_dir}/post-checkout"
  git -C "${REPOSITORY}" config core.hooksPath "${hook_dir}"
  run env PATH="${TEST_ROOT}:${PATH}" WTP_CALLED="${TEST_ROOT}/wtp-called" bash "${RUNNER}" worktree-init run-created --branch feat/created --base main

  [ "$status" -eq 0 ]
  [ -d "${TEST_ROOT}/worktrees/repo/feat/created" ]
  [ "$(git -C "${TEST_ROOT}/worktrees/repo/feat/created" branch --show-current)" = "feat/created" ]
  [ ! -e "${TEST_ROOT}/wtp-called" ]
  [ ! -e "${TEST_ROOT}/post-checkout-ran" ]
  [[ "$(bash "${RUNNER}" status run-created)" == *$'phase\tworktree-created'* ]]
}

@test "agent-workflow: worktree-init は main 以外の base と変更済み main worktree を拒否する" {
  run bash "${RUNNER}" worktree-init invalid-base --branch feat/invalid --base topic
  [ "$status" -ne 0 ]
  [[ "$output" == *"base must be main"* ]]

  printf '%s\n' 'uncommitted' >"${REPOSITORY}/fixture.txt"
  run bash "${RUNNER}" worktree-init dirty-main --branch feat/dirty --base main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unstaged changes"* ]]
}

@test "agent-workflow: push は linked worktree の run state を要求する" {
  run bash -c 'cd "$1" && bash "$2" init push-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  local legacy_state
  legacy_state="$(<"${STATE_DIR}/push-run/state.tsv")"
  legacy_state="${legacy_state/$'version\t3'/$'version\t1'}"
  legacy_state="$(printf '%s\n' "$legacy_state" | awk '!/^common_git_dir\t/')"
  printf '%s\n' "$legacy_state" >"${STATE_DIR}/push-run/state.tsv"
  printf '%s\n' $'approved_gates\tpush' >>"${STATE_DIR}/push-run/state.tsv"
  local remote="${TEST_ROOT}/origin.git"
  local hook_dir="${TEST_ROOT}/push-hooks"
  git init --bare "${remote}" >/dev/null
  git -C "${WORKTREE}" remote set-url origin "${remote}"
  mkdir -p "${hook_dir}"
  printf '%s\n' '#!/bin/sh' 'touch "'"${TEST_ROOT}"'/pre-push-ran"' >"${hook_dir}/pre-push"
  chmod +x "${hook_dir}/pre-push"
  git -C "${WORKTREE}" config core.hooksPath "${hook_dir}"

  run bash -c 'cd "$1" && bash "$2" push push-run' _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"run state is not bound"* ]]

  run bash -c 'cd "$1" && bash "$2" init push-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  [[ "$(bash "${RUNNER}" status push-run)" == *$'common_git_dir\t'* ]]

  run bash -c 'cd "$1" && bash "$2" push push-run' _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -eq 0 ]
  [[ "$(bash "${RUNNER}" status push-run)" == *$'phase\tpushed'* ]]
  [[ "$(bash "${RUNNER}" status push-run)" == *$'version\t3'* ]]
  [[ "$(bash "${RUNNER}" status push-run)" != *$'approved_gates\t'* ]]
  [ ! -e "${TEST_ROOT}/pre-push-ran" ]
}

@test "agent-workflow: PR 下書きは linked worktree から private run state に準備する" {
  run bash -c 'cd "$1" && bash "$2" init draft-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'feat: host action test' >"${WORKTREE}/.agent-workflow-pr-title.md"
  printf '%s\n' 'PR body' >"${WORKTREE}/.agent-workflow-pr-body.md"

  run bash -c 'cd "$1" && bash "$2" prepare-pr draft-run --title-file .agent-workflow-pr-title.md --body-file .agent-workflow-pr-body.md' \
    _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -eq 0 ]
  [ "$(cat "${STATE_DIR}/draft-run/title.md")" = 'feat: host action test' ]
  [ "$(cat "${STATE_DIR}/draft-run/body.md")" = 'PR body' ]
  [ "$(_file_mode "${STATE_DIR}/draft-run/title.md")" = "600" ]
  [ "$(_file_mode "${STATE_DIR}/draft-run/body.md")" = "600" ]
  [[ "$(bash "${RUNNER}" status draft-run)" == *$'phase\tpr-drafted'* ]]
}

@test "agent-workflow: host action の入力 path と repository binding を検証する" {
  run bash -c 'cd "$1" && bash "$2" init bound-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'outside title' >"${TEST_ROOT}/outside-title.md"
  printf '%s\n' 'body' >"${WORKTREE}/body.md"

  run bash -c 'cd "$1" && bash "$2" prepare-pr bound-run --title-file ../outside-title.md --body-file body.md' \
    _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the recorded worktree"* ]]
  [ ! -e "${STATE_DIR}/bound-run/title.md" ]

  local state_file="${STATE_DIR}/bound-run/state.tsv"
  local state_contents
  state_contents="$(<"${state_file}")"
  state_contents="${state_contents/$'common_git_dir\t'*$'\n'/$'common_git_dir\t'"${TEST_ROOT}/other-repository"$'\n'}"
  printf '%s\n' "$state_contents" >"${state_file}"
  run bash -c 'cd "$1" && bash "$2" prepare-pr bound-run --title-file fixture.txt --body-file body.md' \
    _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the recorded repository"* ]]
}

@test "agent-workflow: commit は指定 path だけを stage して state を遷移する" {
  run bash -c 'cd "$1" && bash "$2" init commit-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'included' >"${WORKTREE}/included.txt"
  printf '%s\n' 'ignored' >"${WORKTREE}/ignored.txt"
  printf '%s\n' 'test: 指定ファイルだけを commit する' >"${WORKTREE}/message.txt"

  run bash -c 'cd "$1" && bash "$2" commit commit-run --message-file message.txt -- included.txt' \
    _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  [ "$(git -C "${WORKTREE}" show --format= --name-only HEAD)" = "included.txt" ]
  [[ "$(git -C "${WORKTREE}" status --short)" == *"?? ignored.txt"* ]]
  [[ "$(bash "${RUNNER}" status commit-run)" == *$'phase\tcommitted'* ]]
}

@test "agent-workflow: commit は既存の staged 変更を含めない" {
  run bash -c 'cd "$1" && bash "$2" init staged-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'included' >"${WORKTREE}/included.txt"
  printf '%s\n' 'already staged' >"${WORKTREE}/already-staged.txt"
  printf '%s\n' 'test: 指定ファイルだけを commit する' >"${WORKTREE}/message.txt"
  git -C "${WORKTREE}" add -- already-staged.txt

  run bash -c 'cd "$1" && bash "$2" commit staged-run --message-file message.txt -- included.txt' \
    _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-existing staged changes"* ]]
  [ "$(git -C "${WORKTREE}" rev-parse --verify HEAD)" = "$(git -C "${REPOSITORY}" rev-parse --verify main)" ]
  [[ "$(git -C "${WORKTREE}" diff --cached --name-only)" == *"already-staged.txt"* ]]
}

@test "agent-workflow: CI 確認は固定された GitHub action を通す" {
  local state_file="${STATE_DIR}/ci-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t3\nrun_id\tci-run\nworktree\t%s\ncommon_git_dir\t%s\nbranch\tfeat/runner\nphase\tpr-created\ncreated_at\t2026-01-01T00:00:00Z\npr_number\t123\n' "${WORKTREE}" "$(git -C "${WORKTREE}" rev-parse --path-format=absolute --git-common-dir)" >"${state_file}"
  chmod 600 "${state_file}"

  run bash -c 'cd "$1" && bash "$2" checks ci-run' _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${TEST_ROOT}/gh-args")" = "pr" ]
  [ "$(sed -n '2p' "${TEST_ROOT}/gh-args")" = "checks" ]
  [ "$(sed -n '3p' "${TEST_ROOT}/gh-args")" = "123" ]
  [ "$(sed -n '4p' "${TEST_ROOT}/gh-args")" = "--repo" ]
  [ "$(sed -n '5p' "${TEST_ROOT}/gh-args")" = "example/repository" ]
}

@test "agent-workflow: gh は account 側の pinned mise binary だけを使う" {
  local state_file account runner asset binary
  state_file="${STATE_DIR}/mise-gh-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t3\nrun_id\tmise-gh-run\nworktree\t%s\ncommon_git_dir\t%s\nbranch\tfeat/runner\nphase\tpr-created\ncreated_at\t2026-01-01T00:00:00Z\npr_number\t123\n' "${WORKTREE}" "$(git -C "${WORKTREE}" rev-parse --path-format=absolute --git-common-dir)" >"${state_file}"
  chmod 600 "${state_file}"
  account="${TEST_ROOT}/account"
  asset="$(case "$(uname -s):$(uname -m)" in Darwin:arm64) printf macOS_arm64 ;; Darwin:x86_64) printf macOS_amd64 ;; Linux:aarch64|Linux:arm64) printf linux_arm64 ;; Linux:x86_64) printf linux_amd64 ;; esac)"
  binary="${account}/.local/share/mise/installs/gh/1.2.3/gh_1.2.3_${asset}/bin/gh"
  mkdir -p "${account}/.config/mise" "$(dirname "${binary}")"
  printf 'gh = "1.2.3"\n' >"${account}/.config/mise/config.toml"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@" >"${GH_CAPTURE:?}"' >"${binary}"
  chmod +x "${binary}"
  runner="${TEST_ROOT}/agent-workflow-host-mise-gh"
  sed \
    -e "s|^STATE_ROOT=.*|STATE_ROOT=\"${STATE_DIR}\"|" \
    -e "s|^HOST_PRE_COMMIT=\"\"|HOST_PRE_COMMIT=\"${GH_FIXTURE}/host-pre-commit\"|" \
    "${RUNNER_IMPLEMENTATION_SOURCE}" >"${runner}"
  chmod +x "${runner}"

  run bash -c 'cd "$1" && env -i HOME="$2" USER=test LOGNAME=test AGENT_WORKFLOW_ACCOUNT_HOME="$2" GH_CAPTURE="$3" PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$4" checks mise-gh-run' \
    _ "${WORKTREE}" "${account}" "${TEST_ROOT}/mise-gh-args" "${runner}"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${TEST_ROOT}/mise-gh-args")" = "pr" ]
  [ "$(sed -n '2p' "${TEST_ROOT}/mise-gh-args")" = "checks" ]
}

@test "agent-workflow: PR 下書きは run state 内の file だけを host action に渡す" {
  local state_file="${STATE_DIR}/pr-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t3\nrun_id\tpr-run\nworktree\t%s\ncommon_git_dir\t%s\nbranch\tfeat/runner\nphase\tpushed\ncreated_at\t2026-01-01T00:00:00Z\npr_number\t\n' "${WORKTREE}" "$(git -C "${WORKTREE}" rev-parse --path-format=absolute --git-common-dir)" >"${state_file}"
  printf '%s\n' 'feat: host action test' >"${STATE_DIR}/pr-run/title.md"
  printf '%s\n' 'PR body' >"${STATE_DIR}/pr-run/body.md"
  chmod 600 "${state_file}"

  run bash -c 'cd "$1" && bash "$2" create-pr pr-run --title-file title.md --body-file body.md --base main --draft' \
    _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${TEST_ROOT}/gh-args")" = "pr" ]
  [ "$(sed -n '2p' "${TEST_ROOT}/gh-args")" = "create" ]
  [ "$(sed -n '3p' "${TEST_ROOT}/gh-args")" = "--repo" ]
  [ "$(sed -n '4p' "${TEST_ROOT}/gh-args")" = "example/repository" ]
  [ "$(sed -n '5p' "${TEST_ROOT}/gh-args")" = "--draft" ]
  [ "$(sed -n '6p' "${TEST_ROOT}/gh-args")" = "--title" ]
  [ "$(sed -n '7p' "${TEST_ROOT}/gh-args")" = "feat: host action test" ]
  [ "$(sed -n '8p' "${TEST_ROOT}/gh-args")" = "--body-file" ]
  [ "$(sed -n '9p' "${TEST_ROOT}/gh-args")" = "$(cd "${STATE_DIR}/pr-run" && pwd -P)/body.md" ]
  [ "$(sed -n '10p' "${TEST_ROOT}/gh-args")" = "--base" ]
  [ "$(sed -n '11p' "${TEST_ROOT}/gh-args")" = "main" ]
  [ "$(sed -n '12p' "${TEST_ROOT}/gh-args")" = "--head" ]
  [ "$(sed -n '13p' "${TEST_ROOT}/gh-args")" = "feat/runner" ]
  [[ "$(bash "${RUNNER}" status pr-run)" == *$'phase\tpr-created'* ]]
}

@test "agent-workflow: ready-for-review は記録済み PR 以外を変更しない" {
  local state_file="${STATE_DIR}/ready-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t3\nrun_id\tready-run\nworktree\t%s\ncommon_git_dir\t%s\nbranch\tfeat/runner\nphase\tpr-created\ncreated_at\t2026-01-01T00:00:00Z\npr_number\t123\n' "${WORKTREE}" "$(git -C "${WORKTREE}" rev-parse --path-format=absolute --git-common-dir)" >"${state_file}"
  chmod 600 "${state_file}"

  run bash -c 'cd "$1" && bash "$2" ready-for-review ready-run 456' _ "${WORKTREE}" "${RUNNER}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number does not match the recorded run"* ]]
  [ ! -e "${TEST_ROOT}/gh-args" ]
}

@test "agent-workflow: host action は記録済み worktree からのみ実行する" {
  run bash -c 'cd "$1" && bash "$2" init caller-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'title' >"${WORKTREE}/title.md"
  printf '%s\n' 'body' >"${WORKTREE}/body.md"

  run bash "${RUNNER}" prepare-pr caller-run --title-file title.md --body-file body.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"must run from the recorded worktree"* ]]
  [ ! -e "${STATE_DIR}/caller-run/title.md" ]
}

@test "agent-workflow: host action は信頼済み scan だけを実行し、継承環境と repository hook を無効化する" {
  run bash -c 'cd "$1" && bash "$2" init isolated-run' _ "${WORKTREE}" "${RUNNER}"
  [ "$status" -eq 0 ]
  printf '%s\n' 'included' >"${WORKTREE}/included.txt"
  printf '%s\n' 'test: 隔離した host action' >"${WORKTREE}/message.txt"
  local hook_dir="${TEST_ROOT}/hook-dir"
  local fake_bin="${TEST_ROOT}/fake-bin"
  local bash_env="${TEST_ROOT}/bash-env"
  mkdir -p "${hook_dir}" "${fake_bin}"
  printf '%s\n' '#!/bin/sh' 'touch "'"${TEST_ROOT}"'/hook-ran"' >"${hook_dir}/pre-commit"
  printf '%s\n' '#!/bin/sh' 'touch "'"${TEST_ROOT}"'/fake-git-ran"' >"${fake_bin}/git"
  printf '%s\n' 'touch "'"${TEST_ROOT}"'/bash-env-ran"' >"${bash_env}"
  chmod +x "${hook_dir}/pre-commit" "${fake_bin}/git"
  git -C "${WORKTREE}" config core.hooksPath "${hook_dir}"
  cd "${WORKTREE}"

  run env \
    BASH_ENV="${bash_env}" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0="${hook_dir}" \
    PATH="${fake_bin}:${PATH}" \
    /bin/sh "${RUNNER}" commit isolated-run --message-file message.txt -- included.txt

  [ "$status" -eq 0 ]
  [ ! -e "${TEST_ROOT}/bash-env-ran" ]
  [ ! -e "${TEST_ROOT}/fake-git-ran" ]
  [ ! -e "${TEST_ROOT}/hook-ran" ]
  [ "$(cat "${TEST_ROOT}/host-pre-commit")" = "1" ]
}

@test "agent-workflow: Codex main profile と common contract を配備する" {
  [ -f "${HOME_DIR}/dot_codex/private_main.config.toml.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/private_main.config.toml.tmpl" ]
  grep -qF 'approval_policy = "on-request"' "${HOME_DIR}/.chezmoitemplates/codex-main-config.toml"
  grep -qF 'network_access = true' "${HOME_DIR}/.chezmoitemplates/codex-main-config.toml"
  grep -qF 'web_search = "live"' "${HOME_DIR}/.chezmoitemplates/codex-main-config.toml"
  grep -qF 'network_access = false' "${HOME_DIR}/.chezmoitemplates/codex-agent-config.toml"
  grep -qF 'web_search = "cached"' "${HOME_DIR}/.chezmoitemplates/codex-agent-config.toml"
  grep -qF 'agent-workflow worktree-init' "${HOME_DIR}/dot_agents/workflow/codex.md"
  grep -qF 'agent-workflow prepare-pr' "${HOME_DIR}/dot_agents/workflow/codex.md"
  grep -qF 'native command approval' "${HOME_DIR}/dot_agents/workflow/README.md"
  grep -qF 'STATE_ROOT="$ACCOUNT_HOME/.local/state/agent-workflow"' "${RUNNER_IMPLEMENTATION_SOURCE}"
  ! grep -q 'AGENT_WORKFLOW_STATE_DIR' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'core.hooksPath=/dev/null worktree add -b "$branch" "$worktree" "$base"' "${RUNNER_IMPLEMENTATION_SOURCE}"
  ! grep -q 'wtp add' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF '/usr/bin/env -i' "${RUNNER_SOURCE}"
  grep -qF 'require_invoking_worktree' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'run_secret_scan "$worktree"' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'core.hooksPath=/dev/null commit --no-verify' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'core.hooksPath=/dev/null push -u origin "$branch"' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'resolve_trusted_gitleaks' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'resolve_trusted_gh' "${RUNNER_IMPLEMENTATION_SOURCE}"
  grep -qF 'AGENT_WORKFLOW_GITLEAKS_BIN' "${HOME_DIR}/dot_config/git/hooks/executable_pre-commit"
}
