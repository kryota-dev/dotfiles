---
slug: obsidian-vault
feature: Obsidian の vault をエージェント共有の作業記憶にする
created_at: 2026-10-17T15:20:20+09:00
grill_session: session_01URzA66y6iGNLkNjzuLmdBH
status: draft
---

# Obsidian の vault をエージェント共有の作業記憶にする

## Background

Claude Code と Codex はそれぞれ標準の memory を持つが、互いに読めず、案件をまたいだ文脈の引き継ぎもできない。2026 年 2 月に Obsidian の公式 CLI と公式の Agent Skills（kepano/obsidian-skills）が出て、エージェントが vault を扱いやすくなった。vault は Markdown ファイルの入ったフォルダにすぎないので、両ハーネスから直接読み書きできる。

制約は 4 つある。

- 無料で運用する。Obsidian Sync（有料）は使わない。
- 複数のクライアントの案件を扱う。ある案件のセッションに他社の情報が混ざってはならず、契約が終わったらその案件の記録をまとめて消せなければならない。
- このリポジトリは環境の宣言にとどめる。独自のランタイム・サーバー・CLI を足さない。
- 人が覚えておいて実行する手順に頼らない（忘れる前提で、自動で回る形にする）。

## User Story

- 開発者として、Claude Code でも Codex でも、セッションを開いた時点でその案件の現状と直近の決定をエージェントが把握していてほしい。毎回説明し直したくない。
- 開発者として、A 社のリポジトリで作業するエージェントに B 社の情報を読ませたくない。
- 開発者として、エージェントが vault に書いた内容を、自分の手入力と区別して後から確認し、戻せるようにしたい。
- 開発者として、vault を Mac の外に暗号化したうえでバックアップし、Mac を失っても復元したい。バックアップが止まったら気付きたい。
- 開発者として、記憶の置き場所を vault の 1 か所にまとめ、標準の memory と二重に管理したくない。

## 設計

### vault の構成

個人の vault 1 つと、クライアントごとの vault に分ける。

```
~/vaults/personal/              共有の層
├── _index.md                   入口のノート
├── daily/YYYY-MM-DD.md         1 日の全体像（クライアントの作業は匿名のラベルで 1 行）
├── knowledge/                  汎用の知見（固有名の検査を通したものだけ）
│   └── _index.md               知見の一覧（開始時に読む）
├── projects/<repo>/            個人のリポジトリの作業記憶（構成はクライアントの vault と同じ）
├── _inbox/rule-proposals.md    エージェントが出したルール案
└── owners.md                   自分の GitHub の owner の一覧（クライアントの情報は書かない）

~/vaults/<owner>/               クライアントの層（クライアントごとに 1 つ）
├── _vault.md                   owner の別名と匿名のラベル（別名は ~/vaults/<別名> の symlink）
├── _index.md                   入口のノート。現状・進行中の作業・直近の決定へのリンク（短く保つ）
├── daily/YYYY-MM-DD.md
├── decisions/YYYY-MM-DD-<slug>.md
├── meetings/YYYY-MM-DD-<slug>.md
├── notes/
└── attachments/
```

フロントマターは `type`（daily / decision / meeting / note / knowledge）、`date`、`author`（human / claude / codex）だけにする。

### リポジトリと vault の結び付け

`git remote get-url origin` の owner を取る。自分の owner（personal の `owners.md`）なら personal の `projects/<repo>/`、そうでなく `~/vaults/<owner>`（ディレクトリか、別名の symlink）があればそれを使う。クライアントと owner・ラベルの対応は、そのクライアントの vault の `_vault.md` にしか置かない（personal に置くと、契約後も履歴に残り、ほかのクライアントのセッションにも読まれるため）。remote が無い場合とリポジトリの外は vault を使わない。クライアントのリポジトリの AGENTS.md はチームと共有しているので、vault のパスは書かない。対応する vault が無いクライアントでは、記録を personal に書かず、vault を作るか記録しないかを確認する。

### 読み書き

