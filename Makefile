.PHONY: all help lint fmt test test-bats lint-node lint-console test-node lint-deno test-deno benchmark sync-ghq-completion

# Default target — show help (avoid accidental mutation of $HOME via apply)
all: help

# ========================================
# Linting & formatting
# ========================================

## Run shellcheck, shfmt check, and zsh syntax check
lint:
	@echo "==> Running shellcheck..."
	@find home scripts \( -name '*.sh' -o -name '*.sh.tmpl' -o -path 'home/dot_local/bin/executable_*' \) ! -name 'symlink_*' | while read -r f; do \
		sed '/{{/d' "$$f" | shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 - || exit 1; \
	done
	@echo "==> Running shfmt check..."
	@find home scripts \( -name '*.sh' -o -name '*.sh.tmpl' -o -path 'home/dot_local/bin/executable_*' \) ! -name 'symlink_*' | while read -r f; do \
		sed '/{{/d' "$$f" | shfmt -d -i 2 -ci || exit 1; \
	done
	@echo "==> Checking zsh syntax..."
	@for f in home/dot_config/zsh/*.zsh; do zsh -n "$$f" || exit 1; done
	@for f in home/dot_config/zsh/*.zsh.tmpl; do sed '/{{/d' "$$f" | zsh -n || exit 1; done
	@if [ -f home/dot_config/zsh/completions/_ghq ]; then zsh -n home/dot_config/zsh/completions/_ghq || exit 1; fi
	@echo "==> All lint checks passed."

## Format shell scripts with shfmt (writes .sh in place; .tmpl shown as diff only)
fmt:
	@echo "==> Formatting .sh files (shfmt -w)..."
	@find home -name '*.sh' ! -name 'symlink_*' -exec shfmt -w -i 2 -ci {} +
	@echo "==> Checking .sh.tmpl files (must be fixed manually due to chezmoi {{ }} syntax)..."
	@find home -name '*.sh.tmpl' ! -name 'symlink_*' | while read -r f; do \
		diff=$$(sed '/{{/d' "$$f" | shfmt -d -i 2 -ci 2>&1) && true; \
		if [ -n "$$diff" ]; then \
			echo "$$f needs formatting (fix manually):"; \
			echo "$$diff"; \
			echo ""; \
		fi; \
	done
	@echo "==> Done."

# ========================================
# Testing
# ========================================

## Run all checks (lint + Bats tests)
test: lint lint-node lint-console test-node test-bats

## Run Bats tests
test-bats:
	@bats tests/*.bats

# Globbed rather than enumerated: a new home/dot_local/lib/<tool>/ or tests/<tool>.test.mjs
# must not need a Makefile edit to be linted (the literal list silently skipped new files).
#
# The `## ` line has to sit directly above the target: the help target's awk clears the
# pending description on any line that is not a `## ` comment, so a prose block between the
# two silently drops the target from `make help` (which is where lint-node had gone).
## Syntax-check Node.js modules and tests
lint-node:
	@for f in home/dot_local/lib/*/*.mjs tests/*.test.mjs; do \
		node --check "$$f" || exit 1; \
	done

# Scan roots for lint-console. Overridable so tests/console_lint.bats can aim the target at a
# fixture tree and assert the failing cases without planting a violation in the repo.
CONSOLE_LINT_ROOTS ?= home tests

# The extensions lint-console scans, as a find expression. Kept in one variable because the
# recipe walks the tree three times (emptiness probe, file-level opt-out check, lint) and the
# three must never drift apart.
CONSOLE_LINT_NAMES = -name '*.mjs' -o -name '*.cjs' -o -name '*.js' -o -name '*.mts' -o -name '*.cts' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx'

# Replaces the stop:check-console-log hook retired in #520, which left the house standard
# ("no leftover debug output") with no machine guard at all (#522).
#
# deno lint, not a grep: the rule is AST-based, so `console.log` inside a string literal or a
# comment is not a violation (tests/agent_improvement.test.mjs plants executable source as a
# string). `--rules-tags=` clears the tag-driven defaults, so the only policy rule enforced
# here is no-console -- these are mostly Node modules deno does not otherwise own, and the
# rest of its recommended set would fire on them. deno still reports ban-unused-ignore for a
# stale `deno-lint-ignore no-console` (it evaluates directives of enabled rules), which is
# what keeps exemptions from outliving the call they excused. `--no-config` keeps a deno.json
# above the checkout from changing what gets enforced.
#
# Globbed like lint-node, but at any depth and including .js: lint-node's depth-1 glob
# silently misses the two .js files outside home/dot_local/lib/*/.
#
# A file-level opt-out (`// deno-lint-ignore-file no-console`, or a bare one, which disables
# every rule) would exempt a whole file, so a preflight rejects those before deno runs. deno
# offers no flag to disable ignore directives, so this has to be done by inspecting sources.
#
# The preflight is fail-closed: it finds `deno-lint-ignore-file` anywhere in a line and then
# *allows* it only when the remainder provably names other rules -- ASCII rule names, at least
# one of them, none of them no-console. Anything it cannot prove safe is rejected.
#
# It is written that way because the earlier attempts, which tried to recognise the directive
# the way deno's lexer does, kept leaking. Each of these passed a check anchored on
# `^[[:space:]]*//` while deno honoured the directive and silently exempted the file: a BOM
# (U+FEFF) before the `//`; a non-ASCII space (U+00A0, U+3000, any Unicode Zs) before it or
# between the rule names; U+2028/U+2029 after it, which end a line comment for ECMAScript but
# not a record for awk. The set of such code points is ECMAScript's, not POSIX's, so matching
# it in awk is a list that is never finished -- and every gap is a silent hole, which is the
# failure mode this guard exists to prevent. Inverting the test ends that chase: unfamiliar
# input fails loudly instead of passing quietly.
#
# LC_ALL=C is load-bearing, not tidiness. Character classes are locale-dependent: under a
# UTF-8 locale glibc classifies U+2028 as [[:space:]], so `<U+2028>x` reads to the allow-list
# as "a space and an ASCII rule name" and passes -- the same gap, reintroduced by the
# environment. That slipped through a macOS run (byte-oriented awk) and failed on CI. Pinning
# the locale keeps the match byte-oriented, which is the only way the allow-list means the
# same thing on both platforms.
#
# The cost is false positives -- the literal text in a template literal, a block comment, or
# prose inside a scanned file is rejected even where deno would ignore it. That is the side
# to err on, and it is pinned by tests/console_lint.bats.
#
# awk reads each file itself (FILENAME/FNR) rather than re-parsing `grep -H` output: a path
# containing `:<digits>:` makes a `<path>:<line>:` strip match in the wrong place, and a bare
# directive then slips through. Both the matched text and control characters in the path are
# kept out of the diagnostic, so neither a file's contents nor its name can smuggle terminal
# escapes into a developer's console or a CI log.
#
# Unlike lint-deno this is deliberately not best-effort. It is part of `test`, and a guard
# that skips itself when its tool is missing is the failure mode #522 was filed about, so an
# absent deno and an empty file list are both fatal.
## Reject console.* calls in Node and Deno sources (opt out per line, never per file)
lint-console:
	@command -v deno >/dev/null 2>&1 || { echo "lint-console: deno not found; run 'mise install deno'. This guard does not skip itself." >&2; exit 1; }
	@[ -n "$$(find $(CONSOLE_LINT_ROOTS) -type f \( $(CONSOLE_LINT_NAMES) \) -print -quit)" ] || { \
		echo "lint-console: no JS/TS sources under '$(CONSOLE_LINT_ROOTS)' -- the glob regressed." >&2; \
		exit 1; \
	}
	@bad=$$(LC_ALL=C find $(CONSOLE_LINT_ROOTS) -type f \( $(CONSOLE_LINT_NAMES) \) \
		-exec awk 'match($$0, /deno-lint-ignore-file/) { \
			rest = substr($$0, RSTART + RLENGTH); \
			sub(/--.*$$/, "", rest); gsub(/,/, " ", rest); \
			allow = 0; \
			if (rest ~ /^[[:space:]a-z0-9-]+$$/ && rest ~ /[a-z]/ && \
			    rest !~ /(^|[[:space:]])no-console([[:space:]]|$$)/) allow = 1; \
			if (allow == 0) { \
				name = FILENAME; gsub(/[[:cntrl:]]/, "?", name); \
				printf "%s:%d\n", name, FNR; \
			} \
		}' {} +); \
	if [ -n "$$bad" ]; then \
		echo "lint-console: file-level opt-out is not allowed; use a per-line '// deno-lint-ignore no-console -- <reason>' instead:" >&2; \
		printf '%s\n' "$$bad" >&2; \
		exit 1; \
	fi
	@find $(CONSOLE_LINT_ROOTS) -type f \( $(CONSOLE_LINT_NAMES) \) \
		-exec deno lint --no-config --rules-tags= --rules-include=no-console {} +

