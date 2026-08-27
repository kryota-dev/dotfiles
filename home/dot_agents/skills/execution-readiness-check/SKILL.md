---
name: execution-readiness-check
description: |
  `pr-workflow`、`sdd`、`multi-review`、wave 実行の前に、選択した adapter の capability、
  executable、account scope、rollout、quota、repository capability manifest を確認する dynamic gate。
  現在の session model だけではなく、実行 route の readiness を検証する必要がある場合に必ず使用する。
argument-hint: "<task JSON または route context>"
user-invocable: true
---

# execution-readiness-check

この gate は current session が特定 model かどうかを判定しない。`fh doctor --json` と task state を
根拠に、選択済み adapter がその account scope と rollout で実行可能かを確認する。

## 手順

1. `fh doctor --json` で required capability の status を読む。
2. required adapter が unavailable なら route から除外する。別 account への自動切替、credential の
   読み出し、model 名の推測をしない。
3. repository command/domain が manifest に無ければ実行せず queue に記録する。wave 中は batch approval
   へ集約する。
4. `shadow` では route/evidence だけを記録する。provider write や external operation を実行しない。
5. security、migration、external contract、credential、deploy/release、force push、merge は capability が
   available でも user escalation を維持する。

## 出力

次のいずれかを簡潔に報告する。

- `ready`: capability と manifest が揃い、rollout policy が許可する。
- `shadow`: capability は揃うが provider 実行はしない。
- `unavailable`: executable/account/model/permission のどれが欠けるかを示す。
- `escalation`: risk category と user 判断が必要な理由を示す。

model 名や quota の推測値を SSOT にしない。`frontier-harness` の capability registry と `doctor` の実測を
優先する。
