#!/bin/bash
set -euo pipefail

# GhosttyターミナルのバッファをAppleScript経由で取得し、ファイルに保存する
#
# Usage: capture.sh [label]
#
# 前提条件:
#   - macOS（AppleScript使用）
#   - Ghosttyの macos-applescript が有効（デフォルトで有効）
#   - GHOSTTY_RESOURCES_DIR が設定済み（Ghosttyが自動設定）
#
# 出力（stdout）:
#   生成されたファイルのパス（後続処理で利用）

LABEL="${1:-session}"
LOG_BASE="$HOME/Documents/session-logs"

# --- Ghostty環境の確認 ---
if [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
  echo "Error: Ghostty環境外です（GHOSTTY_RESOURCES_DIR が未設定）" >&2
  exit 1
fi

# --- git情報の取得 ---
OWNER_REPO=$(git remote get-url origin 2>/dev/null |
  perl -pe 's{.*[:/]([^/]+)/([^/]+?)(?:\.git)?$}{$1-$2}') ||
  OWNER_REPO="local-$(basename "$PWD")"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "local")
DATE=$(date +%Y-%m-%d)

# --- ディレクトリ作成 ---
BASE_DIR="${LOG_BASE}/${OWNER_REPO}/${DATE}-${BRANCH}/sessions"
mkdir -p "$BASE_DIR"

# --- mktemp でアトミックにファイル生成 ---
RAW_FILE=$(mktemp "${BASE_DIR}/${LABEL}-XXXXXX")
mv "$RAW_FILE" "${RAW_FILE}.txt"
RAW_FILE="${RAW_FILE}.txt"

# --- クリップボードの退避 ---
CLIP_BACKUP=$(mktemp)
pbpaste >"$CLIP_BACKUP" 2>/dev/null || true

# --- AppleScriptでターミナルバッファを取得 ---
osascript <<'APPLESCRIPT'
tell application "Ghostty"
  set frontWin to front window
  set currentTab to selected tab of frontWin
  set currentTerminal to focused terminal of currentTab
  perform action "select_all" on currentTerminal
  delay 0.1
  perform action "copy_to_clipboard" on currentTerminal
  delay 0.1
  -- 選択を解除
  send key "escape" to currentTerminal
end tell
APPLESCRIPT

# --- クリップボードからファイルに書き出し ---
pbpaste >"$RAW_FILE" 2>/dev/null || true

# --- クリップボードの復元 ---
pbcopy <"$CLIP_BACKUP" 2>/dev/null || true
rm -f "$CLIP_BACKUP"

# --- 取得結果の検証 ---
if [[ ! -s "$RAW_FILE" ]]; then
  echo "Error: バッファの取得結果が空です" >&2
  rm -f "$RAW_FILE"
  exit 1
fi

# --- 結果をstdoutに出力（後続処理用） ---
echo "$RAW_FILE"
