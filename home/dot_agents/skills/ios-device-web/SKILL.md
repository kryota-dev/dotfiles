---
name: ios-device-web
description: |
  USB 接続した**実 iPhone / iPad** の Safari とホーム画面 Web App（PWA）の中で JS を直接実行し、
  DOM・ストレージ・Service Worker・ネットワーク状態を観測する skill。pymobiledevice3 の
  RemoteXPC トンネル越しに Web Inspector を CDP として開くので、Android の `adb forward` + CDP と
  **同等の証拠**を iOS 実機で取れる。
  トリガー: "iOS 実機", "iPhone 実機", "iPad 実機", "実機で確認", "実機検証", "Web Inspector",
  "pymobiledevice3", "実機で JS", "PWA を実機で", "実機のオフライン挙動", "機内モードで確認"
  使用場面: PWA の `navigator.storage.persist()` が実機で付与されるか、ホーム画面に追加した後の
  挙動、機内モードでのコールドスタート、端末再起動を跨いだ保持、iOS 固有のストレージ分離。
  **iPhone を USB で繋いで Web の挙動を確かめる話が出たら、利用者が skill 名を出さなくても必ず使う。**
  ただし実機でなくて済むなら `virtual-device`、ブラウザの外のネイティブ UI 操作なら `phone-harness`。
user-invocable: true
---

# ios-device-web

実 iOS 端末の**ページの中**へ入る。画面を見るのでも、シミュレータで代用するのでもなく、
実機で動いている JS コンテキストに触る。

## まず層を選ぶ

実機は準備に手間がかかり、利用者の手も borrow する。**安く済むなら安いところで終わらせる。**

| 見たいもの | 使う層 |
|---|---|
| レイアウト・a11y 監査・オフライン縮退の UI・vitals | デスクトップ Chromium（`agent-browser set device …`）。最速 |
| WebKit の描画差、iOS の CSS 崩れ | iOS Simulator → **`virtual-device`** |
| 共有シート・ホーム画面に追加・権限ダイアログなど**ブラウザの外** | **`phone-harness`**（iPhone Mirroring）または利用者の手 |
| **実電波・実機の永続化付与・実機の bot 判定・端末再起動を跨いだ保持** | **この skill** |

`virtual-device` は「仮想端末は実機検証の代替にならない」と自分で線を引いている。その先が
ここの担当になる。

## なぜ Web Inspector なのか

実機の Web 層に入る道は事実上これ 1 本しかない。

- **iPhone Mirroring は動画ストリーム**で、DOM にも JS にも触れない（`phone-harness` 自身がそう書いている）。
  画面の文字を OCR で読むところまでが限界で、`navigator.storage.persisted()` の生の値は取れない
- **Simulator は電波を持たない。** 機内モードも、圏外からの復帰も、reCAPTCHA の実判定も再現しない
- iOS 17 以降、Web Inspector のサービスは RemoteXPC の裏へ移った。素の lockdown では届かず、
  **トンネルの確立が必須**になっている

## 前提

母艦（macOS）:

```bash
uv tool install pymobiledevice3
```

端末側は**利用者にしか実行できない**。3 つあるので、細切れに頼まず**まとめて 1 回で依頼する**
（デベロッパモードの切替は端末の再起動を伴うため、往復が増えると待ち時間が積み上がる）。

1. USB ケーブルで接続し、「このコンピュータを信頼しますか？」→ **信頼**（パスコード入力あり）
2. 設定 → プライバシーとセキュリティ → **デベロッパモード** → オン（**再起動が要る**）
3. 設定 → アプリ → Safari → 詳細 → **Web インスペクタ** と **リモートオートメーション** → オン

依頼したら、待ち受けはバックグラウンドのポーリングに任せて他の準備を進める。手が空くのを待たない。

確認:

```bash
pymobiledevice3 usbmux list                  # 端末が見えるか（機種・iOS・UDID）
pymobiledevice3 amfi developer-mode-status   # true
```

## 接続

```bash
scripts/ios-web-connect.sh          # → 接続 OK  RSD=…  CDP=http://127.0.0.1:9222
```

中でやっているのは 3 段だけで、**冪等に何度でも叩ける**。

1. `pymobiledevice3 remote start-tunnel --script-mode` で RemoteXPC トンネルを張る
   （macOS は Apple ネイティブ経路なので **root 不要**）
2. 得た `HOST PORT` を `pymobiledevice3 webinspector cdp --rsd HOST PORT --port 9222` へ渡す
3. `/json/list` が応答するまで待つ

失敗したら、まず端末側の Web インスペクタが ON かを疑う。`Failed to connect to service port` は
「トンネルが無い」、`Web inspector is not enabled` は「端末設定が OFF」で、原因が違う。

## 見る・触る

```bash
scripts/cdp-eval.py list                      # ターゲット一覧（id / title / url）
scripts/cdp-eval.py probe  <target>           # PWA の定番観測値をまとめて
scripts/cdp-eval.py eval   <target> <<'JS'    # 同期式
location.href
JS
scripts/cdp-eval.py aeval  <target> <<'JS'    # 非同期（関数本体。return を書く）
return await navigator.storage.persisted()
JS
```

`<target>` は id / title / url への部分一致。**Safari タブとインストール済み PWA は別プロセス**
として並ぶので、両方いるときは `PID:744:3` のような id で指定する。曖昧なまま先頭一致に任せると、
測ったつもりの対象が違っていても気づけない。

