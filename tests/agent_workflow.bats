#!/usr/bin/env bats

load helpers/setup

RUNNER="${HOME_DIR}/dot_local/bin/executable_agent-workflow"
GH_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/agent-workflow"

setup() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  REPOSITORY="${TEST_ROOT}/repo"
  WORKTREE="${TEST_ROOT}/worktree"
  export AGENT_WORKFLOW_STATE_DIR="${TEST_ROOT}/state/agent-workflow"

  git init "${REPOSITORY}" >/dev/null
  git -C "${REPOSITORY}" checkout -b main >/dev/null
  git -C "${REPOSITORY}" config user.name "Test User"
  git -C "${REPOSITORY}" config user.email "test@example.invalid"
  git -C "${REPOSITORY}" -c commit.gpgsign=false commit --allow-empty -m "test: 初期化" >/dev/null
  git -C "${REPOSITORY}" remote add origin git@github.com:example/repository.git
  git -C "${REPOSITORY}" worktree add -b feat/runner "${WORKTREE}" >/dev/null
  cd "${REPOSITORY}"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

@test "agent-workflow: linked worktree の run state を private に初期化する" {
  run bash "${RUNNER}" init run-1 --worktree "${WORKTREE}" --phase classified

  [ "$status" -eq 0 ]
  [ "$output" = "run-1" ]
  run bash "${RUNNER}" status run-1
  [ "$status" -eq 0 ]
  [[ "$output" == *$'worktree\t'"${WORKTREE}"* ]]
  [[ "$output" == *$'phase\tclassified'* ]]
  [ "$(_file_mode "${AGENT_WORKFLOW_STATE_DIR}/run-1/state.tsv")" = "600" ]
}

@test "agent-workflow: main worktree の state 初期化を拒否する" {
  run bash "${RUNNER}" init run-main --worktree "${REPOSITORY}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to operate on the main worktree"* ]]
  [ ! -e "${AGENT_WORKFLOW_STATE_DIR}/run-main" ]
}

@test "agent-workflow: worktree-init は TTY 承認なしに branch を作成しない" {
  run bash "${RUNNER}" worktree-init run-tty --branch feat/tty --base main

  [ "$status" -ne 0 ]
  [[ "$output" == *"approval must be made from an interactive TTY"* ]]
  ! git -C "${REPOSITORY}" show-ref --verify --quiet refs/heads/feat/tty
  [ ! -e "${AGENT_WORKFLOW_STATE_DIR}/run-tty" ]
}

@test "agent-workflow: worktree-init は TTY 承認後に linked worktree と state を作成する" {
  run env PATH="${GH_FIXTURE}:${PATH}" python3 - bash "${RUNNER}" worktree-init run-created --branch feat/created --base main <<'PY'
import os
import pty
import sys

command = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(command[0], command, os.environ)

os.write(fd, b'y\n')
chunks = []
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    chunks.append(chunk)
exit_status = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
sys.stdout.write(b''.join(chunks).decode())
sys.exit(exit_status)
PY

  [ "$status" -eq 0 ]
  [ -d "${TEST_ROOT}/created-worktree" ]
  [ "$(git -C "${TEST_ROOT}/created-worktree" branch --show-current)" = "feat/created" ]
  [[ "$(bash "${RUNNER}" status run-created)" == *$'phase\tworktree-created'* ]]
}

@test "agent-workflow: push は TTY 承認済み gate を要求する" {
  run bash "${RUNNER}" init push-run --worktree "${WORKTREE}"
  [ "$status" -eq 0 ]

  run bash "${RUNNER}" push push-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"gate 'push' is not approved"* ]]
}

