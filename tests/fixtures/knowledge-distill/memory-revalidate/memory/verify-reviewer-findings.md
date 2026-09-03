---
name: verify-reviewer-findings
description: レビュー指摘は断定的でも誤りうるので、対応前に一次ソースで検証する
metadata:
  type: feedback
modified: 2026-06-21T04:39:00+09:00
---

レビュアー（cc-code-review / cc-security-review / codex / 各サブエージェント）の指摘は、
断定的でも誤っていることがある。対応前に必ず一次ソース（公式 doc / 実装実体 / 実挙動）で
妥当性を検証する。

**Why:** 否定的断定・仕様主張・「○○が無い」系の指摘は特に疑わしい。原文・実体・実挙動を
確認し、覆ったら破棄して理由を残す。

**How to apply:** 確認用サブエージェントの要約も鵜呑みにせず、一次ソースで裏取りしてから
対応方針を決める。
