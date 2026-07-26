---
slug: 361-brief-url-ntfy
feature: Deliver the morning brief as a tailnet URL with ntfy notification
created_at: 2026-07-26T23:39:53+09:00
grill_session: 2cedd4fc-b28d-4d15-83a0-a77921d6078e
status: finalized
---

# Background

morning brief は現在 `~/dotfiles/.kryota-dev/morning-brief/<YYYY-MM-DD>.md`（global gitignore
済・repo 非追跡）に書かれ、`executable_morning-radar.sh` の `notify_user()` が osascript で
デスクトップ通知するだけ。この通知は文書へリンクできず、モバイルにも届かないため brief が
読まれない。平日自動実行（launchd `dev.kryota.morning-radar`、平日 9:00 JST、#257）は既にあり、
残るギャップは「配信」。#357 で publisher-token ベースの ntfy 送信基盤（tailnet-only）が入った。

**確定した privacy 境界（user 承認済み・本 PRD の前提を規定）**: 既存 ntfy は意図的に
tailnet-only（`tailscale funnel` を明示禁止）。brief は work/client 文脈を含みうるため、
**brief 内容を claude.ai(Artifact) 等の第三者クラウドへ出さず、配信は tailnet 内で完結する**。
→ Issue #361 が primary としていた Artifact 経路は**不採用**。Artifact の headless 実現性
spike も**スコープ外**（配信手段として使わないため検証不要）。

# User Story

平日朝、launchd が morning brief を生成したら、私はモバイル端末で ntfy 通知を受け取り、
通知をタップすると tailnet 経由で brief 全文を読める。通知経路は macOS ローカルの osascript
ではなく ntfy に一本化され、外出先（tailnet 接続時）でも brief が届く。

# Acceptance Criteria

- **AC-001**: 平日朝の成功実行が、**モバイルから読める tailnet ntfy メッセージ**として brief を
  配信する（`claude-brief` topic、`markdown: true`、本文＝brief 全文。ntfy web app が Markdown を
  レンダリング、モバイルアプリは raw Markdown 表示）。通知を開けば brief 全文が読める。brief 内容は
  tailnet 外へ出ない。〔改訂: 当初は tailscale serve 静的ページ = URL 配信だったが、macOS の
  standalone/App 版 tailscale がディレクトリ配信不可（ポートのみ）とレビューで判明し、ntfy
  メッセージ配信へ pivot（下記 decision log 参照）。〕
- **AC-002**: `executable_morning-radar.sh` に **osascript 通知経路が一切残らない**（成功・
  各エラー経路すべて）。`osascript` / `display notification` の文字列が wrapper に存在しない
  ことを bats で検証する。
- **AC-003**: 通知配信は **fail-open**。ntfy サーバー / tailscale serve が不達でも wrapper は
  クラッシュせず、失敗を log に残す（既存 ntfy-notify.sh と同じ許容度）。同日 guard の
  `last-run` stamp は「成功時のみ」書く既存挙動を壊さない。
- **AC-004**: brief は 1 通の Markdown メッセージ（title=HEADLINE、body=brief 全文）として配信する。
  message-size-limit を引き上げ、上限超過による添付ファイル化を避ける。〔改訂: 旧「URL 縮退」は
  ntfy メッセージ配信への pivot で不要になった。配信失敗時の挙動は AC-003 の fail-open が担保する。〕
- **AC-005**: エラー経路（claude 不在 / timeout / 非 0 exit / brief ファイル欠落）は ntfy の
  **attention 系 topic**（高 priority）で通知する。成功の brief 配信とは topic / priority で区別する。
- **AC-006**: publisher token は **argv に露出しない**（`curl -K` config file 経由。既存
  ntfy-notify.sh と同じ hygiene）。bats で argv 非露出を検証する。
- **AC-007**: 新規 topic / runtime state（notify-env）は既存 ntfy の provisioning と**衝突しない**。
  serve マッピングは変更しない（tailscale serve は既存の ntfy root proxy のみ）。`tailscale funnel`
  は使わない（tailnet-only 維持）。既存インストールの upgrade でも notify-env に新 topic が反映される。
- **AC-008**: 変更で追加/改名した chezmoi 管理ファイルは `tests/files.bats` に宣言し、
  `make lint` / `make test` が green。docs（notifications.md ＋ `.ja.md`）に brief 配信経路を追記。

# Considered Alternatives / Rejection Rationale

