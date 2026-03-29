#!/bin/bash
set -euo pipefail

# Claude Codeのセッションファイル（JSONL）をコピーして保存する
#
# Usage: capture.sh <session-id> [label]
#
# 引数:
#   session-id  SKILL.md内で ${CLAUDE_SESSION_ID} から展開されたUUID
#   label       出力ファイルのラベル（デフォルト: session）
#
# 出力（stdout）:
#   生成されたファイルのパス（後続処理で利用）

SESSION_ID="${1:?Error: セッションIDが必要です}"
LABEL="${2:-session}"
LOG_BASE="$HOME/Documents/session-logs"

# --- セッションファイルの特定 ---
CLAUDE_PROJECT_DIR="$HOME/.claude/projects"
PROJECT_KEY=$(pwd | sed 's|/|-|g')
SESSION_DIR="${CLAUDE_PROJECT_DIR}/${PROJECT_KEY}"

SOURCE_FILE="${SESSION_DIR}/${SESSION_ID}.jsonl"
if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Error: セッションファイルが見つかりません: $SOURCE_FILE" >&2
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

# --- セッションファイルをコピー ---
RAW_FILE="${BASE_DIR}/${LABEL}-${SESSION_ID}.jsonl"
cp "$SOURCE_FILE" "$RAW_FILE"

# --- 結果をstdoutに出力（後続処理用） ---
echo "$RAW_FILE"
