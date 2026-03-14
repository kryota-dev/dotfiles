#!/bin/bash
set -euo pipefail

echo "=== dotfiles bootstrap ==="
echo ""

OS="$(uname)"

# --- macOS prerequisites ---
if [ "$OS" = "Darwin" ]; then
  if ! xcode-select -p &>/dev/null; then
    echo "Installing Xcode CLI tools..."
    xcode-select --install
    echo ""
    echo "Please re-run this script after installation completes."
    exit 0
  fi

# --- Linux prerequisites ---
elif [ "$OS" = "Linux" ]; then
  echo "Installing prerequisites..."
  if ! command -v sudo &>/dev/null; then
    echo "Error: sudo is required for package installation on Linux."
    exit 1
  fi
  sudo apt-get update -y
  sudo apt-get install -y build-essential curl file git

else
  echo "Error: Unsupported OS: $OS"
  exit 1
fi

# --- Install chezmoi and apply dotfiles ---
echo "Installing chezmoi and applying dotfiles..."

for attempt in 1 2 3; do
  if installer=$(curl -fsLS https://get.chezmoi.io) && [ -n "$installer" ]; then
    break
  elif [ "$attempt" -lt 3 ]; then
    echo "Failed to download chezmoi installer (attempt ${attempt}/3), retrying..."
    sleep $((attempt * 5))
  else
    echo "ERROR: Failed to download chezmoi installer after 3 attempts."
    exit 1
  fi
done

sh -c "$installer" -- init --apply kryota-dev

echo ""
echo "=== Setup complete! ==="
echo "Please restart your terminal."