> **改訂（post-review pivot, #379 レビュー）**: 当初 tailscale serve 静的ページ（URL 配信）を採用し
> 実装したが、multi-review で codex が「macOS の standalone/App 版 tailscale はディレクトリ/ファイルを
> serve できない（ポートのみ）」と指摘。一次ソース（[Tailscale Serve KB 1242](https://tailscale.com/kb/1242/tailscale-serve)）で
> 確定し、当マシンが system-extension 版であることも確認。→ **tailscale serve 静的ページを却下し、
> 下記「ntfy message body(markdown)」を採用**（当初 sidecar port-proxy 案も検討したが、user が最も
> シンプルな ntfy メッセージ配信を選択）。これにより pandoc raw-HTML XSS リスクも同時に消滅した。

- **[却下] Artifact(claude.ai) を primary 配信**（Issue #361 原案）: brief 内容が tailnet 外の
  第三者クラウドへ出る。Artifact tool 仕様上「削除してもキャッシュ/インデックスされうる」。
  既存 ntfy の tailnet-only posture・client 固有名を publish しないポリシーと衝突。**user が
  tailnet-only 維持を選択**したため却下。付随して headless Artifact spike も不要（AC-001 で担保する
  配信手段に Artifact を使わない）。
- **[採用（post-review pivot）] brief を ntfy message body(markdown) で配信**: brief 全文を
  `markdown: true` の 1 メッセージ本文として publish。web app が Markdown をレンダリング（モバイル
  アプリは raw Markdown 表示だが可読）。`message-size-limit` を 32KB に引き上げ 4KB 超の添付化を回避。
  serve マウント・HTML 生成・URL・pandoc をすべて排し最もシンプル。tailnet-only を維持し、
  brief は ntfy の cache.db（既存の 168h plaintext residency、#337 で承認済み）に載る。当初は
  「URL でない/168h で消える」を理由に却下候補としたが、macOS serve 制約の判明で URL 前提が崩れ、
  user 判断で本案を採用した。
- **[却下候補/要確認] brief を ntfy attachment で配信**: 既存 serve マッピング（ntfy root）を
  そのまま再利用でき `https://<magicdns>/file/…` が得られる利点。ただし server.yml に
  `attachment-cache-dir` 追加（現在未設定＝添付無効）＋ cache disk 常駐が増える。HTML 添付の
  in-app 描画挙動が不確実。→ 次善。**採用は sdd 設計で再評価**。
- **[却下（当初採用→撤回）] brief を `tailscale serve` の静的ページとして配信**: MagicDNS 由来の
  durable な tailnet URL が得られる利点で当初採用・実装した。しかし **macOS の standalone/App 版
  tailscale はディレクトリ/ファイルを serve できない**（KB 1242、当マシンが該当）ため `--set-path
  /brief <dir>` が機能せず撤回。ポートプロキシする static server sidecar 案（compose にコンテナ追加）
  も検討したが、user が ntfy メッセージ配信を選択したため不採用。付随して pandoc raw-HTML XSS
  （`-f gfm` が `<script>` 素通し）と mount 失敗時の縮退不整合も pivot で解消された。
- **[却下] 送信ロジックを ntfy-notify.sh から共有 helper へ即リファクタ**: 稼働中の hook wrapper を
  触るリスク＋スコープ拡大。house rule「重複が実在してから DRY 化」に反する先回り抽象化。
  → morning-radar 側に **self-contained な publish**（ntfy-notify.sh の token hygiene を踏襲）を
  置く。重複が問題化した時点で lib.sh への helper 抽出を別 issue 化。
- **[採用（推奨）] brief 配信用の専用 topic を新設**（例 `topic_brief`）: agent-completed 用の
  `claude-done` に混ぜず、独立に mute/subscribe 可能にする。`.chezmoidata.toml [ntfy]` に SSOT 追加、
  ACL grant ループ・notify-env に反映。**却下代替**: `claude-done` 流用（実装は最小だが日次 brief で
  agent 完了ストリームが騒がしくなる）。

# Out of Scope

- Artifact / claude.ai 配信、および headless Artifact の spike。
- ntfy-notify.sh（既存 hook wrapper）のリファクタ / 共有 helper 抽出。
- brief 履歴のダッシュボード化（#371 が別途）。
- brief 生成ロジック（morning-brief skill）の内容変更。配信のみ扱う。
- Linux 対応の新規配信（morning-radar は Darwin 限定。`[ "$(uname)" = "Darwin" ]` 既存 guard を維持）。

# Open Questions

- **OQ-1（serve 分離方式）**: brief ページを `--set-path /brief`（443 に相乗り）か専用ポート
  `--https=8443` か。前者は ntfy の topic route `/brief` と longest-prefix で共存できる想定だが
  実挙動の検証が要る。後者は衝突ゼロだが URL に `:8443` が付く。→ sdd 設計 + smoke test で確定。
- **OQ-2（brief の HTML 描画）**: 生 markdown を serve するとモバイル browser では text/plain 表示。
  可読性のため HTML 化するか（変換手段: 既存ツール有無を要調査／最小 HTML shell／MVP は生 md）。
  → AC-001「読める」を満たす最小手段を sdd で決定。
- **OQ-3（serve マウントの provisioning 場所）**: brief serve を morning-radar 実行時に都度
  assert するか、ntfy の setup（run_onchange_after_31 / ntfy-setup / lib.sh）に相乗りさせるか。
  後者は ntfy provisioning と結合するが serve マッピングの一元管理になる。→ sdd 設計で確定。
- **OQ-4（新規 topic のスモーク/ACL）**: `topic_brief` 新設時、publisher の write ACL grant と
  端末側 subscribe 手順を docs に追記する範囲。

# Assumptions（auto 審議で自律解決した前提。承認時に検分）

- brief dir は global gitignore 済で repo 非追跡 → tailnet serve しても repo へは漏れない。
- publish は既存どおり loopback(`http://127.0.0.1:2586`)へ、click URL のみ MagicDNS。
- morning-radar は「dependency-free な self-contained wrapper」設計を維持（lib.sh を source しない）。
- 新規 serve マウント追加は tailnet-only posture の範囲内（funnel を使わない限り privacy 境界を
  越えない）ため、privacy 面の追加エスカレートは不要と判断（越境判断は既に user 承認済み）。
