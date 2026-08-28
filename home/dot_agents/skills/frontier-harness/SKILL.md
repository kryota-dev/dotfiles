---
name: frontier-harness
description: |
  Claude、Codex、Antigravity を capability と evidence に基づいて route する
  `frontier-harness` / `fh` の運用 skill。複数 frontier model の実行、dynamic routing、
  Evidence Bus、adapter readiness、shadow rollout、candidate patch の選定、または
  `fh doctor` / `fh onboard` / `fh run` / `fh status` / `fh verify` / `fh review` /
  `fh clean` が必要な task では、明示指定がなくても必ず使用する。
argument-hint: "<doctor|onboard|run|status|verify|review|clean> [args]"
user-invocable: true
---

# frontier-harness

`fh` は provider 固有の会話履歴ではなく、task state と検証可能な evidence を正本にする。
利用者向け workflow は `/pr-workflow` のままにし、ここでは engine の状態・route・安全境界を扱う。

## 事前確認

1. `fh doctor --json` を実行し、adapter executable、account scope、capability、rollout を確認する。
2. `frontend.primary` が `r06` で unavailable のときは personal credential へ切り替えない。Antigravity が必須なら user に account mapping を依頼して停止する。
3. `shadow` rollout では provider を実行しない。route と evidence の記録だけを行う。
4. `fh` の state は Git common directory に置かれる。worktree ごとの `.harness/` state を作らない。

## Repository onboarding

repository 固有 command や browser domain は task ごとに承認しない。まず manifest candidate を提示し、
user が内容を確認してから `--approve` を付ける。

```bash
fh onboard --manifest <candidate.json>
fh onboard --manifest <candidate.json> --approve --json
```

manifest は build/test/lint command、browser domain、capability のみを含める。secret、token、
full transcript、任意 shell command を含めない。未知 capability は実行せず queue に残す。

## Shadow route

task JSON には少なくとも `goal`、`modality`、`risk`、`hasDeterministicOracle` を含める。

```bash
fh run --task <task.json> --json
fh status --json
```

route は以下を守る。

- browser task は personal scope で利用可能な Antigravity を初期候補にする。
- 通常 implementation は Codex default capability を候補にする。
- deterministic oracle がない task は independent reviewer を追加する。
- credential、migration、deploy、external contract、force push、merge、release は無条件 escalation にする。

## Evidence と cleanup

次 agent には diff、test result、log、trace、screenshot、browser recording、accepted decision を渡す。
writer の hidden reasoning、全文 transcript、自己正当化を渡してはならない。

```bash
fh clean --dry-run --json
fh clean --json
```

raw evidence は 30 日、aggregate telemetry は 180 日が既定である。`clean` は対象数を報告し、
`--dry-run` では state を変更しない。

## Human gate

local edit、test、temporary worktree、検証済み candidate patch の local apply は自動でよい。
merge、release/deploy、force push/history rewrite、credential、migration apply、未承認 external
side effect は user に上げる。wave 実行では onboarding と intent を task ごとに聞かず、
wave boundary の batch approval を使う。
