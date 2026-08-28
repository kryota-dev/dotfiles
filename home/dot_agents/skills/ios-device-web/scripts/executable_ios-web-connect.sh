#!/bin/bash
# 実 iPhone / iPad の Web Inspector を CDP として 127.0.0.1:<port> に開く。
#
# トンネルは端末の電波状態が変わるたびに落ちる（機内モードの ON/OFF、Wi-Fi 切替）。
# USB 接続自体は生きたままなので、**張り直せば観測を続けられる**。そのため
# このスクリプトは「毎回まっさらに張り直す」ことだけを行い、冪等に何度でも叩ける。
set -e

PORT="${IOS_WEB_CDP_PORT:-9222}"
STATE_DIR="${IOS_WEB_STATE_DIR:-${TMPDIR:-/tmp}/ios-device-web}"
mkdir -p "$STATE_DIR"

command -v pymobiledevice3 >/dev/null 2>&1 || {
  echo "pymobiledevice3 が無い。'uv tool install pymobiledevice3' で入れる" >&2; exit 1; }

# 端末が USB で見えているか。ここで落ちるならケーブル / 信頼のどちらか。
if [ "$(pymobiledevice3 usbmux list 2>/dev/null)" = "[]" ]; then
  echo "USB に端末が見えない。ケーブル接続と「このコンピュータを信頼」を確認する" >&2; exit 1
fi

pkill -f "pymobiledevice3 webinspector cdp" 2>/dev/null || true
pkill -f "pymobiledevice3 remote start-tunnel" 2>/dev/null || true
sleep 3

# --udid は付けない。remotepairingd が UDID で引けず "Device not found" になる。
nohup pymobiledevice3 remote start-tunnel --script-mode > "$STATE_DIR/tunnel.log" 2>&1 &
RSD=""
for _ in $(seq 1 20); do
  RSD=$(grep -Eo '^[0-9a-f:]+ [0-9]+$' "$STATE_DIR/tunnel.log" 2>/dev/null | tail -1)
  [ -n "$RSD" ] && break
  sleep 2
done
[ -z "$RSD" ] && { echo "トンネル確立に失敗:"; tail -5 "$STATE_DIR/tunnel.log"; exit 1; }
printf '%s\n' "$RSD" > "$STATE_DIR/rsd.txt"

# zsh はパラメータ展開を field split しないので、host と port は明示的に 2 引数へ分ける。
RSD_HOST=$(printf '%s' "$RSD" | cut -d' ' -f1)
RSD_PORT=$(printf '%s' "$RSD" | cut -d' ' -f2)

nohup pymobiledevice3 webinspector cdp --rsd "$RSD_HOST" "$RSD_PORT" --port "$PORT" \
  > "$STATE_DIR/cdp.log" 2>&1 &
for _ in $(seq 1 20); do
  if curl -s --max-time 5 "http://127.0.0.1:$PORT/json/list" >/dev/null 2>&1; then
    echo "接続 OK  RSD=$RSD  CDP=http://127.0.0.1:$PORT"
    exit 0
  fi
  sleep 2
done

echo "CDP が応答しない:" >&2
tail -8 "$STATE_DIR/cdp.log" >&2
echo "--- Web インスペクタが端末側で ON か確認する（設定 → アプリ → Safari → 詳細）" >&2
exit 1
