# Notifications: 自己ホスト ntfy over Tailscale

🌐 English (canonical): [notifications.md](notifications.md)

← [ドキュメント目次](../README.ja.md)

Claude Code のセッションイベントは、この Mac 上に自己ホストした ntfy サーバーへ push され、
tailnet 上のデバイスから subscribe されます（kryota-dev/dotfiles#337）。これにより ECC の
`stop:desktop-notify` Stop フック（ローカル osascript、履歴なし）を、帰属情報付きで永続化され、
リモートから subscribe 可能な通知に置き換えます。最終決定の記録は
`.claude/prds/337-ntfy-tailscale.prd.md` にあります。

**スコープの境界**: このページが扱うのは Claude Code の `Notification`/`Stop` フックから
ntfy への経路に加え、平日朝ブリーフの配信（#361）です。本システムが意図的に手を付けて
いない独立したローカル限定の通知経路が他に2つあります: `clv2-session-notify.sh`
（SessionStart、instinct クラスターのレビュー促し）と `notify` zsh エイリアス（可聴チャイム。
本システムの wrapper も失敗時のアラート音として再利用しています）。`morning-radar.sh`
（launchd、平日ブリーフ）は以前はローカル `osascript` で通知していましたが、現在はブリーフを
tailnet の HTML ページにレンダリングし、それにリンクする ntfy 通知を送ります —— 下記
[朝ブリーフの配信](#朝ブリーフの配信-361)を参照。

## アーキテクチャ

```
Claude Code hooks (settings.json)
  Notification: permission_prompt | idle_prompt | agent_needs_input | agent_completed
  Stop
        │ stdin JSON (async, fail-open)
        ▼
~/.claude/ntfy-notify.sh ──── enrich (repo/branch/account/session/event)
        │ curl -K, Bearer write-only token, --max-time 3
        ▼
http://127.0.0.1:2586 ── docker: binwiederhier/ntfy (restart: unless-stopped)
        ▲                        └─ state: ~/Library/Application Support/ntfy/
tailscale serve --bg (HTTPS, MagicDNS)          (user.db, cache.db — outside chezmoi)
        ▲
phones/tablets on the tailnet (username/password login)
```

- **サーバーランタイム**: Homebrew の `ntfy` formula は `noserver` タグ付きで macOS バイナリを
  ビルドするため（`ntfy serve` は存在しない）、サーバーは公式の `binwiederhier/ntfy` Docker イメージとして
  Docker Desktop 上で動作します。イメージタグは `home/dot_config/ntfy/compose.yaml.tmpl` にピン留めされ、
  Renovate が追跡します。
- **ネットワーク境界**: コンテナは `127.0.0.1` にのみバインドします。tailnet への公開は
  `tailscale serve --bg`（再起動をまたいで永続化）を通じてのみ行われます。`tailscale
  funnel` は禁止です — 疑わしい場合は `tailscale funnel status`（何も serve していないことを期待）で
  確認してください。
- **publisher クレデンシャル**: write-only トークンは `~/.config/ntfy/notify-env`（0600）に
  置かれます。これは共有ライブラリ `~/.config/ntfy/lib.sh`（`run_onchange_after_31-setup-ntfy`
  と `ntfy-setup` の両方が source する）が `user.db`/`cache.db` と並ぶランタイム状態として
  書き出すもので、chezmoi の管理対象でも 1Password の保管対象でもありません。
- **subscriber クレデンシャル**: read-only の `subscriber` ntfy ユーザーは、トークンではなく
  **username + password** で認証します。ntfy モバイルアプリの公式ドキュメントは、2つの認証方式
  ——サーバーごとのユーザーログイン（Basic Auth、アプリが自動設定）と、カスタム `Authorization`
  ヘッダー（手動のトークン経路）——が互いに排他的だと説明しており、実際に iOS で機能するのは
  前者のみです。username（`subscriber`）と生成されたパスワードは `Dotfiles - ntfy` 1Password
  アイテムに保存されます。
- **iOS の即時 push**: `upstream-base-url: https://ntfy.sh` は、**受信メッセージすべて**について
  ntfy.sh へポーリングリクエストを送ります — iOS デバイスが購読しているかどうかに関係なく
  （トピックのメタデータのみで、メッセージ本文は含みません）— これが APNs に即時配信の材料を渡します。
  これが唯一の承認済みメタデータ egress です。デバイス自体は本文をこのサーバーから tailnet 経由で
  取得します。smoke test で tailnet-only では即時 push が機能しないと判明した場合は、この key を
  削除して egress をゼロにしてください。実機の iOS 挙動を観測後、ここに記録してください:
  _observed: (pending first smoke test)_.
- **トピック**（固定、緊急度ベース; SSOT は `home/.chezmoidata.toml` の `[ntfy]`）:

| Topic | Events | Priority | Intended device setting |
|-------|--------|----------|------------------------|
| `claude-attention` | permission_prompt, idle_prompt, agent_needs_input, 週次 macOS defaults ドリフト検出 (macos-defaults-drift-check, #365) | high (4) | sound/vibrate on |
| `claude-done` | agent_completed, Stop | default (3) | silent delivery |
| `claude-brief` | weekday morning brief (morning-radar, #361) | default (3) | mute optional |
| `claude-test` | manual smoke tests | — | mute after testing |

帰属情報（repo、branch、account `default`/`r06`、8文字のセッション id、イベント種別）はタイトルと
タグに乗り、トピック名には決して含まれません。Stop の本文は 200 文字に切り詰められ、
`~/.config/git/gitleaks-own.toml` のクライアント識別子パターンでスクラブされます（ベストエフォートの
名前スクラブであり、**secret/PII 検出器ではありません** — 切り詰めが主たる防御手段です）。
許容済み残存リスク（#337 PRD）: プロンプトインジェクションを受けたアシスタントメッセージが
200 文字の窓内に短い secret 断片を含む可能性は残ります — 汎用 secret 検出は明示的にスコープ外です。

## 朝ブリーフの配信 (#361)

平日の `morning-radar.sh` wrapper（launchd `dev.kryota.morning-radar`、#257）は、以前は
ローカル `osascript` 通知でブリーフを知らせていましたが、この通知は文書を運べず、モバイルにも
届きませんでした。現在はブリーフをモバイル可読な HTML ページにレンダリングし、その**ページを開く
click** を持つ ntfy 通知を送ります —— **ブリーフ内容が tailnet 外へ出ることはありません**。2 つの
代替案は却下しました（`.claude/prds/361-brief-url-ntfy.prd.md` の決定ログ参照）: Artifact/claude.ai
ページ（内容が第三者へ出る）と、ブリーフを ntfy **メッセージ**として配信する案（ntfy の iOS/Android
アプリは Markdown をレンダリングせず web app のみ対応のため、モバイルでは raw Markdown 表示になる）。
serve した HTML ページはブラウザがネイティブにレンダリングします。

- **レンダリング**: `render_brief_html` が `~/dotfiles/.kryota-dev/morning-brief/<date>.html` を
  pandoc（`-f markdown-raw_html`。未信頼のブリーフ内容中の **raw HTML をエスケープ**し —— GitHub
  タイトル由来の `<script>` がページ上で実行されない —— GFM テーブルは保持）または self-contained
  でモバイル可読な `<pre>` フォールバックで生成します。headless の claude セッションには `Artifact`
  ツールを**付与しません**。
- **serve**: loopback の **nginx sidecar**（`compose.yaml` の `brief-page` サービス）が brief dir を
  `ntfy_brief_port` で配信し、tailnet 側は `tailscale serve --https 8443` の**ポートプロキシ**が front
  します —— macOS の standalone/App 版 Tailscale は**ポートは proxy できてもファイル/ディレクトリは
  serve できない**ためです。専用 HTTPS ポートで ntfy root（443）と独立。tailnet-only、`funnel` は
  使いません。`NTFY_BRIEF_BASE_URL`（`https://<magicdns>:8443`）はプロビジョニング時に導出され
  notify-env に書かれ、wrapper が `/<date>.html` を付加します。
- **通知**: 成功時、wrapper は `claude-brief` へ `HEADLINE` とページ URL を `click` として publish
  します。エラー経路（claude 不在 / timeout / 非 0 exit / ブリーフファイル欠落）は `claude-attention`
  へ高 priority で publish。publisher トークンは `curl -K` config file 経由（argv には出ず）、subshell
  内でのみ source。env ファイルは owner-only（0600/0400）でなければ fail-open します。
- **fail-open / 縮退**: publish の失敗は log に残すだけで、実行や同日 stamp を中断しません（stamp は
  ブリーフ成功時、配信の前に書かれます）。render やベース URL が使えない場合でも通知は `HEADLINE` を
  届けます（リンクなし）。

既存トピック（`claude-attention`/`claude-done`）も `markdown: true` で publish するようになり、
本文が ntfy web app でレンダリングされます。

Smoke test（オンデマンドでブリーフを publish）:

```bash
~/.claude/morning-radar.sh --force   # 課金される実行 1 回。claude-brief にリンク付きで通知
# tailnet デバイスで通知のリンクを開く（または）:
BASE="https://$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//'):8443"
curl -sI "$BASE/$(date +%F).html" | head -1   # 期待: HTTP/… 200
tailscale funnel status                        # 期待: 何も serve していない（tailnet-only）
```

## セットアップ手順（初回のみ）

これらの手順の前提として、`chezmoi apply` が compose ファイル・`~/.config/ntfy/lib.sh`・
`ntfy-setup` コマンドをすでにデプロイ済みです — どれも手作業で作る必要はありません。

1. **Docker Desktop** — *サインイン時に Docker Desktop を起動する*（設定 →
   一般）を有効化します。これにより compose の `restart: unless-stopped` ポリシーが、
   再起動のたびにサーバーを復帰させます。
2. **Tailscale** — この Mac が `tailscale up` 済みでログインしていることを確認します。
3. **`ntfy-setup` を実行**（`~/.local/bin/ntfy-setup`、PATH 済み）— ライフサイクル
   全体のための単一の再実行可能エントリポイントです。コンテナを起動し
   （`docker compose up -d --remove-orphans`）、`tailscale serve --bg` を検証した上で、
   1 パスで両方のクレデンシャルをプロビジョニングします:
   - **publisher** トークンは `~/.config/ntfy/notify-env`（0600）へ直接書き出されます —
     フックラッパーが source するランタイム状態ファイルです。この処理に `op` は不要です。
   - **subscriber** ユーザーは生成されたパスワードで作成（または修復）され、そのパスワードは
     `Dotfiles - ntfy` 1Password アイテムに保存されます。この処理には `op` CLI が必要です。
     **1Password アイテムは、存在しない場合に初回だけ自動作成されます**（Secure Note、
     `subscriber-username`/`subscriber-password`）— 手動での 1Password 設定は不要です。
     [secrets-1password](../getting-started/secrets-1password.ja.md) を参照してください。

   `chezmoi apply` も同じプロビジョニングを apply 時に実行します
   （`run_onchange_after_31-setup-ntfy` が同じ `~/.config/ntfy/lib.sh` を source します）が、
   Tailscale がすでに up、かつ Docker がすでに起動しているマシンでのみ完了します。
   **フレッシュなマシンではどちらもまだ true ではない**ため、apply 時の実行は警告してスキップ
   します（下記の障害モード参照）— 両方が揃った時点で `ntfy-setup` を実行してセットアップを
   完了させてください。この 2 フェーズのギャップこそが、`ntfy-setup` を `chezmoi apply` 単独に
   頼らない独立した再実行可能コマンドとして用意している理由です。

   以下のコマンドは、`op` が利用できない場合（subscriber 側は警告付きでスキップされます）の
   **手動フォールバック**専用です:

   ```bash
   cd ~/.config/ntfy
   docker compose exec ntfy ntfy user add publisher     # publisher, write-only
   NTFY_PASSWORD='<choose-a-strong-password>' \
     docker compose exec -T -e NTFY_PASSWORD ntfy ntfy user add subscriber   # devices, read-only
   for t in claude-attention claude-done claude-brief claude-test; do
     docker compose exec ntfy ntfy access publisher "$t" write-only
     docker compose exec ntfy ntfy access subscriber "$t" read-only
   done
   docker compose exec ntfy ntfy token add --label chezmoi publisher
   ```

   フォールバック時は、publisher トークンを `~/.config/ntfy/notify-env` に
   `NTFY_TOKEN='tk_…'` として書き込み（ファイルは 0600 のまま）、subscriber の
   username/password は `Dotfiles - ntfy` アイテムの `subscriber-username`/
   `subscriber-password` フィールドに保存します。
   注: `ntfy token add` はトークンを端末の scrollback にそのまま出力します — 値を保存したら
   scrollback をクリアしてください。
4. **デバイスの subscribe** — ntfy アプリ（iOS/Android）→ *別のサーバーを使う* → サーバー URL
   （`ntfy-setup` が表示します。または `tailscale status --json | jq -r .Self.DNSName` で
   自分で導出し、末尾のドットを除去して `https://` を前置します）→ username `subscriber` と
   `Dotfiles - ntfy` 1Password アイテムのパスワードでログイン → トピック（`claude-attention`、
   `claude-done`、および平日ブリーフ用の `claude-brief`）を購読します。

## Smoke test

トークンやパスワードをコマンドラインに乗せることは決してしません（`-H`/`-u` だと `ps` やシェル
履歴に露出します — wrapper が課しているのと同じルールです）。代わりに process substitution で
curl に設定を渡します。サーバー URL もその場で導出し、保存はしません:

```bash
DNS="$(tailscale status --json | jq -r .Self.DNSName)"
BASE="https://${DNS%.}"
ro() { printf 'user = "subscriber:%s"\n' "$(op read 'op://kryota.dev/Dotfiles - ntfy/subscriber-password')"; }
# publisher トークンは 1Password にないため、notify-env から source する。
wo() { ( . ~/.config/ntfy/notify-env; printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" ); }
# anonymous publish must be denied (401/403)
curl -s -o /dev/null -w '%{http_code}\n' -d test "$BASE/claude-test"
# read-only な username/password は publish が拒否されなければならない (403)
curl -s -o /dev/null -w '%{http_code}\n' -K <(ro) -d test "$BASE/claude-test"
# publisher token succeeds (200); phones should receive it
curl -s -o /dev/null -w '%{http_code}\n' -K <(wo) -d test "$BASE/claude-test"
# history retrieval + filtering examples (verify once, then rely on them)
curl -s -K <(ro) "$BASE/claude-done/json?poll=1&since=24h" | jq 'select(.tags | index("dotfiles"))'
curl -s -K <(ro) "$BASE/claude-attention/json?poll=1&since=all" | jq 'select(.tags | index("permission_prompt"))'
```

アプリを閉じた状態で iOS が即時配信するかどうかも記録してください（tailnet 限定サーバー上での
upstream リレーは upstream 側で未検証です — PRD 参照）。

## 障害モードとトラブルシューティング

| Symptom | Cause / fix |
|---------|-------------|
| Local alert sound, no phone notification | Wrapper publish failed — server down. Check `~/Library/Logs/ntfy-notify.log`, then run `ntfy-setup` |
| No notifications right after login | Docker Desktop still starting; the fail-open window is expected. Enable start-at-login (runbook step 1) |
| `chezmoi apply` prints `[ntfy] Docker Desktop is not running` | Intentional warn-and-skip (deviation from lifecycle convention #6): notifications must not block apply. **復旧は Docker 起動後に `ntfy-setup` を実行する** — `chezmoi apply` の再実行だけでは再試行されない（exit 0 で `run_onchange` の state が記録され、compose/server/lib テンプレートが変更されたときのみ再発火する） |
| Phone can't reach the server | Device off the tailnet, or `tailscale serve` mapping lost — `ntfy-setup` を実行する（`tailscale serve --bg` を再検証する。再トリガーされた apply のたびにも検証される） |
| Old messages missing | `cache-duration` (168h, `[ntfy]` in `.chezmoidata.toml`) elapsed |
| Notifications on the wrong account badge | `CLAUDE_CONFIG_DIR` unset in that session; account falls back to `default` |

## リカバリ: user.db (auth) の消失・破損、またはクレデンシャルのローテーション

**クリーンインストールは自己修復します**: `run_onchange` の状態が無いためセットアップ
スクリプトが走り、`~/.config/ntfy/notify-env` が存在しないことを検知して publisher トークンと
subscriber のユーザー/パスワードを再プロビジョニングします。

**既存マシン**では、`run_onchange_after_31-setup-ntfy` は exit 0 を記録し、compose/server/lib
テンプレートが変更されたときのみ再発火するため、`chezmoi apply` だけではダウンしたコンテナの
復旧も、`user.db` の消失の修復も、クレデンシャルのローテーションもできません。**`ntfy-setup` が
これらすべてに対する単一のリカバリコマンドです**:

- **コンテナのダウン / `tailscale serve` マッピングの喪失** — `ntfy-setup` がコンテナを再起動し、
  `tailscale serve --bg` を再検証します。
- **`user.db` の消失・破損** — 先に削除してから `ntfy-setup` を実行します。両方のユーザーを
  再作成し、既知のパスワード/トークンを再適用します。
- **クレデンシャルの漏洩・ローテーション** — `ntfy-setup --rotate publisher|subscriber|all`。
  `ntfy token add` は加算的です（各ユーザーは複数のトークンを持てます。新規発行は既存トークンを
  無効化**しません**）。そのため publisher のローテーションは、まず notify-env から現在の
  トークンを読み取り、新しいトークンを発行して書き込んだ後、古いトークンを（`ntfy token remove`
  で）失効させます — すべてのクレデンシャルを一括無効化するのは `user.db` を削除した場合のみです。
  subscriber のローテーションは `ntfy user change-pass` を使います（ユーザーと ACL を維持、
  del/re-add のギャップなし）。1Password の `subscriber-password` フィールドも更新します。
  **subscriber のローテーション後は、subscribe している全デバイスで新しいパスワードを
  再入力する必要があります。**

## ロールバック（1ステップ）

settings.json の2つの変更をまとめて revert してください — `env.ECC_DISABLED_HOOKS` から
`stop:desktop-notify` を削除し、**かつ** `notification:ntfy-notify` / `stop:ntfy-notify` の
フックエントリを削除した上で `chezmoi apply` を実行します。片方だけ行うと、通知が来なくなるか
二重通知になります。サーバーの停止（任意）:
`docker compose -f ~/.config/ntfy/compose.yaml down` と `tailscale serve --https=443 off`。
