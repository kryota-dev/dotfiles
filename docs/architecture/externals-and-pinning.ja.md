# Externals、SHA ピン固定、シングルタールキャッシュ

🌐 English (canonical): [externals-and-pinning.md](externals-and-pinning.md)

← [ドキュメント目次](../README.ja.md)

`home/.chezmoiexternal.toml` は、chezmoi が apply 時に取得するすべての外部リソースを宣言します。Anthropic スキルアーカイブ、ECC フックランタイム、127 個の ECC スキル（単一リストから生成）、`aside` スラッシュコマンド、Moralerspace フォントです。このドキュメントでは、キャッシュモデル、`range` によるファンアウト、SHA ピン固定、リフレッシュ期間、デプロイ済みファイルを廃棄するための `chezmoiignore`/`chezmoiremove` ライフサイクルについて説明します。

---

## 宣言内容

| カテゴリ | ソースリポジトリ | エントリ種別 | 件数 |
|---------|----------------|------------|------|
| Anthropic スキル | `anthropics/skills` | `archive` | 17 |
| ECC フックランタイム（`scripts/hooks` + `scripts/lib`） | `affaan-m/ECC` | `archive` | 1 |
| ECC 採用スキル | `affaan-m/ECC` | `archive`（range 生成） | 127 |
| `aside` スラッシュコマンド | `affaan-m/ECC` | `file` | 1 |
| Moralerspace フォント（macOS のみ） | `yuru7/moralerspace` | `archive` | 1 |

宣言エントリ総数: 147。コールド apply での実際の HTTP ダウンロード回数: 4（ユニークなタール URL ごとに 1 回 — 以下のキャッシュを参照）。

---

## シングルタール URL キャッシュ

chezmoi は外部アーカイブを URL 文字列の SHA256 をキーとしてキャッシュします。**同一 URL** を持つ 2 つのエントリは正確に 1 回のダウンロードを引き起こします。キャッシュされたバイト列はその URL を共有するすべてのエントリで再利用されます。

このリポジトリはその特性を意図的に活用しています。

- 17 個の Anthropic スキルエントリはすべて `https://github.com/anthropics/skills/archive/{{ .skills.anthropic_commit }}.tar.gz` を共有します。1 回のダウンロード、キャッシュから 17 回の展開。
- 1 個の ECC フックランタイムエントリと 127 個の ECC スキルエントリはすべて `https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz` を共有します。1 回のダウンロード、128 回の展開。

同じリポジトリからのエントリを追加することはネットワーク的にはほぼ無料です。エントリごとに異なるのは `include` グロブと `stripComponents` の値だけです。

---

## アーカイブエントリの構造

典型的な Anthropic スキルエントリ:

```toml
[".agents/skills/algorithmic-art"]
    type = "archive"
    url = "https://github.com/anthropics/skills/archive/{{ .skills.anthropic_commit }}.tar.gz"
    stripComponents = 3
    include = ["*/skills/algorithmic-art/**"]
    refreshPeriod = "168h"
```

| フィールド | 意味 |
|-----------|------|
| セクションキー | `$HOME` 相対のデスティネーションパス |
| `type = "archive"` | タールボールを取得し、マッチするパスを展開 |
| `url` | `.chezmoidata.toml` のコミット SHA でテンプレート化 |
| `stripComponents` | ファイル書き込み前にタール内部パスから除去する先頭パスコンポーネント数 |
| `include` | 展開対象を選択するための**タール内部パス**に対するグロブ |
| `refreshPeriod` | chezmoi がキャッシュコピーを返し続ける期間 |

`stripComponents = 3` は `<repo>-<commit>/skills/<name>/` プレフィックスを除去し、スキルのファイルが `~/.agents/skills/<name>/` に直接配置されます。

単一の `file` エントリ（`aside.md`）は展開なしで生の URL を取得します。

```toml
[".claude/commands/aside.md"]
    type = "file"
    url = "https://raw.githubusercontent.com/affaan-m/ECC/{{ .ecc.commit }}/commands/aside.md"
    refreshPeriod = "168h"
```

---

## `range .ecc.skills` ファンアウト

127 個のほぼ同一の TOML ブロックを手書きするのはエラーが起きやすいです。代わりに、`.chezmoiexternal.toml` 自体が Go テンプレートです。ECC スキルセクション全体が単一の `range` ループになっています。

```
{{ range $skill := .ecc.skills -}}
[".agents/skills/{{ $skill }}"]
    type = "archive"
    url = "https://github.com/affaan-m/ECC/archive/{{ $.ecc.commit }}.tar.gz"
    stripComponents = 3
    include = ["*/skills/{{ $skill }}/**"]
    refreshPeriod = "168h"

{{ end -}}
```

重要なポイント:

- `.ecc.skills` は `home/.chezmoidata.toml` の `[ecc]` テーブルにある 127 エントリの配列です。
- `range` ブロック内では、`.` は現在の要素（スキル名の文字列）に再バインドされます。他のトップレベルデータ（特にコミット SHA）にアクセスするには、**`$`**（ルートコンテキスト）を使用する必要があります: `{{ $.ecc.commit }}`（`{{ .ecc.commit }}` ではありません）。
- **ECC スキルを追加または削除する**には、`home/.chezmoidata.toml` の `[ecc].skills` 配列のみを編集します。range ブロックが external エントリを自動生成します。`.chezmoiexternal.toml` に per-skill エントリを手書きしないでください。

