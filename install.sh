#!/bin/bash
# 新しい Mac のセットアップ: Xcode CLT → Homebrew → 1Password → chezmoi init --apply。
# chezmoi のテンプレートは描画時に 1Password から秘密情報を読むので、1Password を先に用意する。
set -euo pipefail

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  echo "Xcode Command Line Tools のインストールが終わったら、このスクリプトをもう一度実行してください。"
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

brew install --cask 1password 1password-cli
# テンプレートが 1Password を読めるようになるまで待つ。vault 名は chezmoi init が尋ねる。
until op vault list >/dev/null 2>&1; do
  echo "1Password アプリにサインインし、設定 > 開発者 > 「1Password CLI と連携」を有効にしてください。"
  read -r -p "準備ができたら Enter で再確認します..."
done

sh -c "$(curl -fsLS https://get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply kryota-dev

echo "完了しました。ターミナルを開き直してください。"
