# Do everything.
all: init link defaults brew setup other_apps

# Set initial preference.
init:
	@echo "\033[0;34mRun init.sh\033[0m"
	@.bin/init.sh
	@echo "\033[0;34mDone.\033[0m"

# Link dotfiles.
link:
	@echo "\033[0;34mRun link.sh\033[0m"
	@.bin/link.sh
	@echo "\033[0;32mDone.\033[0m"

# Install macOS applications.
brew:
	@echo "\033[0;34mRun brew.sh\033[0m"
	@.bin/brew.sh
	@echo "\033[0;32mDone.\033[0m"

# Setup tools.
setup:
	@echo "\033[0;34mRun setup.sh\033[0m"
	@.bin/setup.sh
	@echo "\033[0;32mDone.\033[0m"
