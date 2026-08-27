---
name: model-fitness-check
description: |
  旧 `model-fitness-check` 呼び出しのための compatibility shim。`pr-workflow`、`sdd`、
  `multi-review`、wave の既存 invocation を壊さず、adapter capability、account scope、
  rollout、permission manifest を検査する `execution-readiness-check` へ移行させる。
  現在の session model だけを理由に block する用途では使わず、互換目的でのみ使用する。
argument-hint: "<legacy tier または task context>"
user-invocable: true
---

# model-fitness-check（互換 shim）

この skill は 2 release の移行期間だけ残す。new workflow は
`/execution-readiness-check <task context>` を直接起動すること。

## 移行規約

1. 受け取った legacy tier/context を task route の補助情報として扱い、current Claude session の
   model/effort だけで pass/fail を決めない。
2. `/execution-readiness-check` を起動し、`fh doctor --json`、adapter account scope、rollout、
   repository capability manifest、risk category を検査する。
3. adapter unavailable、未承認 capability、quota 不足は fail closed にする。personal Antigravity
   credential への account crossing はしない。
4. credential、migration、external contract、deploy/release、force push、merge は session/model に
   かかわらず user escalation を維持する。

## 出力

互換 shim であることを一行で示し、`ready`、`shadow`、`unavailable`、`escalation` のいずれかを
`execution-readiness-check` の結果として報告する。旧 model floor、over-provision counter、
quota snapshot をこの skill に再導入してはならない。
