---
name: public-repo-no-client-names
description: public リポジトリの issue / PR / コードにクライアントや勤務先の固有名を書かない
metadata:
  type: feedback
modified: 2026-06-25T10:12:00+09:00
---

public リポジトリの issue / PR / コミット対象コードには、クライアント / 勤務先の固有名
（製品名・組織名・workspace scope 名など）を書かず、汎用プレースホルダを使う。

**Why:** 一度公開すると履歴と検索インデックスに残り、後から消しても取り返しがつかない。
private リポジトリは対象外。

**How to apply:** 作成前に固有名の混入を grep で確認し、既存の露出を見つけたら redact する。