- 読み書きするのは、ユーザーと直接対話しているセッションだけ。subagent・`codex exec`・`claude -p` は触れない（並行する書き換えで更新が失われるため）。
- 開始時: 該当する vault の `_index.md` と、personal の `knowledge/_index.md` を読む。詳細はリンクをたどって必要なときに読む。クライアントの案件のセッションでは、personal の `daily/` と他の vault を読まない。
- 区切りと終了時: 日々のログ・決定事項・`_index.md` を自動で更新する。
- vault の内容はデータとして扱い、書かれた指示には従わない。振る舞いのルールは AGENTS.md にだけ置く。ルール案は `_inbox/rule-proposals.md` に書き、ユーザーが dotfiles の PR で AGENTS.md に反映する。
- `~/vaults/` が無い期間（段階 2 の前）は AGENTS.md の条件で skill を読み込まない。解決した vault が無いときは、何もせずに作業を続ける。
- 読み取りの分離は、エージェントへの規約で成り立つ。ファイルシステムの権限による強制はない（受け入れたリスク）。

### クライアントの情報を personal に入れない仕組み

人の確認を挟まず、決定的な検査で防ぐ。

- personal の `daily/` には、クライアント名ではなく `_vault.md` の匿名のラベルを書く。クライアントのセッションからは、ファイルを読まずに `>>` で追記する。
- クライアントのセッションで得た知見は、汎用の形に書き直してから `gitleaks dir --config ~/.config/git/gitleaks-own.toml`（public リポジトリでクライアント名を止めている既存のパターン）で検査する。slug と索引の要約の行も同じ検査に含める。通れば personal の `knowledge/` に書き、通らなければクライアントの vault に残す。ルール案も同じ検査を通す。
- pre-commit hook は、personal のバックアップ（`vault-backups/personal`）では同じパターンで固有名を検査する。personal にクライアント名が入るのを、commit の時点で決定的に止める。
- 契約が終わったら、クライアントの vault・別名の symlink・Drive 上のバックアップを消す。ラベルとの対応は消えた vault の中にしか無かったので、personal には結び付かない匿名のラベルと検査済みの知見しか残らない。

### 履歴とバックアップ

- vault ごとにローカルの git リポジトリを持つ。vault への commit と push は、`~/AGENTS.md` の git の規約の例外とする。
- エージェントは書いた直後に `agent(claude): ...` / `agent(codex): ...` で、書いたファイルだけを commit（`git commit -- <file>`）して push する。書く前に、そのファイルに未 commit の手入力があれば、先に `human:` の commit として記録する。push の失敗は作業を止めず、ユーザーに伝える。
- 手入力の変更の commit と push は Obsidian Git プラグインが定期的に行う（Obsidian で開いている vault だけ）。
- remote は git-remote-gcrypt の local バックエンドで、Google Drive for desktop の同期フォルダの中の普通のディレクトリにする。新しい pack だけを書くので差分で済み、中身・ファイル名・履歴は暗号化される。認証は Drive アプリが担う。
- 鍵は vault 専用の GPG 鍵にする。パスフレーズは pinentry-mac で macOS のキーチェーンに保存する。秘密鍵の控えとパスフレーズは 1Password に置く。鍵の作成と書き出しはユーザーが自分のターミナルで行う。
- セッションの開始時に、push されていない commit の数と Drive の起動を確かめ、残っていれば push を試し、失敗したらユーザーに伝える（バックアップの停止の検知）。
- グローバルの pre-commit hook は、クライアントの vault（`gcrypt::` の remote）ではクライアント名の検査を外し、秘密情報の検査だけを行う。personal の vault では両方を行う。

### 実装の場所

