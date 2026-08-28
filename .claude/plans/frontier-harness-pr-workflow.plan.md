---
slug: frontier-harness-pr-workflow
prd: .claude/prds/frontier-harness-pr-workflow.prd.md
created_at: 2026-08-27T17:11:44+09:00
planning_session: 272fbdea-c16d-4cb8-ab0a-7ea4e8cd13a8
status: approved
---

# Multi-frontier PR workflow harness 実装計画

## Approach

`pr-workflow` を新しい `frontier-harness`（`fh`）CLI の thin policy adapter に移行する。
CLI は Node.js 24 の ESM と `node:sqlite` を使い、global config、repository policy、Git
common directory の runtime state を分離する。provider adapter は Claude、Codex、Antigravity
を共通 event/evidence schema に変換し、初期は heuristic router と fake-adapter integration
test に限定する。

実装は既存 workflow を壊さない shadow mode から始める。`sdd`、`multi-review`、
`model-fitness-check`、`wave-orchestrator` は一度に削除せず、責務を薄くして
`execution-readiness-check` と `fh` に順次移す。GitHub/git 操作は既存 specialist skill を
呼び続ける。

## Progress

- 2026-08-27: Step 1 の Homebrew cask 導入と Antigravity settings の target apply を完了。`agy` の interactive keychain login と authenticated model discovery は user action 待ち。
- 2026-08-27: Step 2 の shadow-mode foundation を実装。`fh doctor/onboard/run/status/verify/review/clean`、SQLite route/evidence state、raw-evidence retention、Node/Bats regression test を追加。
- 2026-08-27: `execution-readiness-check` と `frontier-harness` skill の draft、`model-fitness-check` compatibility shim、canonical/mirror documentation を追加。既存 orchestrator の全面移行、provider write adapter、wave batch authorization は未完了。
- 2026-08-28: PR #478 のレビュー指摘に対応。(1) AC-034 の shim 契約を実装し直した —— `pr-workflow` / `sdd` / `multi-review` は `execution-readiness-check` と `model-fitness-check` の**両方**を呼ぶ（floor 判定を readiness gate で置き換えていたため、§4 の blocking floor gate が新経路から到達不能になっていた）。`model-fitness-check` 側にも shim 契約と削除条件を明記。(2) `findCommand` が PATH の空要素を候補にしないよう修正（untrusted repository の `agy` が `doctor --probe` で起動しうる経路）。(3) policy / readiness の書き込みを symlink 検査 + `O_EXCL` + 予測不能な一時名の共通ヘルパーに集約。(4) `doctor --probe` の readiness を既定 state root へ永続化。(5) `config.rollout` を出力値ではなく実行ガードとして消費。(6) 未指定の `hasDeterministicOracle` を安全側（oracle 無し）に倒す task 正規化を追加。(7) SQLite に schema version と migration を追加。(8) CI に `lint-node` / `test-node` を追加（Node テストが CI で一度も実行されていなかった）。Node テストは 20 → 41 件。

## File change plan

- 新規: `home/dot_local/bin/executable_frontier-harness` — `~/.local/bin/frontier-harness` へ展開する POSIX shell launcher。
- 新規: `home/dot_local/bin/symlink_fh` — `frontier-harness` を指す短縮 command。
- 新規: `home/dot_local/lib/frontier-harness/*.mjs` — CLI、schema、SQLite store、router、verifier、worktree/evidence/provider adapter の小さな ESM module 群。
- 新規: `home/dot_config/frontier-harness/config.json` — capability registry、retention、shadow/default rollout policy の non-secret global config。
- 新規: `home/dot_gemini/antigravity-cli/settings.json` — sandbox、non-workspace deny、global command deny と最小 allowlist の Antigravity config。
- 新規: `home/dot_agents/skills/frontier-harness/SKILL.md` — `/pr-workflow` から呼ばれる engine の操作契約。
- 新規: `home/dot_agents/skills/execution-readiness-check/SKILL.md` — adapter capability/availability/quota/manifest を検査する dynamic gate。
- 新規: `tests/frontier_harness.test.mjs` — fake adapter による unit/integration contract test。
- 更新: `home/dot_Brewfile` — `antigravity-cli` cask を追加。
- 更新: `Makefile` — Node test target と root test contract を追加。
- 更新: `tests/files.bats` — chezmoi source、launcher、Antigravity settings、config render の regression check。
- 更新: `home/dot_agents/skills/pr-workflow/SKILL.md` — public entrypoint と action-level gate を維持しつつ `fh` へ委譲。
- 更新: `home/dot_agents/skills/sdd/SKILL.md` — spec compiler へ縮退。
- 更新: `home/dot_agents/skills/multi-review/SKILL.md` — reviewer registry と evidence schema 提供へ縮退。
- 更新: `home/dot_agents/skills/model-fitness-check/SKILL.md` — 2 release compatibility shim。
- 更新: `home/dot_agents/skills/wave-orchestrator/SKILL.md` — batch authorization と `fh` state の利用。
- 更新: `docs/agents/*`、`docs/architecture/*` と各 `*.ja.md` — CLI、account boundary、permissions、Evidence Bus、rollout の English canonical/Japanese mirror。
- 新規または更新: 各改修 skill の `evals/evals.json` — representative prompt の before/after evaluation。

