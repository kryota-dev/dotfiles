#!/usr/bin/env python3
"""既存 auto-memory の機械再検証（knowledge-distill Phase 0.5、kryota-dev/dotfiles#631）。

auto-memory は「新しく保存されたか」しか観測されておらず、**既に保存済みのメモリが腐って
いないか**は誰も見ていなかった。実監査で 4 件（参照先の実体が消えた 2 件・恒久ルールに
吸収されて存在意義が消えた 2 件）が見つかっている。本スクリプトはその 2 種類の腐敗を
機械で拾える範囲だけ拾い、**報告のみ**を行う（memory ディレクトリへは一切書き込まない）。

意味的な判定（「解除条件が満たされたか」「この学びはまだ有効か」）は機械化しない。人に残す。

一次ソース: https://code.claude.com/docs/en/memory#auto-memory
  - "The first 200 lines of MEMORY.md, or the first 25KB, whichever comes first, are loaded
    at the start of every conversation."
  - "Claude Code records the write time in a `modified` frontmatter field as an ISO 8601
    timestamp."（v2.1.214 以降。frontmatter を持たないファイルには付与されない）
  - "It also skips anything your CLAUDE.md files already say."（重複検出はこの公式ルールが
    事後に破れた状態を拾う）

## 設計上の 3 つの不変条件

1. **「検査できなかった」と「問題なし」を別の値で表す。** 各チェックは `checked` /
   `findings` / `unchecked` / `reasons` を独立に持ち、終了コードは finding の有無（bit0）と
   検査可否（bit1）を別ビットで表す。`2>/dev/null` と `|| true` の併用でパース失敗が
   「0 件」に写像される事故を構造的に起こさない。
2. **無言スキップ経路を作らない。** ripgrep 再帰（`rg` 再帰 / `grep -rI`）は gitignore 対象と
   生 NUL バイトを含むファイルをエラーも警告も出さずに飛ばす。ここでは memory ディレクトリを
   `os.scandir` で列挙し、ルールファイルは明示パスで直読みし、NUL バイトを見つけたら
   当該ファイルに関わるチェックを `inconclusive` にする。
3. **finding は「断定できる形」にだけ出す。** 絶対パス・`~` 始まり・glob・root セグメントが
   無いものなどは、存在しないことを断定できないので `unchecked` に落とし、**必ず列挙する**。

単一ファイルに閉じてあるのは、週次 headless 実行の `--allowedTools` 許可エントリを 1 件に
保つため（許可リストに無いコマンドは production で無言拒否される。#491 と同型の故障）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, Iterable, List, NoReturn, Optional, Sequence, Set, Tuple

# --- 名前付き定数 -----------------------------------------------------------

# MEMORY.md の読み込み上限（公式仕様）。
MEMORY_INDEX_MAX_LINES = 200
# 「25KB」は SI（25000）とも 2 進（25600）とも取れる。小さい方を採り、過小警告に倒れない。
MEMORY_INDEX_MAX_BYTES = 25_000
# 上限接近で警告する比率。公式が "If the file is near a limit, Claude Code reminds Claude to
# shorten it" と述べており、接近そのものが行動に値する。
MEMORY_INDEX_WARN_RATIO = 0.9

# 重複検出に使う文字 n-gram の長さ。
DUPLICATE_SHINGLE_SIZE = 5
# 含有率 |A∩B| / |A| がこの値以上なら「恒久ルールが既に同じことを書いている」とみなす。
# 報告のみのフェーズなので、見落とし（永久に見えない）より拾いすぎ（人が 1 行読んで捨てる）に倒す。
DUPLICATE_CONTAINMENT_THRESHOLD = 0.35
# n-gram がこれ未満のファイルは短すぎて判定できない（unchecked に倒す）。
DUPLICATE_MIN_SHINGLES = 30

# PR / Issue 番号の境界検証。桁あふれした数値を外部コマンドへ渡さない。
PR_NUMBER_MAX = 9_999_999
# 1 回の実行で gh に問い合わせる最大件数。
PR_REFERENCE_MAX_QUERIES = 50
# staleness で git log を呼ぶ最大件数。
GIT_LOG_MAX_QUERIES = 200
# 外部コマンド 1 回あたりのタイムアウト（秒）。
SUBPROCESS_TIMEOUT_SECONDS = 20

# 終了コード。finding の有無と検査可否は別ビットで表す。
EXIT_CLEAN = 0
EXIT_FINDING = 1
EXIT_INCONCLUSIVE = 2
EXIT_USAGE = 64
EXIT_INTERNAL = 70

# memory ディレクトリ導出時に Claude Code のプロジェクトスラグへ変換する文字。
PROJECT_SLUG_TRANSLATION = str.maketrans({"/": "-", ".": "-"})

CHECK_IDS = (
    "path-exists",
    "make-target",
    "pr-reference",
    "staleness",
    "rule-duplication",
    "memory-index-size",
)

MEMORY_INDEX_NAME = "MEMORY.md"

# --- 正規表現 ---------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n", re.S)
MODIFIED_FIELD_RE = re.compile(r"^modified:[ \t]*(.+?)[ \t]*$", re.M)
FENCE_RE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"`+([^`\n]+?)`+")
HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*$")
FENCED_BLOCK_RE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,}).*?^[ ]{0,3}\1", re.S | re.M)
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")

# パス候補として扱える文字集合。シェル演算子（> | & ; $ ( ) " '）を含むトークンは
# そもそもパスに見えないので候補にしない。
PATH_TOKEN_RE = re.compile(r"^[A-Za-z0-9._~/+@{}*?,-]+$")
GLOB_CHARS = frozenset("{}*?")
# スラッシュを持たないファイル名候補。拡張子はアルファベット始まり 1〜5 文字に限る
# （`v2.1` や `3.14.7` のようなバージョン番号を巻き込まないため）。
BARE_FILENAME_RE = re.compile(r"^\.?[A-Za-z0-9_][A-Za-z0-9._-]*\.[A-Za-z][A-Za-z0-9]{0,4}$")
# 拡張子を持たない dotfile（`.brewfile-linux-exclude` など）。
BARE_DOTFILE_RE = re.compile(r"^\.[A-Za-z][A-Za-z0-9._-]*$")

MAKE_INVOCATION_RE = re.compile(
    r"\bmake[ \t]+((?:[A-Za-z0-9_.][A-Za-z0-9_.-]*[ \t]+)*[A-Za-z0-9_.][A-Za-z0-9_.-]*)"
)
# 地の文で「target らしい形」だけを拾う（`make sure` のような英文を target と誤認しない）。
MAKE_PROSE_TARGET_RE = re.compile(r"\bmake[ \t]+([A-Za-z0-9_.]+[-_][A-Za-z0-9_.-]*)")
MAKE_TARGET_LINE_RE = re.compile(
    r"^([A-Za-z0-9_.][A-Za-z0-9_./%-]*(?:[ \t]+[A-Za-z0-9_.$(){}/%-]+)*)[ \t]*:(?!=)"
)

PR_REF_RE = re.compile(
    r"(?:(?P<slug>[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*))?"
    r"#(?P<num>\d{1,9})(?![0-9A-Za-z_])"
)
REMOTE_SLUG_RE = re.compile(r"[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$")

# 判定対象外にした候補を剥がすための前後の飾り。
STRIP_LEADING = "(（\"'`「『【"
STRIP_TRAILING = ")）\"'`」』】,、。;:：；!！?？"


# --- データモデル -----------------------------------------------------------


@dataclass
class Item:
    """finding / unchecked の 1 件。

    memory 本文は載せない（クライアント情報の転記面を最小化する）。載せるのは
    「どのファイルの何行目で、どの参照について、なぜそう判定したか」まで。
    """

    memory_file: str
    line: int  # 0 = ファイル全体に対する判定
    subject: str
    reason: str

    def to_dict(self) -> dict:
        return {
            "memory_file": self.memory_file,
            "line": self.line,
            "subject": self.subject,
            "reason": self.reason,
        }


@dataclass
class CheckResult:
    """1 チェックの結果。

    `checked` を必ず持つのが要点。「0 件中 finding 0」と「12 件中 finding 0」が
    レポート上で区別できないと、検査が壊れて何も見ていない状態が「問題なし」に見える。
    """

    id: str
    checked: int = 0
    findings: List[Item] = field(default_factory=list)
    unchecked: List[Item] = field(default_factory=list)
    reasons: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)

    @property
    def status(self) -> str:
        if self.findings:
            return "finding"
        if self.reasons:
            return "inconclusive"
        return "ok"

    def add_reason(self, reason: str) -> None:
        """チェック自体が実行できなかった理由を、重複させずに記録する。"""
        if reason not in self.reasons:
            self.reasons.append(reason)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "status": self.status,
            "checked": self.checked,
            "findings": [i.to_dict() for i in self.findings],
            "unchecked": [i.to_dict() for i in self.unchecked],
            "reasons": list(self.reasons),
            "notes": list(self.notes),
        }


@dataclass
class MemoryFile:
    name: str
    path: Path
    text: Optional[str]
    error: Optional[str]  # 読めなかった理由（nul-bytes / decode-error / io-error: ...）
    size_bytes: int
    line_count: int
    modified: Optional[datetime]
    modified_source: str  # frontmatter-modified | mtime | unknown

    @property
    def is_index(self) -> bool:
        return self.name == MEMORY_INDEX_NAME


@dataclass
class PathCandidate:
    """memory から抽出したパス参照 1 件。"""

    memory_file: str
    line: int
    raw: str
    relpath: Optional[str]  # 判定できた場合のリポジトリ相対パス
    verdict: str  # exists | missing | unchecked
    reason: str


@dataclass
class RuleSection:
    rule_file: str
    heading: str
    shingles: Set[str]


# --- 汎用ヘルパ -------------------------------------------------------------


def run_command(argv: Sequence[str], cwd: Optional[Path] = None) -> subprocess.CompletedProcess:
    """外部コマンドを引数リストで起動する。

    `shell=True` は使わない。memory 由来の文字列がコマンド行として解釈される経路を
    そもそも作らないため（呼び出し側でも値を検証している）。
    """
    return subprocess.run(  # noqa: S603 - 引数リスト起動。shell は介さない
        list(argv),
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=SUBPROCESS_TIMEOUT_SECONDS,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def parse_iso8601(value: str) -> Optional[datetime]:
    """ISO 8601 文字列を timezone 付き datetime にする。解釈できなければ None。"""
    text = value.strip().strip("\"'")
    if not text:
        return None
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    for candidate in (text, re.sub(r"(\.\d{6})\d+", r"\1", text)):
        try:
            parsed = datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.astimezone()
        return parsed
    return None


def iso(dt: Optional[datetime]) -> str:
    return dt.isoformat() if dt else "unknown"


def split_markdown(text: str) -> List[Tuple[int, List[str], str]]:
    """行ごとに (行番号, コード片リスト, コード片を除いた地の文) を返す。

    フェンス（``` / ~~~）の内側は行全体をコードとして扱う。パスと `make <target>` の
    抽出をコード内に限るのは、地の文の `make sure` のような英文を target と誤認しないため。
    """
    rows: List[Tuple[int, List[str], str]] = []
    in_fence = False
    fence_char = ""
    for lineno, line in enumerate(text.splitlines(), start=1):
        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group(1)
            if not in_fence:
                in_fence, fence_char = True, marker[0]
                rows.append((lineno, [], ""))
                continue
            if marker[0] == fence_char:
                in_fence = False
                rows.append((lineno, [], ""))
                continue
        if in_fence:
            rows.append((lineno, [line], ""))
            continue
        codes = [m.group(1) for m in INLINE_CODE_RE.finditer(line)]
        rows.append((lineno, codes, INLINE_CODE_RE.sub(" ", line)))
    return rows


def normalize_for_shingles(text: str) -> str:
    """重複判定用に正規化する。

    句読点・記号・空白を Unicode カテゴリ単位で落とすので、`、` と `,`、全角と半角の
    差で n-gram が割れない。両側に同じ処理を掛けるため情報の非対称は生じない。
    """
    text = FRONTMATTER_RE.sub("", text, count=1)
    text = FENCED_BLOCK_RE.sub(" ", text)
    text = HTML_COMMENT_RE.sub(" ", text)
    text = MD_LINK_RE.sub(r"\1", text)
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(
        ch for ch in text if not unicodedata.category(ch).startswith(("P", "S", "Z", "C"))
    )


def shingles(normalized: str, size: int = DUPLICATE_SHINGLE_SIZE) -> Set[str]:
    if len(normalized) < size:
        return set()
    return {normalized[i : i + size] for i in range(len(normalized) - size + 1)}


def containment(subset: Set[str], superset: Set[str]) -> float:
    """|A∩B| / |A|。「A が B にどれだけ吸収されているか」を測る。

    `difflib` の ratio は長さ差を罰するため、短い memory が長いルール節に吸収されている
    形（今回検出したい重複そのもの）で低く出る。含有率はその定義に直接対応する。
    """
    if not subset:
        return 0.0
    return len(subset & superset) / len(subset)


# --- 入力の解決 -------------------------------------------------------------


def repo_root_of(repo: Path) -> Path:
    """worktree からでも共有元リポジトリのルートを返す（git が無ければ引数のまま）。"""
    try:
        result = run_command(["git", "-C", str(repo), "rev-parse", "--git-common-dir"])
    except (OSError, subprocess.SubprocessError):
        return repo
    if result.returncode != 0 or not result.stdout.strip():
        return repo
    common = Path(result.stdout.strip())
    if not common.is_absolute():
        common = (repo / common).resolve()
    return common.parent


def derive_memory_dir(repo: Path, config_dir: Path) -> Path:
    """auto-memory の既定ディレクトリを導出する。

    公式仕様は「`~/.claude/projects/<project>/memory/`。`<project>` は git リポジトリから
    導出され、worktree 間で共有される」。`<project>` の綴りは公開されていないため、実在の
    ディレクトリ名から `/` と `.` を `-` に置換する規則を読み取った best-effort であり、
    外したときは「解決先が無い」として `inconclusive` になる（黙って誤らない）。
    `--memory-dir` で常に上書きできる。
    """
    slug = str(repo_root_of(repo)).translate(PROJECT_SLUG_TRANSLATION)
    return config_dir / "projects" / slug / "memory"


def default_rule_files(repo: Path) -> List[Path]:
    """重複照合の既定ルールファイル（存在するものだけ）。"""
    home = Path.home()
    candidates = [
        repo / "CLAUDE.md",
        repo / "AGENTS.md",
        repo / ".claude" / "CLAUDE.md",
        home / ".claude" / "CLAUDE.md",
        home / "AGENTS.md",
    ]
    seen: List[Path] = []
    for path in candidates:
        if path.is_file() and path not in seen:
            seen.append(path)
    return seen


def read_text_file(path: Path) -> Tuple[Optional[str], Optional[str], bytes]:
    """(text, error, raw) を返す。生 NUL バイトとデコード失敗を別々に区別する。"""
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return None, "io-error: {}".format(exc.__class__.__name__), b""
    if b"\x00" in raw:
        return None, "nul-bytes", raw
    try:
        return raw.decode("utf-8"), None, raw
    except UnicodeDecodeError:
        return None, "decode-error", raw


def load_memory_files(memory_dir: Path) -> List[MemoryFile]:
    """memory ディレクトリの *.md を列挙して読む。

    ripgrep 系の再帰検索は使わない（gitignore 対象と NUL 入りファイルを無言で飛ばすため）。
    """
    with os.scandir(memory_dir) as entries:
        names = sorted(e.name for e in entries if e.is_file() and e.name.endswith(".md"))

    files: List[MemoryFile] = []
    for name in names:
        path = memory_dir / name
        text, error, raw = read_text_file(path)
        line_count = raw.count(b"\n") + (1 if raw and not raw.endswith(b"\n") else 0)
        modified: Optional[datetime] = None
        source = "unknown"
        if text is not None:
            front = FRONTMATTER_RE.match(text)
            if front:
                field_match = MODIFIED_FIELD_RE.search(front.group(1))
                if field_match:
                    modified = parse_iso8601(field_match.group(1))
                    if modified:
                        source = "frontmatter-modified"
        if modified is None:
            try:
                modified = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
                source = "mtime"
            except OSError:
                source = "unknown"
        files.append(
            MemoryFile(
                name=name,
                path=path,
                text=text,
                error=error,
                size_bytes=len(raw),
                line_count=line_count,
                modified=modified,
                modified_source=source,
            )
        )
    return files


# --- 候補抽出 ---------------------------------------------------------------


def code_tokens(segment: str) -> Iterable[str]:
    for token in segment.split():
        token = token.lstrip(STRIP_LEADING).rstrip(STRIP_TRAILING)
        if token:
            yield token


def classify_path_token(token: str, repo: Path, tracked_basenames: Optional[Set[str]]) -> Optional[Tuple[str, Optional[str], str]]:
    """パス候補を (verdict, relpath, reason) に分類する。None はパス候補ですらない。

    finding を出せるのは「slash 付き・リポジトリ相対・glob 無し・root セグメントが実在」
    という、存在しないことを断定できる形だけ。それ以外は `unchecked` に落とす。
    """
    if not PATH_TOKEN_RE.match(token):
        return None
    if token.startswith(("http:", "https:", "mailto:")):
        return None
    if token.startswith(("/", "~")):
        return "unchecked", None, "リポジトリ相対ではない（絶対パス / ホーム相対）"
    if GLOB_CHARS & set(token):
        return "unchecked", None, "glob / ブレース展開を含み、単一のパスに定まらない"

    if "/" in token:
        rel = token[2:] if token.startswith("./") else token
        rel = rel.rstrip("/")
        if not rel:
            return None
        parts = rel.split("/")
        if any(p in ("", "..") for p in parts):
            return "unchecked", None, "相対参照（..）を含み、指す先が一意でない"
        if not (repo / parts[0]).exists():
            return "unchecked", rel, "先頭セグメント `{}` がリポジトリに無く、パス参照か判定できない".format(parts[0])
        if (repo / rel).exists():
            return "exists", rel, ""
        return "missing", rel, "リポジトリ内に存在しない"

    if not (BARE_FILENAME_RE.match(token) or BARE_DOTFILE_RE.match(token)):
        return None
    if (repo / token).exists():
        return "exists", token, ""
    if tracked_basenames is None:
        return "unchecked", None, "ディレクトリを伴わないファイル名（git の追跡一覧を取得できず未解決）"
    if token in tracked_basenames:
        return "exists", None, ""
    return "unchecked", None, "ディレクトリを伴わないファイル名（リポジトリ直下にも追跡一覧にも無い）"


def collect_path_candidates(
    memory_files: Sequence[MemoryFile], repo: Path, tracked_basenames: Optional[Set[str]]
) -> List[PathCandidate]:
    candidates: List[PathCandidate] = []
    for mem in memory_files:
        if mem.text is None:
            continue
        for lineno, codes, _prose in split_markdown(mem.text):
            for segment in codes:
                for token in code_tokens(segment):
                    classified = classify_path_token(token, repo, tracked_basenames)
                    if classified is None:
                        continue
                    verdict, rel, reason = classified
                    candidates.append(
                        PathCandidate(
                            memory_file=mem.name,
                            line=lineno,
                            raw=token,
                            relpath=rel,
                            verdict=verdict,
                            reason=reason,
                        )
                    )
    return candidates


def git_tracked_basenames(repo: Path) -> Optional[Set[str]]:
    """`git ls-files` で追跡ファイルのベース名集合を得る（取得できなければ None）。

    ripgrep 再帰ではなく git を使うのは house rule どおり。追跡ファイル限定なので
    「無い」の断定には使わず、「ある」と言うためだけに使う。
    """
    try:
        result = run_command(["git", "-C", str(repo), "ls-files", "-z"])
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return {name.rsplit("/", 1)[-1] for name in result.stdout.split("\0") if name}


# --- 各チェック -------------------------------------------------------------


def check_path_exists(candidates: Sequence[PathCandidate]) -> CheckResult:
    result = CheckResult("path-exists")
    for cand in candidates:
        if cand.verdict == "unchecked":
            result.unchecked.append(Item(cand.memory_file, cand.line, cand.raw, cand.reason))
            continue
        result.checked += 1
        if cand.verdict == "missing":
            result.findings.append(Item(cand.memory_file, cand.line, cand.raw, cand.reason))
    return result


def parse_makefile_targets(makefile_text: str) -> Set[str]:
    targets: Set[str] = set()
    for line in makefile_text.splitlines():
        if line.startswith("\t") or not MAKE_TARGET_LINE_RE.match(line):
            continue
        lhs, _, rhs = line.partition(":")
        names = lhs.split()
        if names == [".PHONY"]:
            # `.PHONY: a b c` は右辺が target 名。
            targets.update(n for n in rhs.split() if "$" not in n and "%" not in n)
            continue
        targets.update(n for n in names if "%" not in n and not n.startswith("."))
    return targets


def check_make_target(memory_files: Sequence[MemoryFile], repo: Path) -> CheckResult:
    result = CheckResult("make-target")
    makefile = repo / "Makefile"
    makefile_text: Optional[str] = None
    if makefile.is_file():
        makefile_text, error, _ = read_text_file(makefile)
        if makefile_text is None:
            result.add_reason("Makefile を読めなかった（{}）".format(error))
    else:
        result.add_reason("リポジトリに Makefile が無く、target の実在を確認できない")

    targets = parse_makefile_targets(makefile_text) if makefile_text is not None else set()

    for mem in memory_files:
        if mem.text is None:
            continue
        for lineno, codes, prose in split_markdown(mem.text):
            for segment in codes:
                for match in MAKE_INVOCATION_RE.finditer(segment):
                    for name in match.group(1).split():
                        if makefile_text is None:
                            result.unchecked.append(
                                Item(mem.name, lineno, "make " + name, "Makefile を読めていない")
                            )
                            continue
                        result.checked += 1
                        if name not in targets:
                            result.findings.append(
                                Item(
                                    mem.name,
                                    lineno,
                                    "make " + name,
                                    "Makefile に target `{}` が存在しない".format(name),
                                )
                            )
            for match in MAKE_PROSE_TARGET_RE.finditer(prose):
                result.unchecked.append(
                    Item(
                        mem.name,
                        lineno,
                        "make " + match.group(1),
                        "コードスパン外の記述（地の文の誤検出を避けるため判定しない）",
                    )
                )
    return result


def resolve_repo_slug(repo: Path) -> Optional[str]:
    """`<owner>/<repo>` を git remote から得る（ネットワークには触れない）。"""
    try:
        result = run_command(["git", "-C", str(repo), "remote", "get-url", "origin"])
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    match = REMOTE_SLUG_RE.search(result.stdout.strip())
    return match.group(1) if match else None


def collect_pr_references(memory_files: Sequence[MemoryFile]) -> List[Tuple[MemoryFile, int, str, Optional[str]]]:
    refs: List[Tuple[MemoryFile, int, str, Optional[str]]] = []
    for mem in memory_files:
        if mem.text is None:
            continue
        for lineno, line in enumerate(mem.text.splitlines(), start=1):
            for match in PR_REF_RE.finditer(line):
                refs.append((mem, lineno, match.group("num"), match.group("slug")))
    return refs


def check_pr_reference(memory_files: Sequence[MemoryFile], repo: Path, mode: str) -> CheckResult:
    result = CheckResult("pr-reference")
    refs = collect_pr_references(memory_files)

    # 参照が 1 件も無ければ「確認しなかった」ものは無い。ここで理由を積むと、
    # 検査すべき対象が無いだけの実行まで inconclusive になり、警告が意味を失う。
    if mode == "off":
        if refs:
            result.add_reason(
                "--github=off のため PR / Issue 番号の実在を確認していない（{} 件が未確認）".format(len(refs))
            )
        return result
    if shutil.which("gh") is None:
        if refs:
            result.add_reason(
                "gh CLI が PATH に無く、PR / Issue 番号の実在を確認できない（{} 件が未確認{}）".format(
                    len(refs), "。--github=on が明示されていた" if mode == "on" else ""
                )
            )
        return result
    if not refs:
        return result

    default_slug = resolve_repo_slug(repo)
    if default_slug is None:
        result.add_reason("git remote origin から `<owner>/<repo>` を解決できず、既定の照会先が定まらない")

    cache: Dict[Tuple[str, str], Tuple[str, str]] = {}
    queries = 0
    for mem, lineno, number, slug in refs:
        target_slug = slug or default_slug
        subject = ("{}#{}".format(slug, number)) if slug else "#{}".format(number)
        if target_slug is None:
            result.unchecked.append(Item(mem.name, lineno, subject, "照会先リポジトリが不明"))
            continue
        if number.startswith("0"):
            result.unchecked.append(
                Item(mem.name, lineno, subject, "先頭が 0 の数値は Issue / PR 番号ではない")
            )
            continue
        value = int(number)
        if not 1 <= value <= PR_NUMBER_MAX:
            result.unchecked.append(Item(mem.name, lineno, subject, "番号が想定範囲外"))
            continue

        key = (target_slug, number)
        if key not in cache:
            if queries >= PR_REFERENCE_MAX_QUERIES:
                result.unchecked.append(
                    Item(mem.name, lineno, subject, "1 回の実行での照会上限（{}）に達した".format(PR_REFERENCE_MAX_QUERIES))
                )
                continue
            queries += 1
            cache[key] = query_github_issue(target_slug, value)
        verdict, detail = cache[key]

        if verdict == "found":
            result.checked += 1
        elif verdict == "missing":
            result.checked += 1
            result.findings.append(
                Item(mem.name, lineno, subject, "GitHub 上に存在しない（{}）".format(detail))
            )
        else:
            # 照会そのものが失敗した = 「問題なし」ではない。チェック側にも理由を上げる。
            result.unchecked.append(Item(mem.name, lineno, subject, detail))
            result.add_reason("gh の照会に失敗した参照がある（{}）".format(detail))
    return result


def query_github_issue(slug: str, number: int) -> Tuple[str, str]:
    """(verdict, detail) を返す。verdict は found / missing / error。

    `--silent` で本文を捨てるのは、判定に要るのが「引けたか / 404 か / それ以外の失敗か」
    だけであり、レスポンス本文（issue のタイトル等）をレポートへ持ち込まないため。
    `--jq` のような追加の解釈段を挟むと、式の失敗が「照会失敗」に化ける経路が増える。
    """
    argv = ["gh", "api", "--silent", "repos/{}/issues/{}".format(slug, number)]
    try:
        result = run_command(argv)
    except subprocess.TimeoutExpired:
        return "error", "gh がタイムアウトした"
    except (OSError, subprocess.SubprocessError) as exc:
        return "error", "gh を起動できなかった（{}）".format(exc.__class__.__name__)
    if result.returncode == 0:
        return "found", ""
    stderr = result.stderr.strip()
    if "HTTP 404" in stderr or "Not Found" in stderr:
        return "missing", "gh api が 404 を返した"
    first_line = stderr.splitlines()[0] if stderr else "exit {}".format(result.returncode)
    return "error", "gh api エラー: {}".format(first_line[:200])


def check_staleness(
    memory_files: Sequence[MemoryFile], candidates: Sequence[PathCandidate], repo: Path
) -> CheckResult:
    result = CheckResult("staleness")
    try:
        probe = run_command(["git", "-C", str(repo), "rev-parse", "--is-inside-work-tree"])
    except (OSError, subprocess.SubprocessError) as exc:
        result.add_reason("git を起動できず、参照先の最終変更日を取得できない（{}）".format(exc.__class__.__name__))
        return result
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        result.add_reason("git リポジトリではないため、参照先の最終変更日を取得できない")
        return result

    by_name = {m.name: m for m in memory_files}
    cache: Dict[str, Tuple[str, str]] = {}
    queries = 0

    for cand in candidates:
        if cand.verdict != "exists" or not cand.relpath:
            continue
        mem = by_name.get(cand.memory_file)
        if mem is None or mem.modified is None:
            result.unchecked.append(
                Item(cand.memory_file, cand.line, cand.raw, "memory 側の日付を決められない")
            )
            continue
        if cand.relpath not in cache:
            if queries >= GIT_LOG_MAX_QUERIES:
                result.unchecked.append(
                    Item(cand.memory_file, cand.line, cand.raw, "git log の照会上限（{}）に達した".format(GIT_LOG_MAX_QUERIES))
                )
                continue
            queries += 1
            cache[cand.relpath] = last_commit_iso(repo, cand.relpath)
        verdict, payload = cache[cand.relpath]

        if verdict == "untracked":
            result.unchecked.append(
                Item(cand.memory_file, cand.line, cand.raw, "git 追跡外のため最終変更日が取れない")
            )
            continue
        if verdict == "error":
            result.unchecked.append(Item(cand.memory_file, cand.line, cand.raw, payload))
            result.add_reason("git log の照会に失敗した参照がある（{}）".format(payload))
            continue

        commit_dt = parse_iso8601(payload)
        if commit_dt is None:
            result.unchecked.append(
                Item(cand.memory_file, cand.line, cand.raw, "git log の日付を解釈できなかった")
            )
            result.add_reason("git log の出力を日付として解釈できなかった")
            continue

        result.checked += 1
        if commit_dt > mem.modified:
            result.findings.append(
                Item(
                    cand.memory_file,
                    cand.line,
                    cand.raw,
                    "参照先が {} に変更されている（memory の日付 {} / 出所 {}）より後。記述が実態と合っているか要再確認".format(
                        iso(commit_dt), iso(mem.modified), mem.modified_source
                    ),
                )
            )
    return result


def last_commit_iso(repo: Path, relpath: str) -> Tuple[str, str]:
    try:
        result = run_command(
            ["git", "-C", str(repo), "log", "-1", "--format=%cI", "--", relpath]
        )
    except subprocess.TimeoutExpired:
        return "error", "git log がタイムアウトした"
    except (OSError, subprocess.SubprocessError) as exc:
        return "error", "git log を起動できなかった（{}）".format(exc.__class__.__name__)
    if result.returncode != 0:
        first_line = result.stderr.strip().splitlines()
        return "error", "git log エラー: {}".format(first_line[0][:200] if first_line else "exit 非 0")
    output = result.stdout.strip()
    if not output:
        return "untracked", ""
    return "ok", output


def load_rule_sections(rule_files: Sequence[Path], result: CheckResult) -> List[RuleSection]:
    sections: List[RuleSection] = []
    for path in rule_files:
        text, error, _ = read_text_file(path)
        if text is None:
            result.add_reason("ルールファイル {} を読めなかった（{}）".format(path.name, error))
            continue
        label = str(path)
        current_heading = "(冒頭)"
        buffer: List[str] = []
        in_fence = False
        fence_char = ""

        def flush(heading: str, body: List[str]) -> None:
            joined = "\n".join(body)
            normalized = normalize_for_shingles(joined)
            grams = shingles(normalized)
            if grams:
                sections.append(RuleSection(label, heading, grams))

        for line in text.splitlines():
            fence = FENCE_RE.match(line)
            if fence:
                marker = fence.group(1)
                if not in_fence:
                    in_fence, fence_char = True, marker[0]
                elif marker[0] == fence_char:
                    in_fence = False
                buffer.append(line)
                continue
            heading = None if in_fence else HEADING_RE.match(line)
            if heading:
                flush(current_heading, buffer)
                current_heading = heading.group(2)
                buffer = []
                continue
            buffer.append(line)
        flush(current_heading, buffer)
    return sections


def check_rule_duplication(memory_files: Sequence[MemoryFile], rule_files: Sequence[Path]) -> CheckResult:
    result = CheckResult("rule-duplication")
    if not rule_files:
        result.add_reason("照合できる CLAUDE.md / AGENTS.md が 1 つも見つからない")
        return result

    sections = load_rule_sections(rule_files, result)
    if not sections:
        result.add_reason("ルールファイルから比較可能なセクションを取り出せなかった")
        return result

    for mem in memory_files:
        if mem.is_index:
            # MEMORY.md は 1 行 1 メモリの索引であり、恒久ルールとの重複判定に馴染まない。
            continue
        if mem.text is None:
            result.unchecked.append(Item(mem.name, 0, mem.name, "読めなかった（{}）".format(mem.error)))
            result.add_reason("memory ファイル {} を読めず重複判定できない（{}）".format(mem.name, mem.error))
            continue
        grams = shingles(normalize_for_shingles(mem.text))
        if len(grams) < DUPLICATE_MIN_SHINGLES:
            result.unchecked.append(
                Item(mem.name, 0, mem.name, "本文が短く（n-gram {} 個）重複を判定できない".format(len(grams)))
            )
            continue

        result.checked += 1
        best = max(sections, key=lambda s: containment(grams, s.shingles))
        score = containment(grams, best.shingles)
        if score >= DUPLICATE_CONTAINMENT_THRESHOLD:
            result.findings.append(
                Item(
                    mem.name,
                    0,
                    "{} 「{}」".format(best.rule_file, best.heading),
                    "恒久ルールが同じことを既に書いている疑い（含有率 {:.2f} ≥ 閾値 {:.2f}）".format(
                        score, DUPLICATE_CONTAINMENT_THRESHOLD
                    ),
                )
            )
        else:
            result.notes.append(
                "{}: 最も近いのは {} 「{}」（含有率 {:.2f} < 閾値 {:.2f}）".format(
                    mem.name, best.rule_file, best.heading, score, DUPLICATE_CONTAINMENT_THRESHOLD
                )
            )
    return result


def check_memory_index_size(memory_files: Sequence[MemoryFile]) -> CheckResult:
    result = CheckResult("memory-index-size")
    index = next((m for m in memory_files if m.is_index), None)
    if index is None:
        if memory_files:
            result.add_reason("topic ファイルはあるが MEMORY.md が無く、索引のサイズを判定できない")
        return result
    if index.error:
        result.add_reason("MEMORY.md を読めなかった（{}）".format(index.error))
        return result

    result.checked += 1
    over_lines = index.line_count > MEMORY_INDEX_MAX_LINES
    over_bytes = index.size_bytes > MEMORY_INDEX_MAX_BYTES
    if over_lines or over_bytes:
        result.findings.append(
            Item(
                index.name,
                0,
                "{} 行 / {} バイト".format(index.line_count, index.size_bytes),
                "読み込み上限（{} 行 / {} バイト）を超過。超過分は次回セッションで読み込まれない".format(
                    MEMORY_INDEX_MAX_LINES, MEMORY_INDEX_MAX_BYTES
                ),
            )
        )
        return result

    warn_lines = MEMORY_INDEX_MAX_LINES * MEMORY_INDEX_WARN_RATIO
    warn_bytes = MEMORY_INDEX_MAX_BYTES * MEMORY_INDEX_WARN_RATIO
    if index.line_count > warn_lines or index.size_bytes > warn_bytes:
        result.findings.append(
            Item(
                index.name,
                0,
                "{} 行 / {} バイト".format(index.line_count, index.size_bytes),
                "読み込み上限（{} 行 / {} バイト）の {:.0f}% に到達。索引を 1 行 1 件へ圧縮する余地がある".format(
                    MEMORY_INDEX_MAX_LINES, MEMORY_INDEX_MAX_BYTES, MEMORY_INDEX_WARN_RATIO * 100
                ),
            )
        )
    return result


# --- 出力 -------------------------------------------------------------------


FOOTER_NOTES = (
    "本フェーズは**報告のみ**。memory の修正・削除は user が明示承認したあとに別途行う。",
    "意味的な判定（解除条件の充足・学びがまだ有効か）は機械化していない。人が判断する。",
    "`make <target>` とパスの抽出はコードスパン／コードブロック内に限定している"
    "（地の文の `make sure` のような誤検出を避けるため）。",
    "「未検査」は設計上判定対象外にした候補で、**「問題なし」ではない**。"
    "「実行不能」はチェック自体が走れなかったことを表す。",
)


def render_text(report: dict) -> str:
    lines: List[str] = []
    add = lines.append
    add("## Phase 0.5: 既存 auto-memory の再検証（報告のみ）")
    add("")
    add("- memory ディレクトリ: `{}`（*.md {} 件）".format(report["memory_dir"], report["memory_file_count"]))
    add("- 照合リポジトリ: `{}`".format(report["repo"]))
    rules = report["rule_files"]
    add("- 重複照合したルールファイル: " + (", ".join("`{}`".format(r) for r in rules) if rules else "（なし）"))
    summary = report["summary"]
    add(
        "- 総合: finding {} 件 / 未検査 {} 件 / 実行不能チェック {} 件（exit {}）".format(
            summary["findings"], summary["unchecked"], summary["inconclusive_checks"], summary["exit_code"]
        )
    )
    add("")
    add("| チェック | 状態 | 検査 | finding | 未検査 | 実行不能 |")
    add("|---|---|---|---|---|---|")
    for check in report["checks"]:
        add(
            "| `{}` | {} | {} | {} | {} | {} |".format(
                check["id"],
                check["status"],
                check["checked"],
                len(check["findings"]),
                len(check["unchecked"]),
                len(check["reasons"]),
            )
        )
    add("")

    findings = [(c["id"], i) for c in report["checks"] for i in c["findings"]]
    add("### finding（{} 件）".format(len(findings)))
    add("")
    if findings:
        for idx, (check_id, item) in enumerate(findings, start=1):
            add("{}. `[{}]` {} — {} : {}".format(idx, check_id, _locate(item), item["subject"], item["reason"]))
    else:
        add("なし")
    add("")

    unchecked = [(c["id"], i) for c in report["checks"] for i in c["unchecked"]]
    add("### 未検査（黙って 0 件に落とさないための明示列挙・{} 件）".format(len(unchecked)))
    add("")
    if unchecked:
        for check_id, item in unchecked:
            add("- `[{}]` {} — {} : {}".format(check_id, _locate(item), item["subject"], item["reason"]))
    else:
        add("なし")
    add("")

    reasons = [(c["id"], r) for c in report["checks"] for r in c["reasons"]]
    add("### 実行不能（「問題なし」ではない・{} 件）".format(len(reasons)))
    add("")
    if reasons:
        for check_id, reason in reasons:
            add("- `[{}]` {}".format(check_id, reason))
    else:
        add("なし")
    add("")

    notes = [(c["id"], n) for c in report["checks"] for n in c["notes"]]
    if notes:
        add("### 参考（閾値未満のスコア）")
        add("")
        for check_id, note in notes:
            add("- `[{}]` {}".format(check_id, note))
        add("")

    add("---")
    add("")
    for note in FOOTER_NOTES:
        add("- " + note)
    return "\n".join(lines) + "\n"


def _locate(item: dict) -> str:
    return "{}:{}".format(item["memory_file"], item["line"]) if item["line"] else item["memory_file"]


def build_report(
    memory_dir: Path,
    repo: Path,
    rule_files: Sequence[Path],
    memory_files: Sequence[MemoryFile],
    checks: Sequence[CheckResult],
) -> dict:
    total_findings = sum(len(c.findings) for c in checks)
    total_unchecked = sum(len(c.unchecked) for c in checks)
    inconclusive = sum(1 for c in checks if c.reasons)
    exit_code = EXIT_CLEAN
    if total_findings:
        exit_code |= EXIT_FINDING
    if inconclusive:
        exit_code |= EXIT_INCONCLUSIVE
    return {
        "memory_dir": str(memory_dir),
        "repo": str(repo),
        "rule_files": [str(p) for p in rule_files],
        "memory_file_count": len(memory_files),
        "memory_files": [
            {
                "name": m.name,
                "readable": m.text is not None,
                "error": m.error,
                "lines": m.line_count,
                "bytes": m.size_bytes,
                "modified": iso(m.modified),
                "modified_source": m.modified_source,
            }
            for m in memory_files
        ],
        "checks": [c.to_dict() for c in checks],
        "summary": {
            "findings": total_findings,
            "unchecked": total_unchecked,
            "inconclusive_checks": inconclusive,
            "exit_code": exit_code,
        },
    }


# --- CLI --------------------------------------------------------------------


class _Parser(argparse.ArgumentParser):
    """usage error を argparse 既定の 2 ではなく EXIT_USAGE(64) で返す。

    2 は「実行できなかったチェックがある」の意味に割り当ててあるため、引数ミスと
    inconclusive が同じ値になると呼び出し側が区別できない。
    """

    def error(self, message: str) -> NoReturn:  # type: ignore[override]
        self.print_usage(sys.stderr)
        sys.stderr.write("{}: error: {}\n".format(self.prog, message))
        raise SystemExit(EXIT_USAGE)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = _Parser(
        prog="memory-revalidate.py",
        description="既存 auto-memory を機械再検証して報告する（書き込みは行わない）",
    )
    parser.add_argument("--memory-dir", type=Path, default=None, help="auto-memory ディレクトリ（省略時はリポジトリから導出）")
    parser.add_argument("--repo", type=Path, default=None, help="照合対象リポジトリ（既定: カレントディレクトリ）")
    parser.add_argument("--rules", type=Path, action="append", default=None, help="重複照合するルールファイル（繰り返し可）")
    parser.add_argument("--config-dir", type=Path, default=None, help="CLAUDE_CONFIG_DIR 相当（memory ディレクトリ導出用）")
    parser.add_argument("--github", choices=("auto", "on", "off"), default="auto", help="PR / Issue 番号の実在確認（既定 auto）")
    parser.add_argument("--format", dest="fmt", choices=("text", "json"), default="text", help="出力形式（既定 text）")
    return parser.parse_args(list(argv))


def guarded(check_id: str, fn: Callable[[], CheckResult]) -> CheckResult:
    """チェック内の想定外例外を握り潰さず `inconclusive` に写像する。

    握り潰して空の結果を返すと、壊れたチェックが「問題なし」に化ける。
    """
    try:
        return fn()
    except Exception as exc:  # noqa: BLE001 - 想定外を inconclusive として可視化するための捕捉
        result = CheckResult(check_id)
        result.add_reason("チェック内で例外が発生した（{}: {}）".format(exc.__class__.__name__, str(exc)[:200]))
        return result


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    repo = (args.repo or Path.cwd()).resolve()
    config_dir = args.config_dir or Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
    memory_dir = (args.memory_dir or derive_memory_dir(repo, Path(config_dir))).expanduser()

    rule_files = [p.expanduser() for p in args.rules] if args.rules else default_rule_files(repo)
    missing_rules = [p for p in rule_files if not p.is_file()]
    rule_files = [p for p in rule_files if p.is_file()]

    try:
        memory_files = load_memory_files(memory_dir)
    except OSError as exc:
        checks = [
            CheckResult(cid, reasons=["memory ディレクトリを読めない: {} ({})".format(memory_dir, exc.__class__.__name__)])
            for cid in CHECK_IDS
        ]
        report = build_report(memory_dir, repo, rule_files, [], checks)
        _emit(report, args.fmt)
        return report["summary"]["exit_code"]

    tracked = git_tracked_basenames(repo)
    candidates = collect_path_candidates(memory_files, repo, tracked)

    checks = [
        guarded("path-exists", lambda: check_path_exists(candidates)),
        guarded("make-target", lambda: check_make_target(memory_files, repo)),
        guarded("pr-reference", lambda: check_pr_reference(memory_files, repo, args.github)),
        guarded("staleness", lambda: check_staleness(memory_files, candidates, repo)),
        guarded("rule-duplication", lambda: check_rule_duplication(memory_files, rule_files)),
        guarded("memory-index-size", lambda: check_memory_index_size(memory_files)),
    ]

    # 読めなかった memory ファイルは、参照抽出に依存するチェックを不完全にする。
    # `memory-index-size` は MEMORY.md 自身だけを見て自前で報告し、`rule-duplication` は
    # topic ファイル単位で自前の理由を積むので、ここでは二重に積まない。
    self_reporting = {"memory-index-size", "rule-duplication"}
    for mem in memory_files:
        if mem.text is None:
            for check in checks:
                if check.id not in self_reporting:
                    check.add_reason(
                        "memory ファイル {} を読めず走査対象から外れている（{}）".format(mem.name, mem.error)
                    )
    for missing in missing_rules:
        for check in checks:
            if check.id == "rule-duplication":
                check.add_reason("指定されたルールファイルが存在しない: {}".format(missing))

    report = build_report(memory_dir, repo, rule_files, memory_files, checks)
    _emit(report, args.fmt)
    return report["summary"]["exit_code"]


def _emit(report: dict, fmt: str) -> None:
    if fmt == "json":
        sys.stdout.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    else:
        sys.stdout.write(render_text(report))


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - 予期せぬ失敗を 0 で終わらせない
        sys.stderr.write("memory-revalidate.py: 内部エラー: {}: {}\n".format(exc.__class__.__name__, exc))
        raise SystemExit(EXIT_INTERNAL)
