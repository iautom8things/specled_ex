.DEFAULT_GOAL := help

# Worktree detection: directory name becomes the project name
WORKTREE_NAME := $(notdir $(CURDIR))
MAIN_NAME := specled_ex

# GNU make executes recipe lines that reference the special $(MAKE) variable
# even under -n/--dry-run. Use this alias for recursive invocations so dry-run
# stays side-effect free for worktree/bootstrap targets.
RECURSIVE_MAKE := $(MAKE)

.PHONY: help clean deps format test compile check \
	worktree-new worktree-bootstrap worktree-info worktree-status \
	worktree-cleanup worktree-cleanup-all smoke \
	wts wti wtn wtb wtc wtca

define SPECLED
------------------------------
          specled
------------------------------
endef
export SPECLED

# General
help: ## Show this help
	@echo "$$SPECLED"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

clean: ## Remove build artifacts
	rm -rf _build deps

deps: ## Install dependencies
	mix deps.get

format: ## Format the project
	mix format

test: ## Run the test suite
	mix test

compile: ## Compile with warnings-as-errors
	mix compile --warnings-as-errors

check: ## Run the spec verification gate
	mix spec.check

# Worktree workflow

# Worktree workflow
include make/worktree.mk
