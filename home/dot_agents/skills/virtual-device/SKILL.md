---
name: virtual-device
description: |
  iOS Simulator / Android Emulator を起動し、実 Mobile Safari / 実 Chrome をエージェントから
  駆動する skill。WebKit 固有の崩れ、PWA の「ホーム画面に追加」、実モバイル Chrome での
  Service Worker / オフライン挙動を、実機を出さずに検証したいときに使う。
  探索テストの進め方そのものは `agent-browser skills get dogfood` へ委譲する（再発明しない）。
  トリガー: "virtual-device", "シミュレータ", "エミュレータ", "iOS で確認", "Android で確認",
  "モバイルで dogfood", "実機っぽく確認"
  使用場面: WebKit 固有バグの再現、PWA インストール検証、モバイル幅の実描画確認。
user-invocable: true
---

# virtual-device

仮想端末の**実ブラウザ**を駆動する。デスクトップ Chromium のデバイスエミュレーションでは
出ない差（WebKit の描画、モバイル Chrome の SW、ネイティブ UI）を見るためだけに使う。

## まず層を選ぶ

**全部を仮想端末でやらない。** 仮想端末は遅く、使える機能も減る。目的で層を選ぶ。

| 見たいもの | 使う層 |
|---|---|
| レイアウト・タッチターゲット・a11y 監査・オフライン縮退・vitals・React 再描画 | **デスクトップ Chromium**（`agent-browser set device "iPhone 16 Pro"`）。最速・全機能 |
| 実 WebKit の描画、iOS 固有の崩れ（safe-area・100vh・input ズーム） | **iOS Simulator** |
| 実モバイル Chrome の DOM・Service Worker・オフライン | **Android Emulator** |
| ホーム画面に追加(A2HS)・共有シート・権限ダイアログなど**ブラウザの外** | **mobile-mcp**（両 OS） |

デスクトップ Chromium で足りるなら、そこで終わらせる。

## 前提

`xcrun simctl` / `adb` / `emulator` / `appium` / `mobile-mcp` を使う。導入は chezmoi 管理下に
あるので、**この skill でインストール手順を実行しない**。足りないものがあれば、何が無いかを
利用者に伝えて止まる。

端末の UDID / AVD 名は環境ごとに違う。**ハードコードせず必ず列挙してから使う。**

```bash
xcrun simctl list devices available     # iOS
emulator -list-avds && adb devices      # Android
```

## iOS Simulator

### 1. 起動

```bash
xcrun simctl boot "<UDID>"        # 既に Booted ならエラーになるので無視してよい
```

### 2. どちらのドライバが使えるか必ず確かめる

`agent-browser -p ios` は Appium セッションの確立に失敗すると、**エラーを出さずに
デスクトップの HeadlessChrome へフォールバックして成功として報告する**。snapshot も
screenshot も返ってくるので、UA を見るまで検出できない。

**この確認を飛ばさない:**

```bash
agent-browser --session ios -p ios --device "<名前>" batch \
  "open <url>" "eval navigator.userAgent"
```

- `Mozilla/5.0 (iPhone; ...) Version/xx Mobile/15E148 Safari/604.1` が返った
  → **実 Safari を掴めている。** そのまま `snapshot -i` / `click @e1` / `eval` が使える
- `HeadlessChrome` や `Macintosh` が返った
  → **掴めていない。** 以降の結果は WebKit の証拠にならない。下の mobile-mcp に切り替える

### 3. mobile-mcp で駆動する（フォールバック、およびネイティブ UI 全般）

```
mobile_list_available_devices              # UDID を得る
mobile_open_url        {device, url}       # Safari で開く
mobile_list_elements_on_screen {device}    # ネイティブのアクセシビリティツリー
mobile_save_screenshot {device, saveTo}
mobile_click_on_screen_at_coordinates {device, x, y}
mobile_swipe_on_screen {device, direction}
```

