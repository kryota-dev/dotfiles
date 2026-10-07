#!/bin/bash
# apply のたびに実行する。macOS の更新で Rosetta が消えたり、新しい Xcode で Homebrew が動かなくなる
# ライセンス同意が再び必要になったりするため。正常なマシンでは何もしない。
set -euo pipefail

[ -n "${CI:-}" ] && exit 0

# Homebrew 自身のライセンス判定に合わせる。developer dir が "/" だと xcrun が固まるので飛ばす。
if xcode_dir="$(/usr/bin/xcode-select -p 2>/dev/null)" && [ -n "$xcode_dir" ] && [ "$xcode_dir" != "/" ]; then
  if ! out="$(/usr/bin/xcrun --find clang 2>&1)" && [[ "$out" == *license* ]]; then
    echo "Xcode のライセンスに同意します..."
    /usr/bin/sudo /usr/bin/xcodebuild -license accept || echo "WARNING: sudo xcodebuild -license accept を手で実行してください。" >&2
  fi
fi

# Brewfile の Intel 専用の cask と App Store アプリのための Rosetta 2。
if [ "$(/usr/bin/uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Rosetta 2 をインストールします..."
  /usr/bin/sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license || echo "WARNING: Rosetta 2 のインストールに失敗しました。" >&2
fi