## Run Node.js tests without invoking live provider credentials
test-node:
	@node --test tests/*.test.mjs

## Type-check, lint, and format-check the ntfy dashboard's Deno code (kryota-dev/dotfiles#371)
lint-deno:
	@command -v deno >/dev/null 2>&1 || { echo "deno not found (mise install deno); skipping."; exit 0; }
	@echo "==> Running deno check/lint/fmt (ntfy dashboard)..."
	@cd home/dot_config/ntfy-dashboard && deno check server.ts server_test.ts && deno lint server.ts server_test.ts && deno fmt --check server.ts server_test.ts

## Run the ntfy dashboard's Deno unit tests (kryota-dev/dotfiles#371)
test-deno:
	@command -v deno >/dev/null 2>&1 || { echo "deno not found (mise install deno); skipping."; exit 0; }
	@cd home/dot_config/ntfy-dashboard && deno test

## Run zsh startup benchmark
benchmark:
	@scripts/benchmark.sh

# ========================================
# Utilities
# ========================================

## Sync vendored _ghq completion from the mise-pinned upstream ghq version
sync-ghq-completion:
	@version=$$(scripts/ghq-version.sh) || exit 1; \
	echo "Syncing _ghq from x-motemen/ghq@v$$version..."; \
	url="https://raw.githubusercontent.com/x-motemen/ghq/v$$version/misc/zsh/_ghq"; \
	tmpfile=$$(mktemp); \
	tmpout=$$(mktemp); \
	if ! curl -fsSL "$$url" -o "$$tmpfile"; then \
		echo "ERROR: failed to fetch $$url"; \
		rm -f "$$tmpfile" "$$tmpout"; \
		exit 1; \
	fi; \
	if [ ! -s "$$tmpfile" ]; then \
		echo "ERROR: fetched _ghq is empty"; \
		rm -f "$$tmpfile" "$$tmpout"; \
		exit 1; \
	fi; \
	case "$$(head -n1 "$$tmpfile")" in \
		'#compdef ghq'*) ;; \
		*) echo "ERROR: fetched file does not start with '#compdef ghq'"; rm -f "$$tmpfile" "$$tmpout"; exit 1 ;; \
	esac; \
	mkdir -p home/dot_config/zsh/completions; \
	{ \
		head -n1 "$$tmpfile"; \
		echo "# vendored: x-motemen/ghq@v$$version misc/zsh/_ghq"; \
		echo "# Run 'make sync-ghq-completion' to refresh."; \
		tail -n +2 "$$tmpfile"; \
	} > "$$tmpout"; \
	if ! zsh -n "$$tmpout" 2>/dev/null; then \
		echo "ERROR: vendored _ghq fails zsh syntax check"; \
		rm -f "$$tmpfile" "$$tmpout"; \
		exit 1; \
	fi; \
	mv "$$tmpout" home/dot_config/zsh/completions/_ghq; \
	rm -f "$$tmpfile"; \
	echo "Done."

## Show this help
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^## / { sub(/^## /, ""); desc = $$0; next } \
	      /^[a-zA-Z0-9_-]+:/ { if (desc) { name = $$1; sub(/:.*/, "", name); \
	        printf "  %-22s %s\n", name, desc; desc = "" } } \
	      !/^## / { desc = "" }' $(MAKEFILE_LIST)
