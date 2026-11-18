# GitHub API での commit

dotfiles の作業ツリーを変更せず、固定した oid のファイルを一時ディレクトリで編集する。
ローカルの `git commit` と push は使わない。
[GitHub の公式仕様](https://docs.github.com/en/graphql/reference/commits)では、
`createCommitOnBranch` の commit は資格情報の所有者が author となり、対応していれば GitHub が署名して verified になる。
この経路なら、ローカルの署名で 1Password の承認を待たずに済む。

## 1. 基底を固定する（S5）

対象リポジトリと反映の PR を personal モードで確定する。
開いた PR がある場合は、その `headRefName` と `headRefOid` を使う。
無い場合は、既存の `rule-sweep/<日付>` ブランチと状況のノートを調べ、PR 作成前に止まった実行を回収する。
すべてのページの commit を調べて ID を照合する。由来が分からない同名ブランチは使わず止まる。
回収先も無い場合だけ `git fetch origin main` の後の `origin/main` の oid を使う。
fetch はよいが、dotfiles の checkout・index・HEAD は変更しない。

API の oid がローカルに無ければ、そのブランチを fetch してオブジェクトを取得する。
変えるファイルごとに、元の版を次の形で一時ディレクトリへ書き出す。

```bash
git show <基底の oid>:<リポジトリ内のパス> > <一時ディレクトリ内のファイル>
```

変えてよいのは `origin/main` に存在する `home/AGENTS.md` と、既存の skill の `SKILL.md`・`references/*.md` だけにする。
新しいファイルの作成と削除はしない。基底の oid にも対象のファイルが存在することを確認する。
パスの各要素を確認し、名前が `.tmpl` を含むもの、`run_`・`executable_`・`symlink_`・`modify_`・`create_`・`.chezmoi` で始まるもの、`.md` 以外は送らない。
当たる件は `反映先が範囲外` として除外する。chezmoi によるテンプレートの評価やスクリプトの実行を避けるためである。
ローカルの作業ツリーのファイルや、途中で進んだ `origin/main` を混ぜない。
一時ディレクトリは `mktemp -d "${TMPDIR:-/tmp}/rule-sweep-personal.XXXXXX"` など、実行ごとに分ける。
ファイルのパスはリポジトリ相対とし、上の条件をすべて満たすものだけを送る。

## 2. 作業ブランチを API で作る

新規の場合は固定の `rule-sweep/<YYYY-MM-DD>` を使う。既存 PR のブランチには作り直さず追加する。
新規作成は次の REST API で行う。

```bash
gh api repos/<owner>/<repo>/git/refs \
  -f ref=refs/heads/<branch> -f sha=<基底の oid>
```

作成の競合・認証・API の失敗では止まり、別名のブランチを自動で増やさない。
書き込みを始める前に、personal モードの vault の保存・push と公開物の検査、本人の承認を終えておく。

## 3. 1 件 1 commit を送る

最初に、既存か新規かにかかわらず ID が `^rp-[0-9]{8}-[0-9a-f]{4}$` に合うことを確認する。
合わない件は `形が不正` として除外する。headline は、この確認を通った ID と固定の文だけで組み立てる。
1 件を適用した後のファイル全体は、personal モードの手順 6 で検査用ディレクトリに作り、本人が承認したものを使う。ここで作り直さない。
そのファイルを UTF-8 のバイト列として base64 にする。
シェルに提案の原文を展開せず、ファイルから読む。例では `jq` の `@base64` を使う。
既存ファイルの更新だけを `additions` に入れ、`deletions` は常に空配列にする。
複数のファイルにまたがる 1 件は、同じ `fileChanges` にまとめる。

以下は既存の 1 ファイルを更新する形。山括弧の箇所は確定した値に置き換える。
`--arg`・`--rawfile` で渡し、提案の文をコマンドや JSON に直接埋め込まない。

```bash
jq -n \
  --arg repository '<owner>/<repo>' \
  --arg branch '<branch>' \
  --arg expected '<直前の head の oid>' \
  --arg headline 'docs(agents): 決まりの反映 <ID>' \
  --arg path '<リポジトリ内のパス>' \
  --rawfile contents '<編集済みファイル>' \
  '{query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }",
    variables: {input: {
      branch: {repositoryNameWithOwner: $repository, branchName: $branch},
      message: {headline: $headline, body: ""},
      fileChanges: {additions: [{path: $path, contents: ($contents | @base64)}], deletions: []},
      expectedHeadOid: $expected
    }}}' > <API の入力ファイル>

gh api graphql --input <API の入力ファイル> > <API の応答ファイル>
```

`gh` の終了コードに加え、応答の `errors` が無く、`data.createCommitOnBranch.commit.oid` と `url` があることを確認する。
返った oid を次の `expectedHeadOid` に渡す。最初は手順 1 の基底 oid を渡す。
件ごとの版は、前の件を適用した版に積み上げて作ってある。
送るときに最初の版から作り直すと、前の件を消してしまう。
API の入力ファイルも秘密情報を含みうるので、公開物やログに写さない。

本人の外す指定を戻す場合は、`docs(agents): 決まりの取り消し <ID>` の追加 commit にする。
commit のメッセージ・ブランチ名・PR の題には、提案の原文や出典を入れず、固定の文と ID・日付だけを使う（S4）。

## 4. 不一致と途中停止を扱う

`expectedHeadOid` が合わないときは、ほかの書き込みが入っている。
再試行や force push をせず止まり、成功済みの ID・oid・ブランチを状況のノートに残す。
ほかの API エラーと認証の失敗も、別の資格情報やローカルの署名へ切り替えず止まる。
通信が途切れて成功したか不明な場合も、その場で同じ commit を送らない。
次回、リモートの commit の ID と内容を照合してから再開する。

PR の作成・本文の更新は personal モードに戻って行う。
PR 作成前に止まったブランチの回収は、手順 1 に従う。
最終的な inbox・状況の保存まで終えたら、一時ディレクトリを `rm -r` で消す（`rm -rf` は Claude Code の deny に当たる）。
