---
slug: renovate-automerge-gate
feature: Renovate PR の全面 automerge とエージェント必須ゲート
created_at: 2026-09-03T16:29:38+09:00
grill_session: 01GUUTjcLmA6cehu7uE5SrWg
status: draft
---

# Renovate PR の全面 automerge とエージェント必須ゲート

## Background

### 現状の手間

Renovate PR のマージは、ローカルの Claude Code で `/renovate-sweep` を回して人手で承認する運用に
なっている。`.github/workflows/renovate-triage.yml` が週次でトリアージするが、**このワークフローは
マージを一切しない**（設計上の明示的な制約）ため、実際のマージは毎回ローカルセッションを起こす
必要がある。

直近 90 日（2026-06-05〜2026-09-03）に **165 件**の Renovate PR がマージされている。週あたり約 13 件。
この全件が人手を経由している。

### 現状の automerge 設定と、それが機能していない理由

`.github/renovate.json5` は既に `patch.automerge: true` / `pin.automerge: true` を持つが、実際には
ほとんど発火しない。2026-09-03 時点で open だった 7 件は 1 件も automerge に乗らなかった:

| PR | updateType | automerge されなかった理由 |
|---|---|---|
| #600 gh, #587 yazi, #584 agent-browser | `minor` | `minor: { automerge: false }` |
| #636 phone-harness, #579 claude-code-action | `digest` | packageRule で明示的に `automerge: false` |
| #595 anthropics/skills, #635 nginx | `digest` | `digest` は automerge レーンに乗っていない（`pin` とは別 updateType） |

### 調査で判明した、設計に効く事実

1. **`Setup Validation` ワークフローが `disabled_manually`**。最後の実行は 2026-07-08。これは
   `chezmoi apply` + mise install + brew bundle を実際に走らせる唯一のジョブだった。したがって
   現在の「CI 全緑」が保証するのは shellcheck / shfmt / zsh 構文 / bats / CodeQL / gitleaks のみで、
   **新しい pin が実際にインストールできるか・apply が通るかは検証されていない**。
   無効化の理由（user 談）: GHA 実行コスト、Setup Validation 自体の複雑化、そして
   **ローカル環境と CI 環境のギャップが大きく、ローカルでの実行を保証できているか疑わしい**。

2. **`main` にブランチ保護もルールセットも無い**（`GET /branches/main/protection` → 404、
   `GET /rulesets` → 空）。required status check が存在しない。Renovate は `ignoreTests: false` に
   より存在するステータスの緑を待つが、**存在しないチェックは「失敗」ではない**。ゲートの
   ワークフローが起動しなければ、Renovate から見て「赤いものは無い」となり素通しでマージされる。

3. **Merge Confidence はセキュリティチェックではない**。公式ドキュメントいわく
   「finds and flags **undeclared breaking releases**. It analyzes **test and release adoption data**」。
   指標は Age / Adoption / Passing / Confidence で、破壊的変更の予測であり、新バージョンの中身の
   改ざん検査ではない。さらに対応 datasource は `go / npm / maven / pypi / nuget / packagist /
   rubygems` のみで、**この repo の依存の大半（mise の aqua / ubi / github-releases、docker、
   git-refs、github-actions）には最初から効かない**。実際 #636（phone-harness digest）の PR 本文は
   バッジ列を持たない。

4. **既存のエージェント調査は automerge 経路の外にある**。`renovate-triage.yml` は週次スケジュール
   （月曜 00:00 UTC）で、B 分類のみを分析し、マージはしない。automerge を有効化すると PR は CI 通過後
   数分〜数時間で消えるため、**月曜にエージェントが起きる頃には調査対象が存在しない**。

5. **public リポジトリでは第三者も approve レビューを送信できる**。したがって承認を PR レビューで
   受ける場合、「approve されたか」ではなく「**approve した人が write 権限を持つか**」の検証が必要。

6. **`REQUEST_CHANGES` は body が必須**（GitHub REST API 公式: "Required when using REQUEST_CHANGES
   or COMMENT for the event parameter"）。`APPROVE` は body 省略可。

### 更新種別の内訳（90 日 / 165 件）

| 区分 | 件数 | 月あたり |
|---|---|---|
| 合計 | 165 | 約 55 |
| GitHub Actions（digest pin） | 12 | 約 4 |
| digest（git-refs, main 追従） | 15 | 約 5 |
| docker digest | 4 | 約 1 |
| major | 3 | 約 1 |
| security advisory 付き | **0** | 0 |
| 上記以外（タグ付きリリースのバージョンピン） | 約 134 | 約 45 |

