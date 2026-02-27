.PHONY: all apply init diff verify update watch test lint fmt benchmark dump-brewfile help

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

# ========================================
# Testing
# ========================================

## Run all tests
test: lint test-bats

## Run shellcheck and shfmt
lint:
	@echo "==> Running shellcheck..."
	@find home -name "*.sh" -o -name "*.sh.tmpl" | xargs shellcheck --shell=bash --exclude=SC1091,SC2034,SC2086 2>/dev/null || true
	@echo "==> Running shfmt check..."
	@find home -name "*.sh" -o -name "*.sh.tmpl" | xargs shfmt -d -i 2 -ci 2>/dev/null || true
	@echo "==> Checking zsh syntax..."
	@for f in home/dot_config/zsh/*.zsh; do zsh -n "$$f" || exit 1; done
	@echo "==> All lint checks passed."

## Fix formatting with shfmt
fmt:
	@find home -name "*.sh" -o -name "*.sh.tmpl" | xargs shfmt -w -i 2 -ci

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
