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
	@version=$$(grep -E '^ghq[[:space:]]*=' home/dot_config/mise/config.toml | sed -E 's/.*"([^"]+)".*/\1/'); \
	if [ -z "$$version" ]; then \
		echo "ERROR: Could not extract ghq version from home/dot_config/mise/config.toml"; \
		exit 1; \
	fi; \
	if ! printf '%s' "$$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "ERROR: Unexpected ghq version format: $$version"; \
		exit 1; \
	fi; \
	echo "Syncing _ghq from x-motemen/ghq@v$$version..."; \
	url="https://raw.githubusercontent.com/x-motemen/ghq/v$$version/misc/zsh/_ghq"; \
	tmpfile=$$(mktemp); \
	if ! curl -fsSL "$$url" -o "$$tmpfile"; then \
		echo "ERROR: failed to fetch $$url"; \
		rm -f "$$tmpfile"; \
		exit 1; \
	fi; \
	mkdir -p home/dot_config/zsh/completions; \
	{ \
		head -n1 "$$tmpfile"; \
		echo "# vendored: x-motemen/ghq@v$$version misc/zsh/_ghq"; \
		echo "# Run 'make sync-ghq-completion' to refresh."; \
		tail -n +2 "$$tmpfile"; \
	} > home/dot_config/zsh/completions/_ghq; \
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
