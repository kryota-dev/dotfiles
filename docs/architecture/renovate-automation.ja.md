# Renovate 自動化: マージゲート

[English canonical](renovate-automation.md)

依存更新は人手を介さずにマージされる。Renovate PR は月におよそ 55 件流れるが、
機械的に判定しきれない何かがない限り、どれも承認を待たない。

このページは、何がそれを通しているのか、安全網がなぜ黙って外れないのか、
そしてリポジトリではなく GitHub UI 側に置いた唯一の設定について述べる。

## 更新がたどる経路

```
Renovate が PR を作成
  └─ GitHub ネイティブ auto-merge をキュー（platformAutomerge の既定は true）
  └─ renovate-gate.yml が起動
       ├─ 作者が Renovate でない ─────────────► status: success（人間の PR を塞がない）
       ├─ renovate-gate-classify.sh が pass ──► status: success
       └─ needs-agent ─► エージェントが審査 ─► 判定をローカルファイルに記録
                                              └─ ワークフローがそれを status に変換
                                                   ├─ pass ► success
                                                   ├─ fail ► failure ＋ メンション付きコメント
                                                   └─ 不在 ► failure
  └─ ruleset が全 required check の通過までマージを保持
       └─ 全緑   ► auto-merge が実行される
       └─ 保留   ► オーナーが PR をレビュー
            ├─ Approve         ► status が success に変わる
            └─ Request changes ► 本文で分岐: PR をクローズ、または保留のまま
```

週次では `renovate-digest.yml` が、何がマージされ何が実際に知る価値があるかを
Dependency Dashboard（Issue #12）に投稿する。

## 決定論ゲートが通すもの・通さないもの

`scripts/renovate-gate-classify.sh` は、シェルのみで「エージェント審査を省いてよい
ありふれた更新か」を判定する。これはリスクスコアではなく**更新の形に基づく
allowlist** であり、差分の小ささを根拠にはしない。

| 更新 | 判定 | 理由 |
| --- | --- | --- |
| `update dependency gh to v2.99.0` | `pass` | 名前付き依存のタグ付き 3 桁 semver リリース、1 ファイル、`+1/-1` |
| `update anthropics/skills digest to 5304866` | `needs-agent` | digest は移動する `main` を追従する。1 行の裏に upstream の任意の変更がある |
| `update nginx:… docker digest to a9ae6f6` | `needs-agent` | コンテナイメージでも同じ |
| `update …/claude-code-action action to v1.0.214` | `needs-agent` | 長期トークンを握って CI で走る |
| `update dependency java to v25` | `needs-agent` | 3 桁 semver ではない major |
| `update deno monorepo to v2.8.3` | `needs-agent` | グループ更新であり単一の名前付き依存ではない |
| `update dependency somelib to v3.0.0`（`2.9.0` から） | `needs-agent` | メジャー更新。タイトルだけでは分からないため旧バージョンを差分から読む |
| `update dependency npm:agent-browser to v0.36.0`（`0.35.2` から） | `needs-agent` | semver 上、`0.x` のマイナー更新は破壊的変更を許す |
| `home/dot_config/mise/config.toml` 以外の pin | `needs-agent` | fast lane に乗れるのは明示的に起動する道具だけ（後述） |
| 解釈不能なもの、`gh` の呼び出し失敗 | `needs-agent` | 判定不能は決して「安全」ではない |

**fast lane の範囲は、どの依存かではなく pin がどこに置かれているかで決まる。**
`update dependency phone-harness to v1.2.3` は `update dependency gh to v2.99.0` と
形が完全に同一だが、一方はロック解除された端末に HID 入力を合成する Python を配布する。
危険な依存を名指しする方式は、ツールが入れ替わるまでしか保たない。このリポジトリは既に
その線を構造として引いている: `home/dot_config/mise/config.toml` にはあなたが明示的に
起動する道具が、`home/.chezmoidata.toml` には環境の一部として勝手に走るもの —— ECC の
hook コード、phone-harness、skill アーカイブ —— が置かれている。コンテナイメージと
ワークフローの pin はさらに別の場所にある。したがって fast lane に乗れるのは mise 設定の
pin だけであり、そこに CLI を足せば自動的に対象になり、**誰も想定していなかった置き場所は
既定でマージではなく審査に倒れる。**