## Step-by-step

1. - [ ] Package and provider spike を固定する
   - Homebrew registry で確認済みの `antigravity-cli` cask を Brewfile に追加する。
   - `brew bundle` 後に `agy --version`、`agy --help`、`agy models` を実測し、model slug・headless JSON/NDJSON・settings location を config/adapter contract に反映する。
   - interactive account login は user が一度だけ実施する。`doctor` は credential value を一切出力しない。
   - 完了条件: `agy` の install、authentication readiness、headless behavior、sandbox/permission の事実が source/test/doctor の期待値と矛盾しない。

2. - [ ] ランタイムの土台と test contract を先に作る
   - shell launcher は Node runtime を `mise which node` で解決し、実装本体 `~/.local/lib/frontier-harness/cli.mjs` を exec する。
   - module は `cli.mjs`、`config.mjs`、`schema.mjs`、`state-store.mjs`、`errors.mjs`、`paths.mjs` に分ける。global config は JSON とし、runtime 依存を追加しない。
   - `git rev-parse --git-common-dir` を使って shared state root を解決し、database permission と atomic migration を fail closed にする。
   - Node built-in test runner を Makefile contract に入れ、Bats から deploy shape を検査する。
   - 完了条件: `fh doctor` と `fh status` が fake repository/state で動き、schema migration と invalid config の failure が test される。

3. - [ ] Task、evidence、verification、retention schema を実装する
   - Task/route/adapter run/evidence/verification/review/approval/telemetry の table と JSON schema validator を追加する。
   - evidence は content hash、producer、command、exit code、artifact path、claim を持つ。transcript/chain-of-thought を field に持たない。
   - raw artifact 30 日、aggregate telemetry 180 日の prune を `fh clean` に実装する。削除対象を dry-run で表示してから実行し、state DB の migration/aggregation を transaction 化する。
   - 完了条件: fake artifact、old timestamp、hash collision、missing file の retention/error path が unit test される。

4. - [ ] Provider adapter と capability registry を実装する
   - `codex-adapter.mjs` は existing launcher と `shared`/`agent` profile を使い、read/write mode と JSONL output を normalized event に変換する。
   - `claude-adapter.mjs` は existing launcher/account env を尊重する。明示的な model/effort と fresh-context review mode を registry から受け取る。
   - `antigravity-adapter.mjs` は `agy -p`、JSON/stream-json、`--model`、`--effort`、`--sandbox` を使う。personal scope 以外は mapping がない限り unavailable を返す。
   - `fake-adapter.mjs` は availability、tool event、patch/evidence、failure を制御可能にし、実 credential/ quota を使わない。
   - 完了条件: provider process を起動せずに availability、structured output parse、unavailable fallback、account-scope fail-closed が test される。

5. - [ ] Onboarding、action-level permission、heuristic router を実装する
   - `fh onboard` は manifest candidate を検出して表示し、user approval 後に repository policy へ task hash/command/domain/capability を保存する。
   - unknown capability は deny + queue とし、task 内の追加 approval を発生させない。wave は queue を batch approval として消費できる。
   - router は modality、risk、scope、oracle の有無、adapter availability、repeated failure、information gain、verification result を入力にし、explainable route decision/evidence を保存する。
   - security、migration、external contract、deploy/release、force push、credential、merge を unconditionally escalate にする。
   - 完了条件: simple task は single executor、frontend/browser task は Antigravity candidate、oracle 不足/高 risk は cross-model review、unknown command は queue になることを test する。