`probe` が返すのは `persisted` / `standalone` / `displayMode` / `online` / `navType` / SW の
active・waiting / cache キーと precache 件数 / IndexedDB 一覧 / localStorage・sessionStorage の
キー / body テキストの先頭。**PWA の検証で毎回同じものを見ることになるので定型化してある。**

React などの制御下にある入力を埋めるときは、`value` の native setter を呼んでから `input` を
`bubbles: true` で投げる。素の `el.value = x` はフレームワークの state に伝わらない。

```js
const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
set.call(el, '…'); el.dispatchEvent(new Event('input', { bubbles: true }))
```

## 落とし穴

どれも一度は踏む。**症状から原因が読み取りにくいものばかり**なので、先に目を通しておく価値がある。

| 症状 | 実際の原因と対処 |
|---|---|
| `start-tunnel --udid <UDID>` が `remotepairingd reported no device` | `--udid` を**付けない**と通る。remotepairingd は UDID で引けない |
| `webinspector` が `Failed to connect to service port` | iOS 17+ は RemoteXPC の裏。トンネルを先に張る |
| `webinspector` が `Web inspector is not enabled` | 端末設定が OFF。利用者に依頼する（母艦側では直せない） |
| `--rsd` が `requires 2 arguments` | **zsh はパラメータ展開を field split しない。** `$RSD` は 1 引数のまま渡る。host と port を明示的に分ける |
| `await` を含む式が `{}` を返す | このアダプタは CDP 固有の `awaitPromise` を解決しない。`aeval` を使う |
| **電波状態を変えた直後に CDP が HTTP 500 /** `No route to host` | トンネルが落ちただけ。`usbmux list` は端末を返し続ける＝ USB は生きている。`ios-web-connect.sh` を叩き直せば**機内モードのままでも観測を続けられる** |
| **ダウンロード後に `href` が `about:blank` / `bodyLen: 0`** | iOS がファイルビューアをオーバーレイ表示し、**inspect 対象を横取りしている**。アプリは白紙化していない。→ 下記 |

### `about:blank` を「アプリが壊れた」と読まない

ページがファイルを保存させると（`<a download>` + blob URL など）、iOS は受け側のアプリの上に
**ネイティブのファイルビューアを重ねる**。Web Inspector から見えるのはそのビューアの空の
コンテキストなので、`about:blank` / 本文長 0 が返る。

これは**実際に誤診しやすい**。画面を見ずに CDP の値だけで「アプリが白紙化した」と結論すると、
存在しないバグを報告することになる。ダウンロードを伴う操作をしたら、**画面のスクリーンショットを
利用者に求めてから判断する**。ビューアは × で閉じられ、閉じれば元のページへ戻る。

`history.back()` を送って復旧を試みるのは**やらない** — 掴んでいるのはビューア側の履歴で、
何が起きるか読めない。

## 電波を切って測る

実機でしか取れない検証の本体。手順は単純だが**順序が効く**。

1. 利用者に機内モードを ON にしてもらう
2. **トンネルが落ちるので `ios-web-connect.sh` を叩き直す**（USB は生きている）
3. `probe` で `online: false` を確認してから測り始める。ここを飛ばすと「本当に圏外だったか」の
   証拠が無い記録になる
4. 復帰も同じ。機内モード OFF → **張り直し** → 収束を観測

`agent-browser set offline` や CDP のネットワークエミュレーションとは**断ち方が違う**
（DNS・TCP タイムアウト・`navigator.onLine` の発火タイミング）。実電波で測ることに意味がある
場面でだけここへ来ているはずなので、エミュレーションで代用しない。

## 人にしか押せない操作

CDP は**ページの中**しか触れない。次は利用者に頼む。頼むときは**何を確認したいのかを添える**と、
利用者が画面で異常に気づいて教えてくれる。

- ホーム画面に追加（共有シート）。**「Web アプリとして開く」トグルがオンであること**を必ず確認して
  もらう — オフだと単なるブックマークになり、`persisted()` が付与されない
- PWA の強制終了（App スイッチャーから上スワイプ）→ ホーム画面から起動。**これが真のコールドスタート**で、
  `location.reload()` は代用にならない（`probe` の `navType` が `navigate` かで見分けられる）
- 端末そのものの再起動、機内モードの切替、パスコード / パスワード入力、ダウンロードのビューアを閉じる

**強制終了と端末再起動の後はプロセスが変わる**ので、`cdp-eval.py list` でターゲット id を取り直す。
再起動後は当然トンネルも張り直す。

## 片付け

```bash
pkill -f "pymobiledevice3 webinspector cdp"
pkill -f "pymobiledevice3 remote start-tunnel"
```

端末側の**デベロッパモードと Web インスペクタは利用者の設定**なので、こちらで戻さない。
検証が終わったら「戻すならこの 2 つ」と伝えるところまでをやる。

## ここでも取れないもの

- **ブラウザの外**（ネイティブ UI・共有シート・OS の権限ダイアログ）→ `phone-harness` か利用者の手
- **CDP 固有の機能**の一部。これは WebKit Inspector Protocol へのアダプタなので、Chrome DevTools
  Protocol にしか無い API を前提にした道具はそのまま動くとは限らない。`Runtime.evaluate` は堅い
- **長時間運用の再現**。数回のコールドスタートが通ったことは、当日の連続運用の保証にならない
