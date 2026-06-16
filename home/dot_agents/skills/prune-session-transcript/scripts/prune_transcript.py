#!/usr/bin/env python3
"""Claude Code のセッション transcript (JSONL) を安全に切り詰めるツール。

汚染されたコンテキスト（誤ったツール出力・思考に基づく調査など）を、ユーザーが
指定した「ここまで残したい」メッセージ以降から駆除し、そのセッションを resume した
ときに正しい地点から再開できる状態にする。

設計上の要点:
- JSONL は1行=1イベント。保持する行は再シリアライズせず原文のまま書き出し、
  既存行へのフォーマット差分の混入を防ぐ。
- Claude Code の resume は `last-prompt` エントリの `leafUuid` を分岐点として使う。
  したがって leaf メッセージ直後のメタ行（last-prompt 等）を保持境界に含め、
  「保持領域の最後の last-prompt が leaf を指している」状態を担保する。
- 破壊的操作なので、書き込みは --apply 指定時のみ。既定は dry-run。
- 書き込み前に必ずタイムスタンプ付きバックアップを作成し、保持行が全て有効な
  JSON であることを検証してから atomic に置換する。
- 実行中の自セッションは誤操作防止のため拒否する（--current-session-id）。
"""

import argparse
import glob
import json
import os
import shutil
import sys
import time

# parentUuid によるメッセージツリーを構成する行種別
MESSAGE_TYPES = {"user", "assistant"}

# メッセージツリーを壊さない「メタ行」種別。leaf 直後に連続するこれらは
# 同一ターン境界の付随情報とみなし、保持境界に取り込む。
META_TYPES = {
    "last-prompt",
    "ai-title",
    "mode",
    "permission-mode",
    "system",
    "file-history-snapshot",
    "attachment",
    "summary",
}


def short(u):
    """UUID を先頭8文字に短縮（None は "-"）。"""
    return u[:8] if u else "-"


def load(path):
    """JSONL を読み込み、(行番号1始まり, 原文文字列, パース結果 or None) のリストを返す。"""
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for i, raw in enumerate(f, start=1):
            line = raw.rstrip("\n")
            if line.strip() == "":
                rows.append((i, raw, None))
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                obj = None
            rows.append((i, raw, obj))
    return rows


def content_snippet(obj, limit=72):
    """message.content から人間可読のスニペットを生成する。"""
    if obj is None:
        return "(invalid json)"
    t = obj.get("type")
    if t == "last-prompt":
        return f"leaf={short(obj.get('leafUuid'))} prompt={(obj.get('lastPrompt') or '')[:48]!r}"
    if t in ("ai-title", "mode", "permission-mode", "file-history-snapshot", "system", "attachment"):
        return f"({t})"
    msg = obj.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content[:limit].replace("\n", " ")
    if isinstance(content, list):
        parts = []
        for c in content:
            ct = c.get("type")
            if ct == "text":
                parts.append("TXT:" + (c.get("text") or "")[:40].replace("\n", " "))
            elif ct == "thinking":
                parts.append("THINK")
            elif ct == "tool_use":
                parts.append("USE:" + str(c.get("name")))
            elif ct == "tool_result":
                parts.append("RESULT")
            else:
                parts.append(str(ct))
        return " | ".join(parts)[:limit]
    return "-"


def cmd_map(args):
    """全行を 行番号/種別/role/uuid/parent/内容 で一覧表示する（切り詰め点を探す用）。

    先頭の `*` は resume 安全な leaf 候補（= Claude Code がターン境界として記録した点）。
    切り詰めはこの印の付いた行を leaf に選ぶと resume が最もきれいになる。印の有無は
    構造（last-prompt.leafUuid）から導く客観情報で、内容の意味づけはしない。
    """
    rows = load(args.file)
    boundaries = set(turn_boundary_lines(rows, uuid_line_map(rows)))
    for ln, _raw, obj in rows:
        mark = "*" if ln in boundaries else " "
        if obj is None:
            print(f"{mark}{ln:>4}\t(blank/invalid)")
            continue
        t = obj.get("type", "-")
        role = (obj.get("message") or {}).get("role", "-")
        uuid = short(obj.get("uuid"))
        parent = short(obj.get("parentUuid"))
        print(f"{mark}{ln:>4}\t{t:<22}\t{role:<9}\t{uuid}\t<-{parent}\t{content_snippet(obj)}")
    print(f"\n# 合計 {len(rows)} 行 / `*`=resume安全な leaf候補: {args.file}", file=sys.stderr)


