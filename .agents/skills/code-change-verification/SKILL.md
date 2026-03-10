---
name: code-change-verification
description: >-
  Run the mandatory verification stack (lint + test) when changes affect shell scripts,
  zsh config, Makefile, or CI config. Skip when only documentation files are changed.
  Report results and prompt for fixes on failure.
user-invocable: true
allowed-tools: Bash
---

# Code Change Verification

Run the mandatory verification stack for the dotfiles repository.

## Steps

### 1. Identify changed files

```bash
# Working tree and staging changes
git diff --name-only
git diff --cached --name-only

# All branch changes (including already committed)
git diff --name-only main...HEAD 2>/dev/null
```

### 2. Check if changes are documentation-only

If all changed files are `.md` files, skip verification and report:

```
Verification skipped: only documentation (.md) files were changed — lint/test not required.
```

### 3. Run the verification stack

If code changes are present, run the following in order:

```bash
# lint (shellcheck + shfmt + zsh syntax check)
make lint

# test (lint + bats)
make test
```

### 4. Report results

#### On success

```
Verification passed: all lint and test checks passed.
```

#### On failure

Report the error output and suggest fixes:

```
Verification failed:
- make lint: {pass/fail}
- make test: {pass/fail}

Error details:
{error output}

Suggested fix:
{specific fix proposal}
```

## Notes

- `make fmt` (auto-fix) is intentionally excluded. Auto-fix should be run explicitly by the user.
- Verification commands reference Makefile targets. If the command structure changes, only the Makefile needs to be updated.
