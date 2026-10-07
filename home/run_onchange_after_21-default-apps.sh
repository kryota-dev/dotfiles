#!/bin/bash
set -euo pipefail

# duti は brew bundle で入る。入っていなければ apply を止めずに飛ばす。
if ! command -v duti >/dev/null; then
  echo "WARNING: duti が無いため、既定のアプリを設定しませんでした。" >&2
  exit 0
fi

# ブラウザは Chrome。macOS は確認のダイアログを経ない変更を拒むことがある（error -54）ので、
# 失敗しても apply は止めない。
for scheme in http https; do
  duti -s com.google.Chrome "${scheme}" ||
    echo "WARNING: ${scheme} の既定のブラウザを設定できませんでした。システム設定で選んでください。" >&2
done

# Web で開くことが多い HTML・PDF も Chrome
duti -s com.google.Chrome public.html all
duti -s com.google.Chrome com.adobe.pdf all

# テキストのデータは VS Code
duti -s com.microsoft.VSCode public.json all
duti -s com.microsoft.VSCode net.daringfireball.markdown all

echo "既定のアプリを設定しました。"