**タイトルだけでは patch と major を区別できない。** Renovate のタイトルは新バージョンしか
含まないため、`to v3.0.0` と `to v2.99.0` は同じ形である。分類器は差分の削除行
（`-gh = "2.98.0"`）から旧バージョンを読んでメジャー番号を比較し、読み取れなければ
エージェントへ回す。

**1 行の差分は、変更が小さい証拠にならない。** このリポジトリが digest で pin して
いる skill アーカイブは、リリース工程を一切持たない upstream の `main` を追従して
おり、中身はエージェントへの指示そのものである Markdown だ。`renovate.json5` の
コメント自身が prompt injection の経路として名指ししている。fast lane を allowlist
にしてあるのはそのためで、Renovate が将来新しいタイトル形式を作っても既定で
エージェントへ落ちる。

**CI の状態は意図的に判定に含めない。** ゲートは PR が開いた瞬間に走る一方 Test
ジョブは数分かかるため、チェックの集計を読むとほぼ全 PR が「実行中」となり、
決定論レーン全体がエージェントへ流れてしまう。さらにゲート自身の status が同じ
集計に現れるため自己参照でもある。代わりに CI チェックをゲートと並べて required
check に登録し、マージにはその全部を要求する。**ゲートを通ることはマージでは
ない。**

## 安全網が自分で外れない理由

未審査の更新がマージされるまでに、独立した 3 つが同時に壊れる必要がある。

1. **報告されないチェックは、通ったチェックではない。** `renovate-gate` status は
   required status check である。YAML の破損・ワークフローの無効化・障害などで
   ワークフローが走らなければ何も報告されず、ruleset が PR を pending で保持する。
2. **判定の不在は失敗である。** 報告ステップは `if: always()` で走る。エージェントが
   クラッシュ・タイムアウトして何も記録しなければチェックは失敗する。「エラーが
   無い」を「承認」とは読まない。
3. **判定不能はエージェントへ落ちる。** 決定論ゲートに「判断できなかった」から
   `pass` へ至る経路は存在しない。

## 書き込み面の分離

更新を審査するエージェントは、その更新を「審査済み」にできない。

| スクリプト | 呼び出し元 | ネットワークに到達するか |
| --- | --- | --- |
| `scripts/renovate-gate-verdict.sh` | エージェント | しない。ローカル JSON を 1 つ書くだけで `gh` も `curl` も呼ばない |
| `scripts/renovate-gate-status.sh` | ワークフローのステップのみ | する。ただしエージェントの `--allowedTools` に**入っていない** |
| `scripts/renovate-triage-comment.sh` | エージェント | Issue #12 か open な Renovate PR へのコメント作成のみ |

エージェントは判定を記録し、ワークフローが実行する。判定ファイルの `close` は
「ワークフローがこの PR をクローズすべき」という意味であって、「エージェントが
クローズした」ではない。`tests/files.bats` がこれらの不在を検証するため、
ワークフローを編集してもこの性質は残る。

これらのワークフローに `issue_comment` トリガーは存在しない。public リポジトリでは、
コメント欄に入力できる誰からでも指示を受け取ることになるからだ。

## 承認・却下・方針指示

ゲートが PR を保留すると、あなたをメンションしたコメントが届き、GitHub Slack App が
それを中継する。あとはレビュー 1 回で済む。

- **Approve** — ゲートが解除され、キュー済みの auto-merge が引き継ぐ。GitHub は
  本文の省略を許すので、これはワンタップで完了する。
- **Request changes** — 本文が意図を決める。却下と読める記述なら PR をクローズし
  （これが Renovate にそのバージョンの提案をやめさせる方法）、それ以外は方針指示と
  して扱われ、コメントで回答され、PR は保留のまま残る。GitHub はこのレビュー種別に
  本文を**必須**とするので、読むべきものが必ず存在する。

