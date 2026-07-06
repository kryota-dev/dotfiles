#!/bin/bash
set -euo pipefail

# Claude Codeのセッションファイル（JSONL）をコピーして保存する
#
# Usage: capture.sh <session-id> [label]
#
# 引数:
#   session-id  SKILL.md内で ${CLAUDE_SESSION_ID} から展開されたUUID
#   label       出力ファイルのラベル（デフォルト: session）。
#               `/` は `-` に置換される（ブランチ名をそのまま渡す用途を許容するため）。
#
# 出力（stdout）:
#   生成されたファイルのパス（後続処理で利用）
#
# セッションファイルの探索順:
#   1. $CLAUDE_CONFIG_DIR/projects （環境変数が設定されていれば最優先）
#   2. $HOME/.claude*/projects     （標準 ~/.claude のほか、~/.claude-r06 等の派生環境）

SESSION_ID="${1:?Error: セッションIDが必要です}"
LABEL_RAW="${2:-session}"
# ラベルに含まれる '/' をファイル名安全な '-' に置換
LABEL="${LABEL_RAW//\//-}"
LOG_BASE="$HOME/Documents/session-logs"

# --- セッションファイルの探索候補を構築 ---
PROJECT_KEY=$(pwd | sed 's|/|-|g')
CANDIDATES=()

# 1. CLAUDE_CONFIG_DIR が設定されていれば最優先
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  CANDIDATES+=("${CLAUDE_CONFIG_DIR}/projects/${PROJECT_KEY}/${SESSION_ID}.jsonl")
fi

# 2. 標準 (~/.claude) + 派生環境 (~/.claude-r06 等)
for dir in "$HOME"/.claude*; do
  [[ -d "${dir}/projects" ]] && CANDIDATES+=("${dir}/projects/${PROJECT_KEY}/${SESSION_ID}.jsonl")
done

# --- セッションファイルの特定 ---
SOURCE_FILE=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -f "$candidate" ]]; then
    SOURCE_FILE="$candidate"
    break
  fi
done

if [[ -z "$SOURCE_FILE" ]]; then
  {
    echo "Error: セッションファイルが見つかりません"
    echo "  Session ID: $SESSION_ID"
    echo "  Project key: $PROJECT_KEY"
    echo "  探索した候補:"
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
      echo "    (候補なし: ~/.claude*/projects が存在せず、CLAUDE_CONFIG_DIR も未設定)"
    else
      for c in "${CANDIDATES[@]}"; do
        echo "    - $c"
      done
    fi
  } >&2
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