---

## ECC フックランタイム vs ECC スキル: `stripComponents` の違い

ECC フックランタイムエントリは `stripComponents = 3` ではなく `stripComponents = 2` を使用します。

```toml
[".agents/skills/ecc/scripts"]
    type = "archive"
    url = "https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz"
    stripComponents = 2
    include = ["*/scripts/hooks/**", "*/scripts/lib/**"]
    refreshPeriod = "168h"
```

`stripComponents = 2` は `<repo>-<commit>/scripts/` を除去し、`hooks/` と `lib/` サブディレクトリが `~/.agents/skills/ecc/scripts/hooks/` と `~/.agents/skills/ecc/scripts/lib/` に配置されます。

`stripComponents = 3`（すべてのスキルエントリで使用）はさらに 1 レベル（`<repo>-<commit>/skills/<name>/`）を除去し、ファイルが `~/.agents/skills/<name>/` に直接配置されます。

この設定を誤るとファイルが誤った深さに配置され、スキルディスカバリーで見つからなくなります。

---

## SHA ピン固定と `refreshPeriod`

すべての external URL は、ブランチ名やタグではなく**イミュータブルなコミット SHA** を補間します。

```toml
url = "https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz"
```

SHA は `home/.chezmoidata.toml` で定義されています。

```toml
[ecc]
  commit = "8ad4151095e453301ce0e50374103bcd8f50ded2"
```

タグが移動しても取得されるバイト列は変わりません。`refreshPeriod` は chezmoi がローカルキャッシュを返し続ける期間を制御します。

| リソース | `refreshPeriod` |
|---------|----------------|
| Anthropic スキル | `168h`（7 日） |
| ECC フックランタイム | `168h`（7 日） |
| ECC スキル | `168h`（7 日） |
| `aside` コマンド | `168h`（7 日） |
| Moralerspace フォント | `672h`（28 日） |

期間内は chezmoi がネットワークリクエストなしにキャッシュコピーを返します。期間が切れると、次の `chezmoi apply` で再ダウンロードします（SHA が変わっていなければ同じバイト列を取得します）。

---

## Renovate バンプモデル

`renovate.json5` には `customManager` の正規表現が含まれており、`.chezmoidata.toml` の `version` と `commit` フィールドにマッチし、新しい ECC リリースタグが現れると 1 つの PR として両方を一緒にバンプします。

重要なポリシー: **ECC は絶対に自動マージしません。** `renovate.json5` の `packageRule` で `affaan-m/ECC` に `"automerge": false` を設定しています。ECC タールボールにはエージェントハーネス内で実行される実行可能なフックスクリプトが含まれているため、すべての ECC バンプは手動でレビューする必要があります。

同じ「データにピン固定して Renovate でバンプ」パターンは `anthropics/skills`（`.skills.anthropic_commit`）と Moralerspace フォント（`.versions.moralerspace_font`）にも適用されます。

---

## `.chezmoiignore` と `.chezmoiremove`

これら 2 つのファイルは、chezmoi がソースツリーで所有しないパスをどう扱うかを制御します。

### `.chezmoiignore` — 管理対象外のまま放置

chezmoi が作成も更新も削除もしないデスティネーションパスのグロブです。ソースツリーに入れてはいけないランタイム状態（セッション履歴、SQLite データベース、認証トークン、ローカルオーバーライド）に使用します。

このファイル自体がテンプレートなので、パターンを OS 条件付きにできます。`.chezmoiignore` の例:

```
{{ if ne .chezmoi.os "darwin" }}
Library/
{{ end }}
```

### `.chezmoiremove` — アクティブに削除

`chezmoi apply` のたびに chezmoi が**削除**するデスティネーションパスです。以前にデプロイされたファイルを廃棄する際に必要です。

chezmoi ソースツリーからファイルを削除（`git rm`）しても、`$HOME` にすでにデプロイされたコピーは**削除されません**。デプロイ済みコピーはオーファンになります。クリーンアップするには 2 つのステップが必要です。

1. ソースから削除: `git rm home/path/to/file`（または `.ecc.skills` から名前を削除）。
2. `$HOME` 相対のデスティネーションパスを `home/.chezmoiremove` に追加する。

現在の `.chezmoiremove` エントリ:

```
# オーファン化した SDD エージェント
.claude/agents/sdd-designer.md
.claude/agents/sdd-worker.md
.claude/agents/sdd-work-reviewer.md
.claude/agents/sdd-design-reviewer.md

# agent-browser の専用スキル（実行時に CLI がサービス）
.agents/skills/electron
.agents/skills/slack
.agents/skills/dogfood
```

`agent-browser` の専用スキルはこのパターンの具体例です。以前は静的ファイルとしてベンダリングされていましたが、バージョンマッチしたコピーを実行時にサービスする CLI に置き換えられました。静的コピーをソースから削除し、**かつ**デスティネーションパスを `.chezmoiremove` に追加することで、次の `chezmoi apply` で確実に削除されます。
