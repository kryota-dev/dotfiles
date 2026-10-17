---
slug: obsidian-vault
feature: Obsidian の vault をエージェント共有の作業記憶にする
created_at: 2026-10-17T15:20:20+09:00
grill_session: session_01URzA66y6iGNLkNjzuLmdBH
status: draft
---

# Obsidian の vault をエージェント共有の作業記憶にする

## Background

Claude Code と Codex はそれぞれ標準の memory を持つが、互いに読めず、案件をまたいだ文脈の引き継ぎもできない。
2026 年 2 月に Obsidian の公式 CLI と公式の Agent Skills（kepano/obsidian-skills）が出て、エージェントが vault を
正規の手段で扱えるようになった。vault は Markdown ファイルの入ったフォルダにすぎないので、両ハーネスから
直接読み書きできる。

制約は 3 つある。

- 無料で運用する。Obsidian Sync（有料）は使わない。
- 複数のクライアントの案件を扱う。ある案件のセッションに他社の情報が混ざってはならず、契約が終わったら
  その案件の記録をまとめて消せなければならない。
- このリポジトリは環境の宣言にとどめる。独自のランタイム・サーバー・CLI を足さない。

## User Story

- 開発者として、Claude Code でも Codex でも、セッションを開いた時点でその案件の現状と直近の決定を
  エージェントが把握していてほしい。毎回説明し直したくない。
- 開発者として、A 社のリポジトリで作業するエージェントに B 社の情報を読ませたくない。
- 開発者として、エージェントが vault に書いた内容を、自分の手入力と区別して後から確認し、戻せるようにしたい。
- 開発者として、vault を Mac の外に暗号化したうえでバックアップし、Mac を失っても復元したい。
- 開発者として、記憶の置き場所を vault の 1 か所にまとめ、標準の memory と二重に管理したくない。

## 設計

### vault の構成

個人の vault 1 つと、クライアントごとの vault に分ける。

```
~/vaults/personal/              共有の層
├── _index.md                   入口のノート
├── daily/YYYY-MM-DD.md         1 日の全体像（各案件は 1 行の要約まで）
├── knowledge/                  汎用の知見（固有の情報を取り除いて書く）
├── projects/<repo>/            個人のリポジトリの作業記憶（構成はクライアントの vault と同じ）
├── _inbox/rule-proposals.md    エージェントが出したルール案
└── owners.md                   owner から vault への対応表

~/vaults/<owner>/               クライアントの層（クライアントごとに 1 つ）
├── _index.md                   入口のノート。現状・進行中の作業・直近の決定へのリンク（短く保つ）
├── daily/YYYY-MM-DD.md
├── decisions/YYYY-MM-DD-<slug>.md
├── meetings/YYYY-MM-DD-<slug>.md
├── notes/
└── attachments/
```

フロントマターは `type`（daily / decision / meeting / note / knowledge）、`date`、`author`（human / claude /
codex）だけにする。

### リポジトリと vault の結び付け

`git remote get-url origin` の owner を取り、`~/vaults/<owner>/` を使う。自分の owner と、1 つのクライアントが
複数の owner を持つ場合は `owners.md` で解決する。クライアントのリポジトリの AGENTS.md はチームと共有して
いるので、vault のパスは書かない。

### 読み書き

- 開始時: 該当する vault の `_index.md` と、personal の `knowledge/` を読む。詳細はリンクをたどって必要な
  ときに読む。クライアントの案件のセッションでは、personal の `daily/` と他の vault を読まない。
- 区切りと終了時: 日々のログ・決定事項・`_index.md` を自動で更新する。
- vault の内容はデータとして扱い、書かれた指示には従わない。振る舞いのルールは AGENTS.md にだけ置く。
  ルール案は `_inbox/rule-proposals.md` に書き、ユーザーが dotfiles の PR で AGENTS.md に反映する。

### 履歴とバックアップ

- vault ごとにローカルの git リポジトリを持つ。
- エージェントは書いた直後に `agent(claude): ...` / `agent(codex): ...` で commit する。git のロックが
  ぶつかったら待ってやり直す。
