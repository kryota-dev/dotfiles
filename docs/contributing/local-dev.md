# Local Development

🌐 日本語: [local-dev.ja.md](local-dev.ja.md)

← [Docs index](../README.md)

This document describes the contributor workflow for the dotfiles repo: the `make` target contract, the lint pipeline internals, and the generated-file workflow for the vendored `_ghq` completion.

---

## The `make` contract

The `Makefile` is the single source of truth for all local dev commands. The default target is `help` — running bare `make` prints the target list and exits without touching `$HOME`.

| Target | What it runs |
|---|---|
| `help` (default) | Prints the target list via `awk` on `## ` doc-comment lines |
| `lint` | shellcheck + shfmt diff-check + `zsh -n` syntax (see below) |
| `fmt` | `shfmt -w -i 2 -ci` on `.sh` files in place; `.sh.tmpl` files are diff-reported only |
| `test` | `lint`, `lint-node`, `lint-console`, `test-node`, then `test-bats` |
| `test-bats` | `bats tests/*.bats` |
| `lint-node` | `node --check` for frontier-harness modules and tests |
| `lint-console` | `deno lint` with only `no-console` enabled, over every JS/TS source under `home/` and `tests/` (see below) |
| `test-node` | `node --test tests/frontier_harness.test.mjs` without live provider credentials |
| `benchmark` | `scripts/benchmark.sh` (cold start + 10-iteration average) |
| `sync-ghq-completion` | Fetches the vendored `_ghq` from upstream at the mise-pinned ghq version |
| `lint-deno` | `deno check` + `deno lint` + `deno fmt --check` on the ntfy dashboard (kryota-dev/dotfiles#371); best-effort, skips if `deno` is absent. Not part of `lint`/CI |
| `test-deno` | `deno test` on the ntfy dashboard; same best-effort/opt-in scope as `lint-deno` |

### Why there is no `make apply`

Applying dotfiles mutates `$HOME`. Making that mutation the default `make` target (or even an available one) risks accidental runs from muscle memory or CI typos. Instead, apply and diff are done directly:

```bash
chezmoi apply -v    # apply with verbose output
chezmoi diff        # show what would change
```

The `all` target is aliased to `help` precisely to prevent accidental `$HOME` mutation.

---

## The lint pipeline

`make lint` runs three tools in sequence. All operate on `home/**/*.sh` and `home/**/*.sh.tmpl`, excluding files matching `symlink_*`.

### 1. shellcheck

```
shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329
```

Excluded codes and rationale:

| Code | Reason |
|---|---|
| SC1091 | Sourced files are not present in the lint environment |
| SC2034 | Variables used only in subshells or by chezmoi templates appear unused |
| SC2086 | Word-splitting on certain variables is intentional |
| SC2317 | Unreachable code false-positives on chezmoi template-conditional blocks |
| SC2329 | Loop-variable warnings on template-driven constructs |

### 2. shfmt

```
shfmt -d -i 2 -ci
```

Flags: 2-space indent (`-i 2`), case-indent (`-ci`), diff mode (`-d`). The `fmt` target uses `-w` instead of `-d` for `.sh` files to write in place.

### 3. zsh syntax check

`zsh -n` is run on:

- All `home/dot_config/zsh/*.zsh` files directly
- All `home/dot_config/zsh/*.zsh.tmpl` files after template-line stripping
- `home/dot_config/zsh/completions/_ghq`

---

## The console guard

`make lint-console` is the machine check behind the house rule that no debug output ships. It
replaced the `stop:check-console-log` hook retired in #520, whose removal left that rule with
nothing enforcing it (#522).

```
deno lint --no-config --rules-tags= --rules-include=no-console
```

- **What it scans.** Every `.mjs`, `.cjs`, `.js`, `.mts`, `.cts`, `.ts`, `.jsx` and `.tsx` file
  under `home/` and `tests/`, at any depth. This is deliberately wider than `lint-node`, whose
  glob is one level deep and skips `.js` entirely.
- **Why `deno lint` and not `grep`.** The rule is AST-based, so `console.log` written inside a
  string literal or a comment is not a violation. `tests/agent_improvement.test.mjs` plants
  executable source as a string; a textual scan would report it.
- **Why only one rule.** `--rules-tags=` clears the tag-driven defaults, so `no-console` is
  the only policy rule enforced — these are mostly Node modules deno does not otherwise own,
  and the rest of its recommended set would fire on them. deno still reports
  `ban-unused-ignore`, because it evaluates ignore directives belonging to *enabled* rules;
  that is what stops an exemption from outliving the call it excused. `--no-config` stops a
  `deno.json` above the checkout from changing what gets enforced.
- **Why it is fatal without deno.** Unlike `lint-deno`, this target does not skip itself when
  the tool is missing (`mise install deno`). A guard that opts itself out when its tool is
  absent is how the check went missing in the first place. An empty file list is fatal for the
  same reason: a glob that matches nothing must not read as "no violations found".

### Opting a line out

Intentional output — a CLI writing to its user, a server-side log — opts out per line, with a
reason after `--`:

```js
// deno-lint-ignore no-console -- user-facing CLI output, not a debug leftover
console.log(banner);
```

The exemption is line-scoped on purpose: a second `console.*` call in the same file still
fails. Delete the comment when the call goes: a directive that no longer suppresses anything
is reported as `ban-unused-ignore`.

File-level opt-out is not merely discouraged, it is rejected. deno honours
`// deno-lint-ignore-file no-console` (and a bare `// deno-lint-ignore-file`, which disables
every rule), either of which would silently exempt an entire file, so the target scans for
those two forms and fails before it lints:

```
lint-console: file-level opt-out is not allowed; use a per-line '// deno-lint-ignore no-console -- <reason>' instead:
home/dot_local/lib/example/cli.mjs:1:// deno-lint-ignore-file no-console
```

A file-level directive naming only other rules (`// deno-lint-ignore-file no-explicit-any`)
is left alone — it does not weaken this guard, and the console call underneath it is still
reported.

Most of the tree needs no exemption at all — the CLI modules under `home/dot_local/lib/`
already write through `process.stdout.write` / `process.stderr.write`. At the time the guard
was enabled the only exemption in the repo was the ntfy dashboard's server-side error log.

`tests/console_lint.bats` drives the target against fixture trees (via the overridable
`CONSOLE_LINT_ROOTS`) rather than asserting on its text, because a guard that still exists but
no longer detects anything passes every textual assertion.

---

## Template-line stripping

chezmoi templates embed Go `{{ }}` directives inline with shell code. Shell linters do not understand Go template syntax, so the `Makefile` strips every line containing `{{` before passing content to shellcheck, shfmt, or `zsh -n`:

```bash
sed '/{{/d' "$f" | shellcheck --shell=bash --exclude=... -
sed '/{{/d' "$f" | shfmt -d -i 2 -ci
sed '/{{/d' "$f" | zsh -n
```

### The backslash-continuation hazard

This stripping is line-granular: it deletes the entire line if `{{` appears anywhere on it. A shell construct that spans multiple lines via `\` continuation is safe only if the `{{` appears on its own line. If a `\`-continued line is stripped, the next line becomes a dangling continuation target and the linter sees broken syntax.

**Pattern that breaks:**

```sh
# Do NOT write this in a .sh.tmpl
some_command \
  {{ if .someFlag }}"--flag"{{ end }} \   # <- this line is deleted
  last_arg                                 # <- dangling, parser error
```

**Safe alternative:** put template directives on their own lines or avoid `\` continuations that depend on a line containing `{{`.

---

## The `sync-ghq-completion` generated-file workflow

`home/dot_config/zsh/completions/_ghq` is a vendored copy of the upstream zsh completion for `ghq`. It is generated, not hand-edited.

### How it works

1. `scripts/ghq-version.sh` reads the mise-pinned ghq version (e.g. `0.6.2`) from `home/dot_config/mise/config.toml`.
2. The target fetches `https://raw.githubusercontent.com/x-motemen/ghq/v<version>/misc/zsh/_ghq`.
3. Validation: the fetched file must be non-empty and begin with `#compdef ghq`.
4. A vendored-by header is prepended:
   ```
   #compdef ghq
   # vendored: x-motemen/ghq@v<version> misc/zsh/_ghq
   # Run 'make sync-ghq-completion' to refresh.
   ```
5. `zsh -n` is run on the output.
6. The file is atomically moved into place via `mv`.

### When to run it

- When bumping the `ghq` version in `home/dot_config/mise/config.toml`, run `make sync-ghq-completion` before committing.
- On pull requests, CI runs the `sync-ghq-completion` job automatically and auto-commits a refreshed `_ghq` if it changed.

The CI job is gated to same-repo PRs only. Fork PRs receive a read-only `GITHUB_TOKEN` and the job is skipped rather than attempted.

Never edit `_ghq` by hand — the next sync will overwrite any manual changes.

---

## Cross-references

- CI workflow that mirrors `make lint` + `make test-bats`: [ci-and-tests.md](ci-and-tests.md)
- Worktree and environment setup: [worktrees-and-env.md](worktrees-and-env.md)
- chezmoi apply and source structure: [../architecture/chezmoi-engine.md](../architecture/chezmoi-engine.md)