def cmd_list(args):
    """$HOME/.claude*/projects/ 配下のセッション JSONL を更新時刻順に一覧表示する。"""
    roots = []
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.append(os.path.join(cfg, "projects"))
    roots += sorted(glob.glob(os.path.join(os.path.expanduser("~"), ".claude*", "projects")))
    seen = set()
    files = []
    for root in roots:
        for p in glob.glob(os.path.join(root, "*", "*.jsonl")):
            if p in seen:
                continue
            seen.add(p)
            try:
                files.append((os.path.getmtime(p), p))
            except OSError:
                continue
    files.sort(reverse=True)
    for mtime, p in files[: args.limit]:
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime))
        first = ""
        try:
            for _ln, _raw, obj in load(p):
                if obj and obj.get("type") == "user":
                    msg = (obj.get("message") or {}).get("content")
                    if isinstance(msg, str):
                        first = msg[:50].replace("\n", " ")
                        break
        except OSError:
            pass
        print(f"{ts}\t{os.path.basename(p)}\t{first}")


def resolve_leaf(rows, args):
    """--line / --uuid / --match から leaf 行 (index 0始まり) を解決する。

    複数候補や未発見は例外でなく (None, 理由メッセージ) を返し、呼び出し側が制御する。
    """
    msg_rows = [(idx, ln, obj) for idx, (ln, _raw, obj) in enumerate(rows)
                if obj and obj.get("type") in MESSAGE_TYPES]
    if args.line is not None:
        for idx, (ln, _raw, obj) in enumerate(rows):
            if ln == args.line:
                if not (obj and obj.get("type") in MESSAGE_TYPES):
                    return None, f"行 {args.line} は user/assistant メッセージではありません（type={obj.get('type') if obj else 'invalid'}）"
                return idx, None
        return None, f"行 {args.line} が存在しません"
    if args.uuid is not None:
        cands = [idx for idx, ln, obj in msg_rows if obj.get("uuid") == args.uuid or short(obj.get("uuid")) == args.uuid]
        if not cands:
            return None, f"uuid {args.uuid} のメッセージが見つかりません"
        if len(cands) > 1:
            return None, f"uuid {args.uuid} が複数該当します"
        return cands[0], None
    if args.match is not None:
        needle = args.match
        cands = []
        for idx, ln, obj in msg_rows:
            blob = json.dumps(obj.get("message", {}), ensure_ascii=False)
            if needle in blob:
                cands.append((idx, ln))
        if not cands:
            return None, f"`{needle}` を含むメッセージが見つかりません"
        if len(cands) > 1:
            lns = ", ".join(str(ln) for _i, ln in cands)
            return None, f"`{needle}` が複数行に該当します（行: {lns}）。--line で一意に指定してください"
        return cands[0][0], None
    return None, "--line / --uuid / --match のいずれかを指定してください"


def compute_keep_boundary(rows, leaf_idx):
    """leaf 行以降、連続するメタ行を取り込んだ保持境界 index (inclusive) を返す。"""
    k = leaf_idx
    n = len(rows)
    while k + 1 < n:
        nxt = rows[k + 1][2]
        if nxt is None:
            break
        if nxt.get("type") in META_TYPES:
            k += 1
        else:
            break
    return k


def last_last_prompt_leaf(rows, k_inclusive):
    """保持領域 (0..k) 内で最後の last-prompt の leafUuid を返す（無ければ None）。"""
    leaf = None
    found = False
    for idx in range(0, k_inclusive + 1):
        obj = rows[idx][2]
        if obj and obj.get("type") == "last-prompt":
            leaf = obj.get("leafUuid")
            found = True
    return (found, leaf)


