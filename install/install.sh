#!/bin/bash
set -euo pipefail

echo "=== dotfiles installer ==="
echo ""

# Check macOS
if [ "$(uname)" != "Darwin" ]; then
  echo "Error: This installer is for macOS only."
  exit 1
fi

# 1. Xcode CLI tools
if ! xcode-select -p &>/dev/null; then
  echo "Installing Xcode CLI tools..."
  xcode-select --install
  echo ""
  echo "Please re-run this script after installation completes."
  exit 0
fi

# 2. Homebrew
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [ "$(uname -m)" = "arm64" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# 3. chezmoi
if ! command -v chezmoi &>/dev/null; then
  echo "Installing chezmoi..."
  brew install chezmoi
fi

# 4. Init and apply
echo "Initializing dotfiles..."
chezmoi init --apply kryota-dev

echo ""
echo "=== Setup complete! ==="
echo "Please restart your terminal."