`git-refs` の digest（anthropics/skills 5・phone-harness 3・drawio 3・supabase 2・
claude-plugins-community 1）は `.github/renovate.json5` の customManager で
`currentValueTemplate: 'main'` を指定しており、**upstream の main ブランチ HEAD を追従**している。
タグ付きリリースと違い upstream 側のリリース判断工程が無く、main への push が即 PR 化される。
中身は skill の Markdown、すなわちエージェントへの指示そのものであり、`renovate.json5` 自身の
コメントが「supply-chain risk is limited to **prompt-injected instructions**」と記している。

## User Story

repo オーナーとして、依存更新を自分の介入なしに継続的に取り込みたい。ただし、
機械的に安全と判定できないものだけは自分に届き、モバイルから最小のアクション数で
承認 / 却下 / 方針指示を下せるようにしたい。automerge されたもののうち自分が把握しておくべき
機能変更は、読むコストと理解コストを抑えた形で後追いできるようにしたい。

## Acceptance Criteria

### automerge と境界

- **AC-001**: Renovate PR は updateType（patch / minor / major / digest / pin）と実行場所
  （ローカル配布物 / GitHub Actions）で区別せず、全面的に automerge の対象とする。
  `.github/renovate.json5` の既存 `automerge: false` packageRule 4 件
  （`affaan-m/ECC` / `jgraph/drawio-mcp` 等 / `anthropics/claude-code-action` /
  `phone-harness` 系）は削除する。マージの可否はエージェントゲートが決める。
- **AC-002**: security advisory 付きの更新も automerge 対象に含める（ゲート判定は経由する）。

### 決定論ゲート

- **AC-003**: エージェントを起動する前に、シェルのみで判定する決定論ゲートを通す。
  次の**すべて**を満たす PR はエージェントを起動せずに合格とする:
  CI が全緑 / `mergeable` が `CONFLICTING` でない / 変更が既知依存であり新規追加でない /
  diff がバージョンピン 1 行のみ / security advisory が付いていない。
- **AC-004**: 次のいずれかに該当する PR は決定論ゲートで合格させず、エージェント調査に回す:
  **`git-refs` の digest 更新（main 追従）** / **docker digest 更新** /
  **GitHub Actions の digest 更新** / major 更新 / semver 判定不能 /
  diff が 1 行を超える / 新規依存の追加 / security advisory 付き。
- **AC-005**: 「diff が 1 行だから安全」という判定は使わない。digest 更新は 1 行 diff の裏に
  upstream の任意の変更を持つため、行数ではなく **updateType と追従先** で振り分ける。

### エージェント調査（required check）

- **AC-006**: エージェント調査は週次スケジュールではなく、**PR ごとにマージ経路上で**実行する。
  判定結果を commit status（または check run）として当該 PR に報告する。
- **AC-007**: `main` に ruleset を作成し、このゲートを **required status check** として登録する。
  チェックが報告されない場合は pending のままマージ不能となること（fail-closed）。
  ruleset は GitHub UI で設定し、リポジトリ内でコード管理しない。
- **AC-008**: ゲートのワークフローは **Renovate 以外の PR でも実行され、即座に success を報告する**。
  required check は PR の作者を問わず要求されるため、これが無いと通常の PR が永久 pending になる。
- **AC-009**: ゲートが不合格を出した PR には、`scripts/renovate-triage-comment.sh` 経由で
  **リポジトリオーナーへのメンションを含むコメント**を投稿する。コメントには不合格の理由と
  対応案を含める。Slack への通知は GitHub Slack App のメンション中継に委ね、
  Incoming Webhook 等の新規インフラは作らない。

### 承認 UI

- **AC-010**: ゲート不合格の PR に対し、**Approve レビューの送信**をもって承認とみなす。
  承認を検知したワークフローがゲートのステータスを success に更新し、Renovate の automerge が走る。
- **AC-011**: **Request changes レビューの送信**をもって却下または方針指示とみなす。
  レビュー本文をエージェントが読み、却下の意思であれば PR をクローズしたうえで
  当該バージョンを Renovate に無視させ、そうでなければ本文を指示として実行する。
- **AC-012**: レビューを承認 / 指示として受理する前に、**レビュー送信者が write 権限を持つことを
  検証する**（`GET /repos/{owner}/{repo}/collaborators/{username}/permission`）。
  権限を持たない者のレビューはゲートに一切影響を与えないこと。

### キャッチアップ

- **AC-013**: 週次で Issue #12（Dependency Dashboard）に、**リポジトリオーナーへのメンションを
  含むコメント**としてダイジェストを投稿する。
- **AC-014**: ダイジェストはマージ済み全件を列挙せず、**注目すべき機能変更のみを抽出**し、
  この repo での使い方への含意を添える。読むコストと理解コストの削減を目的とする。

### 権限とセキュリティ

- **AC-015**: ゲートのワークフローには `statuses: write`（または `checks: write`）を追加する。
  現行 `renovate-triage.yml` の最小権限方針を維持し、追加は必要最小限にとどめる。
