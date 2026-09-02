---
slug: frontier-harness-pr-workflow
feature: Multi-frontier PR workflow harness
created_at: 2026-08-27T17:07:25+09:00
grill_session: acbedca2-4e7b-4476-aeb8-fcc729dad772
status: finalized
---

# Background

現在の `pr-workflow` は tier ごとの固定 phase、固定された model role、常時の
`multi-review` を中心に構成されている。`sdd` も worktree・worker 選択・実装・PR 作成を
抱え、実行責務が複数 skill に分散している。

この構成を、Claude、Codex、Antigravity を異種 adapter として使う model-independent
harness へ置き換える。モデル名や固定 role ではなく、task state、capability contract、
検証可能な evidence、risk、cost、availability に基づいて route する。

利用者向けの入口は `/pr-workflow` を維持する。新しい global CLI `frontier-harness`
（短縮名 `fh`）が task lifecycle、routing、Evidence Bus、verification、telemetry を実行し、
既存 skill は policy、spec、GitHub/git の専門 executor として責務を絞る。

# User Story

開発者として、単一 task も wave で並列化した複数 task も、最初から固定した model pipeline
に縛られずに実行したい。実装・review・browser/visual verification の各段階で、実行結果と
証跡を根拠に最小限の adapter を選び、危険な操作だけを確実に止めたい。

また、会話 context が失われても、決定・制約・acceptance criteria・却下理由をこの PRD から
復元できなければならない。

# Acceptance Criteria

## Core engine

- AC-001: Node.js 24 と `node:sqlite` だけで動く global CLI `frontier-harness` / `fh` を配備する。追加の runtime や build tool を必須にしない。
- AC-002: CLI は `doctor`、`onboard`、`run`、`status`、`verify`、`review`、`clean` だけを初期 public command とする。DB の直接操作や内部 route 操作は public API にしない。
- AC-003: global 設定は `~/.config` 配下、repository policy/schema は `.harness/` 配下、実行 state は Git common directory 配下に分離する。worktree ごとに state が分裂してはならない。
- AC-004: task、route decision、adapter run、evidence、verification result、review finding、approval、telemetry を SQLite の正規化された schema で記録する。
- AC-005: adapter interface は provider 固有の CLI を抽象化し、router が vendor command、credential、profile path を知らない構造にする。
- AC-006: capability registry は exact model ID と effort を保持し、router は `executor.default`、`executor.hard`、`semantic.judge`、`frontend.primary` などの capability name のみを選択する。adapter は実行前に model availability を検査する。
- AC-007: 初期 router は explainable な heuristic に限定する。contextual bandit などの learned router は、100 件以上の意味ある task trajectory が蓄積されるまで実装しない。
- AC-008: router は initial classification だけで固定せず、tool failure の反復、information gain の低下、scope expansion、verification regression、不確実性、risk を用いて continue / escalate / diversify を判断する。

## Providers and account boundaries

- AC-009: Codex は既存 launcher と `agent` / `shared` profile を通じて adapter 化し、write run は isolated worktree に限定する。既存の Codex account-isolation と profile SSOT を壊さない。
- AC-010: Claude は ambiguity reduction、architecture/root-cause analysis、fresh-context semantic review の初期 capability provider として adapter 化する。初期 capability registry は既存 Claude pin を bootstrap 値として参照するが、既存 settings を harness が書き換えない。
- AC-011: Homebrew `antigravity-cli` cask を `home/dot_Brewfile` で管理し、既存 `brew bundle` lifecycle で `agy` を導入・更新する。非固定の公式 install script を chezmoi lifecycle から実行しない。
- AC-012: Antigravity は OS keychain に保存された対話ログインを使う。API key、credential、token profile を dotfiles、environment、harness DB に保存しない。
- AC-013: Antigravity adapter は `agy` の headless JSON/NDJSON protocol、model selection、conversation ID、structured result を Evidence Bus に取り込む。
- AC-014: Antigravity は初期から frontend/browser task の primary writable implementer 候補に含める。Codex はその他の implementation default とするが、この割当は eval で更新可能な bootstrap policy である。
- AC-015: Antigravity の global policy は sandbox 有効、non-workspace access 拒否、最小 allowlist、`sudo`・破壊的削除・任意 `curl` の deny を含む。`--dangerously-skip-permissions` を使わない。
- AC-016: `r06` profile では、vendor-supported で検証済みの別 Antigravity account mapping がない限り Antigravity adapter を unavailable として fail closed にする。personal credential へ自動切替・credential 複製・環境変数上書きをしてはならない。