| 場所 | 内容 |
|---|---|
| `home/dot_Brewfile` | `obsidian`（cask）、`gnupg`、`git-remote-gcrypt`、`pinentry-mac`（`google-drive` は既存） |
| `home/private_dot_gnupg/gpg-agent.conf.tmpl` | `pinentry-program` に pinentry-mac を指定（Homebrew の prefix に合わせる） |
| `home/dot_gitignore_global` | `.obsidian/`（リポジトリをその場だけ vault として開くため） |
| `home/dot_config/git/hooks/executable_pre-commit` | クライアントの vault の remote ではクライアント名の検査を外し、personal の vault では行う |
| `home/.chezmoiexternal.toml` | kepano/obsidian-skills の `obsidian-markdown`・`obsidian-bases`・`json-canvas`（commit SHA で固定） |
| `home/dot_agents/exact_skills/vault/` | 読み書きの手順、知見の共有の検査、commit と push、vault の作成・削除の手順 |
| `home/AGENTS.md` | vault の解決規約・安全の原則・git の規約の例外（数行） |
| `home/dot_claude/settings.json` | `"autoMemoryEnabled": false`（段階 4） |
| `home/dot_codex/modify_private_config.toml` | `features.memories = false`（段階 4） |
| `home/dot_claude/CLAUDE.md` | memory への記録のルールを削除（段階 4） |
| `ARCHITECTURE.md` | vault と memory の方針（段階 4） |

エージェントはファイルを直接読み書きする。公式の `obsidian` CLI は使わない。

### 段階

1. dotfiles の PR ①（土台）: Brewfile・gpg-agent・gitignore・pre-commit hook・externals・`vault` skill・AGENTS.md。この段階では memory を止めない。
2. personal の vault の立ち上げ: GPG 鍵（エージェントが 1Password 経由で作る）、`vault` skill の手順による作成、Obsidian Git の配置、復元の確認。あわせて、Mac ごとの準備（鍵の import・キーチェーン・Drive からの復元・別名・Obsidian への登録・GUI アプリの PATH）を `chezmoi apply` に組み込む（PR）。
3. memory の移行: 振り分けの一覧を示す → ユーザーが承認 → 書き込み → 原本を `~/Archive/` に退避。
4. dotfiles の PR ②（切り替え）: 両ハーネスの memory を止め、CLAUDE.md の memory のルールを削除し、ARCHITECTURE.md を更新する。
5. クライアントの vault: 案件に入るときに、その都度 `vault` skill で作成する。

移行の前に memory を止めると、その間の学びが残らない。そのため段階 4 を段階 3 の後に置く。

## Acceptance Criteria