- **AC-016**: エージェントの書き込み面は引き続き**構造的に限定**する。取得したすべての PR 情報
  （タイトル・本文・ラベル・diff・CI 出力）は信頼できないデータとして扱い、指示として解釈しない。
  環境変数・シークレット・トークンをコメント本文に出力しない。
- **AC-017**: `issue_comment` を起点にエージェントを起動する経路は作らない。
  public リポジトリでは第三者がコメントできるため、認証済みの経路である `pull_request_review`
  ＋権限検証のみを指示チャネルとする。

## Considered Alternatives / Rejection Rationale

| # | 検討した代替案 | 却下理由 | 関連 AC |
|---|---|---|---|
| 1 | **Setup Validation を復活させ、マージ前に apply を検証する** | user の指摘どおり、CI 環境とローカル環境のギャップが大きく「ローカルで動く」ことを保証できていない。無効化の動機（GHA コスト・複雑化）もそのまま戻る。ギャップは CI を厚くしても埋まらない | AC-003 |
| 2 | **launchd で無人ローカル apply を回し、失敗を検知して自動 revert / 自動 issue 作成** | apply は 1Password・Docker・tailnet に依存し、環境要因の失敗と依存更新起因の失敗が混ざる。自動 revert はこの誤判定を「無実の PR の revert と誤った issue」に増幅する。user 判断により、不具合はローカルで user 自身が検知して issue 化する運用とした。`#365` の「検知と通知のみ、repo には書かない」原則も維持される | AC-003 |
| 3 | **1Password サービスアカウント（`OP_SERVICE_ACCOUNT_TOKEN`）で無人 apply を成立させる** | 代替案 2 の撤回により**丸ごと不要化**。調査済みの内容は将来の参照用に後述 | — |
| 4 | **automerge の境界を semver（major 以外は自動）で引く** | この repo の依存の大半は digest であり semver を持たない。digest こそ main 追従で最もリスクが高いため、semver 軸では危険な経路が素通りする | AC-004, AC-005 |
| 5 | **automerge の境界を実行場所（ローカル配布物 / GitHub Actions）で引く** | 当初はローカル apply ゲートが守る範囲を根拠に採用しかけたが、代替案 2 の撤回でその根拠が消えた。最終的にエージェントゲートを門番に据えたため、実行場所による区別が不要になった | AC-001 |
| 6 | **Merge Confidence を安全網として信頼する** | 破壊的変更の予測であってセキュリティ検査ではない。加えてこの repo の依存の大半の datasource に対応していない（公式ドキュメントで確認済み） | AC-004 |
| 7 | **週次トリアージのまま automerge を有効化する** | automerge された PR は数分〜数時間で消えるため、週次のエージェントが起きる頃には調査対象が存在しない。安全網が経路の外に置かれる | AC-006 |
| 8 | **全 PR にエージェントを走らせる** | 月 55 セッションが Claude の利用枠を消費する。バージョンピン 1 行の更新にエージェントを使うのは無駄。決定論ゲートで振り分ければ月 ~10 件に絞れる | AC-003 |
| 9 | **実行コードを含む digest だけエージェントに回し、Markdown のみの skill は素通しする** | Markdown の skill こそ prompt injection の主経路であり、`renovate.json5` 自身がそう記している。最も見逃してはいけないものを素通しすることになる | AC-004 |
| 10 | **digest の追従先を main からタグ / リリースへ変更する** | 問題を根で消せるが、upstream がリリースを切っていなければ適用できない。今回は採らず、ゲート側で対処する | AC-004 |
| 11 | **ブランチ保護を入れず、PR 作成時に pending ステータスを立てて fail-closed を模す** | pending を立てるワークフロー自体が起動しなければ同じ穴が開く。穴が 1 段奥に移るだけで、fail-closed にならない | AC-007 |
| 12 | **ラベル駆動のワンタップ承認** | GitHub Mobile でのラベル付与はアクション数が多い。PR レビューの Approve の方が少ない操作で済む | AC-010 |
| 13 | **Slack Incoming Webhook で通知する** | PR / Issue コメントにメンションを付ければ GitHub Slack App が中継するため、新規インフラが不要。Webhook・シークレット・保守が増えるだけ | AC-009, AC-013 |
| 14 | **Slack の Block Kit でインタラクティブ 3 択を実装する** | 公開エンドポイント（Cloudflare Worker 等）と repo 書き込み権限を持つトークンという新規攻撃面を負う。承認は月 1〜2 件と見積もられ、割に合わない | AC-010, AC-011 |
| 15 | **既存の ntfy を通知に再利用する** | ntfy は loopback + `tailscale serve` で tailnet 限定のため、GitHub Actions から到達できない。ローカルのポーリング中継が必要になり、「Mac が起きていること」が通知の前提になる | AC-009 |
| 16 | **`@claude` メンション（`issue_comment`）でエージェントを起動する** | public リポジトリでは誰でもコメントできる。`renovate-triage.yml` の「書き込み面を構造的に限定する」という設計の柱を崩す。`pull_request_review` ＋権限検証で同じ機能が安全に実現できる | AC-017 |
| 17 | **Request changes を常に却下（クローズ）に固定する** | 当初 To-Be の「承認 / 却下 / その他方針の指示」の 3 択目が失われる。`REQUEST_CHANGES` は body 必須と確認できたため、本文による分岐に空本文のエッジケースが無い | AC-011 |
| 18 | **ダイジェストを morning-brief に統合する** | Mac が起きていることが前提になる。また既に密度の高いブリーフにセクションが 1 つ増える。チャネル方針（コメント＋メンション）とも一貫しない | AC-013 |