def cmd_prune(args):
    path = args.file
    rows = load(path)

    # 自セッションへの誤操作防止
    if args.current_session_id:
        base = os.path.splitext(os.path.basename(path))[0]
        if base == args.current_session_id:
            print(f"[拒否] 対象は実行中の自セッション ({base}) です。別セッションから実行してください。", file=sys.stderr)
            return 2

    leaf_idx, err = resolve_leaf(rows, args)
    if leaf_idx is None:
        print(f"[エラー] leaf を解決できません: {err}", file=sys.stderr)
        return 1

    leaf_obj = rows[leaf_idx][2]
    leaf_uuid = leaf_obj.get("uuid")
    leaf_line = rows[leaf_idx][0]

    k = compute_keep_boundary(rows, leaf_idx)
    keep_count = k + 1
    removed = len(rows) - keep_count
    boundary_line = rows[k][0]

    found_lp, lp_leaf = last_last_prompt_leaf(rows, k)
    resume_safe = found_lp and (lp_leaf == leaf_uuid)

    # 保持行が全て有効 JSON か検証
    invalid = [rows[i][0] for i in range(keep_count) if rows[i][2] is None and rows[i][1].strip() != ""]

    print("==== 切り詰めプラン ====")
    print(f"対象ファイル      : {path}")
    print(f"総行数            : {len(rows)}")
    print(f"leaf メッセージ   : 行 {leaf_line} (type={leaf_obj.get('type')}, uuid={short(leaf_uuid)})")
    print(f"  内容            : {content_snippet(leaf_obj)}")
    print(f"保持境界          : 行 1〜{boundary_line}（メタ行 {boundary_line - leaf_line} 行を取り込み）")
    print(f"保持/削除         : 保持 {keep_count} 行 / 削除 {removed} 行")
    if found_lp:
        print(f"resume 分岐点     : 保持領域 最後の last-prompt.leafUuid = {short(lp_leaf)}")
    else:
        print("resume 分岐点     : 保持領域に last-prompt が存在しません")
    if resume_safe:
        print("resume 整合性     : OK（leaf と一致。回答直後から再開できます）")
    else:
        print("resume 整合性     : 要注意（leaf と不一致 → resume が手前から再開する恐れ）")
        print("                    --fix-resume を付けると leaf を指す last-prompt を補正追記します。")
    if invalid:
        print(f"[警告] 保持対象に不正 JSON 行があります: {invalid}")

    if not args.apply:
        print("\n(dry-run) 実際に書き込むには --apply を付けてください。")
        return 0

    if invalid:
        print("\n[中止] 不正 JSON 行を含むため書き込みません。", file=sys.stderr)
        return 1

    # バックアップ
    ts = time.strftime("%Y%m%d-%H%M%S")
    bak = f"{path}.bak-{ts}"
    shutil.copy2(path, bak)

    # 保持行を組み立て（原文のまま）
    kept = [rows[i][1] if rows[i][1].endswith("\n") else rows[i][1] + "\n" for i in range(keep_count)]

    # resume 補正（任意）: leaf を指す last-prompt を末尾に追記
    appended_fix = False
    if args.fix_resume and not resume_safe:
        template = None
        for i in range(keep_count):
            obj = rows[i][2]
            if obj and obj.get("type") == "last-prompt":
                template = dict(obj)
        if template is None:
            template = {"type": "last-prompt"}
        template["type"] = "last-prompt"
        template["leafUuid"] = leaf_uuid
        # 直近の user テキストプロンプトを lastPrompt に採用
        for i in range(leaf_idx, -1, -1):
            obj = rows[i][2]
            if obj and obj.get("type") == "user":
                c = (obj.get("message") or {}).get("content")
                if isinstance(c, str):
                    template["lastPrompt"] = c
                    break
        kept.append(json.dumps(template, ensure_ascii=False) + "\n")
        appended_fix = True

    # atomic 置換
    tmp = f"{path}.tmp-{ts}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(kept)
    os.replace(tmp, path)

    # 検証
    after = load(path)
    after_invalid = [ln for ln, _raw, obj in after if obj is None and _raw.strip() != ""]
    found_lp2, lp_leaf2 = last_last_prompt_leaf(after, len(after) - 1)
    ok2 = found_lp2 and lp_leaf2 == leaf_uuid

    print("\n==== 実行結果 ====")
    print(f"バックアップ      : {bak}")
    print(f"書き込み後行数    : {len(after)}（削除 {len(rows) - len(after) + (1 if appended_fix else 0)} 行）")
    print(f"JSON 検証         : {'OK' if not after_invalid else 'NG ' + str(after_invalid)}")
    if appended_fix:
        print("resume 補正        : leaf を指す last-prompt を追記しました")
    print(f"resume 整合性     : {'OK' if ok2 else '要確認（leaf と不一致）'}（最後の last-prompt.leafUuid={short(lp_leaf2)} / leaf={short(leaf_uuid)}）")
    print("\n復元する場合: cp '%s' '%s'" % (bak, path))
    return 0 if (not after_invalid and ok2) else 1


def uuid_line_map(rows):
    """uuid -> 行番号 の対応表。"""
    m = {}
    for ln, _raw, obj in rows:
        if obj and obj.get("uuid"):
            m[obj["uuid"]] = ln
    return m


def turn_boundary_lines(rows, umap):
    """resume 安全な leaf 候補（= last-prompt.leafUuid が指す「メッセージ行」）一覧。

    Claude Code は各ターン境界で last-prompt を記録する。その leafUuid が指す行を
    leaf にすると、保持領域の last-prompt がちょうどその leaf を指す＝resume が
    意図通りに再開する。prune は leaf にメッセージ型しか受け付けないため、ここでも
    user/assistant 行に限定する（attachment 等を指す境界は候補にしない）。
    """
    # uuid -> その行の type
    type_of = {obj["uuid"]: obj.get("type")
               for _ln, _raw, obj in rows if obj and obj.get("uuid")}
    lines = set()
    for _ln, _raw, obj in rows:
        if obj and obj.get("type") == "last-prompt":
            leaf = obj.get("leafUuid")
            if leaf in umap and type_of.get(leaf) in MESSAGE_TYPES:
                lines.add(umap[leaf])
    return sorted(lines)


