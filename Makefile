.PHONY: all apply init diff verify update watch test lint fmt benchmark dump-brewfile sync-ghq-completion help

# Default target
all: apply

# ========================================
# chezmoi operations
# ========================================

## Apply dotfiles with chezmoi
apply:
	@chezmoi apply -v

## Initialize chezmoi (first time or re-init)
init:
	@chezmoi init --source=$(CURDIR) --apply

## Show pending changes
diff:
	@chezmoi diff

## Verify no drift from desired state
verify:
	@chezmoi verify

## Pull remote changes and apply
update:
	@chezmoi update -v

# ========================================
# Development
# ========================================

## Watch for changes and auto-apply
watch:
	@echo "Watching for changes in home/..."
	@fswatch -o home/ | xargs -n1 -I{} chezmoi apply -v

## Re-lock sheldon plugins
sheldon-lock:
	@sheldon lock

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

# ========================================
# Testing
# ========================================

## Run all tests
test: lint test-bats

## Run shellcheck and shfmt
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

## Show shfmt formatting suggestions (template files need manual fixes)
fmt:
	@find home \( -name '*.sh' -o -name '*.sh.tmpl' \) ! -name 'symlink_*' | while read -r f; do \
		diff=$$(sed '/{{/d' "$$f" | shfmt -d -i 2 -ci 2>&1) && true; \
		if [ -n "$$diff" ]; then \
			echo "$$f needs formatting:"; \
			echo "$$diff"; \
			echo ""; \
		fi; \
	done
	@echo "Note: Template files (.tmpl) must be fixed manually due to chezmoi {{ }} syntax."

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

## Show help
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