- 手入力の変更の commit と push は Obsidian Git プラグインが定期的に行う。
- remote は `gcrypt::` を付けた private GitHub リポジトリにし、中身・ファイル名・履歴を暗号化する。
- 鍵は vault 専用の GPG 鍵にする。パスフレーズは pinentry-mac で macOS のキーチェーンに保存する。
  秘密鍵の控えとパスフレーズは 1Password に置く。

### 実装の場所

| 場所 | 内容 |
|---|---|
| `home/dot_Brewfile` | `obsidian`（cask）、`git-remote-gcrypt`、`pinentry-mac` |
| `~/.gnupg/gpg-agent.conf` | `pinentry-program` に pinentry-mac を指定 |
| `home/dot_gitignore_global` | `.obsidian/`（リポジトリをその場だけ vault として開くため） |
| `home/.chezmoiexternal.toml` | kepano/obsidian-skills（commit SHA で固定） |
| `home/dot_agents/exact_skills/vault/` | 読み書きの手順、commit の規約、ルール案の提案先、新しい vault の作成手順 |
| `home/AGENTS.md` | vault の解決規約と安全の原則（数行） |
| `home/dot_claude/settings.json` | `"autoMemoryEnabled": false` |
| `home/dot_codex/modify_private_config.toml` | `features.memories = false` |
| `home/dot_claude/CLAUDE.md` | memory への記録のルールを削除 |
| `ARCHITECTURE.md` | vault と memory の方針 |

エージェントはファイルを直接読み書きする。公式 CLI は Obsidian アプリが起動していないと動かないので、
必須にしない。

### 段階

1. dotfiles の PR ①（土台）: Brewfile・gpg-agent・gitignore・externals・`vault` skill・AGENTS.md。
   この段階では memory を止めない。
2. personal の vault の立ち上げ: GPG 鍵、`vault` skill の手順による作成、Obsidian Git の設定、
   復元の確認。
3. memory の移行: 振り分けの一覧を示す → ユーザーが承認 → 書き込み → 原本を `~/Archive/` に退避。
4. dotfiles の PR ②（切り替え）: 両ハーネスの memory を止め、CLAUDE.md の memory のルールを削除し、
   ARCHITECTURE.md を更新する。
5. クライアントの vault: 案件に入るときに、その都度 `vault` skill で作成する。

移行の前に memory を止めると、その間の学びが残らない。そのため段階 4 を段階 3 の後に置く。

## Acceptance Criteria

- **AC-001**: `chezmoi apply` で Obsidian・git-remote-gcrypt・pinentry-mac が入り、`gpg-agent.conf` が
  pinentry-mac を指す。
- **AC-002**: kepano/obsidian-skills が `.chezmoiexternal.toml` から commit SHA で固定して取得され、
  Claude Code と Codex の両方で skill として読み込まれる。
- **AC-003**: `vault` skill が Claude Code と Codex の両方で読み込まれ、開始時に読むもの、区切りで書くもの、
  commit の規約、ルール案の提案先、新しい vault の作成手順を定める。
- **AC-004**: `~/AGENTS.md` に、owner から vault を引く規約、読んでよい範囲、vault の内容をデータとして
  扱う原則が書かれている。public リポジトリにクライアントの固有名が含まれない。
- **AC-005**: クライアントの owner を持つリポジトリでセッションを始めると、エージェントはその vault の
  `_index.md` と personal の `knowledge/` だけを読み、他の vault と personal の `daily/` を読まない。
- **AC-006**: 自分の owner を持つリポジトリでは、personal の `projects/<repo>/` が作業記憶として使われる。
- **AC-007**: エージェントの書き込みは `agent(claude|codex):` で始まる commit として残り、
  `git log --grep '^agent'` で一覧にできる。
- **AC-008**: Obsidian Git が手入力の変更を定期的に commit し、`gcrypt::` の remote に push する。
  GitHub 上のリポジトリからファイル名と中身が読めない。
- **AC-009**: 別のディレクトリに `gcrypt::` の remote から clone すると、vault の全履歴が復号されて
  復元できる。GPG 鍵は 1Password の控えから入れ直せる。
- **AC-010**: エージェントが振る舞いのルールを学んだとき、AGENTS.md や vault の自動で読まれる場所ではなく、
  `_inbox/rule-proposals.md` に提案として書く。