@test "agent-workflow: CI 確認は固定された GitHub action を通す" {
  local state_file="${AGENT_WORKFLOW_STATE_DIR}/ci-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t1\nrun_id\tci-run\nworktree\t%s\nbranch\tfeat/runner\nphase\tpr-created\ncreated_at\t2026-01-01T00:00:00Z\napproved_gates\t\npr_number\t123\n' "${WORKTREE}" >"${state_file}"
  chmod 600 "${state_file}"

  run env PATH="${GH_FIXTURE}:${PATH}" GH_CAPTURE="${TEST_ROOT}/gh-args" bash "${RUNNER}" checks ci-run

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${TEST_ROOT}/gh-args")" = "pr" ]
  [ "$(sed -n '2p' "${TEST_ROOT}/gh-args")" = "checks" ]
  [ "$(sed -n '3p' "${TEST_ROOT}/gh-args")" = "123" ]
  [ "$(sed -n '4p' "${TEST_ROOT}/gh-args")" = "--repo" ]
  [ "$(sed -n '5p' "${TEST_ROOT}/gh-args")" = "example/repository" ]
}

@test "agent-workflow: PR 下書きは run state 内の file だけを host action に渡す" {
  local state_file="${AGENT_WORKFLOW_STATE_DIR}/pr-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t1\nrun_id\tpr-run\nworktree\t%s\nbranch\tfeat/runner\nphase\tpushed\ncreated_at\t2026-01-01T00:00:00Z\napproved_gates\tcreate-pr\npr_number\t\n' "${WORKTREE}" >"${state_file}"
  printf '%s\n' 'feat: host action test' >"${AGENT_WORKFLOW_STATE_DIR}/pr-run/title.md"
  printf '%s\n' 'PR body' >"${AGENT_WORKFLOW_STATE_DIR}/pr-run/body.md"
  chmod 600 "${state_file}"

  run env PATH="${GH_FIXTURE}:${PATH}" GH_CAPTURE="${TEST_ROOT}/gh-args" bash "${RUNNER}" create-pr pr-run --title-file title.md --body-file body.md --base main --draft

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "${TEST_ROOT}/gh-args")" = "pr" ]
  [ "$(sed -n '2p' "${TEST_ROOT}/gh-args")" = "create" ]
  [ "$(sed -n '3p' "${TEST_ROOT}/gh-args")" = "--repo" ]
  [ "$(sed -n '4p' "${TEST_ROOT}/gh-args")" = "example/repository" ]
  [ "$(sed -n '5p' "${TEST_ROOT}/gh-args")" = "--draft" ]
  [[ "$(bash "${RUNNER}" status pr-run)" == *$'phase\tpr-created'* ]]
}

@test "agent-workflow: ready-for-review は記録済み PR 以外を変更しない" {
  local state_file="${AGENT_WORKFLOW_STATE_DIR}/ready-run/state.tsv"
  mkdir -p "$(dirname "${state_file}")"
  printf 'version\t1\nrun_id\tready-run\nworktree\t%s\nbranch\tfeat/runner\nphase\tpr-created\ncreated_at\t2026-01-01T00:00:00Z\napproved_gates\tready-for-review\npr_number\t123\n' "${WORKTREE}" >"${state_file}"
  chmod 600 "${state_file}"

  run env PATH="${GH_FIXTURE}:${PATH}" GH_CAPTURE="${TEST_ROOT}/gh-args" bash "${RUNNER}" ready-for-review ready-run 456

  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number does not match the recorded run"* ]]
  [ ! -e "${TEST_ROOT}/gh-args" ]
}

@test "agent-workflow: Codex main profile と common contract を配備する" {
  [ -f "${HOME_DIR}/dot_codex/private_main.config.toml.tmpl" ]
  [ -f "${HOME_DIR}/dot_codex-r06/private_main.config.toml.tmpl" ]
  grep -qF 'network_access = true' "${HOME_DIR}/.chezmoitemplates/codex-main-config.toml"
  grep -qF 'web_search = "live"' "${HOME_DIR}/.chezmoitemplates/codex-main-config.toml"
  grep -qF 'network_access = false' "${HOME_DIR}/.chezmoitemplates/codex-agent-config.toml"
  grep -qF 'web_search = "cached"' "${HOME_DIR}/.chezmoitemplates/codex-agent-config.toml"
  grep -qF 'agent-workflow worktree-init' "${HOME_DIR}/dot_agents/workflow/codex.md"
}
