.PHONY: help lint fmt test
.DEFAULT_GOAL := help

SOURCE := $(CURDIR)/home
# 通常のシェルスクリプトと、描画してから lint するスクリプトのテンプレート。
SCRIPTS := install.sh $(shell find home -name '*.sh' -not -name '*.tmpl') home/dot_config/git/exact_hooks/executable_pre-commit
SCRIPT_TEMPLATES := $(wildcard home/run_*.sh.tmpl)
ZSH_FILES := home/dot_zshrc home/dot_zprofile $(wildcard home/dot_config/zsh/*.zsh)

help: ## このヘルプを表示する
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

lint: ## shellcheck・shfmt・zsh の構文・JSON・workflow を検査する
	shellcheck -s bash $(SCRIPTS)
	shfmt -d -i 2 -ci $(SCRIPTS)
	@for f in $(SCRIPT_TEMPLATES); do \
		echo "render $$f"; \
		chezmoi execute-template --source "$(SOURCE)" < "$$f" | shellcheck -s bash - || exit 1; \
	done
	@for f in $(ZSH_FILES); do zsh -n "$$f" || exit 1; done
	jq empty home/dot_claude/settings.json
	actionlint

fmt: ## シェルスクリプトを整形する
	shfmt -w -i 2 -ci $(SCRIPTS)

test: lint ## lint の後に bats のテストを実行する
	bats tests
