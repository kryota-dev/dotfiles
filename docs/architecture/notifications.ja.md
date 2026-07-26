# Notifications: 自己ホスト ntfy over Tailscale

🌐 English (canonical): [notifications.md](notifications.md)

← [ドキュメント目次](../README.ja.md)

Claude Code のセッションイベントは、この Mac 上に自己ホストした ntfy サーバーへ push され、
tailnet 上のデバイスから subscribe されます（kryota-dev/dotfiles#337）。これにより ECC の
`stop:desktop-notify` Stop フック（ローカル osascript、履歴なし）を、帰属情報付きで永続化され、
リモートから subscribe 可能な通知に置き換えます。最終決定の記録は
`.claude/prds/337-ntfy-tailscale.prd.md` にあります。

**スコープの境界**: このページが扱うのは Claude Code の `Notification`/`Stop` フックから
ntfy への経路のみです。リポジトリには、本システムが意図的に手を付けていない独立した
ローカル限定の通知経路が他に3つあります: `clv2-session-notify.sh`（SessionStart、
instinct クラスターのレビュー促し）、`morning-radar.sh`（launchd、osascript による
朝ブリーフ）、`notify` zsh エイリアス（可聴チャイム。本システムの wrapper も失敗時の
アラート音として再利用しています）。

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
phones/tablets on the tailnet (read-only token)
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
  置かれます。これは `run_onchange_after_31-setup-ntfy` が `user.db`/`cache.db` と並ぶランタイム状態
  として書き出すもので、chezmoi の管理対象でも 1Password の保管対象でもありません。1Password に
  残すのは read-only の subscriber トークン（クロスデバイス配布チャネル）のみです。
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
| `claude-attention` | permission_prompt, idle_prompt, agent_needs_input | high (4) | sound/vibrate on |
| `claude-done` | agent_completed, Stop | default (3) | silent delivery |
| `claude-test` | manual smoke tests | — | mute after testing |

帰属情報（repo、branch、account `default`/`r06`、8文字のセッション id、イベント種別）はタイトルと
タグに乗り、トピック名には決して含まれません。Stop の本文は 200 文字に切り詰められ、
`~/.config/git/gitleaks-own.toml` のクライアント識別子パターンでスクラブされます（ベストエフォートの
名前スクラブであり、**secret/PII 検出器ではありません** — 切り詰めが主たる防御手段です）。
許容済み残存リスク（#337 PRD）: プロンプトインジェクションを受けたアシスタントメッセージが
200 文字の窓内に短い secret 断片を含む可能性は残ります — 汎用 secret 検出は明示的にスコープ外です。

## セットアップ手順（初回のみ）

1. **1Password アイテム** — `kryota.dev` Vault に `Dotfiles - ntfy` を作成し、
   `base-url` には実値（serve エンドポイント `https://<host>.<tailnet>.ts.net`。
   `tailscale status --json | jq -r .Self.DNSName` で確認可能）を、`subscriber-token`
   にはブートストラップ用プレースホルダー（`tk_REPLACE…`）を設定します — 自動
   プロビジョニングは、プレースホルダーが残っている間のみ read-only の subscriber
   トークンを発行します。write-only の publisher トークンはここには**置きません**:
   セットアップスクリプトが `~/.config/ntfy/notify-env` へ直接書き出します（手順 4 参照）。
   [secrets-1password](../getting-started/secrets-1password.ja.md) を参照してください。
2. **Docker Desktop** — *サインイン時に Docker Desktop を起動する*（設定 →
   一般）を有効化します。これにより compose の `restart: unless-stopped` ポリシーが、
   再起動のたびにサーバーを復帰させます。
3. **Apply** — `chezmoi apply` が設定をレンダリングし、コンテナを起動し
   （`run_onchange_after_31-setup-ntfy`）、`tailscale serve --bg` のマッピングを検証します。
