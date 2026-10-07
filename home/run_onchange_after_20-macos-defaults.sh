#!/bin/bash
set -euo pipefail

# キーボード・表示の基本
defaults write com.apple.HIToolbox AppleFnUsageType -int 2
defaults write NSGlobalDomain AppleKeyboardUIMode -int 2
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write NSGlobalDomain AppleShowScrollBars -string "Always"
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain InitialKeyRepeat -int 25

# 外観をダークにする
defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"
defaults write NSGlobalDomain AppleIconAppearanceTheme -string "RegularDark"

# 開く・保存のダイアログをリスト表示にする
defaults write NSGlobalDomain NavPanelFileListModeForOpenMode -int 2
defaults write NSGlobalDomain NavPanelFileListModeForSaveMode -int 2

# ⌘Space を Raycast に譲り、Spotlight を ⌘⌥Space に移す。⌘⌥Space の既定の割り当て（Finder の
# 検索ウィンドウ）は衝突するので無効にする。activateSettings で即時に反映する。
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 \
  '<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1572864</integer></array><key>type</key><string>standard</string></dict></dict>'
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 65 \
  '<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1572864</integer></array><key>type</key><string>standard</string></dict></dict>'

# 入力ソースの切り替えは ⌃Space（前の入力ソース）だけを使い、「次の入力ソース」は無効にする
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 61 \
  '<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>786432</integer></array><key>type</key><string>standard</string></dict></dict>'

# 入力ソースは ABC と Google 日本語入力（IME を入れてから再ログインで反映）
defaults write com.apple.HIToolbox AppleEnabledInputSources -array \
  '<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>252</integer><key>KeyboardLayout Name</key><string>ABC</string></dict>' \
  '<dict><key>Bundle ID</key><string>com.apple.CharacterPaletteIM</string><key>InputSourceKind</key><string>Non Keyboard Input Method</string></dict>' \
  '<dict><key>Bundle ID</key><string>com.apple.50onPaletteIM</string><key>InputSourceKind</key><string>Non Keyboard Input Method</string></dict>' \
  '<dict><key>Bundle ID</key><string>com.apple.PressAndHold</string><key>InputSourceKind</key><string>Non Keyboard Input Method</string></dict>'
defaults write com.apple.inputsources AppleEnabledThirdPartyInputSources -array \
  '<dict><key>Bundle ID</key><string>com.google.inputmethod.Japanese</string><key>Input Mode</key><string>com.apple.inputmethod.Japanese</string><key>InputSourceKind</key><string>Input Mode</string></dict>' \
  '<dict><key>Bundle ID</key><string>com.google.inputmethod.Japanese</string><key>InputSourceKind</key><string>Keyboard Input Method</string></dict>'

# 表示言語と地域を日本語にする（再ログインで反映）
defaults write NSGlobalDomain AppleLanguages -array "ja-JP" "en-JP"
defaults write NSGlobalDomain AppleLocale -string "ja_JP"

# パーソナライズ広告を無効にする
defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false

# Finder のスプリングローディング
defaults write NSGlobalDomain com.apple.springing.enabled -bool true
defaults write NSGlobalDomain com.apple.springing.delay -float 0.5

# トラックパッド
defaults write NSGlobalDomain com.apple.trackpad.forceClick -bool true
defaults write NSGlobalDomain com.apple.trackpad.scaling -float 2

# サウンドフィードバック
defaults write NSGlobalDomain com.apple.sound.beep.feedback -bool true
defaults write NSGlobalDomain com.apple.sound.beep.flash -bool false

# ネットワーク・USB ドライブに .DS_Store を作らない
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Dock
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock tilesize -int 44

# Finder
defaults write com.apple.finder AppleShowAllFiles -bool true
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool true
defaults write com.apple.finder ShowMountedServersOnDesktop -bool true
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# スクリーンショットをデスクトップに散らかさず、影も付けない（SystemUIServer の再起動で反映）
mkdir -p "${HOME}/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "${HOME}/Pictures/Screenshots"
defaults write com.apple.screencapture disable-shadow -bool true

# メニューバーの時計（ControlCenter の再起動で反映）
defaults write com.apple.menuextra.clock IsAnalog -bool false
defaults write com.apple.menuextra.clock Show24Hour -bool true
defaults write com.apple.menuextra.clock ShowAMPM -bool true
defaults write com.apple.menuextra.clock ShowDate -int 0
defaults write com.apple.menuextra.clock ShowDayOfWeek -bool true
defaults write com.apple.menuextra.clock ShowSeconds -bool true

# ターミナル
defaults write com.apple.terminal StringEncodings -array 4

# Simulator で Mac のキーボードとクリップボードをそのまま使う
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool true
defaults write com.apple.iphonesimulator PasteboardAutomaticSync -bool true

# TextEdit の新規書類をプレーンテキストにする（sandbox のアプリなので、値はコンテナ側に書かれる）
defaults write com.apple.TextEdit RichText -bool false

for app in "Dock" "Finder" "SystemUIServer" "ControlCenter"; do
  killall "${app}" &>/dev/null || true
done
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

# ファイアウォールを有効にする（既定は無効）。sudo に失敗しても apply は止めない。
/usr/bin/sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null ||
  echo "WARNING: sudo socketfilterfw --setglobalstate on を手で実行してください。" >&2

echo "macOS の defaults を適用しました。"
