# Externals、SHA ピン固定、シングルタールキャッシュ

🌐 English (canonical): [externals-and-pinning.md](externals-and-pinning.md)

← [ドキュメント目次](../README.ja.md)

`home/.chezmoiexternal.toml` は、chezmoi が apply 時に取得するすべての外部リソースを宣言します。Anthropic スキルアーカイブ、ECC フックランタイム、<!-- FACT:ecc-skill-count -->126<!-- /FACT --> 個の ECC スキル（単一リストから生成）、`aside` スラッシュコマンド、Moralerspace フォントです。このドキュメントでは、キャッシュモデル、`range` によるファンアウト、SHA ピン固定、リフレッシュ期間、デプロイ済みファイルを廃棄するための `chezmoiignore`/`chezmoiremove` ライフサイクルについて説明します。

---

## 宣言内容

| カテゴリ | ソースリポジトリ | エントリ種別 | 件数 |
|---------|----------------|------------|------|
| Anthropic スキル | `anthropics/skills` | `archive` | 17 |
| drawio スキル | `jgraph/drawio-mcp` | `archive` | 1 |
| Supabase スキル | `supabase/agent-skills` | `archive` | 2 |
| ECC フックランタイム（`scripts/hooks` + `scripts/lib`） | `affaan-m/ECC` | `archive` | 1 |
| ECC 採用スキル | `affaan-m/ECC` | `archive`（range 生成） | `[ecc].skills` の長さと等しい（`tests/docs_facts.bats` で検証） |
| `aside` スラッシュコマンド | `affaan-m/ECC` | `file` | 1 |
| phone-harness スキル | `ShawnPana/phone-harness` | `file` | 1 |
| eli5 スキル | `anthropics/claude-plugins-community` | `file` | 1 |
| ax スキル | `yusukebe/ax` | `file` | 1 |
| Moralerspace フォント（macOS のみ） | `yuru7/moralerspace` | `archive` | 1 |

宣言エントリ総数: <!-- FACT:external-static-entry-count -->26<!-- /FACT --> 件の静的エントリ（17 + 1 + 2 + 1 + 1 + 1 + 1 + 1 + 1）と `range` 生成の ECC スキルエントリ（= `[ecc].skills` の長さ）の合計であり、配列に追随して自動的に変化します。静的エントリ数は `tests/docs_facts.bats` が `.chezmoiexternal.toml` と突き合わせて検証します（pin 化する前に実際に drift していました。drawio と supabase が external として追加されたのに、この総数が取り残されていました）。

コールド apply での HTTP ダウンロード回数はエントリ数より少なくなります。取得の単位がエントリではなく**ユニークな URL** だからです。17 件の Anthropic エントリは 1 つのタールボールを共有し、2 件の Supabase エントリも別の 1 つを共有し、ECC ランタイムは `range` 生成の全 ECC スキルとタールボールを共有します。結果として Anthropic / drawio / Supabase / ECC / `aside.md` / phone-harness / eli5 / ax / フォントそれぞれ 1 回ずつになります。

---

## シングルタール URL キャッシュ

chezmoi は外部アーカイブを URL 文字列の SHA256 をキーとしてキャッシュします。**同一 URL** を持つ 2 つのエントリは正確に 1 回のダウンロードを引き起こします。キャッシュされたバイト列はその URL を共有するすべてのエントリで再利用されます。

このリポジトリはその特性を意図的に活用しています。

- 17 個の Anthropic スキルエントリはすべて `https://github.com/anthropics/skills/archive/{{ .skills.anthropic_commit }}.tar.gz` を共有します。1 回のダウンロード、キャッシュから 17 回の展開。
- 1 個の ECC フックランタイムエントリとすべての ECC スキルエントリが `https://github.com/affaan-m/ECC/archive/{{ .ecc.commit }}.tar.gz` を共有します。1 回のダウンロード、1 + len([ecc].skills) 回の展開。

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

ECC スキルごとにほぼ同一の TOML ブロックを手書きするのはエラーが起きやすいです。代わりに、`.chezmoiexternal.toml` 自体が Go テンプレートです。ECC スキルセクション全体が単一の `range` ループになっています。

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