## Permission and approval model

- AC-017: `fh onboard` は repository ごとに build/test/lint command、browser domain、capability を検出し、capability manifest として一度だけ user 承認を得る。承認済み manifest は同 repository の後続 task で再利用する。
- AC-018: unknown command/domain は実行せず queue に記録する。wave 実行中は task ごとに質問せず、wave boundary でまとめて承認できる。
- AC-019: local edit、test、temporary worktree、検証済み candidate patch の local apply は自動実行できる。merge、release/deploy、force push/history rewrite、credential、migration apply、未承認 external side effect は必ず escalation する。
- AC-020: standard/large の intent approval は維持する。`wave-orchestrator` は task hash に束縛した intent/scope/capability の一括 authorization を発行でき、child workflow は hash が一致する場合だけそれを消費する。security、migration、external contract change、hash 変更は個別に停止する。

## Evidence and verification

- AC-021: Evidence Bus の primary interface は source/diff、command result、test failure、trace、benchmark、screenshot、browser recording、accepted decision とする。writer の hidden reasoning、会話 transcript、自己正当化を次 adapter へ常時渡してはならない。
- AC-022: deterministic verifier を最上位の completion oracle にする。test、typecheck、lint、browser assertion、performance check を policy に応じて実行し、LLM の完了宣言だけでは task を成功扱いにしない。
- AC-023: deterministic oracle がない task は single-worker success として accept せず、independent cross-model review へ昇格する。
- AC-024: raw log、screenshot、browser recording は 30 日で自動削除する。内容を含まない aggregate telemetry は 180 日保持する。chain-of-thought と全文 transcript は保存しない。
- AC-025: writer と異なる provider family を reviewer に選び、reviewer へ task、constraints、diff、verification evidence だけを渡す。review finding は actionable evidence、severity、uncertainty、discriminating experiment を持つ schema に正規化する。

## Worktrees, candidate patches, and review

- AC-026: `pr-workflow` は primary worktree と PR branch の唯一の owner であり続ける。engine は複数 writable route が必要な場合だけ `wtp` で disposable child worktree を作る。read-only route は worktree を増やさない。
- AC-027: child worktree の candidate patch は verifier を通し、primary に clean apply できる場合だけ自動で primary worktree に統合できる。複数 pass した candidate は fresh-context judge が evidence と diff を比較して選ぶ。
- AC-028: verification failure、apply conflict、同点での判断不能では candidate patch を保持して escalation する。candidate branch の削除は自動実行せず cleanup queue に残す。
- AC-029: `multi-review` は static mandatory phase ではなく、reviewer roster、rubric、finding schema を提供する registry へ縮退する。engine は risk、verification failure、uncertainty、diff 特性に応じて選択的に呼び出す。
- AC-030: `commit`、`create-pr`、`monitor-ci`、`review-resolve-loop` は git/GitHub の専門 executor として維持し、engine は normalized event/result を利用する。同等の外部操作を engine が再実装しない。

## Skill migration and rollout

- AC-031: `/pr-workflow` は利用者向け entrypoint を維持し、thin policy adapter として `fh` を呼び出す。
- AC-032: `/sdd` は requirements/design/task decomposition を生成する spec compiler へ縮退する。worktree、worker selection、implementation、commit、PR 作成を所有しない。
- AC-033: `execution-readiness-check` を新しい dynamic gate とする。capability、availability、quota、permission manifest を検証し、session model だけを理由に block しない。
- AC-034: `model-fitness-check` は 2 release の間、`execution-readiness-check` を呼ぶ compatibility shim として残す。**（#503 で達成・撤去済み）** 撤去条件（全 caller の readiness gate 直接呼び出し + pilot telemetry）を満たしたため shim を除去した。§4 contract と over-provision gate は撤去対象外で、`tests/files.bats` の floor 生存テストが機械検証する。
- AC-035: `wave-orchestrator` は `fh` の state と batch approval を利用し、可逆な routine decision は代理応答できる。merge 等の無条件 escalation と一次ソース検証の安全契約は維持する。
- AC-036: rollout は shadow mode（既存 workflow を維持し route/evidence を記録）→ pilot repository → default の順に進める。`--legacy` で旧 path に戻せること。

## Quality, observability, and documentation

