# Frontier Harness foundation — TDD evidence

## Source plan

- [Implementation plan](../plans/frontier-harness-pr-workflow.plan.md)
- [PRD](../prds/frontier-harness-pr-workflow.prd.md)

## User journeys

1. 開発者は `fh doctor --json` で provider executable、account scope、rollout を確認し、
   personal Antigravity credential が r06 task に自動利用されないことを確認できる。
2. 開発者は shadow rollout で task を route し、provider を実行せずに SQLite state へ decision を
   残せる。
3. 開発者は repository capability manifest を一度承認し、raw evidence を保持期限に従って
   cleanup できる。

## RED / GREEN evidence

| Behavior | RED evidence | GREEN evidence | Guarantee |
|---|---|---|---|
| Config/router/state foundation | `node --test tests/frontier_harness.test.mjs` が `config.mjs` 未存在で `ERR_MODULE_NOT_FOUND` | 同 command で config、route、evidence state の test が pass | invalid config、route、transcript 非保存を固定 |
| Doctor account boundary | 同 test が unprobed Antigravity を `available` と報告して fail | 同 test が `unverified` を確認して pass | r06 mismatch は unavailable、unprobed personal Antigravity は unverified |
| Shadow lifecycle | 同 test が未実装 `run` / `onboard` / `clean` / `verify` / `review` で exit 64 | 同 test が shadow evidence/state を確認して pass | provider/shell を起動せず planned evidence を保存 |
| ChezmoI deploy shape | `bats tests/files.bats --filter 'frontier-harness source files'` が launcher 未存在で fail | 同 command が launcher、symlink、JSON config、Brewfile entry を確認して pass | `fh` と Antigravity policy が source state に存在 |

## Test specification

| # | What is guaranteed | Test command | Type | Result |
|---|---|---|---|---|
| 1 | Invalid rollout is rejected before adapter execution | `node --test tests/frontier_harness.test.mjs` | Unit | PASS |
| 2 | Browser task selects an available personal Antigravity capability | same | Unit | PASS |
| 3 | r06 never crosses into personal Antigravity | same | Unit | PASS |
| 4 | Unprobed Antigravity is unverified | same | Unit | PASS |
| 5 | No deterministic oracle adds independent review | same | Unit | PASS |
| 6 | Evidence state omits transcript and prunes expired records | same | Integration | PASS |
| 7 | Shadow run/onboard/verify/review/clean persist normalized state without live provider execution | same | Integration | PASS |
| 8 | Shell launcher, symlink, JSON config, and cask source exist | `bats tests/files.bats --filter 'frontier-harness source files'` | Source integration | PASS |
| 9 | Persistent state is private and concurrent-safe (0600, WAL, busy timeout) | `node --test tests/frontier_harness.test.mjs` | Integration | PASS |
| 10 | Manifest keys/commands/domains are strict and credential-free | same | Unit | PASS |
| 11 | Antigravity readiness probe is structured, fresh, and credential-free | same | Unit/integration | PASS |
| 12 | Artifact pruning deletes only contained non-symlink files | same | Integration | PASS |
| 13 | `findCommand` ignores empty PATH entries so a repository-local `agy` is never spawned | `node --test tests/frontier_harness.test.mjs` | Unit | PASS |
| 14 | The probe refuses a relative executable path (defence in depth for #13) | same | Unit | PASS |
| 15 | `fh doctor --probe` persists readiness through the default state root, and a later `fh run` consumes it | same | Integration | PASS |
| 16 | A capability whose configured model is absent from discovery stays `unverified` | same | Unit | PASS |
| 17 | A future-dated readiness cache stays unverified | same | Unit | PASS |
| 18 | A missing `hasDeterministicOracle` is treated as "no oracle" and escalates to independent review | same | Unit | PASS |
| 19 | The rollout guard never calls an injected executor while the rollout is `shadow` | same | Unit/integration | PASS |
| 20 | A caller-supplied task `id` cannot override the generated primary key | same | Unit | PASS |
| 21 | A symlinked state database is rejected before SQLite creates the link target | same | Integration | PASS |
| 22 | The schema version is stamped, and a newer database is refused | same | Integration | PASS |
| 23 | `fh onboard` refuses to write through a symlinked `.harness` directory | same | Integration | PASS |
| 24 | The shipped config escalates every risk name the harness skill instructs agents to use | same | Unit | PASS |

## Coverage and known gaps

Node's built-in test runner covers the currently implemented config, router, state store, doctor,
readiness probe, retention, manifest, and shadow CLI contracts (41 tests). CI runs the same
`lint-node` / `test-node` targets, so the suite is no longer local-only.

Intentionally **not** implemented in this foundation slice:

- Provider write adapter, candidate worktree apply, wave batch authorization, learned router
  (plan steps 4, 6, and the router work in step 5).
- The normalized `adapter run` / `verification result` / `review finding` / `approval` /
  `telemetry` tables of AC-004, and the 180-day aggregate-telemetry prune of AC-024. The store
  keeps a stamped schema version so those tables can be added as a migration.
- Enforcement of the approved `.harness/policy.json`: `fh onboard` writes it, but no command
  reads it yet, and unknown commands/domains are not queued (AC-017/AC-018, plan step 5).
- The `--legacy` rollback flag and pilot/default promotion of AC-036 (plan step 8). The rollout
  is now an explicit guard rather than a value that is only echoed, so promoting it is a code
  change rather than a silent behaviour change.
- Before/after skill evals for the **modified** skills (`pr-workflow`, `sdd`, `multi-review`,
  `model-fitness-check`) required by AC-040; only the two new skills ship `evals/evals.json`.
- The AC-029 reduction of `multi-review` to a reviewer registry. This PR only changes its
  Phase 1 gate wording; the roster and phase structure are untouched.

`make test` reaches the complete lint/Node/Bats stack but has one unrelated failure inherited from
the pre-existing RunCat worktree change: `tests/files.bats` expects `mas "RunCat Neo"`, while the
uncommitted source entry is `mas "RunCatNeo"`. This PR does not modify that user-owned change or
weaken its assertion.