def render_blocks(obj, limit):
    """1メッセージを役割つきの読みやすいテキストに整形する（show 用）。"""
    msg = obj.get("message") or {}
    c = msg.get("content")
    if isinstance(c, str):
        return c[:limit]
    if not isinstance(c, list):
        return "-"
    parts = []
    for b in c:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text":
            parts.append("【TEXT】 " + (b.get("text") or "")[:limit])
        elif t == "thinking":
            parts.append("【THINK】 " + (b.get("thinking") or "")[:limit])
        elif t == "tool_use":
            inp = json.dumps(b.get("input") or {}, ensure_ascii=False)
            parts.append(f"【TOOL_USE: {b.get('name')}】 {inp[:limit]}")
        elif t == "tool_result":
            rc = b.get("content")
            if isinstance(rc, list):
                txt = "".join(x.get("text", "") for x in rc if isinstance(x, dict) and x.get("type") == "text")
            else:
                txt = rc if isinstance(rc, str) else ""
            parts.append("【TOOL_RESULT】 " + (txt or "")[:limit])
        else:
            parts.append(f"【{t}】")
    return "\n".join(parts)


def cmd_show(args):
    """指定範囲のメッセージを、デコード済みの読みやすい本文で表示する（読み取り専用）。

    生 JSON を読むより低コストで、エージェントが「どこから汚染が始まったか」を
    自分の判断で見極めるための材料を提供する。判定ロジックは持たない。
    """
    rows = load(args.file)
    umap = uuid_line_map(rows)
    boundaries = set(turn_boundary_lines(rows, umap))

    if args.range:
        try:
            lo_s, hi_s = args.range.split("-", 1)
            lo, hi = int(lo_s), int(hi_s)
        except ValueError:
            print("[エラー] --range は A-B 形式で指定してください（例: 95-130）", file=sys.stderr)
            return 1
    else:
        lo = hi = args.line

    for ln, _raw, obj in rows:
        if not (lo <= ln <= hi):
            continue
        if obj is None:
            print(f"\n===== 行{ln} (invalid json) =====")
            continue
        t = obj.get("type")
        mark = "  ◀ resume安全な leaf候補" if ln in boundaries else ""
        if t not in MESSAGE_TYPES:
            print(f"\n----- 行{ln} [{t}]{mark} -----")
            continue
        role = (obj.get("message") or {}).get("role", "-")
        print(f"\n===== 行{ln} {role} ({t}){mark} =====")
        print(render_blocks(obj, args.limit))
    return 0


def build_parser():
    p = argparse.ArgumentParser(description="Claude Code セッション JSONL を安全に切り詰める")
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("map", help="全行の一覧（切り詰め点を探す）")
    m.add_argument("file")
    m.set_defaults(func=cmd_map)

    sh = sub.add_parser("show", help="指定範囲のメッセージをデコード本文で表示（内容を読んで判断する用）")
    sh.add_argument("file")
    g2 = sh.add_mutually_exclusive_group(required=True)
    g2.add_argument("--range", help="表示する行範囲 A-B（例: 95-130）")
    g2.add_argument("--line", type=int, help="単一行")
    sh.add_argument("--limit", type=int, default=600, help="各ブロックの最大表示文字数（既定600）")
    sh.set_defaults(func=cmd_show)

    ls = sub.add_parser("list", help="セッション JSONL を更新時刻順に一覧")
    ls.add_argument("--limit", type=int, default=20)
    ls.set_defaults(func=cmd_list)

    pr = sub.add_parser("prune", help="leaf 以降を切り詰める（既定 dry-run）")
    pr.add_argument("file")
    g = pr.add_mutually_exclusive_group(required=True)
    g.add_argument("--line", type=int, help="残す最後のメッセージの行番号")
    g.add_argument("--uuid", help="残す最後のメッセージの uuid（先頭8文字可）")
    g.add_argument("--match", help="残す最後のメッセージに含まれる文字列（一意であること）")
    pr.add_argument("--apply", action="store_true", help="実際に書き込む（無指定は dry-run）")
    pr.add_argument("--fix-resume", action="store_true", help="leaf を指す last-prompt が無い場合に補正追記する")
    pr.add_argument("--current-session-id", help="実行中セッションID。一致時は拒否")
    pr.set_defaults(func=cmd_prune)
    return p


def main():
    args = build_parser().parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