- AC-037: telemetry には task category、scope、risk、provider/model/effort、wall clock、token usage、tool result、verification result、review precision、human correction、rollback、merge/post-merge outcome を含める。
- AC-038: `fh doctor` は adapter executable、authentication readiness（secret を出力しない）、model availability、account scope、permission manifest、state schema を検査し、unavailable provider を明示する。
- AC-039: fake adapter を使う unit/integration test により router、evidence schema、retention、approval hash、worktree selection、candidate apply、unavailable fallback を検証する。実 provider の quota/credential を test に使わない。
- AC-040: 新規・改修 skill には代表 prompt の before/after eval を用意し、router/skill behavior の regression を確認する。
- AC-041: source code、SKILL.md、script comment は repository policy に従い日本語で書く。English canonical docs と Japanese mirror を更新し、CLI の境界、account isolation、permission onboarding、Evidence Bus、rollout を説明する。

# Considered Alternatives / Rejection Rationale

| Decision | Rejected alternative | Rationale |
|---|---|---|
| AC-001/003 | Python の独立 application と per-worktree `.harness/db.sqlite` | Node 24 と `node:sqlite` は既存 runtime であり追加 build が不要。per-worktree DB は evidence を分裂させる。 |
| AC-006/007 | model name と固定 role を `pr-workflow` に埋め込み、最初から learned router を導入 | model pool は短期間で変わる。初期データなしの learned policy は不透明かつ誤 route を起こす。 |
| AC-011 | 公式 `curl | bash` installer を `chezmoi apply` で実行 | Homebrew `antigravity-cli` cask は実バイナリと version が確認でき、既存 package lifecycle に整合する。 |
| AC-012 | Gemini API key を source/env/DB に保持 | account keychain auth で十分であり、secret を永続化する必要がない。 |
| AC-015/017/018 | task ごとの permission approval または全権限 auto-approve | task ごとの approval は wave の並列運用を止める。`--dangerously-skip-permissions` は安全境界を失わせる。repository onboarding と batch approval を採用する。 |
| AC-016 | r06 task で personal Antigravity credential へ自動 fallback | account、billing、data boundary をまたぐため fail closed にする。 |
| AC-021/024 | transcript/chain-of-thought の常時共有・長期保持 | anchoring、context bloat、機微情報の長期滞留を増やす。facts/evidence と集計 telemetry に限定する。 |
| AC-026/028 | shared working tree、candidate branch の自動削除 | concurrent write が衝突する。未選定 candidate の削除は復旧可能性を下げる。 |
| AC-029 | 全 PR に固定 multi-review | simple task の費用・待ち時間を増やす。risk/uncertainty based escalation を採用する。 |
| AC-031--035 | `pr-workflow`、`sdd`、`multi-review` を一度に削除 | public entrypoint と既存 executor を壊す。compatibility shim と staged rollout を採用する。 |

# Out of Scope

- 100 task trajectory 未満での learned router、contextual bandit、end-to-end RL。
- Antigravity の未検証な r06 / multi-account mapping。
- merge、release、deploy、force push、migration apply の自動化。
- API key を使う Antigravity headless/CI authentication。
- raw transcript/chain-of-thought の保存、共有、学習利用。
- GitHub/git executor の API 実装を `fh` に再実装すること。
- child candidate branch の無承認な自動削除。

# Open Questions

- ~~`execution-readiness-check` と `model-fitness-check` shim の正確な 2 release 判定方法（versioning scheme と retirement signal）。~~ **解決（#503）**: release 数ではなく撤去条件そのものを retirement signal とした —— (1) `rollout` が `pilot` 以降であること、(2) `pr-workflow` / `sdd` / `multi-review` が `/execution-readiness-check` を直接起動すること、(3) `wave-orchestrator` が Phase 0 で `fh doctor --json` と `fh onboard` を自ら通すこと。3 点とも実測で確認したうえで撤去した。
- Claude/Codex/Antigravity の non-interactive invocation ごとの最終 model ID、effort、timeout、quota source。registry は `doctor` と eval により実測して初期値を確定する。
- Antigravity の project-scope permission を headless workflow から宣言的に管理できる公式 API/file location。初期版は documented global settings と onboarding manifest の組み合わせを使う。
- repository の package-manager/config から test/lint/build command を安全に検出する allowlist と、domain allowlist の candidate generation 規則。
- raw evidence prune を起動する scheduler と、180 日 telemetry aggregation の正確な削除/compaction strategy。
- `fh review` が既存 `multi-review` skill と standalone/PR workflow のどちらで呼ばれたかをどう表現するか。
- pilot repository の選定、shadow mode の exit criteria、100 meaningful trajectory の数え方。
