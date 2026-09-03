---
name: MEMORY
description: fixture 用の auto-memory 索引。監査で見つかった乖離 2 件をこの中で再現する
metadata:
  type: project
modified: 2026-06-21T04:39:00+09:00
---

# Project Memory

これは `tests/fixtures/knowledge-distill/memory-revalidate/` の合成 fixture であり、実際の
auto-memory の写しではない。監査（kryota-dev/dotfiles#631）で見つかった腐敗の**形だけ**を写している。

## Key Patterns

- chezmoi source dir: `home/`
- Brewfile を更新したら `make dump-brewfile` を実行して Brewfile を同期する
- Linux 非互換の formula は `.brewfile-linux-exclude` に列挙する
- 廃止済みのヘルパ: `home/dot_local/bin/executable_removed-tool`

## CI Architecture

- `.github/workflows/setup-validation.yml`: macOS + Ubuntu の 2 ジョブ
- macOS: キャッシュ対象は `~/Library/Caches/Homebrew`
- 経緯は PR #38 と PR #373 を参照