4. **認証は手順 3 が自動でプロビジョニングします**（再 apply 不要の 1 パス）: スクリプトが
   `publisher`/`subscriber` ユーザーを使い捨てパスワードで作成し、トピック別 ACL を
   付与し、2 つのトークンをプロビジョニングします:
   - **publisher** トークンは `~/.config/ntfy/notify-env`（0600）へ直接書き出されます —
     フックラッパーが source するランタイム状態ファイルです。1Password には一切触れず、
     この処理に `op` は不要です。
   - **subscriber** トークンは 1Password アイテムに保存されます（各スマホに手入力する
     クロスデバイスチャネル）。この処理には `op` CLI が必要です。

   以下のコマンドは、プロビジョニングがスキップ警告を出した場合（例: Docker 停止中、
   または subscriber 側で `op` 不在）の**手動フォールバック**です:

   ```bash
   cd ~/.config/ntfy
   docker compose exec ntfy ntfy user add publisher     # publisher, write-only
   docker compose exec ntfy ntfy user add subscriber    # devices, read-only
   for t in claude-attention claude-done claude-test; do
     docker compose exec ntfy ntfy access publisher "$t" write-only
     docker compose exec ntfy ntfy access subscriber "$t" read-only
   done
   docker compose exec ntfy ntfy token add --label chezmoi publisher
   docker compose exec ntfy ntfy token add --label devices subscriber
   ```

   フォールバック時は、publisher トークンを `~/.config/ntfy/notify-env` に
   `NTFY_TOKEN='tk_…'` として書き込み（ファイルは 0600 のまま）、subscriber トークンは
   アイテムの `subscriber-token` フィールドに保存します。
   注: `ntfy token add` はトークンを端末の scrollback にそのまま出力します — 値を保存したら
   scrollback をクリアしてください。
5. **デバイスの subscribe** — ntfy アプリ（iOS/Android）→ *別のサーバーを使う* で `base-url`
   エンドポイント、1Password の subscriber トークン、2つのトピックを設定します。

## Smoke test

トークンをコマンドラインに乗せることは決してしません（`-H` だと `ps` やシェル履歴に露出します —
wrapper が課しているのと同じルールです）。代わりに process substitution で curl に header 設定を
渡します:

```bash
BASE="$(op read 'op://kryota.dev/Dotfiles - ntfy/base-url')"
ro() { printf 'header = "Authorization: Bearer %s"\n' "$(op read 'op://kryota.dev/Dotfiles - ntfy/subscriber-token')"; }
# publisher トークンは 1Password にないため、notify-env から source する。
wo() { ( . ~/.config/ntfy/notify-env; printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" ); }
# anonymous publish must be denied (401/403)
curl -s -o /dev/null -w '%{http_code}\n' -d test "$BASE/claude-test"
# read-only token must be denied for publish (403)
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
| Local alert sound, no phone notification | Wrapper publish failed — server down. Check `~/Library/Logs/ntfy-notify.log`, then `docker compose -f ~/.config/ntfy/compose.yaml up -d` |
| No notifications right after login | Docker Desktop still starting; the fail-open window is expected. Enable start-at-login (runbook step 2) |
| `chezmoi apply` prints `[ntfy] Docker Desktop is not running` | Intentional warn-and-skip (deviation from lifecycle convention #6): notifications must not block apply. **復旧は印字された `docker compose up -d` コマンドで行う** — `chezmoi apply` の再実行だけでは再試行されない（exit 0 で `run_onchange` の state が記録され、compose/server テンプレートが変更されたときのみ再発火する） |
| Phone can't reach the server | Device off the tailnet, or `tailscale serve` mapping lost — re-run `tailscale serve --bg http://127.0.0.1:2586` (also asserted by every re-triggered apply) |
| Old messages missing | `cache-duration` (168h, `[ntfy]` in `.chezmoidata.toml`) elapsed |
| Notifications on the wrong account badge | `CLAUDE_CONFIG_DIR` unset in that session; account falls back to `default` |

## リカバリ: user.db (auth) の消失・破損、またはトークンローテーション

**クリーンインストールは自己修復します**: `run_onchange` の状態が無いためセットアップ
スクリプトが走り、`~/.config/ntfy/notify-env` が存在しないことを検知して publisher トークンを
再プロビジョニングします。

**既存マシン**では notify-env を削除するだけでは不十分です — `run_onchange_after_31-setup-ntfy`
は exit 0 を記録し、compose/server テンプレートが変更されたときのみ再発火するため、`chezmoi apply`
だけでは書き直されません。手動フォールバック（手順 4）で再プロビジョニングしてください: 新しい
`ntfy token add … publisher` を発行し、notify-env に `NTFY_TOKEN='tk_…'`（0600 のまま）として
書き込みます。`user.db` が消失・破損している場合は先に削除してください。**トークンを再発行すると
すべての既存トークンが無効化されます**ので、subscribe している全デバイスで subscriber トークンも
再入力してください。

## ロールバック（1ステップ）

settings.json の2つの変更をまとめて revert してください — `env.ECC_DISABLED_HOOKS` から
`stop:desktop-notify` を削除し、**かつ** `notification:ntfy-notify` / `stop:ntfy-notify` の
フックエントリを削除した上で `chezmoi apply` を実行します。片方だけ行うと、通知が来なくなるか
二重通知になります。サーバーの停止（任意）:
`docker compose -f ~/.config/ntfy/compose.yaml down` と `tailscale serve --https=443 off`。