このリポジトリは public なので、誰でもレビューを送信できる。
`renovate-review-action.yml` の**最初のステップ**がレビュアーの collaborator 権限を
確認し、`admin` か `write` でなければ一切何もしない。

**digest** PR のクローズは、その upstream コミット 1 つを無視するにとどまる。
追従先ブランチに次のコミットが積まれれば新しい PR が来る。依存そのものの追従を
止めたい場合は [`.github/renovate.json5`](../../.github/renovate.json5) の
`ignoreDeps` を使う。

## GitHub UI 側に置いた設定

<!-- ruleset を意図的にコード管理しない: リポジトリ内の ruleset 定義は、
     それが本来ゲートすべき pull request 自身によって弱められうる。 -->

required status check は一度だけ手で設定する。これが無いと、ゲートは判定を報告する
だけで誰もそれに基づいて動かない。

1. **Settings → Rules → Rulesets → New ruleset → New branch ruleset**
2. **Name**: `main-protection`
3. **Enforcement status**: `Active`
4. **Bypass list**: 自分（Repository admin）を追加する。`main` への直 push を維持するため
5. **Target branches**: 既定ブランチ（`main`）を追加
6. **Rules**: **Require status checks to pass** を有効化し、次を追加する:
   - `renovate-gate` — ゲート本体
   - `Lint`, `Test`, `Sync ghq completion` — 決定論ゲートが意図的に読まない CI ジョブ。
     必須化して安全なのは `ci.yml` が **`paths:` フィルタを持たない**ためで、全 pull request
     がこれらを受け取る。ジョブを飛ばしうるフィルタは、飛ばされた PR を永久にマージ不能に
     する（走らないチェックは報告されない）。逆に必須にしないのも誤りで、auto-merge は
     required check しか待たないため、CI が赤いままマージされうる
   - `CodeQL`, `GitGuardian Security Checks` — 任意。理由は同じ
7. **Require branches to be up to date before merging** は**オフ**のままにする。
   有効にすると `main` が動くたびに Renovate が全 PR をリベースすることになり、
   auto-merge が滞る。

確認方法: 任意の pull request を開き、チェック一覧に `renovate-gate` が現れ、
Renovate 以外の PR では `success` を報告することを確かめる。

## このゲートが覆えない唯一のケース: fork からの pull request

fork からの `pull_request` で起動したワークフローは **read-only** の `GITHUB_TOKEN` を
受け取り、`permissions:` ブロックでは広げられない（GitHub 公式: 「Run workflows from fork
pull requests — using a `GITHUB_TOKEN` with read-only permission, and with no access to
secrets」）。したがって `renovate-gate` は fork PR に status を付けられず、status を必須に
した時点でその PR は pending のまま残る。

`renovate-gate.yml` はこれを検出し、説明のない 403 で落ちる代わりにジョブサマリーへ理由を
書き出す。fork の貢献をマージするには、手動で status を付けるか、このリポジトリ内の
ブランチへ載せ替える。

これは解決ではなく受容である。解決するなら `workflow_run` で起動する 2 本目のワークフローに
なる（base リポジトリのコンテキストで write 権限を持って走り、fork の head SHA に status を
報告できる）。fork からの貢献が日常になれば作る価値があるが、個人の dotfiles リポジトリでは
そうならない。

## 導入順序

ruleset が存在しないうちに automerge を有効化すると、ゲート無しで全 PR がマージ
される窓が開く。順序が重要である。

1. ゲートワークフローを入れ、実際の PR で status を報告することを確認する
2. Renovate 以外の PR で即座に `success` が付くことを確認する
3. ruleset を作成する（上記）
4. **その後にはじめて** `.github/renovate.json5` の `automerge: true` を有効化する

## 関連

- [外部依存、SHA ピン、単一 tarball キャッシュ](externals-and-pinning.ja.md) —
  digest で pin された項目が何であり、どう更新されるか
- [開発ツールチェーン: mise, Brewfile & git](dev-tooling.ja.md) —
  Renovate が更新するバージョン pin の実体