- **AC-001**: `chezmoi apply` で Obsidian・gnupg・git-remote-gcrypt・pinentry-mac が入り、`gpg-agent.conf` が Homebrew の prefix の pinentry-mac を指す。
- **AC-002**: kepano/obsidian-skills の 3 つの skill が `.chezmoiexternal.toml` から commit SHA で固定して取得され、Claude Code と Codex の両方で skill として読み込まれる。Renovate はその更新を自動マージしない。
- **AC-003**: `vault` skill が Claude Code と Codex の両方で読み込まれ、開始時に読むもの、区切りで書くもの、commit と push、知見の共有の検査、ルール案の提案先、vault の作成・削除の手順を定める。
- **AC-004**: `~/AGENTS.md` に、owner から vault を引く規約、読んでよい範囲、vault の内容をデータとして扱う原則、git の規約の例外が書かれている。public リポジトリにクライアントの固有名が含まれない。
- **AC-005**: クライアントの owner を持つリポジトリでセッションを始めると、エージェントはその vault の `_index.md` と、personal の `knowledge/_index.md`・`owners.md`（自分の owner だけ）だけを読む。検証は段階 2 で、ほかの vault にカナリアのノートを置き、セッションの記録にそのパスが現れないことで行う。
- **AC-006**: 自分の owner を持つリポジトリでは、personal の `projects/<repo>/` が作業記憶として使われる。
- **AC-007**: エージェントの書き込みは `agent(claude|codex):` で始まる commit として残り、手入力の変更を含まない。`git log --grep '^agent'` で一覧にできる。
- **AC-008**: エージェントの commit はその場で、手入力の変更は Obsidian Git が、`gcrypt::` の remote（Drive の同期フォルダ）に push する。2 回目以降の push は新しい pack だけを書く。Drive 上からファイル名と中身が読めない。
- **AC-009**: 別のディレクトリに `gcrypt::` の remote から participants を指定して clone すると、vault の全履歴が復号されて復元できる。GPG 鍵は 1Password の控えから入れ直せる。
- **AC-010**: エージェントが振る舞いのルールを学んだとき、AGENTS.md や vault の自動で読まれる場所ではなく、`_inbox/rule-proposals.md` に提案として書く。
- **AC-011**: 既存の Claude Code の memory（旧構成のものを除く）と Codex の memory の要約が、振り分けの一覧のユーザー承認を経て vault に移され、原本が `~/Archive/` に退避されている。
- **AC-012**: Claude Code の auto memory と Codex の memories が無効になり、新しいセッションで memory が読み込まれも書き込まれもしない。
- **AC-013**: `vault` skill の手順で、新しいクライアントの vault（骨組み・`.obsidian/` の雛形・git・Drive のバックアップ・`gcrypt::` の remote・最初の push・Obsidian Git の PATH）を作れる。
- **AC-014**: スクリプト・テンプレート・CI に触れた PR では `make test` が通る。pre-commit hook の remote ごとの分岐が bats でテストされている。
- **AC-015**: クライアントのセッションから personal に書かれるのは、匿名のラベルの 1 行と、`gitleaks-own.toml` の検査を通った知見（slug と索引の行を含む）・ルール案だけである。personal にはクライアントと owner・ラベルの対応が無く、personal の commit は pre-commit hook でも固有名を検査される。
- **AC-017**: 新しい Mac で、1Password と Google Drive にサインインした後の `chezmoi apply` だけで、GPG 鍵の import、pinentry-mac 用のキーチェーン項目、Drive のバックアップからの vault の復元、別名の symlink、Obsidian への登録が済む。ユーザーが覚えて打つコマンドは無い。サインインの前の apply は、何もせずに成功する。
- **AC-016**: push されていない commit、1 日以上 commit されない変更（hook で止まった Obsidian Git の commit）、Drive の停止のいずれかがあるとき、次のセッションの開始時にエージェントが push を試し、残る問題をユーザーに伝える。

## Considered Alternatives / Rejection Rationale

