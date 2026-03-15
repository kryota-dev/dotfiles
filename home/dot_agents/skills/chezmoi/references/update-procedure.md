# chezmoi Skill Update Procedure

This document describes how to update the chezmoi skill when the official chezmoi documentation changes.

## When to Update

- chezmoi releases a new version with new features, commands, or template functions
- The user explicitly requests an update (e.g. "chezmoi skill update", "chezmoi docs refresh")

## Update Steps

### Step 1: Fetch the Latest Documentation Index

List all markdown documentation files in the chezmoi repository:

```bash
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/")) | select(.path | endswith(".md") or endswith(".md.tmpl")) | .path'
```

### Step 2: Download Key Documentation Files

Download each file using the GitHub API and base64 decode:

```bash
gh api "repos/twpayne/chezmoi/contents/assets/chezmoi.io/docs/$PATH" --jq '.content' | base64 -d
```

The following documentation categories must be covered:

#### Core Reference (highest priority - changes here affect SKILL.md directly)
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

#### Special Files and Directories
- `docs/reference/special-files/chezmoiroot.md`
- `docs/reference/special-files/chezmoiignore.md`
- `docs/reference/special-files/chezmoiexternal-format.md`
- `docs/reference/special-files/chezmoidata-format.md`
- `docs/reference/special-directories/chezmoidata.md`
- `docs/reference/special-directories/chezmoiexternals.md`
- `docs/reference/special-directories/chezmoiscripts.md`
- `docs/reference/special-directories/chezmoitemplates.md`

#### Template Functions (update `references/template-functions.md`)
- `docs/reference/templates/variables.md`
- `docs/reference/templates/directives.md`
- `docs/reference/templates/functions/` - all `.md` files
- `docs/reference/templates/1password-functions/` - all `.md` files
- `docs/reference/templates/init-functions/` - all `.md` files
- `docs/reference/templates/github-functions/` - all `.md` files
- Other password manager function directories as needed

#### Commands (update `references/commands.md`)
- `docs/reference/commands/` - all `.md` files

#### Configuration (update relevant sections)
- `docs/reference/configuration-file/index.md`
- `docs/reference/configuration-file/hooks.md`
- `docs/reference/configuration-file/interpreters.md`
- `docs/reference/configuration-file/editor.md`
- `docs/reference/configuration-file/variables.md.tmpl`

### Step 3: Identify Changes

Compare downloaded content against existing skill files. Focus on:

1. **New prefixes or suffixes** in source state attributes
2. **New or changed commands** and their flags
3. **New template functions** (especially new password manager integrations)
4. **New special files or directories**
5. **New configuration options**
6. **Changed behavior** in existing features
7. **New troubleshooting entries**

Use this script to quickly detect new template function files:

```bash
# List all template function docs
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/reference/templates/")) | select(.path | endswith(".md")) | .path' \
  | sort > /tmp/chezmoi-upstream-functions.txt

# Compare with functions documented in the skill
echo "Review /tmp/chezmoi-upstream-functions.txt for new entries not in references/template-functions.md"
```

Use this script to detect new commands:

```bash
gh api "repos/twpayne/chezmoi/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.path | startswith("assets/chezmoi.io/docs/reference/commands/")) | select(.path | endswith(".md")) | .path' \
  | sort > /tmp/chezmoi-upstream-commands.txt

echo "Review /tmp/chezmoi-upstream-commands.txt for new entries not in references/commands.md"
```

### Step 4: Update Skill Files

Update the following files in order:

1. **`SKILL.md`** - Update if there are changes to:
   - Core concepts or terminology
   - Source state attribute prefixes/suffixes
   - Application order
   - Template variable table
   - Essential template functions list
   - Special files/directories list
   - Common commands table
   - Troubleshooting section

2. **`references/template-functions.md`** - Update if there are:
   - New template functions
   - Changed function signatures or behavior
   - New password manager integrations
   - New init-time functions

3. **`references/externals.md`** - Update if there are:
   - New external types
   - New entry fields
   - Changed include/exclude behavior

4. **`references/commands.md`** - Update if there are:
   - New commands
   - New flags on existing commands
   - Changed command behavior

### Step 5: Verify

After updating, verify the skill files:

```bash
# Check no broken internal references
grep -r 'references/' home/dot_agents/skills/chezmoi/SKILL.md

# Check file sizes are reasonable (SKILL.md should stay under 500 lines)
wc -l home/dot_agents/skills/chezmoi/SKILL.md home/dot_agents/skills/chezmoi/references/*.md
```

## Parallelization Tips

To speed up downloads, use subagents to download documentation categories in parallel:
- Agent 1: Core reference + special files/directories
- Agent 2: Template functions (all subdirectories)
- Agent 3: Commands + configuration + user guide

## Notes

- The `gh api` approach is preferred over `git clone` because it avoids downloading the entire chezmoi repository (which is large)
- Files are base64-encoded in the GitHub API response; pipe through `base64 -d` to decode
- Some files like `variables.md.tmpl` are Go templates themselves and contain template syntax - their rendered output differs from raw content, but the raw template source is sufficient for understanding the available variables
- The `.md.yaml` files (e.g., `articles.md.yaml`) are data files for generating link pages and can be ignored