- `.ecc.skills` は `home/.chezmoidata.toml` の `[ecc]` テーブルにある配列です。その長さが ECC スキルの正規の件数です。
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

SHA は `home/.chezmoidata.toml` の `[ecc].commit` で定義されています。Renovate は新しい ECC リリースが出るたびにこの値をバンプします（「Renovate バンプモデル」セクション参照）。頻繁に変わるため、現在の値はここには記載しません — SSOT は `.chezmoidata.toml` です。値の形式の例:

```toml
[ecc]
  commit = "<commit-sha>"   # 現在値: home/.chezmoidata.toml [ecc].commit
```

タグが移動しても取得されるバイト列は変わりません。`refreshPeriod` は chezmoi がローカルキャッシュを返し続ける期間を制御します。

| リソース | `refreshPeriod` |
|---------|----------------|
| Anthropic スキル | `168h`（7 日） |
| ECC フックランタイム | `168h`（7 日） |
| ECC スキル | `168h`（7 日） |
| `aside` コマンド | `168h`（7 日） |
| phone-harness スキル | `168h`（7 日） |
| ax スキル | `168h`（7 日） |
| Moralerspace フォント | `672h`（28 日） |

期間内は chezmoi がネットワークリクエストなしにキャッシュコピーを返します。期間が切れると、次の `chezmoi apply` で再ダウンロードします（SHA が変わっていなければ同じバイト列を取得します）。

---

## Renovate バンプモデル

`renovate.json5` には `customManager` の正規表現が含まれており、`.chezmoidata.toml` の `version` と `commit` フィールドにマッチし、新しい ECC リリースタグが現れると 1 つの PR として両方を一緒にバンプします。

重要なポリシー: **ECC の更新は必ずマージ前に審査されます。** ECC タールボールにはエージェントハーネス内で実行される実行可能なフックスクリプトが含まれます。マージゲートの fast lane は `home/dot_config/mise/config.toml` の pin —— あなたが明示的に起動する道具 —— に限定されており、ECC はこの `.chezmoidata.toml` に pin されているため、その lane には決して乗らず、差分がどう見えようとエージェントが審査します。この保証は ECC を名指ししていることではなく、**pin がどこに置かれているか**から導かれます。依存をこのファイルに置けば、自動的に審査対象になります。（マージゲート導入前は `renovate.json5` の `automerge: false` packageRule でした。設定側は updateType しか見られず、ECC のリリースを他のタグ付きリリースと区別できません — [Renovate 自動化](renovate-automation.ja.md) 参照。）

同じ「データにピン固定して Renovate でバンプ」パターンは `anthropics/skills`（`.skills.anthropic_commit`）と Moralerspace フォント（`.versions.moralerspace_font`）にも適用されます。

### 1 つのツールに 2 つの pin: phone-harness

`phone-harness` は、成果物が**2 つの異なるデータソース**から来る唯一のエントリです。そのため `[phone_harness]` は 2 つの pin を持ち、Renovate は同じテーブルに対して 2 つの custom manager を走らせます。

| pin | 対象 | データソース | 取得元 |
|-----|------|------------|--------|
| `version` | CLI（PyPI リリース） | `pypi` | `run_onchange_after_19-setup-phone-harness.sh.tmpl` → `uv tool install` |
| `commit` | `SKILL.md`（リポジトリ内のファイル） | `git-refs` | `.chezmoiexternal.toml` の `file` external |

両者は upstream 履歴上の別地点にあってかまいません。`SKILL.md` は独立した markdown なので、スキル側の pin が遅れていてもインストール済みの CLI が壊れることはなく、最悪でもスキル本文が実際より少し古いヘルパーを説明するだけです。2 つの正規表現はいずれも `[phone_harness]` テーブルにスコープされており、隣接テーブルの `version =` / `commit =` を掴むことはありません。

ECC と同様に **phone-harness の更新も必ずマージ前に審査されます**。しかもその理由は markdown のみのスキルアーカイブより強いものです。phone-harness は、実機のロック解除された端末の画面をキャプチャし HID レベルの入力を合成する実行可能な Python を配布し、その `SKILL.md` こそがエージェントをその操作へ導くものだからです。2 つの pin はどちらも覆われており、しかもどちらも名指しではありません。PyPI リリースは fast lane の対象外である `.chezmoidata.toml` に pin され、`SKILL.md` の digest は `digest` 更新としてやはりその lane に乗りません。保証を担っているのは**対象範囲**です —— `update dependency phone-harness to v1.2.3` は通常の CLI 更新と形が完全に同一であり、更新の*形*だけでは実アカウントを保持した端末への到達を止められないからです。

