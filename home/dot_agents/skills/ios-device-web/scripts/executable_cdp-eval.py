#!/usr/bin/env -S uv run --quiet --with websocket-client --python 3.13
"""実 iPhone / iPad のページで JS を評価する。ios-web-connect.sh が開いた CDP を使う。

  cdp-eval.py list                       ターゲット一覧（id / title / url）
  cdp-eval.py eval   <target> < expr     同期式を評価する
  cdp-eval.py aeval  <target> < body     非同期の関数本体を評価する（`return` を書く）
  cdp-eval.py probe  <target>            PWA の定番観測値をまとめて取る

<target> はターゲットの id / title / url のいずれかに対する部分一致。
先頭で一致したものを使うので、Safari タブと PWA が両方いるときは id で指定する。

なぜ aeval が要るか: この CDP は WebKit Inspector Protocol へのアダプタで、
CDP 固有の `awaitPromise` を解決しない。素直に `await` を書いた式は `{}` を返す。
aeval は「グローバルへ結果を書いてから同期で読み出す」定型を代行する。
"""
import json
import sys
import time
import urllib.request
import uuid

import websocket

PORT = __import__("os").environ.get("IOS_WEB_CDP_PORT", "9222")
BASE = f"http://127.0.0.1:{PORT}"


def targets():
    try:
        with urllib.request.urlopen(f"{BASE}/json/list", timeout=10) as r:
            return json.load(r)
    except Exception as e:
        raise SystemExit(
            f"CDP に繋がらない ({e})。端末の電波状態を変えたならトンネルが落ちている。"
            " ios-web-connect.sh を叩き直す"
        )


def pick(sub):
    hits = [t for t in targets() if sub.lower() in json.dumps(t, ensure_ascii=False).lower()]
    if not hits:
        listing = "\n".join(f"  {t.get('id')} | {t.get('title')} | {t.get('url')}" for t in targets())
        raise SystemExit(f"target が見つからない: {sub}\n見えているもの:\n{listing}")
    return hits[0]


def evaluate(ws_url, expr):
    ws = websocket.create_connection(ws_url, timeout=30)
    try:
        ws.send(json.dumps({
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {"expression": expr, "returnByValue": True,
                       "allowUnsafeEvalBlockedByCSP": True},
        }))
        while True:
            msg = json.loads(ws.recv())
            if msg.get("id") == 1:
                break
    finally:
        ws.close()
    res = msg.get("result", {})
    if "exceptionDetails" in res:
        raise SystemExit("EXCEPTION: " + json.dumps(res["exceptionDetails"], ensure_ascii=False))
    return res.get("result", {}).get("value")


def async_evaluate(ws_url, body, timeout=30.0):
    key = "__cdp_" + uuid.uuid4().hex[:8]
    kick = (
        f"window.{key}={{s:'pending'}};"
        f"(async()=>{{try{{const v=await (async()=>{{{body}}})();"
        f"window.{key}={{s:'ok',v:JSON.stringify(v===undefined?null:v)}};}}"
        f"catch(e){{window.{key}={{s:'err',v:String(e&&e.stack||e)}};}}}})();'kicked'"
    )
    evaluate(ws_url, kick)
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = evaluate(ws_url, f"JSON.stringify(window.{key})")
        state = json.loads(got) if got else {"s": "pending"}
        if state.get("s") == "ok":
            evaluate(ws_url, f"delete window.{key}")
            raw = state.get("v")
            return json.loads(raw) if raw is not None else None
        if state.get("s") == "err":
            evaluate(ws_url, f"delete window.{key}")
            raise SystemExit("EXCEPTION: " + str(state.get("v")))
        time.sleep(0.5)
    raise SystemExit(f"{timeout}s 以内に解決しなかった")


PROBE = """
const reg = await navigator.serviceWorker.getRegistration().catch(() => null)
const cacheKeys = await caches.keys().catch(() => [])
let precache = null
const c = cacheKeys.find(k => k.includes('precache'))
if (c) precache = (await (await caches.open(c)).keys()).length
const dbs = indexedDB.databases ? (await indexedDB.databases()).map(d => d.name).sort() : 'unsupported'
return {
  href: location.href,
  navType: (performance.getEntriesByType('navigation')[0] || {}).type,
  online: navigator.onLine,
  standalone: navigator.standalone,
  displayMode: matchMedia('(display-mode: standalone)').matches,
  persisted: await navigator.storage.persisted(),
  sw: reg ? { active: !!reg.active, waiting: !!reg.waiting, installing: !!reg.installing } : null,
  cacheKeys, precache, idb: dbs,
  local: Object.keys(localStorage), session: Object.keys(sessionStorage),
  bodyText: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 600),
}
"""


def main():
    argv = sys.argv[1:]
    cmd = argv[0] if argv else "list"
    if cmd == "list":
        for t in targets():
            print(f"{t.get('id')}\t{t.get('title')}\t{t.get('url')}")
        return
    if cmd not in ("eval", "aeval", "probe"):
        raise SystemExit(__doc__)
    if len(argv) < 2:
        raise SystemExit("target を指定する（cdp-eval.py list で確認できる）")
    t = pick(argv[1])
    ws = t["webSocketDebuggerUrl"]
    if cmd == "probe":
        out = async_evaluate(ws, PROBE)
    elif cmd == "aeval":
        out = async_evaluate(ws, sys.stdin.read())
    else:
        out = evaluate(ws, sys.stdin.read())
    print(out if isinstance(out, str) else json.dumps(out, ensure_ascii=False, indent=1))


main()