6. - [ ] Verifier、review registry、candidate worktree integration を実装する
   - package-manager/config から approved deterministic checks を選び、command result を evidence として保存する。
   - writable diversified route のみ `wtp` child worktree を作る。primary worktree/PR branch は `pr-workflow` が owner のままにする。
   - verification pass かつ clean apply の candidate patch だけを primary に適用する。multiple pass は fresh-context judge に evidence/diff だけを渡し、conflict/tie/failure は candidate を保持して escalate する。
   - `fh review` は `multi-review` registry の rubric/findings schema を利用し、writer transcript を渡さない。
   - 完了条件: fake worktree provider を用いて isolation、candidate selection、clean apply、conflict retention、cross-model handoff を integration test する。

7. - [ ] Skill graph を compatibility-first に移行する
   - `execution-readiness-check` を追加し、`model-fitness-check` を shim にする。shim の removal condition と deprecation output を明記する。
   - `pr-workflow` は entrypoint/action gate、`sdd` は spec compiler、`multi-review` は reviewer registry に役割を限定する。
   - `monitor-ci`、`review-resolve-loop`、`commit`、`create-pr` は既存 executor を維持し、normalized results を `fh` に渡す。
   - `wave-orchestrator` は wave plan 時の batch authorization、child task hash 検証、shared `fh` state を扱う。merge などの無条件 escalation は維持する。
   - 完了条件: skill provenance test が pass し、明示 invocation/legacy call が compatibility shim で動き、static role/always-review の古い契約が残らない。

8. - [ ] Shadow rollout、documentation、skill eval を完了する
   - global config は `shadow` を default とし、existing workflow を変えずに recommended route/evidence/verification outcome を記録する。
   - `--legacy` を deterministic rollback として実装し、pilot/default に昇格する条件を telemetry と config で明文化する。
   - English canonical docs と Japanese mirrors を更新し、Antigravity onboarding、personal/r06 boundary、manifest、retention、worktree model、operator commands を説明する。
   - 新規/改修 skill の eval prompts を作成し、旧 skill snapshot と before/after comparison を実施する。
   - 完了条件: `make test`、Node test、Bats、skill eval が pass し、`fh doctor` の実機 smoke と shadow-mode dry run が成功する。

## Risk

- Antigravity CLI の version/model slug/permission format は変動する。`doctor` と strict availability check で fail closed にし、model registry を独立させる。
- `agy` の global settings が repository 固有 command を過度に許可しうる。repository onboarding manifest は allow candidate として扱い、global policy は最小 command set と明示 deny を維持する。
- worktree 間で runtime state が分裂すると candidate/evidence 選択が壊れる。Git common directory を唯一の runtime state root にする。
- raw artifacts は機微な log を含みうる。permissions、transcript 非保存、30-day retention、dry-run prune を必須にする。
- skill 文面を一括変更すると public behavior が崩れる。shadow mode、compatibility shim、representative prompt eval、`--legacy` rollback を使う。
- Homebrew cask install と interactive authentication は host state を変更する。source/test を先に追加し、install/login/result を evidence として記録する。

## Estimated effort

総見積: large（複数 PR 相当）。

- Provider spike と Homebrew/Antigravity configuration: 0.5–1 日
- Core CLI/state/schema/fake adapter tests: 2–3 日
- Router/onboarding/verifier/worktree integration: 2–3 日
- Skill graph migration/compatibility: 2–3 日
- Documentation, skill eval, shadow/pilot validation: 1–2 日

## AC coverage

| Step | PRD acceptance criteria |
|---|---|
| 1 | AC-011–016, AC-038 |
| 2 | AC-001–005, AC-039 |
| 3 | AC-004, AC-021, AC-024, AC-037 |
| 4 | AC-005–006, AC-009–010, AC-013–016, AC-038–039 |
| 5 | AC-007–008, AC-017–020, AC-023 |
| 6 | AC-021–030, AC-039 |
| 7 | AC-031–035, AC-040 |
| 8 | AC-036–041 |
