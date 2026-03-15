# chezmoi Skill更新手順

chezmoi公式ドキュメントが変更された際にskill fileを更新する方法を記述する。

## 更新タイミング

- chezmoiが新機能、command、template関数を含む新versionをreleaseした時
- Userが明示的に更新を要求した時（例: 「chezmoiスキルを更新」「chezmoi docs refresh」）

## 更新手順

### Step 1: 最新ドキュメントindexの取得

Chezmoi repositoryの全markdownドキュメントfileをlist:

```bash
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/")) | select(.path | endswith(".md") or endswith(".md.tmpl")) | .path'
```

### Step 2: 主要ドキュメントfileのdownload

GitHub APIを使用して各fileをdownloadしbase64 decode:

```bash
gh api "repos/twpayne/chezmoi/contents/assets/chezmoi.io/docs/$PATH" --jq '.content' | base64 -d
```

以下のドキュメントcategoryをcoverする必要がある:

#### Core Reference（最優先 - ここの変更はSKILL.mdに直接影響）
- `docs/reference/concepts.md`
- `docs/reference/source-state-attributes.md`
- `docs/reference/target-types.md`
- `docs/reference/application-order.md`

#### User Guide
- `docs/user-guide/templating.md`
- `docs/user-guide/manage-machine-to-machine-differences.md`
- `docs/user-guide/manage-different-types-of-file.md`
- `docs/user-guide/use-scripts-to-perform-actions.md`
- `docs/user-guide/daily-operations.md`
- `docs/user-guide/setup.md`
- `docs/user-guide/include-files-from-elsewhere.md`
- `docs/user-guide/password-managers/1password.md`
- `docs/user-guide/encryption/age.md`
- `docs/user-guide/frequently-asked-questions/usage.md`
- `docs/user-guide/frequently-asked-questions/troubleshooting.md`

#### Special File / Directory
- `docs/reference/special-files/chezmoiroot.md`
- `docs/reference/special-files/chezmoiignore.md`
- `docs/reference/special-files/chezmoiexternal-format.md`
- `docs/reference/special-files/chezmoidata-format.md`
- `docs/reference/special-directories/chezmoidata.md`
- `docs/reference/special-directories/chezmoiexternals.md`
- `docs/reference/special-directories/chezmoiscripts.md`
- `docs/reference/special-directories/chezmoitemplates.md`

#### Template関数（`references/template-functions.md` を更新）
- `docs/reference/templates/variables.md`
- `docs/reference/templates/directives.md`
- `docs/reference/templates/functions/` - 全 `.md` file
- `docs/reference/templates/1password-functions/` - 全 `.md` file
- `docs/reference/templates/init-functions/` - 全 `.md` file
- `docs/reference/templates/github-functions/` - 全 `.md` file
- その他のpassword manager関数directoryも必要に応じて

#### Command（`references/commands.md` を更新）
- `docs/reference/commands/` - 全 `.md` file

#### Configuration（関連sectionを更新）
- `docs/reference/configuration-file/index.md`
- `docs/reference/configuration-file/hooks.md`
- `docs/reference/configuration-file/interpreters.md`
- `docs/reference/configuration-file/editor.md`
- `docs/reference/configuration-file/variables.md.tmpl`

### Step 3: 変更の特定

Downloadした内容を既存のskill fileと比較する。以下に注目:

1. **新しいprefixまたはsuffix** - source state attribute
2. **新規または変更されたcommand** - flagを含む
3. **新しいtemplate関数** - 特に新しいpassword manager連携
4. **新しいspecial file / directory**
5. **新しいconfiguration option**
6. **既存機能の動作変更**
7. **新しいtroubleshooting項目**

新しいtemplate関数fileを素早く検出するscript:

```bash
# 全template関数ドキュメントをlist
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/reference/templates/")) | select(.path | endswith(".md")) | .path' \
  | sort > /tmp/chezmoi-upstream-functions.txt

# Skillに記載されている関数と比較
echo "Review /tmp/chezmoi-upstream-functions.txt for new entries not in references/template-functions.md"
```

新しいcommandを検出するscript:

```bash
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/reference/commands/")) | select(.path | endswith(".md")) | .path' \
  | sort > /tmp/chezmoi-upstream-commands.txt

echo "Review /tmp/chezmoi-upstream-commands.txt for new entries not in references/commands.md"
```

### Step 4: Skill Fileの更新

以下のfileを順番に更新する:

1. **`SKILL.md`** - 以下に変更がある場合に更新:
   - Core conceptsまたは用語
   - Source state attributeのprefix/suffix
   - Application order
   - Template variable table
   - 主要template関数list
   - Special file/directory list
   - 主要command table
   - Troubleshooting section

2. **`references/template-functions.md`** - 以下がある場合に更新:
   - 新しいtemplate関数
   - 関数signatureまたは動作の変更
   - 新しいpassword manager連携
   - 新しいinit-time関数

3. **`references/externals.md`** - 以下がある場合に更新:
   - 新しいexternal type
   - 新しいentry field
   - Include/exclude動作の変更

4. **`references/commands.md`** - 以下がある場合に更新:
   - 新しいcommand
   - 既存commandの新しいflag
   - Command動作の変更

### Step 5: 検証

更新後、skill fileを検証する:

```bash
# 内部referenceが壊れていないか確認
grep -r 'references/' home/dot_agents/skills/chezmoi/SKILL.md

# File sizeが適切か確認（SKILL.mdは500行以下に保つ）
wc -l home/dot_agents/skills/chezmoi/SKILL.md home/dot_agents/skills/chezmoi/references/*.md
```

## 並列化のヒント

Downloadを高速化するため、subagentを使ってドキュメントcategoryを並列download:
- Agent 1: Core reference + special file/directory
- Agent 2: Template関数（全subdirectory）
- Agent 3: Command + configuration + user guide

## 注意事項

- `gh api` approachは `git clone` より推奨される。Chezmoi repository全体（大容量）のdownloadを避けられるため
- GitHub API responseのfileはbase64 encodeされている。`base64 -d` でdecodeする
- `variables.md.tmpl` のようなfileはGo template自体であり、template syntaxを含む。Rendering後の出力と生の内容は異なるが、利用可能な変数の理解には生のtemplate sourceで十分
- `.md.yaml` file（例: `articles.md.yaml`）はlink page生成用のdata fileであり、無視してよい
