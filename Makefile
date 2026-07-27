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
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

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

# Forensic capture directory for the gate. A failing or timed-out verification
# command persists its full output — and, for a merged tagged_tests run, its
# attribution artifact — here; findings truncate that output and drop it
# entirely on timeout, so a flake that does not reproduce leaves no evidence
# without this. Gitignored.
#
# This file exports it for `check` only, so `make test` from a plain shell adds
# nothing. That is a property of this file alone, not of every environment:
# .claude/settings.json arms the same variable for agent shells globally, so
# `make test` THERE does deposit a log per deliberate command failure in the
# suite. Harmless — gitignored, and the capture never alters a result — but do
# not read this export as a guarantee that only the gate writes here.
#
# Override in the environment to relocate; CI sets its own.
SPECLED_COMMAND_OUTPUT_DIR ?= $(CURDIR)/tmp/specled-command-output

check: export SPECLED_COMMAND_OUTPUT_DIR := $(SPECLED_COMMAND_OUTPUT_DIR)
check: ## Run the spec verification gate (failing-command forensics land in tmp/specled-command-output)
	mix spec.check

# Worktree workflow

# Worktree workflow
include make/worktree.mk
