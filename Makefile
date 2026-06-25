.PHONY: all help lint fmt test test-bats benchmark dump-brewfile sync-ghq-completion

# Default target — show help (avoid accidental mutation of $HOME via apply)
all: help

# ========================================
# Linting & formatting
# ========================================

## Run shellcheck, shfmt check, and zsh syntax check
lint:
	@echo "==> Running shellcheck..."
	@find home \( -name '*.sh' -o -name '*.sh.tmpl' \) ! -name 'symlink_*' | while read -r f; do \
		sed '/{{/d' "$$f" | shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086,SC2317,SC2329 -; \
	done
	@echo "==> Running shfmt check..."
	@find home \( -name '*.sh' -o -name '*.sh.tmpl' \) ! -name 'symlink_*' | while read -r f; do \
		sed '/{{/d' "$$f" | shfmt -d -i 2 -ci; \
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
test: lint test-bats

## Run Bats tests
test-bats:
	@bats tests/*.bats

## Run zsh startup benchmark
benchmark:
	@scripts/benchmark.sh

# ========================================
# Utilities
# ========================================

## Dump current brew packages to Brewfile
dump-brewfile:
	@rm -f home/dot_Brewfile
	@brew bundle dump --file home/dot_Brewfile
	@echo "Brewfile updated at home/dot_Brewfile"

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