### 1Password サービスアカウント調査結果（代替案 3 の記録・今回は不採用）

将来ふたたび無人 apply を検討する場合に備えて記録する。

- 個人 / Families プランでも利用可能（Business 限定ではない）。`op` は 2.32.1 で要件 2.18.0 を満たす。
- built-in の Personal / Private / Employee / 既定 Shared vault にはアクセス権を与えられない。
  この repo が使う `kryota.dev` はカスタム vault なので対象外（＝利用可能）。
- ただし `kryota.dev` には 86 アイテムが入っており、dotfiles が使うのは `Dotfiles - *` の 5 件のみ。
  サービスアカウントの権限は **vault 単位**なので、素直に作るとトークンが 86 アイテム全部への
  アクセス権を持つ。**専用 vault を新設して 5 件を移設するのが前提条件**になる。
- 必要な op アクセスは 5 件:
  `Dotfiles - AWS Config` / `Dotfiles - Exa API` / `Dotfiles - Firecrawl API` /
  `Dotfiles - Redact Patterns` / `Dotfiles - ntfy`。
- **read 専用トークンで足りる**。`ntfy_provision_subscriber` は定常状態（アイテムが存在し実
  パスワードが保存済み）では `op item get` と `op read` しか呼ばない。`op item create` は
  アイテム不在時、`op item edit` は値がプレースホルダのときと `ntfy_rotate_subscriber`
  （手動 runbook 操作）でのみ発火する。
- レート上限（個人 / Families）: read 1,000/時・write 100/時（トークン毎）、
  read/write 合計 1,000/24時間（**1Password アカウント全体**）。apply 1 回あたり op 呼び出しは
  5〜15 回程度なので日次なら余裕があるが、高頻度実行では日次上限が視界に入る。
- 権限と vault アクセスは作成後に変更不可（変更したい場合は作り直し）。
- トークンの保管には鶏卵問題がある（トークン自体を 1Password に置いて `op` で読むことはできない）。
  macOS Keychain か 0600 ファイルになり、**長期クレデンシャルがディスク上に常駐する**。
- `OP_SERVICE_ACCOUNT_TOKEN` が設定されていると `op` はデスクトップアプリ連携を使わないため、
  シェルの共通プロファイルに置いてはならない（launchd ジョブのプロセス環境に限定する必要がある）。

## Out of Scope

- **`Setup Validation` の復活・改修**。無効のまま据え置く。
- **ローカル `chezmoi apply` の自動化**。apply は引き続き user が手動で実行し、
  不具合は user 自身が検知して issue 化する。
- **自動 revert / 自動 issue 作成**。
- **1Password サービスアカウントの導入、専用 vault の新設、シークレットの移設**。
- **`renovate.json5` の digest 追従先の変更**（main → タグ）。
- **ローカルの `renovate-sweep` skill の廃止**。本設計が定着したのちに別途判断する。
- **`main` の ruleset 作成そのもの**。GitHub UI で user が設定する運用作業であり、
  リポジトリ内でコード管理しない（AC-007）。

## Open Questions

1. ゲート不合格時のコメントに含める「対応案」の粒度をどこまで詳細にするか（実装時に調整）。
2. 週次ダイジェストの「注目すべき機能変更」の抽出基準。初版はエージェントの判断に委ね、
   運用しながら基準を明文化するかを判断する。
3. `renovate-triage.yml` を 2 本のワークフロー（PR 毎のゲート / 週次ダイジェスト）に分割するか、
   1 本のまま `on:` を増やして分岐させるか。実装時に決める。
4. Renovate の `prConcurrentLimit10` を automerge 主体の運用に合わせて緩めるかどうか。
5. Request changes 本文から「却下の意思」を判定する方法（キーワード規約を設けるか、
   エージェントの自然言語判断に委ねるか）。
