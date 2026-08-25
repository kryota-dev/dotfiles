# Shared reviewer rubrics

ここは `multi-review` が使用する reviewer rubric の SSOT である。各 rubric は harness
非依存の本文だけを持つ。Claude Code の agent file は frontmatter を付けた adapter として
この本文から生成し、Codex は本文を child prompt に注入する。

レビュー結果は次を含める。

- severity (`MUST` / `SHOULD` / `NITS` / `GOOD`)
- confidence (`high` / `medium` / `low`)
- 根拠となる file と line
- 不確実な技術的主張の `（未確認）` 表示

finding 段は coverage を優先し、最終的な一次情報での検証と投稿判断は parent が行う。
