.DEFAULT_GOAL := help

# Worktree detection: directory name becomes the project name
WORKTREE_NAME := $(notdir $(CURDIR))
MAIN_NAME := specled_ex

# GNU make executes recipe lines that reference the special $(MAKE) variable
# even under -n/--dry-run. Use this alias for recursive invocations so dry-run
# stays side-effect free for worktree/bootstrap targets.
RECURSIVE_MAKE := $(MAKE)

.PHONY: help clean deps format test compile check xref \
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

test: ## Run the test suite (TEST=path[:line] for a targeted run)
	mix test $(TEST)

compile: ## Compile with warnings-as-errors
	mix compile --warnings-as-errors

# Forensic capture directory for the gate. A failing or timed-out verification
# command persists its full output — and, for a merged tagged_tests run, its
# attribution artifact — here; findings truncate that output and drop it
# entirely on timeout, so a flake that does not reproduce leaves no evidence
# without this. Gitignored.
#
# What keeps this directory holding gate evidence and nothing else is
# test/test_helper.exs, which unsets the variable inside the BEAM before
# ExUnit.start/0 — so the suite's deliberate command failures write nothing
# here however the variable reached them, plain shell or agent shell. That is
# the load-bearing half; remove it and this directory fills with noise.
#
# The `check:`-scoped export below is hygiene on top, not a second line of
# defence: it keeps a plain shell from carrying a gate variable at all.
# Removing it would not put noise in this directory.
#
# Override in the environment to relocate; CI sets its own.
SPECLED_COMMAND_OUTPUT_DIR ?= $(CURDIR)/tmp/specled-command-output

check: export SPECLED_COMMAND_OUTPUT_DIR := $(SPECLED_COMMAND_OUTPUT_DIR)
check: ## Run the spec verification gate (failing-command forensics land in tmp/specled-command-output)
	mix spec.check

# MIX_ENV=test pinned for CI parity: the test env compiles test/test_support/,
# so its xref graph is a superset of dev's — a dev-only pass can hide edges
# CI would reject.
xref: ## Fail on any compile-connected xref edge (CI runs this same target)
	MIX_ENV=test mix xref graph --label compile-connected --fail-above 0

# Worktree workflow

# Worktree workflow
include make/worktree.mk
