---
name: frontier-harness
description: |
  Claude、Codex、Antigravity を capability と evidence に基づいて route する
  `frontier-harness` / `fh` の運用 skill。複数 frontier model の実行、dynamic routing、
  Evidence Bus、adapter readiness、shadow rollout、candidate patch の選定、または
  `fh doctor` / `fh onboard` / `fh run` / `fh status` / `fh verify` / `fh review` /
  `fh candidate` / `fh clean` が必要な task では、明示指定がなくても必ず使用する。
argument-hint: "<doctor|onboard|run|status|verify|review|candidate|clean> [args]"
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

## route の記録

task JSON には少なくとも `goal`、`modality`、`risk`、`hasDeterministicOracle` を含める。
人の判断が必須の task には `requiresApproval: true` を、書き込みを伴う task には
`requiresWrite: true` を付ける（どちらも省略時は `false`）。

```bash
fh run --task <task.json> --json
fh status --json
```

route は以下を守る。

- browser task は personal scope で利用可能な Antigravity を初期候補にする。
- 通常 implementation は Codex default capability を候補にする。
- deterministic oracle がない task は independent reviewer を追加する。
- credential、migration、deploy、external contract、force push、merge、release は無条件 escalation にする。
- `requiresApproval` の task は、承認要求を外部へ往復できる provider（`approvalChannel` が
  `external`）へしか route しない。Codex の agent review も Antigravity の無言のソフト拒否も
  人の gate ではないので、要求を満たさない。
- `requiresWrite` の task は、封じ込めを保証できる provider（`writeAccess` が `supported`）へしか
  route しない。Antigravity は `--sandbox` を付けても書き込みを止められないため対象外である。
- 塞いだ route は捨てずに記録する。browser task のように既存の fallback（frontend が使えない
  ときの Codex default capability）がある場合はそちらへ回し、fallback が無い場合は provider を
  起動せず escalation にする。承認チャネルを理由に capability の役割（executor / reviewer /
  frontend）を跨いだ代替はしない。
- 塞いだ route は `route_block` evidence として task と route に紐付けて残る。`fh run --json` の
  `blocked` と `blockEvidence` から、どの capability のどの provider がどの軸で外れたかを追える。

## 決定的な検証

完了判定の根拠を model の自己申告より上に置く。`fh verify` は承認済みのチェックを**実際に走らせ**、
終了コードを `verification_results` に記録する。

```bash
fh verify --task <task id> --command "npm run test" --json
fh verify --task <task id> --command "npm run lint" --kind lint --json
fh verify --task <task id> --candidate <candidate id> --command "npm run test" --json
```

- コマンドは承認済み manifest に載っているものだけが走る。未承認なら `fh gaps` に積んで終了コード 2。
- シェルを介さない。harness はチェックの stdout / stderr を受け取らず、判定材料は終了コードだけ。
- `fh verify` が 0 を返すのは**チェックが通ったとき**だけ。赤・時間切れ・起動失敗はすべて非 0。
- task id は `fh run` が印字する。検証結果は必ず何かの検証なので、task なしでは記録しない。

「テストは通っている」と書く前に、その task の `fh verify` が 0 で終わっていることを確かめる。

## review registry

レビューは散文ではなく正規化された finding として扱う。

```bash
fh review packet --task <task id> --out <abs path> --json   # reviewer へ渡すものを組み立てる
fh review record --task <task id> --findings <abs path> --json  # 返ってきた finding を登録する
```

- **packet に入るのは task・制約・差分・検証結果の 4 つだけ**。writer の会話履歴・prompt・transcript は
  渡さない（`buildReviewPacket` にそれらを渡す引数が無い）。
- reviewer を実際に走らせるなら `fh session` を使う。provider を起こす経路を別に作らない。
- finding は severity / uncertainty / 1 行の要約 / 反証実験だけを持つ。レビュー本文を summary へ
  貼らない（長さと 1 行制約で拒否される）。
- `must` が 1 件でもあれば verdict は `blocked` で終了コードは非 0。0 と読んで先へ進めない。

## candidate worktree

書き込みを伴う多様化ルートには、使い捨ての子ワークツリーを与える。

```bash
fh candidate create --task <task id> --json
fh candidate adopt --candidate <id> --json
fh candidate discard --candidate <id> --json
```

- primary worktree と PR ブランチは `pr-workflow` の所有物。candidate はそれを置き換えない。
- 取り込めるのは、**その candidate に対して**記録された決定的チェックがすべて通ったものだけ。
  チェックは `fh verify --candidate <id>` で走らせる（`--worktree` でツリーを直接指すと、
  policy.json が未コミットのとき承認境界が正しく止める）。
- 合格した**後に** candidate のツリーへ書き込むと、取り込みは断られる（tree hash が食い違うため）。
  書き換えたら `fh verify` をやり直す。**チェックの実行中**に書き換えた場合も、結果は `errored`
  になる（どのツリーについての判定でもないため）。
- `fh candidate discard` は冪等。撤去が途中で失敗してツリーだけ残った場合も、もう一度叩けば片付く。
- 承認済みコマンドの実行はサンドボックスされない。`npm run test` を承認することは、その時点の
  `package.json` が書いてある内容を自分の環境で実行してよい、という意味になる。未検証の差分を
  抱えた candidate を検証するときは、この点を踏まえること。
- **衝突したら捨てない。** `conflicted` にしてツリーを保持し、終了コード 2 で user の判断へ戻す。
  自分で rebase したり衝突を解決したりしない。
- 取り込みは patch の適用まで。commit も push もしない。

## Evidence と cleanup

次 agent には diff、test result、log、trace、screenshot、browser recording、accepted decision を渡す。
writer の hidden reasoning、全文 transcript、自己正当化を渡してはならない。

```bash
fh clean --dry-run --json
fh clean --json
```

raw evidence と実行系レコード（adapter run / verification result / review finding）は 30 日、
内容を含まない aggregate telemetry は 180 日が既定である。`clean` は両方の窓を処理して
クラスごとの対象数を報告し、`--dry-run` では state を変更しない。承認記録（approvals）は
監査証跡なのでどちらの窓にも属さず、`clean` では削除されない。

## Human gate

local edit、test、temporary worktree、検証済み candidate patch の local apply は自動でよい
（`fh candidate adopt` が検証を確かめてから適用する）。
merge、release/deploy、force push/history rewrite、credential、migration apply、未承認 external
side effect は user に上げる。wave 実行では onboarding と intent を task ごとに聞かず、
wave boundary の batch approval を使う。