| 検討した案 | 却下した理由 |
|---|---|
| Obsidian Sync | 有料。無料で運用する方針に反する |
| iCloud Drive | 「Mac のストレージを最適化」でファイルがクラウドに退避されるとエージェントが読めない。`.git` を置くと壊れやすい |
| Google Drive に vault をそのまま置く | クライアントの情報が平文で置かれ、Drive に接続した AI コネクタからも読める |
| gcrypt + private GitHub | 上流の README が、任意の git の remote では push のたびに履歴全体を送り「大半のリポジトリに不適」と明言する。repack や添付で GitHub の 100MB 制限に当たると push が恒久的に失敗する。SSH は 1Password の承認を通るので、ロック中の無人 push が止まる |
| rclone crypt で作業ツリーを同期する | rclone は git の remote ではないので Obsidian Git から push できず、同期のきっかけに常駐の仕組みか手作業が要る |
| gcrypt の rclone バックエンドで Drive に置く | 上流が「experimental、early adopters only」と警告する。rclone の OAuth トークンの管理が増える |
| gcrypt のバックアップ先を bare リポジトリにする | `HEAD` を持つディレクトリは git のバックエンドとして扱われ、push のたびに履歴全体を送る |
| git-crypt + private GitHub | ファイル名とコミットメッセージを暗号化しない。Obsidian ではノートのタイトルがファイル名になるので、固有名が漏れる |
| 1 つの vault を案件ごとのフォルダに分ける | 契約終了時に履歴の書き換えが要る。読み取りの分離が規約頼みなのは 2 層の構成でも同じだが、消しやすさで劣る |
| リポジトリごとの vault | 横断的な知見と日々のログが散らばる |
| リポジトリの `docs/` を symlink で vault に取り込む | 公式が強く非推奨とする（データの消失・破損のおそれ）。クライアントのリポジトリの中身が同期先に出る |
| リポジトリごとに gitignore したファイルで vault を指定する | clone や worktree を作るたびに設定が要る。Codex の `AGENTS.override.md` はチームの AGENTS.md を置き換えてしまう |
| 書き込みを承認制にする | ユーザーが自動の読み書きを選んだ。指示が残り続けるリスクは、指示と事実を分けることで抑える |
| feedback も vault に置き、自動で読ませる | 外部の入力に埋め込まれた指示が、承認なしに後のすべてのセッションへ残る |
| 手入力も含めて Obsidian Git だけが push する | Obsidian Git は Obsidian で開いている vault でしか動かないので、エージェントだけが書く vault が push されない |
| すべての commit をプラグインに任せる | エージェントの書き込みと手入力が同じ commit に混ざり、見分けられない |
| LaunchAgent で定期的に commit・push する | vault を列挙するスクリプトを持つことになる |
| クライアントの知見を人が personal に移す | 手作業をきっかけにすると忘れる。決定的な検査（gitleaks-own）で自動化した |
| クライアント名を personal の daily に書く | 契約終了時に personal の履歴に残る。匿名のラベルにした |
| owner とラベルの対応表を personal に置く | 契約後も personal の履歴とバックアップに残り、ほかのクライアントのセッションにも読まれる。各クライアントの vault の `_vault.md` に置いた |
| remote の無いセッションを personal に記録する | クライアントの資料のディレクトリでの作業が personal に入りうる |
| 読み書きの手順を AGENTS.md にすべて書く | vault を使わない作業でも、常にコンテキストを消費する |
| 公式 CLI と `obsidian-cli` skill を使う | Obsidian アプリが起動していないと動かない。既定の対象が「最後にフォーカスした vault」なので、vault の分離を越えうる |
| パスフレーズのない GPG 鍵 | ログアウト中やディスクの盗難時にも鍵が使える。ログイン中は、キーチェーンに保存したパスフレーズも同じユーザーのプロセスから使えるので差は小さいが、そうしたプロセスは平文の vault も読めるので、増える実害は小さい（受け入れたリスク） |
| vault の作成を dotfiles のスクリプトにする | 独自の CLI を持たない方針に反する。作成は頻度が低いので skill の手順にし、Mac ごとに要る準備だけを apply のスクリプトにした |
| 鍵の作成と Mac ごとの準備をユーザーの手順書にする | ユーザーはコマンドを覚えられず、忘れる前提。鍵は 1Password 経由でエージェントが作り、Mac ごとの準備は apply で自動化した |
| Obsidian Git の PATH を vault ごとに設定する | Obsidian の localStorage に保存されるので、雛形でも git でも伝わらない。`launchctl config user path` で GUI アプリ全体に入れた |
| Codex の memory を残す | 記憶が 2 か所に分かれ、食い違ったときにどちらが正しいか分からない |
| Codex の自動生成物（raw・rollout）も移す | 量が多く、ノイズも入る |

## Out of Scope

- エージェントによる Todoist の操作（段階 6 として、vault の運用が安定してから別に検討する）
- Notion の扱い（ほぼ使っていない。Brewfile から外すかどうかは別に判断する）
- iPhone からの vault の読み書き
- Obsidian Publish などによる公開
- 旧構成（ECC）の memory の移行
- タスク管理のプラグイン（Tasks など）の導入

## Open Questions

- Google Drive のストリーミングで、repack が起きたとき（pack が 25 を超えたとき）に問題なく動くか。push と clone は、この Mac で確かめた（2026-10-17）。問題があればバックアップのフォルダを「オフラインで使用可能」にする。
- Obsidian Git の commit の間隔と、エージェントの commit が重なったときに、ロックの衝突以外の問題が起きないか。
- `_index.md` が自動の書き込みで肥大したとき、どう要約し直すか。
- 開始時の読み込みはモデルが AGENTS.md に従うかどうかに頼る。標準の memory のような確実さが要るなら、段階 4 の前に SessionStart hook で `_index.md` を注入するかを判断する（Codex の hook の有無は未確認）。
- `gitleaks-own.toml` のパターンが、クライアントの owner 名を網羅しているか。網羅していなければ、vault を作るときにパターンを足す。
