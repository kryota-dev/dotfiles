.PHONY: all lint test test-bats

# fixture 用の最小 Makefile。`dump-brewfile` target は意図的に存在しない
# （監査で見つかった乖離 1「存在しない Make target を案内していた」の再現に使う）。
all: lint

lint:
	@echo lint

test: lint test-bats
	@echo test

test-bats:
	@echo bats