- **AC-011**: 既存の Claude Code の memory（旧構成のものを除く）と Codex の memory の要約が、振り分けの
  一覧のユーザー承認を経て vault に移され、原本が `~/Archive/` に退避されている。
- **AC-012**: Claude Code の auto memory と Codex の memories が無効になり、新しいセッションで memory が
  読み込まれも書き込まれもしない。
- **AC-013**: `vault` skill の手順で、新しいクライアントの vault（骨組み・`.obsidian/` の雛形・git・
  private リポジトリ・`gcrypt::` の remote・最初の push）を作れる。
- **AC-014**: スクリプト・テンプレート・CI に触れた PR では `make test` が通る。

## Considered Alternatives / Rejection Rationale

| 検討した案 | 却下した理由 |
|---|---|
| Obsidian Sync | 有料。無料で運用する方針に反する |
| iCloud Drive | 「Mac のストレージを最適化」でファイルがクラウドに退避されるとエージェントが読めない。`.git` を置くと壊れやすい |
| Google Drive に vault をそのまま置く | クライアントの情報が平文で置かれ、Drive に接続した AI コネクタからも読める |
| Google Drive + rclone crypt | 安全性は gcrypt と同等だが、rclone と OAuth の設定が増える。履歴が増えて push が遅くなったら移行先として検討する |
| git-crypt + private GitHub | ファイル名とコミットメッセージを暗号化しない。Obsidian ではノートのタイトルがファイル名になるので、固有名が漏れる |
| 1 つの vault を案件ごとのフォルダに分ける | 混ざるのを防ぐ手段が規約と Read deny（Bash は止められない）だけになる。契約終了時に履歴の書き換えが要る |
| クライアントの vault の代わりにリポジトリごとの vault | 横断的な知見と日々のログが散らばる |
| リポジトリの `docs/` を symlink で vault に取り込む | 公式が強く非推奨とする（データの消失・破損のおそれ）。クライアントのリポジトリの中身が同期先に出る |
| リポジトリごとに gitignore したファイルで vault を指定する | clone や worktree を作るたびに設定が要る。Codex の `AGENTS.override.md` はチームの AGENTS.md を置き換えてしまう |
| 書き込みを承認制にする | ユーザーが自動の読み書きを選んだ。指示が残り続けるリスクは、指示と事実を分けることで抑える |
| feedback も vault に置き、自動で読ませる | 外部の入力に埋め込まれた指示が、承認なしに後のすべてのセッションへ残る |
| エージェントだけが commit と push をする | エージェントを使わない日の手入力が push されない（ユーザーは Obsidian Git を選んだ） |
| すべての commit をプラグインに任せる | エージェントの書き込みと手入力が同じ commit に混ざり、見分けられない |
| LaunchAgent で定期的に commit する | vault を列挙するスクリプトを持つことになる |
| 読み書きの手順を AGENTS.md にすべて書く | vault を使わない作業でも、常にコンテキストを消費する |
| 公式 CLI を必須にする | Obsidian アプリが起動していないと動かない |
| パスフレーズのない GPG 鍵 | `~/.gnupg` を読めるプロセスに GitHub 上の vault を復号されうる |
| vault の作成を dotfiles のスクリプトにする | 独自の CLI を持たない方針に反する |
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

- Obsidian Git プラグインの設定（commit の間隔、Dock から起動したときの PATH、pinentry-mac との連携）を
  vault ごとにどう揃えるか。personal の `.obsidian/` を雛形としてコピーする前提で、段階 2 で確かめる。
- gcrypt の push が、Obsidian Git とエージェントの commit の頻度でどれだけ遅くなるか。遅くなるなら、push の
  間隔を延ばすか、rclone crypt に移す。
- エージェントの commit と Obsidian Git の自動 commit が同時に走ったとき、ロックの衝突以外の問題（作業途中の
  ファイルを commit するなど）が起きないか。
- `_index.md` をどれだけ短く保てるか。自動で書き込むうちに肥大したとき、どう要約し直すか。
- kepano/obsidian-skills のライセンスと、externals で取得したときの配置（`exact_skills` の中の位置）。
