---
name: notify
description: 音を鳴らして user に知らせる。ほかの skill の手順が `notify` を指示したときに使う。
user-invocable: false
---

# notify

次のコマンドを実行して、音を 2 つ鳴らす。

```bash
afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Glass.m4r && afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/Bamboo.m4r
```