**mobile-mcp は WebView の中の DOM を見ない。** ページの要素は `WebView` 1 個としてしか
返らないので、入力欄やボタンは**スクリーンショットを見て座標でタップする**。
DOM に対するアサーションが要るなら Android かデスクトップ Chromium で取る。

A2HS の検証はここでしかできない（共有シート → ホーム画面に追加はネイティブ UI）。

## Android Emulator

adb が入力を全部持っているので、追加の自動化ツールは要らない。

### 1. 起動して boot 完了を待つ

```bash
emulator -avd <名前> -no-boot-anim &
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 5; done
adb devices
```

### 2. Chrome を開いて CDP を通す

```bash
adb shell am start -a android.intent.action.VIEW -d '<url>' \
  -n com.android.chrome/com.google.android.apps.chrome.Main
adb forward tcp:9222 localabstract:chrome_devtools_remote
curl -s http://127.0.0.1:9222/json/version    # 応答がなければ Chrome がまだ前面に無い
```

`adb forward` は**セッションのたびに張り直す**。

初回起動の Chrome はサインイン誘導や通知許諾のダイアログを出し、これを閉じるまで
CDP ソケットが開かない。`adb exec-out screencap -p > /tmp/x.png` で画面を見て、
`adb shell input tap <x> <y>` で閉じる。**座標を覚えない**（解像度と Chrome の版で動く）。

### 3. agent-browser を CDP で繋ぐ

```bash
agent-browser --session android --cdp 9222 batch \
  "eval navigator.userAgent" "snapshot -i" "screenshot /tmp/x.png"
```

CDP なので `set offline on|off` / `console` / `network` / `vitals` / `a11y` が**実モバイル
Chrome に対して**使える。オフライン検証はここが本命。

## ローカル開発サーバを見るとき

Service Worker は secure context でしか登録されない。

- **iOS Simulator** は Mac と同じネットワークスタックなので `http://localhost:<port>` が
  そのまま通る
- **Android Emulator** の `10.0.2.2` は **secure origin ではないので SW が登録されない**。
  必ずポートを逆方向に通して `localhost` で開く:

  ```bash
  adb reverse tcp:<port> tcp:<port>
  ```

https で配信済みの URL があるなら、それを叩くのが一番確実。

## 落とし穴

- **agent-browser はコマンドをまたぐとセッションが持たないことがある。** `open` の次の
  `snapshot` が空を返したり `No sessionId in response` で落ちる。**`batch` で 1 呼び出しに
  まとめる。** 用途ごとに `--session <名前>` を分ける（既存セッションのプロバイダは
  後から切り替わらない）
- **iOS / Safari の WebDriver セッションでは CDP 依存機能が使えない** — `a11y` 監査・
  `set offline`・`console`・`vitals`・`react`・`--allowed-domains` は対象外。これらは
  デスクトップ Chromium と Android で担保する
- **iOS Simulator にカメラは無い。** `getUserMedia` は必ず失敗するので、QR スキャンなどの
  正常系は検証できない（縮退 UI の検証にはなる）。カメラが要るなら Android で AVD に
  ホストの webcam を割り当てる
- **仮想端末は実機検証の代替にならない。** 電波、実機カメラ、iOS の 7 日 storage eviction、
  reCAPTCHA/bot 判定に依存する疎通は、ここでは確認できない。**iOS 実機のページの中を
  JS レベルで見る必要が出たら `ios-device-web`**（USB 経由で Web Inspector を CDP として開く）
- エミュレータ／シミュレータは重い。使い終わったら落とす

## 片付け

```bash
agent-browser close --all
adb emu kill
xcrun simctl shutdown all
```

## 探索テストそのもの

「何をどう探索して、どう報告するか」はこの skill の担当ではない。端末とブラウザが
繋がったら `agent-browser skills get dogfood` を読み、そのワークフロー（証跡付きレポート）に
乗せる。