### ズレてはいけない 2 つの pin: ax

`ax` も 2 つの pin を持ち、テーブルの見た目は `[phone_harness]` と同じです。**しかし理由は逆**なので、上の drift 許容をそのまま持ち込まないでください。

| pin | 対象 | データソース | 取得元 |
|-----|------|------------|--------|
| `version` | CLI（GitHub リリースの成果物） | `github-releases`（mise 組み込み manager 経由） | `run_onchange_after_12-setup-mise.sh.tmpl` → `mise install`（mise 設定の `"github:yusukebe/ax"`） |
| `commit` | `skills/ax/SKILL.md`（リポジトリ内のファイル） | `github-tags`（`[ax]` にスコープした custom manager 経由） | `.chezmoiexternal.toml` の `file` external |

phone-harness は PyPI リリースと可動 `main` 上のコミットという、本当に独立した 2 つのデータソースを pin しているので、スキル側の pin が遅れても無害です。**ax の 2 つの pin は同一リリース由来**であり、しかも ax は `v0.1.x` で安定 API の宣言がありません。別バージョンのフラグを説明する `SKILL.md` は、見た目上の遅れではなく実害になりえます。そのため `tests/ax.bats` が `[ax].version` と mise の pin が同じバージョンを指すことを検証します。

この検証が成立し続けるのは、Renovate が 2 つを 1 単位でバンプするからです。`renovate.json5` の `yusukebe/ax` の `packageRule` が両 manager に同じ `groupName` を与えるため、リリースは単一 PR として届きます。2 つに割れると、各 PR は更新を半分だけ適用した状態になって検証が赤くなり、どちらも単独でマージできません。この group ルールの存在自体も `tests/ax.bats` が検証します。削除しても次の ax リリースまで何も壊れないからです。

CLI の pin は fast lane の対象範囲である mise 設定にありますが、ax の更新がその lane に乗ることはありません。グループ化された PR は 2 ファイルに跨り、分類器の fast lane は 1 ファイル `+1/-1` の差分を要求するからです。1 つの PR が実行バイナリと、エージェントの web アクセスを導くスキル本文の両方を動かす以上、エージェント審査に落ちるのが正しい結果です。

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

> **例外 — 再生成不能な鍵素材を含む runtime ディレクトリ。** ペアリング情報や E2E 暗号鍵を含む
> パスは登録**しない**でください。ここのエントリは一度きりの後片付けではなく恒久宣言であり、その
> ツールを将来再導入した場合、以後の apply のたびに無警告で鍵が削除され続けます。そうした対象は
> 手動で撤去し、順序依存の手順は判断のすぐ隣に残るよう `home/.chezmoiremove` のコメントとして
> 記録してください。前例: `~/.happy`（#331）— 意図的に未登録とし、未登録のままであることを
> `tests/files.bats` が検証しています。

`home/.chezmoiremove` の抜粋 — 完全な一覧はファイル自体を参照してください（廃止された dmux レイヤー、happy 撤去の注記と手動 runbook、2026-07-06 の棚卸し、ケースリネームのクリーンアップも含まれます）:

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
.agents/skills/agentcore
.agents/skills/vercel-sandbox

# agent-browser ディスカバリースタブ自身の凍結された references/・templates/ コピー
.agents/skills/agent-browser/references
.agents/skills/agent-browser/templates
```

`agent-browser` の専用スキルはこのパターンの具体例です。以前は静的ファイルとしてベンダリングされていましたが、バージョンマッチしたコピーを実行時にサービスする CLI に置き換えられました。静的コピーをソースから削除し、**かつ**デスティネーションパスを `.chezmoiremove` に追加することで、次の `chezmoi apply` で確実に削除されます。スタブ自身の `references/`・`templates/` も、どこからもリンクされていない 0.32 より前のコンテンツの凍結済みコピーだと判明した時点で、同じ 2 ステップの削除を経ています。
